/// 视频地址提取器：从 HTML 的 `<video>` / `<iframe>` / `<source>` 标签与
/// `<script>` 内嵌播放器数据中抽取视频直链或嵌入页 URL。
///
/// 同时提供顶层函数 [extractFromVideoTag] 作为简洁入口。
library;

import 'dart:convert';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

/// 从 HTML 提取出的单个视频信息。
class ExtractedVideo {
  /// 视频 URL（直链或嵌入页 URL），已基于 baseUrl 解析为绝对地址。
  final String url;

  /// 类型：`hls` / `video/mp4` / `embed` / `unknown` 等。
  final String type;

  /// `<video poster>` 海报图 URL（可选）。
  final String? poster;

  /// 嵌入来源标识（`youtube` / `bilibili` / ...），仅 type == `embed` 时有值。
  final String? source;

  const ExtractedVideo({
    required this.url,
    required this.type,
    this.poster,
    this.source,
  });

  @override
  String toString() {
    return 'ExtractedVideo(url: $url, type: $type, poster: $poster, '
        'source: $source)';
  }
}

/// 从 HTML 提取视频地址。
///
/// 依次扫描 `<video src>`、`<video><source>`、`<iframe src>`、独立 `<source>`
/// 标签，返回去重后的 [ExtractedVideo] 列表（保持出现顺序）。
class VideoExtractor {
  /// 从 [html] 提取视频地址列表。
  ///
  /// [baseUrl] 用于将相对 URL 解析为绝对 URL。
  static List<ExtractedVideo> extract(String html, {String? baseUrl}) {
    final document = html_parser.parse(html);
    final videos = <ExtractedVideo>[];
    final seen = <String>{};

    _extractFromVideoTags(document, baseUrl, videos, seen);
    // script 内嵌播放器数据优先于 iframe：很多站（MacCMS 模板等）把真实
    // 播放地址写在 `<script>var player_xxx={...}</script>` 里，而页面上的
    // `<video>` 标签在跨域 iframe 播放器内部，WebView getHtml 拿不到——
    // 只扫标签会漏掉（「无法解析到视频」0×0 黑屏的根因）。此扫描是引擎
    // 通用能力（协议级模式），不针对任何特定站点。
    _extractFromScripts(document, baseUrl, videos, seen);
    _extractFromIframes(document, baseUrl, videos, seen);
    _extractFromSourceTags(document, baseUrl, videos, seen);

    return videos;
  }

  /// 提取 `<video src>` 与 `<video><source src>` 标签。
  static void _extractFromVideoTags(
    Document document,
    String? baseUrl,
    List<ExtractedVideo> videos,
    Set<String> seen,
  ) {
    final videoElements = document.querySelectorAll('video[src]');
    for (final el in videoElements) {
      final src = el.attributes['src'];
      if (src == null || src.isEmpty) continue;

      final resolved = _resolveUrl(src, baseUrl);
      if (seen.contains(resolved)) continue;
      seen.add(resolved);

      final poster = el.attributes['poster'];

      videos.add(ExtractedVideo(
        url: resolved,
        type: _guessType(src),
        poster: poster != null ? _resolveUrl(poster, baseUrl) : null,
      ));
    }

    final sourceElements = document.querySelectorAll('video source[src]');
    for (final el in sourceElements) {
      final src = el.attributes['src'];
      if (src == null || src.isEmpty) continue;

      final resolved = _resolveUrl(src, baseUrl);
      if (seen.contains(resolved)) continue;
      seen.add(resolved);

      final type = el.attributes['type'] ?? _guessType(src);

      videos.add(ExtractedVideo(url: resolved, type: type));
    }
  }

  /// 提取 `<script>` 内嵌播放器数据中的视频地址（引擎通用，协议级模式）。
  ///
  /// 两类通用模式，按优先级：
  /// 1. MacCMS 播放器变量：`var player_xxxx = {"url":"...","encrypt":N,...}`
  ///    ——MacCMS 是国内影视/动漫站最常见的建站程序，其播放页统一把地址放在
  ///    该 JSON 的 `url` 字段（`encrypt`：0/缺省=明文，1=urlencode，
  ///    2=base64(urlencode)）。
  /// 2. 任意脚本文本中的裸直链：`https?://....m3u8|mp4`（含 `\/` 转义形式）。
  static void _extractFromScripts(
    Document document,
    String? baseUrl,
    List<ExtractedVideo> videos,
    Set<String> seen,
  ) {
    final scripts = document.querySelectorAll('script');
    final buffer = StringBuffer();
    for (final el in scripts) {
      if (el.attributes.containsKey('src')) continue; // 只看内联脚本
      buffer.writeln(el.text);
    }
    final text0 = buffer.toString();
    if (text0.isEmpty) return;

    // 预归一化：JS 字符串里常见的转义斜杠 `\/` 还原为 `/`。否则裸直链正则与
    // 播放器 URL 在路径段会被反斜杠截断（例如 `https:\/\/host\/path.m3u8`）。
    final text = text0.replaceAll('\\/', '/');

    // —— 模式1：player_xxx = { ... "url":"..." ... } ——
    // 用 `\{[^{}]*\}` 而非 `\{.*?\}`：MacCMS player 对象是扁平 JSON（不含嵌套
    // 花括号），精准截到对象结尾，避免跨语句多捕获。
    final playerRe = RegExp(
      r'player_\w+\s*=\s*(\{[^{}]*\})\s*(?:<|;|\n|$)',
      dotAll: true,
    );
    for (final m in playerRe.allMatches(text)) {
      final jsonText = m.group(1)!;
      String? url;
      int encrypt = 0;
      try {
        final obj = jsonDecode(jsonText);
        if (obj is Map) {
          final u = obj['url'];
          if (u is String && u.isNotEmpty) url = u;
          final e = obj['encrypt'];
          if (e is int) encrypt = e;
          if (e is String) encrypt = int.tryParse(e) ?? 0;
        }
      } on Object {
        // 非严格 JSON（单引号/尾逗号等）：退化用正则抠 url 字段。
        final um = RegExp(r'''["']url["']\s*:\s*["']([^"']+)["']''')
            .firstMatch(jsonText);
        url = um?.group(1);
        final em = RegExp(r'''["']encrypt["']\s*:\s*["']?(\d+)''')
            .firstMatch(jsonText);
        encrypt = int.tryParse(em?.group(1) ?? '') ?? 0;
      }
      if (url == null || url.isEmpty) continue;
      final decoded = _decodePlayerUrl(url, encrypt);
      if (decoded.isEmpty) continue;
      // MacCMS 的 player.url 可能是「加密 token」而非可直接播放的地址（如 233 动漫
      // 的 player_aaaa.url 解出后是 32 位 hex，需经外域播放器页 playData 再解密）。
      // 这类值不是媒体 URL，若当作直链喂给播放器只会拿到一堆乱码字节而黑屏。
      // 这里只接受「看起来像可播放媒体」的解码结果（绝对 http(s) 且带 m3u8/mp4/
      // webm 后缀），否则跳过，让更合适的通道（webview 抽取脚本）去解析真实地址。
      final looksPlayable = RegExp(
        r'^https?://.+?\.(m3u8|mp4|webm)(\?|$|#)',
        caseSensitive: false,
      ).hasMatch(decoded);
      if (!looksPlayable) continue;
      final resolved = _resolveUrl(decoded.replaceAll(r'\/', '/'), baseUrl);
      if (!resolved.startsWith('http')) continue;
      if (seen.contains(resolved)) continue;
      seen.add(resolved);
      videos.add(ExtractedVideo(url: resolved, type: _guessType(resolved)));
    }

    // —— 模式2：脚本文本中的裸 m3u8/mp4 直链（含 \/ 转义） ——
    final rawRe = RegExp(
      r'''https?:(?:\\/|/){2}[^"'\s\\<>]+?\.(?:m3u8|mp4)[^"'\s\\<>]*''',
    );
    for (final m in rawRe.allMatches(text)) {
      final resolved = m.group(0)!.replaceAll(r'\/', '/');
      if (seen.contains(resolved)) continue;
      seen.add(resolved);
      videos.add(ExtractedVideo(url: resolved, type: _guessType(resolved)));
    }
  }

  /// 按 MacCMS `encrypt` 约定解码播放地址：1=urlencode，2=base64(urlencode)。
  /// 解码失败时返回原文（明文直链场景）。
  static String _decodePlayerUrl(String url, int encrypt) {
    try {
      if (encrypt == 1) return Uri.decodeComponent(url);
      if (encrypt == 2) {
        final b64 = utf8.decode(base64.decode(base64.normalize(url)));
        return Uri.decodeComponent(b64);
      }
    } on Object {
      // 解码失败按明文处理。
    }
    return url;
  }

  /// 提取 `<iframe src>` 中的视频嵌入页 URL。
  static void _extractFromIframes(
    Document document,
    String? baseUrl,
    List<ExtractedVideo> videos,
    Set<String> seen,
  ) {
    final iframes = document.querySelectorAll('iframe[src]');
    for (final el in iframes) {
      final src = el.attributes['src'];
      if (src == null || src.isEmpty) continue;

      final resolved = _resolveUrl(src, baseUrl);
      if (seen.contains(resolved)) continue;
      seen.add(resolved);

      if (_isVideoEmbed(resolved)) {
        videos.add(ExtractedVideo(
          url: resolved,
          type: 'embed',
          source: _detectEmbedSource(resolved),
        ));
      }
    }
  }

  /// 提取独立 `<source src>` 标签（非 `<video>` 内的）。
  static void _extractFromSourceTags(
    Document document,
    String? baseUrl,
    List<ExtractedVideo> videos,
    Set<String> seen,
  ) {
    final sources = document.querySelectorAll('source[src]');
    for (final el in sources) {
      final src = el.attributes['src'];
      if (src == null || src.isEmpty) continue;

      final resolved = _resolveUrl(src, baseUrl);
      if (seen.contains(resolved)) continue;
      seen.add(resolved);

      videos.add(ExtractedVideo(
        url: resolved,
        type: el.attributes['type'] ?? _guessType(src),
      ));
    }
  }

  /// 根据 URL 后缀猜测视频类型。
  static String _guessType(String url) {
    if (url.contains('.m3u8') || url.contains('hls')) return 'hls';
    if (url.contains('.mp4')) return 'video/mp4';
    if (url.contains('.webm')) return 'video/webm';
    if (url.contains('.mkv')) return 'video/x-matroska';
    return 'unknown';
  }

  /// URL 是否为已知视频嵌入站。
  static bool _isVideoEmbed(String url) {
    const videoDomains = [
      'youtube.com',
      'youtu.be',
      'vimeo.com',
      'bilibili.com',
      'player.bilibili.com',
      'dailymotion.com',
      'twitch.tv',
    ];
    return videoDomains.any((d) => url.contains(d));
  }

  /// 识别嵌入站来源。
  static String _detectEmbedSource(String url) {
    if (url.contains('youtube.com') || url.contains('youtu.be')) return 'youtube';
    if (url.contains('vimeo.com')) return 'vimeo';
    if (url.contains('bilibili.com')) return 'bilibili';
    if (url.contains('dailymotion.com')) return 'dailymotion';
    if (url.contains('twitch.tv')) return 'twitch';
    return 'unknown';
  }

  /// 将相对 URL 基于 baseUrl 解析为绝对 URL。
  static String _resolveUrl(String url, String? baseUrl) {
    if (url.startsWith('http://') || url.startsWith('https://')) return url;
    if (baseUrl == null) return url;
    if (url.startsWith('//')) {
      final baseUri = Uri.parse(baseUrl);
      return '${baseUri.scheme}:$url';
    }
    if (url.startsWith('/')) {
      final baseUri = Uri.parse(baseUrl);
      return '${baseUri.scheme}://${baseUri.host}$url';
    }
    return '$baseUrl/$url';
  }
}

/// 从 HTML 的 `<video>` / `<iframe>` / `<source>` 标签提取视频 URL。
///
/// 等价于 [VideoExtractor.extract]，返回 [ExtractedVideo] 列表。
List<ExtractedVideo> extractFromVideoTag(String html, {String? baseUrl}) {
  return VideoExtractor.extract(html, baseUrl: baseUrl);
}

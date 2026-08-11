/// 视频下载「先嗅探真实地址、再下载字节」的核心：后台无界面 WebView 嗅探器。
///
/// 与播放器的嗅探/WebView 解析同源（复用 [SnifferEngine] / [SnifferBridge] /
/// `assets/sniffer/sniffer_hook.js`），但运行在 [HeadlessInAppWebView] 中，
/// 不打断用户、不弹页面，可在下载管线（主隔离域）里被静默调用。
///
/// 解析优先级（对齐播放器 `_resolveVideoWithCapture`）：
/// 1. 直连解析快路径 [MediaApiService.fetchVideoUrl]：多数源直接拿到直链 / m3u8，
///    不加载 WebView，最快；
/// 2. 若快路径抛出 [WebViewExtractionRequest]（jsExtractor）/ [WebViewHtmlRequest]
///    （渲染后抽取）→ 拉起一个无界面 WebView 处理；
/// 3. 若快路径返回非媒体地址 / 抛其它异常 → 通用嗅探兜底（加载播放页捕获真实直链）。
library;

import 'dart:async';
import 'dart:collection' show UnmodifiableListView;
import 'dart:convert' show jsonDecode;

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../models/plugin_config.dart';
import '../models/episode.dart' show VideoLine, VideoResult;
import '../resolver/webview_resolver.dart'
    show WebViewExtractionRequest, WebViewHtmlRequest;
import '../scraper/media_api_service.dart';
import '../sniffer/sniffer_bridge.dart' show SnifferBridge;
import '../utils/app_log.dart';
import '../sniffer/sniffer_engine.dart' show SnifferEngine;
import '../sniffer/sniffer_models.dart' show SniffedMedia, SniffFilter;

/// 嗅探得到的可下载视频直链。
class SniffedVideoLink {
  final String url;

  /// 解析器给出的类型（mp4 / m3u8 / dash …），可空。
  final String? type;

  /// 下载该地址所需的防盗链请求头（Referer 等）。
  final Map<String, String>? headers;

  /// 同源备用线路（替代播放列表 / CDN 镜像）。
  final List<VideoLine> lines;

  SniffedVideoLink({
    required this.url,
    this.type,
    this.headers,
    this.lines = const <VideoLine>[],
  }) : isHls = _isHls(url, type);

  final bool isHls;

  static bool _isHls(String url, String? type) {
    final l = url.toLowerCase();
    if (l.contains('.m3u8') || l.contains('.mpd')) return true;
    final t = type?.toLowerCase();
    return t == 'm3u8' || t == 'hls' || t == 'dash' || t == 'mpd';
  }
}

/// 后台静默视频地址嗅探器。
class VideoLinkSniffer {
  /// 解析单集的真实下载地址。
  ///
  /// [timeout] 为单次无界面 WebView 嗅探/抽取的上限；超时未拿到地址返回 null。
  static Future<SniffedVideoLink?> resolveEpisode(
    MediaApiService service,
    PluginConfig source,
    String episodeUrl, {
    Duration timeout = const Duration(seconds: 25),
  }) async {
    // 1) 直连解析快路径：不加载 WebView，最快。
    try {
      final vr = await service.fetchVideoUrl(source, episodeUrl);
      final link = _fromVideoResult(vr);
      if (link != null) {
        AppLog.instance.d('[嗅探] 直连解析命中: ${link.url}');
        return link;
      }
      // 返回的是网页等非媒体地址 → 落通用嗅探兜底。
    } on WebViewHtmlRequest catch (e) {
      return _resolveViaWebView(
        service, source, episodeUrl, e.url, e.headers,
        timeout: timeout,
      );
    } on WebViewExtractionRequest catch (e) {
      return _resolveViaWebView(
        service, source, episodeUrl, e.url, e.headers,
        jsExtractor: e.jsExtractor, timeout: timeout,
      );
    } on Object catch (e) {
      AppLog.instance.w('[嗅探] 直连解析异常，转通用嗅探: $e');
    }

    // 2) 通用嗅探兜底：加载播放页，靠嗅探链路捕获真实直链。
    final pageUrl = _absolutePageUrl(source, episodeUrl);
    if (pageUrl == null) return null;
    return _resolveViaWebView(
      service, source, episodeUrl, pageUrl, source.site.headers,
      timeout: timeout,
    );
  }

  /// 用单个无界面 WebView 处理「需要 WebView 才能拿到地址」的源。
  ///
  /// - [jsExtractor] 非空：在已加载页面内执行抽取脚本拿直链（MacCMS 等）；
  /// - [jsExtractor] 为空：取回渲染后整页 HTML 回填解析（webview-html 源）；
  /// - 手动解析未命中时，回退到通用嗅探（同一 WebView，捕获首个 http 视频直链）。
  static Future<SniffedVideoLink?> _resolveViaWebView(
    MediaApiService service,
    PluginConfig source,
    String episodeUrl,
    String loadUrl,
    Map<String, String>? headers, {
    String? jsExtractor,
    Duration timeout = const Duration(seconds: 25),
  }) async {
    final hookJs = await _loadHookJs();
    final sniffer = _HeadlessSniffer();
    final capture = Completer<SniffedMedia?>();
    sniffer.engine.onUpdate = () {
      for (final m in sniffer.videos) {
        if (m.url.startsWith('http://') || m.url.startsWith('https://')) {
          if (!capture.isCompleted) capture.complete(m);
          break;
        }
      }
    };

    try {
      await sniffer.load(loadUrl, headers, hookJs);
    } on Object {
      if (!capture.isCompleted) capture.complete(null);
    }

    final timer = Timer(timeout, () {
      if (!capture.isCompleted) capture.complete(null);
    });

    // 先尝试「源声明的手动解析」（抽取脚本 / 渲染后 HTML）。
    SniffedVideoLink? manual;
    if (jsExtractor != null && jsExtractor.isNotEmpty) {
      for (var attempt = 0; attempt < 5 && manual == null; attempt++) {
        try {
          final raw = await sniffer.eval(jsExtractor);
          final url = _parseExtractedResult(raw);
          if (url != null && url.isNotEmpty) {
            manual = SniffedVideoLink(url: url, headers: headers);
            break;
          }
        } on Object {
          // decrypt() 可能尚未就绪，稍后重试。
        }
        await Future<void>.delayed(const Duration(milliseconds: 600));
      }
    } else {
      try {
        final html = await sniffer.getHtml();
        if (html != null && html.isNotEmpty) {
          final vr = await service.fetchVideoUrl(
            source,
            episodeUrl,
            renderedHtml: html,
          );
          manual = _fromVideoResult(vr);
        }
      } on Object {
        // 渲染后解析失败 → 落通用嗅探。
      }
    }

    if (manual != null) {
      timer.cancel();
      await sniffer.dispose();
      AppLog.instance.d('[嗅探] WebView 手动解析命中: ${manual.url}');
      return manual;
    }

    // 手动解析未中 → 等通用嗅探捕获（同一 WebView）。
    final media = await capture.future;
    timer.cancel();
    await sniffer.dispose();
    if (media == null) return null;
    return SniffedVideoLink(
      url: media.url,
      headers: _refHeaders(media.referer),
    );
  }

  /// 把 [VideoResult] 转成可下载链接；明显是网页（非媒体）则返回 null 让上层嗅探。
  static SniffedVideoLink? _fromVideoResult(VideoResult vr) {
    final url = vr.url;
    if (url.isEmpty) return null;
    final lower = url.toLowerCase();
    if (lower.endsWith('.html') ||
        lower.endsWith('.php') ||
        lower.endsWith('.asp') ||
        lower.endsWith('.aspx')) {
      return null;
    }
    return SniffedVideoLink(
      url: url,
      type: vr.type,
      headers: vr.headers,
      lines: vr.lines,
    );
  }

  /// 解析 jsExtractor 回传结果（对齐播放器 `_parseExtractedResult`）。
  static String? _parseExtractedResult(dynamic result) {
    if (result == null) return null;
    if (result is String) {
      final trimmed = result.trim();
      if (trimmed.isEmpty) return null;
      if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
        return trimmed;
      }
      try {
        return _parseExtractedResult(jsonDecode(trimmed));
      } on Object {
        return null;
      }
    }
    if (result is List) {
      for (final item in result) {
        final parsed = _parseExtractedResult(item);
        if (parsed != null && parsed.isNotEmpty) return parsed;
      }
      return null;
    }
    if (result is Map) {
      const keys = <String>['url', 'src', 'video', 'file', 'source', 'link'];
      for (final key in keys) {
        final value = result[key];
        if (value is String && value.startsWith('http')) return value;
        if (value is List || value is Map) {
          final parsed = _parseExtractedResult(value);
          if (parsed != null && parsed.isNotEmpty) return parsed;
        }
      }
      return null;
    }
    return null;
  }

  static Map<String, String>? _refHeaders(String? ref) =>
      (ref != null && ref.isNotEmpty) ? <String, String>{'Referer': ref} : null;

  static String? _absolutePageUrl(PluginConfig source, String url) {
    if (url.startsWith('http://') || url.startsWith('https://')) return url;
    final base = source.site.baseUrl;
    if (base.isEmpty) return null;
    return Uri.tryParse(base)?.resolve(url).toString();
  }

  static Future<String> _loadHookJs() async {
    try {
      return await rootBundle.loadString('assets/sniffer/sniffer_hook.js');
    } on Object {
      return '';
    }
  }
}

/// 单例无界面 WebView 包装：加载页面、接线嗅探桥、提供抽取/取 HTML 能力。
class _HeadlessSniffer {
  final SnifferEngine engine = SnifferEngine();
  late final SnifferBridge bridge = SnifferBridge(engine);
  HeadlessInAppWebView? _wv;
  final Completer<InAppWebViewController> _created =
      Completer<InAppWebViewController>();

  Future<InAppWebViewController> load(
    String url,
    Map<String, String>? headers,
    String hookJs,
  ) async {
    _wv = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(url), headers: headers),
      initialUserScripts:
          UnmodifiableListView(<UserScript>[SnifferBridge.userScript(hookJs)]),
      onWebViewCreated: (c) {
        bridge.attach(c);
        if (!_created.isCompleted) _created.complete(c);
      },
      onLoadResource: (c, r) => bridge.onResource(r.url?.toString()),
      onLoadStart: (c, uri) => bridge.onRequest(uri?.toString(), _referer(headers)),
      onLoadStop: (c, uri) async {
        // 加载完成后 DOM 深度扫描，扩大召回（对齐播放器嗅探模式）。
        await bridge.deepScan();
      },
    );
    await _wv!.run();
    return _created.future;
  }

  List<SniffedMedia> get videos => engine.filtered(SniffFilter.video);

  Future<String?> getHtml() async => (await _created.future).getHtml();

  Future<dynamic> eval(String js) async =>
      (await _created.future).evaluateJavascript(source: js);

  Future<void> dispose() async {
    try {
      await _wv?.dispose();
    } on Object {
      // best-effort
    }
  }

  static String? _referer(Map<String, String>? headers) {
    if (headers == null) return null;
    return headers['Referer'] ?? headers['referer'];
  }
}

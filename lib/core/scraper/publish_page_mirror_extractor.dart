/// 发布页镜像提取器：从源声明 [SiteConfig.publishPageUrl] 抓取 HTML，
/// 按 [SiteConfig.publishMirrorSelector]（正则）或通用 URL 正则提取候选镜像。
///
/// 用途：站点主域失效时，发布页通常列出最新可用镜像地址。本提取器把发布页
/// 上的绝对 http(s) 链接解析为 [MirrorConfig]，交由 UI 让用户勾选导入。
library;

import '../models/plugin_config.dart';
import 'http_fetcher.dart';

/// 判断 [selector] 是否「看起来像正则」：以 `/` 开头（JS 正则字面量写法）
/// 或包含正则元字符。
bool _looksLikeRegex(String selector) {
  if (selector.isEmpty) return false;
  if (selector.startsWith('/')) return true;
  // 常见正则元字符集合
  return RegExp(r'[\\[\]{}()*+?|^$.]').hasMatch(selector);
}

/// 从 JS 风格正则字面量 `/pattern/flags` 中取出 pattern 部分。
String _stripRegexDelimiters(String selector) {
  var s = selector;
  if (s.startsWith('/')) s = s.substring(1);
  final lastSlash = s.lastIndexOf('/');
  if (lastSlash > 0) s = s.substring(0, lastSlash);
  return s;
}

class PublishPageMirrorExtractor {
  /// 抓取 [publishPageUrl] 并提取候选镜像列表。
  ///
  /// 内部通过 [HttpFetcher.instance.getHtml] 获取 HTML，再委托
  /// [extractFromHtml] 解析。失败时抛出底层异常，由调用方捕获。
  Future<List<MirrorConfig>> extract(
    String publishPageUrl, {
    String? selector,
  }) async {
    final html = await HttpFetcher.instance.getHtml(publishPageUrl);
    return extractFromHtml(
      html,
      publishPageUrl: publishPageUrl,
      selector: selector,
    );
  }

  /// 从已抓取的 HTML 中提取候选镜像（纯解析，无网络依赖，便于测试）。
  ///
  /// - [selector] 为空时使用通用 URL 正则提取所有绝对 http(s) 链接，
  ///   排除与发布页同 host 的链接，按 host 去重。
  /// - [selector] 看起来像正则时（以 `/` 开头或含元字符），用它匹配 HTML，
  ///   命中的字符串作为候选 URL（优先取首个捕获组）。
  ///
  /// 返回结果按 baseUrl 去重，可能为空列表。
  List<MirrorConfig> extractFromHtml(
    String html, {
    String? publishPageUrl,
    String? selector,
  }) {
    if (html.isEmpty) return const <MirrorConfig>[];

    final String? publishHost =
        publishPageUrl == null ? null : _safeHost(publishPageUrl);
    final candidateUrls = <String>{};

    final effectiveSelector = selector?.trim() ?? '';
    if (effectiveSelector.isNotEmpty && _looksLikeRegex(effectiveSelector)) {
      final pattern = effectiveSelector.startsWith('/')
          ? _stripRegexDelimiters(effectiveSelector)
          : effectiveSelector;
      try {
        final regExp = RegExp(pattern);
        for (final match in regExp.allMatches(html)) {
          // 优先取首个捕获组（用户正则常把 URL 放在分组里），否则取整段匹配。
          final url = match.groupCount >= 1
              ? (match.group(1) ?? '')
              : (match.group(0) ?? '');
          if (url.isNotEmpty && _isHttpUrl(url)) {
            candidateUrls.add(url.trim());
          }
        }
      } catch (_) {
        // 正则编译失败：回退到通用提取。
      }
    }

    // 通用兜底：若正则模式未命中任何候选，则用通用 URL 正则提取。
    if (candidateUrls.isEmpty) {
      final urlRegex = RegExp(r'''https?://[^\s"'<>\\\]^`{|}]+''');
      for (final match in urlRegex.allMatches(html)) {
        final raw = (match.group(0) ?? '').trim();
        final cleaned = _stripTrailingPunct(raw);
        if (_isHttpUrl(cleaned)) candidateUrls.add(cleaned);
      }
    }

    // 按 host 去重，排除与发布页同 host 的链接，构造 MirrorConfig。
    final seenHosts = <String>{};
    final result = <MirrorConfig>[];
    for (final url in candidateUrls) {
      final uri = Uri.tryParse(url);
      if (uri == null || !uri.hasScheme) continue;
      if (uri.scheme != 'http' && uri.scheme != 'https') continue;
      final host = uri.host;
      if (host.isEmpty) continue;
      if (publishHost != null &&
          host.toLowerCase() == publishHost.toLowerCase()) {
        continue;
      }
      if (!seenHosts.add(host.toLowerCase())) continue;
      final baseUrl = uri.origin;
      result.add(MirrorConfig(
        name: host,
        domain: host,
        baseUrl: baseUrl,
      ));
    }
    return result;
  }

  /// 安全解析 [url] 的 host，失败返回 null。
  String? _safeHost(String url) {
    try {
      final uri = Uri.parse(url);
      return uri.host.isEmpty ? null : uri.host;
    } catch (_) {
      return null;
    }
  }

  bool _isHttpUrl(String s) =>
      s.startsWith('http://') || s.startsWith('https://');

  /// 去除 URL 尾部可能粘连的标点（如 `.`、`,`、`)`、`;`）。
  String _stripTrailingPunct(String url) {
    var s = url;
    while (s.isNotEmpty && '.,;:)]}>\'"'.contains(s[s.length - 1])) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }
}

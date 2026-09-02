/// 站点 HTML 自动发现订阅源（RSS / Atom）。
///
/// 用户输入一个网站地址（如 `https://example.com`），本服务：
/// 1. 抓首页 HTML，抽取 `<link rel="alternate" type="application/rss+xml">`
///    这类 feed 声明标签，按站点地址把相对 href 解析成绝对地址；
/// 2. 若首页没声明（不少站点漏写），再按常见 feed 路径探测
///    （`/feed`、`/rss`、`/atom.xml` …），能解析成合法 feed 的才算候选。
///
/// 网络请求一律由调用方通过 [HttpFetcher] 发起并传入 `net`（代理/SNI/DNS/hosts
/// 才生效），本类只做纯解析，不碰网络。
library;

import 'rss_parser.dart';

/// 一个发现的候选订阅源。
class RssFeedCandidate {
  /// 绝对地址的 feed 链接。
  final String url;

  /// 来源声明的标题（可能为 null）。
  final String? title;

  /// feed 类型：`rss` / `atom` / `rdf`（用于 UI 角标）。
  final String type;

  /// 候选来源：`link` = 首页声明标签，`probe` = 常见路径探测。
  final String source;

  const RssFeedCandidate({
    required this.url,
    required this.type,
    required this.source,
    this.title,
  });
}

/// 从站点 HTML 中发现订阅源（纯解析，无网络）。
class RssFeedDiscovery {
  RssFeedDiscovery._();

  /// 常见 feed 路径（首页没声明时的兜底探测顺序）。
  static const List<String> commonPaths = <String>[
    '/feed',
    '/feed/',
    '/rss',
    '/rss.xml',
    '/feed.xml',
    '/atom.xml',
    '/index.xml',
    '/rss/',
    '/feed/atom',
    '/blog/feed',
  ];

  static final RegExp _linkTag =
      RegExp(r'<link\b[^>]*>', caseSensitive: false);
  static final RegExp _attr = RegExp(
    r'''([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)')''',
  );

  /// 从首页 HTML 抽取 feed 声明。
  ///
  /// [html] 首页源码；[baseUrl] 站点地址（用于把相对 href 解析为绝对地址）。
  /// 只认 `rel` 含 `alternate` 且 `type` 是 feed MIME 的 `<link>`。
  static List<RssFeedCandidate> fromHtml(String html, String baseUrl) {
    final base = Uri.tryParse(baseUrl);
    final found = <RssFeedCandidate>[];
    final seen = <String>{};

    for (final match in _linkTag.allMatches(html)) {
      final tag = match.group(0)!;
      final attrs = <String, String>{};
      for (final a in _attr.allMatches(tag)) {
        final name = a.group(1)!.toLowerCase();
        final value = a.group(2) ?? a.group(3) ?? '';
        attrs[name] = _unescape(value);
      }

      final rel = (attrs['rel'] ?? '').toLowerCase();
      final type = (attrs['type'] ?? '').toLowerCase();
      final href = (attrs['href'] ?? '').trim();
      if (!rel.contains('alternate') || href.isEmpty) continue;
      if (!_isFeedType(type)) continue;

      final absolute = base != null ? base.resolve(href).toString() : href;
      if (!seen.add(absolute)) continue;

      found.add(RssFeedCandidate(
        url: absolute,
        title: (attrs['title'] ?? '').trim().isEmpty ? null : attrs['title']!.trim(),
        type: _typeLabel(type),
        source: 'link',
      ));
    }
    return found;
  }

  /// 判断抓到的文本是不是一个能解析的 feed；是则返回其标题。
  ///
  /// 用于常见路径探测：抓取候选 URL 后调用本方法验证，
  /// 避免把 404 页面 / 站点首页误当成订阅源。
  static String? validateFeedText(String text) {
    try {
      final parsed = RssParser.parse(text);
      if (parsed.items.isEmpty) return null;
      return parsed.title;
    } on Object {
      return null;
    }
  }

  static bool _isFeedType(String type) {
    return type == 'application/rss+xml' ||
        type == 'application/atom+xml' ||
        type == 'application/rdf+xml' ||
        type == 'application/rss' ||
        type == 'application/atom' ||
        type == 'text/xml' ||
        type == 'application/xml';
  }

  static String _typeLabel(String type) {
    if (type.contains('atom')) return 'atom';
    if (type.contains('rdf')) return 'rdf';
    return 'rss';
  }

  /// 根据 URL 猜测 feed 类型（探测兜底用，无法 100% 准确）。
  static String typeFromUrl(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('atom')) return 'atom';
    if (lower.contains('rdf')) return 'rdf';
    return 'rss';
  }

  /// 反转义 XML 属性里的常见实体（&amp; 等），避免链接带 & 时解析错。
  static String _unescape(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'");
}

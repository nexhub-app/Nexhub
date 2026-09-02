/// RSS / Atom / RDF(RSS 1.0) / JSON Feed 解析器（文档 §10.2）。
///
/// 支持 RSS 2.0、Atom 1.0、RDF(RSS 1.0) 三种 XML 格式与 JSON Feed 1.1。
/// 使用 `xml` 包解析 XML，`dart:convert` 解析 JSON Feed。
library;

import 'dart:convert';

import 'package:xml/xml.dart';

import 'rss_feed.dart';

/// 解析 RSS/Atom/RDF/JSON Feed 文本为 [ParsedFeed]。
class RssParser {
  /// 解析文本。
  ///
  /// 自动检测格式：JSON Feed（以 `{` 开头且含 jsonfeed 版本/items）→
  /// RSS 2.0（根 `<rss>`）→ Atom（根 `<feed>`）→ RDF/RSS 1.0（根 `<rdf:RDF>`）。
  static ParsedFeed parse(String xmlText) {
    // BOM 剥除必须最先：带 BOM 的 feed 直接进 XML 解析会整篇失败（标准解析器
    // 不接受 BOM 位于 `<?xml ...?>` 声明之前），JSON Feed 的 jsonDecode 同样
    // 不接受 BOM。此前未剥 → 「整个源一条都读不出来」。
    final trimmed = _stripBom(xmlText.trim());

    // JSON Feed（Content-Type: application/feed+json）以 { 开头。
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map<String, dynamic> &&
            (decoded['version']?.toString().contains('jsonfeed') == true ||
                decoded.containsKey('items'))) {
          return _parseJsonFeed(decoded);
        }
      } catch (_) {
        // 不是合法 JSON，继续按 XML 处理。
      }
    }

    final doc = _parseXmlTolerant(trimmed);
    final root = doc.rootElement;

    final local = root.name.local.toLowerCase();
    if (local == 'rss') {
      return _parseRss2(root);
    } else if (local == 'feed') {
      return _parseAtom(root);
    } else if (local == 'rdf') {
      return _parseRdf(root);
    }

    // 兜底一：根节点名不标准但内容是 Atom（自定义根里直接放 <entry>）。
    if (root.findAllElements('entry').isNotEmpty) {
      return _parseAtom(root);
    }

    // 兜底二：RSS 2.0 降级（根下直接挂 <channel>）。
    final channel = root.findElements('channel').firstOrNull;
    if (channel != null) return _parseRss2(channel);

    // 兜底三：根下直接挂 <item>（既无 channel 也无 entry 的极简/破损源）。
    if (root.findAllElements('item').isNotEmpty) return _parseRss2(root);

    throw FormatException('Unrecognized feed format: root <${root.name}>');
  }

  // ── 宽容 XML 解析 ─────────────────────────────────────

  /// 正文承载标签：这些标签的内容是「文本 / HTML」而非结构化子元素，
  /// 修补时可以整段包进 CDATA 而不丢信息。
  ///
  /// 刻意**不含** `author` / `name` / `link` 等结构标签：`<author><name>x</name></author>`
  /// 若被包成 CDATA，作者名就取不到了；`<link/>` 在 Atom 里是自闭合属性标签。
  static const List<String> _textBearingTags = <String>[
    'title',
    'description',
    'summary',
    'content:encoded',
    'content',
    'subtitle',
    'dc:creator',
    'rights',
    'copyright',
    'comments',
  ];

  /// 宽容解析：原样 → 修补（PI/裸 &/CDATA）→ 激进修补（剥 DOCTYPE 与全部 PI）。
  ///
  /// 现实中大量订阅源把裸 HTML 直接塞进 `<description>` 而不加 CDATA、也不转义，
  /// 例如 `<description>摘要 <img src="a.jpg"> 尾部</description>`。`<img>` 在 XML
  /// 里是未闭合标签，标准解析会抛 `XmlTagException: Expected </img>`，**整个源**
  /// 一条都读不出来。这里逐级降级修补后重试；三级全败才把异常抛给上层显示。
  static XmlDocument _parseXmlTolerant(String xmlText) {
    // 一级：原样解析（绝大多数规范源走这条路，零开销）。
    try {
      return XmlDocument.parse(xmlText);
    } on XmlException {
      // 落到二级修补。
    } on FormatException {
      // 落到二级修补。
    }

    // 二级：剥样式表 PI + 转义裸 & + 正文承载标签包 CDATA。
    try {
      return XmlDocument.parse(_repairFeedXml(xmlText));
    } on XmlException {
      // 落到三级修补。
    } on FormatException {
      // 落到三级修补。
    }

    // 三级：更激进——剥掉 DOCTYPE 与**全部**处理指令（含 `<?xml ...?>` 声明，
    // XML 声明本身可缺省）后再修补。少数源带畸形 DOCTYPE / 内部实体声明，
    // 标准解析器无法处理，但正文数据本身是好的，剥掉即可读。
    final aggressive = _repairFeedXml(
      xmlText
          .replaceAll(RegExp(r'<!DOCTYPE[\s\S]*?>', caseSensitive: false), '')
          .replaceAll(RegExp(r'<\?[\s\S]*?\?>', caseSensitive: false), ''),
    );
    try {
      return XmlDocument.parse(aggressive);
    } on XmlException catch (e) {
      throw FormatException('无法解析订阅源 XML：${e.message}');
    }
  }

  /// XML 字节顺序标记（BOM）：UTF-8 编码为 `EF BB BF`，解码后码位是 U+FEFF。
  static const int _bomCodeUnit = 0xFEFF;

  /// 剥除开头连续出现的 BOM（U+FEFF）。
  ///
  /// `String.trim()` / `trimLeft()` **不会**移除 U+FEFF（Unicode 早已不将其
  /// 归类为空白），必须显式剥除。带 BOM 的 feed 直接进 XML 解析会整篇失败——
  /// 标准解析器不接受 BOM 位于 `<?xml ...?>` 声明之前；JSON Feed 的
  /// `jsonDecode` 同样不接受。此前未剥 → 「该源一条都读不出来」。
  static String _stripBom(String s) {
    var i = 0;
    while (i < s.length && s.codeUnitAt(i) == _bomCodeUnit) {
      i++;
    }
    return i == 0 ? s : s.substring(i);
  }

  /// 剥除 `<?xml-stylesheet ...?>` 处理指令（保留 `<?xml ...?>` 声明本身）。
  ///
  /// 少数源在 XML 声明后紧跟样式表 PI，部分解析器对 PI 位置敏感直接报错；
  /// 而样式表对 RSS 正文毫无用途，直接丢弃最省事。
  static String _stripStylesheetPis(String xml) => xml.replaceAll(
        RegExp(r'<\?xml-stylesheet[\s\S]*?\?>', caseSensitive: false),
        '',
      );

  /// 转义裸 `&`（未构成合法 XML 实体的那些）。
  ///
  /// XML 只认 5 个预定义实体（`&amp; &lt; &gt; &quot; &apos;`）加数字字符引用；
  /// HTML 里常见的 `&nbsp;` `&mdash;` `&copy;` 在 XML 中**未定义**，feed 正文
  /// 里直接出现会让解析器抛 `XmlException`。属性值里的裸 `&`（如
  /// `<enclosure url="a.mp3?x=1&y=2">`）同理，且 CDATA 修补覆盖不到属性——
  /// 必须在包 CDATA **之前**先把它们转义掉。
  static String _escapeBareAmpersands(String xml) => xml.replaceAllMapped(
        RegExp(r'&(?!(?:#\d+|#[xX][0-9A-Fa-f]+|amp|lt|gt|quot|apos);)'),
        (Match m) => '&amp;',
      );

  /// 把正文承载标签的内容包进 CDATA，消除裸 HTML / 裸 `&` 造成的解析失败。
  ///
  /// 修补顺序有讲究：先剥样式表 PI → 再转义裸 `&`（覆盖属性值）→ 最后才把
  /// 正文包进 CDATA（CDATA 内的 `&` 无需转义，反过来做会漏掉属性里的裸 `&`）。
  static String _repairFeedXml(String xml) {
    var out = _escapeBareAmpersands(_stripStylesheetPis(xml));
    for (final String tag in _textBearingTags) {
      final String esc = RegExp.escape(tag);
      final RegExp re = RegExp(
        '<$esc(\\s[^>]*)?>([\\s\\S]*?)</$esc>',
        caseSensitive: false,
      );
      out = out.replaceAllMapped(re, (Match m) {
        final String whole = m.group(0)!;
        final String attrs = m.group(1) ?? '';
        final String inner = m.group(2) ?? '';
        // 已经是 CDATA，或本身就是纯文本 → 原样保留，避免无谓改写。
        if (inner.contains('<![CDATA[')) return whole;
        if (!inner.contains('<') && !inner.contains('&')) return whole;
        // CDATA 内不能出现 ]]>，按惯例拆成两段。
        final String safe = inner.replaceAll(']]>', ']]]]><![CDATA[>');
        return '<$tag$attrs><![CDATA[$safe]]></$tag>';
      });
    }
    return out;
  }

  // ── RSS 2.0 ──────────────────────────────────────────

  static ParsedFeed _parseRss2(XmlElement rss) {
    final channel = rss.findElements('channel').firstOrNull ?? rss;

    final title = _text(channel, 'title') ?? 'Untitled Feed';
    final description = _text(channel, 'description');
    final siteUrl = _text(channel, 'link');
    final iconUrl = _text(channel, 'image', child: 'url');

    final items = <RssItem>[];
    for (final item in channel.findElements('item')) {
      final parsed = RssItem.fromXml(_itemFields(item));
      final enclosures = _parseEnclosures(item);
      items.add(enclosures.isEmpty ? parsed : parsed.copyWith(enclosures: enclosures));
    }

    return ParsedFeed(
      title: title,
      description: description,
      siteUrl: siteUrl,
      iconUrl: iconUrl,
      items: items,
    );
  }

  static Map<String, String> _itemFields(XmlElement item) {
    final fields = <String, String>{};
    for (final child in item.children.whereType<XmlElement>()) {
      final tag = child.name.local;
      // 处理带命名空间的标签如 dc:creator
      final fullTag = child.name.qualified;
      if (!fields.containsKey(tag)) {
        fields[tag] = child.innerText.trim();
      }
      if (fullTag != tag && !fields.containsKey(fullTag)) {
        fields[fullTag] = child.innerText.trim();
      }
    }
    return fields;
  }

  /// 解析条目附件：RSS 2.0 / RDF 的 `<enclosure url type length>`、
  /// Atom 的 `<link rel="enclosure" href type length>`，以及 Media RSS 的
  /// `<media:content url type>`（含 `<media:group>` 内嵌）。
  ///
  /// 此前只认 enclosure / link——大量视频源用 media 命名空间承载真实视频
  /// 地址，导致视频整批「拉取不到」。
  static List<RssEnclosure> _parseEnclosures(XmlElement item) {
    final list = <RssEnclosure>[];
    for (final enc in item.findElements('enclosure')) {
      final url = enc.getAttribute('url');
      if (url == null || url.isEmpty) continue;
      list.add(RssEnclosure(
        url: url,
        type: enc.getAttribute('type'),
        length: int.tryParse(enc.getAttribute('length') ?? ''),
      ));
    }
    for (final link in item.findElements('link')) {
      if (link.getAttribute('rel') != 'enclosure') continue;
      final href = link.getAttribute('href');
      if (href == null || href.isEmpty) continue;
      list.add(RssEnclosure(
        url: href,
        type: link.getAttribute('type'),
        length: int.tryParse(link.getAttribute('length') ?? ''),
      ));
    }
    // Media RSS：<media:content>（含 <media:group> 内嵌，递归查找覆盖）。
    // 按 url 去重——同一地址在 enclosure 与 media:content 里重复出现时保留
    // 先解析到的，避免同一视频在附件区渲染两份。
    final seen = <String>{for (final e in list) e.url};
    for (final mc in item.findAllElements('media:content')) {
      final url = mc.getAttribute('url');
      if (url == null || url.isEmpty || seen.contains(url)) continue;
      seen.add(url);
      list.add(RssEnclosure(
        url: url,
        type: mc.getAttribute('type'),
        length: int.tryParse(mc.getAttribute('fileSize') ?? ''),
        title: mc.getAttribute('title'),
      ));
    }
    return list;
  }

  // ── RDF / RSS 1.0 ───────────────────────────────────

  static ParsedFeed _parseRdf(XmlElement rdf) {
    final channel = rdf.findElements('channel').firstOrNull ?? rdf;
    final title = _text(channel, 'title') ?? 'Untitled Feed';
    final description = _text(channel, 'description');
    final siteUrl = _text(channel, 'link');
    final imageEl = channel.findElements('image').firstOrNull;
    final iconUrl = imageEl?.findElements('url').firstOrNull?.innerText.trim();

    final items = <RssItem>[];
    for (final item in rdf.findElements('item')) {
      final parsed = RssItem.fromXml(_itemFields(item));
      final enclosures = _parseEnclosures(item);
      items.add(enclosures.isEmpty ? parsed : parsed.copyWith(enclosures: enclosures));
    }

    return ParsedFeed(
      title: title,
      description: description,
      siteUrl: siteUrl,
      iconUrl: iconUrl,
      items: items,
    );
  }

  // ── JSON Feed 1.1 ────────────────────────────────────

  static ParsedFeed _parseJsonFeed(Map<String, dynamic> json) {
    final title = (json['title'] as String?) ?? 'Untitled Feed';
    final items = <RssItem>[];
    final rawItems = json['items'];
    if (rawItems is List) {
      for (final raw in rawItems) {
        if (raw is! Map) continue;
        final Map<String, dynamic> m = raw as Map<String, dynamic>;
        final content =
            m['content_html'] as String? ?? m['content_text'] as String?;
        final summary = m['summary'] as String? ?? content;
        final authorRaw = m['author'];
        final author = authorRaw is Map
            ? (authorRaw['name'] as String?)
            : (authorRaw as String?);
        DateTime? published;
        final pub = m['date_published'];
        if (pub is String) published = DateTime.tryParse(pub);

        final enclosures = <RssEnclosure>[];
        final atts = m['attachments'];
        if (atts is List) {
          for (final a in atts) {
            if (a is! Map) continue;
            final u = a['url'];
            if (u is! String || u.isEmpty) continue;
            enclosures.add(RssEnclosure(
              url: u,
              type: a['mime_type'] as String?,
              length: a['size_in_bytes'] is int
                  ? a['size_in_bytes'] as int
                  : int.tryParse(a['size_in_bytes']?.toString() ?? ''),
              title: a['title'] as String?,
            ));
          }
        }

        items.add(RssItem(
          title: (m['title'] as String?) ?? '',
          url: (m['url'] as String?) ?? (m['external_url'] as String?) ?? '',
          description: summary,
          author: author,
          publishedAt: published,
          coverUrl: RssItem.extractCoverFromHtml(content ?? summary ?? ''),
          content: content,
          enclosures: enclosures,
        ));
      }
    }

    return ParsedFeed(
      title: title,
      description: json['description'] as String?,
      siteUrl: json['home_page_url'] as String?,
      iconUrl: json['icon'] as String? ?? json['favicon'] as String?,
      items: items,
    );
  }

  // ── Atom 1.0 ─────────────────────────────────────────

  static ParsedFeed _parseAtom(XmlElement feed) {
    final title = _text(feed, 'title') ?? 'Untitled Feed';
    final subtitle = _text(feed, 'subtitle');

    // Atom link 有 rel 属性，alternate 为站点地址
    String? siteUrl;
    for (final link in feed.findElements('link')) {
      final rel = link.getAttribute('rel');
      if (rel == null || rel == 'alternate') {
        siteUrl = link.getAttribute('href');
        break;
      }
    }

    final iconUrl = _text(feed, 'icon') ?? _text(feed, 'logo');

    final items = <RssItem>[];
    for (final entry in feed.findElements('entry')) {
      items.add(_atomEntryToItem(entry));
    }

    return ParsedFeed(
      title: title,
      description: subtitle,
      siteUrl: siteUrl,
      iconUrl: iconUrl,
      items: items,
    );
  }

  static RssItem _atomEntryToItem(XmlElement entry) {
    final title = _text(entry, 'title') ?? '';
    String? link;
    for (final l in entry.findElements('link')) {
      final rel = l.getAttribute('rel');
      if (rel == null || rel == 'alternate') {
        link = l.getAttribute('href');
        break;
      }
    }
    // Atom：<content> 为全文，<summary> 为摘要（无 content 时回退）。
    // 此前只取 summary 导致 Atom 源永远只显示摘要（B3）。
    final content = _text(entry, 'content');
    final summary = _text(entry, 'summary') ?? content;
    final author = _text(entry, 'author', child: 'name') ?? _text(entry, 'author');
    final published = _text(entry, 'published') ?? _text(entry, 'updated');

    return RssItem(
      title: title,
      url: link ?? '',
      description: summary,
      author: author,
      publishedAt: published != null ? _tryParseDate(published) : null,
      coverUrl: RssItem.extractCoverFromHtml(content ?? summary ?? ''),
      content: content,
      enclosures: _parseEnclosures(entry),
    );
  }

  // ── 辅助方法 ──────────────────────────────────────────

  static String? _text(XmlElement parent, String tag, {String? child}) {
    final el = parent.findElements(tag).firstOrNull;
    if (el == null) return null;
    if (child != null) {
      final childEl = el.findElements(child).firstOrNull;
      return childEl?.innerText.trim();
    }
    return el.innerText.trim();
  }

  static DateTime? _tryParseDate(String raw) {
    try {
      return DateTime.parse(raw.trim());
    } catch (_) {
      return null;
    }
  }
}

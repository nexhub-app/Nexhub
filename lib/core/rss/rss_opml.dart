/// OPML 2.0 导入 / 导出（对标阅读器通用的订阅交换格式）。
///
/// 用途：把本应用的 RSS 订阅导出成一个 `.opml` 文件（可分享 / 备份，
/// 也可导入到其他阅读器），以及把别人导出的 OPML 解析成订阅条目批量导入。
///
/// 格式要点（OPML 2.0）：
/// - 根节点 `<opml version="2.0">`，含 `<head>`（标题）与 `<body>`。
/// - `<body>` 下是 `<outline>` 树：带 `xmlUrl` 属性的即一条订阅；
///   不带的视为分组节点，其 `text`/`title` 作为子条目的分类名。
/// - 属性可乱序、大小写敏感（规范用 `xmlUrl` / `htmlUrl` / `text` / `title` / `type`）。
library;

import 'package:xml/xml.dart';

import 'rss_feed.dart';

/// 从 OPML 解析出的一条订阅条目。
class OpmlEntry {
  /// 订阅标题（缺省时回退 xmlUrl）。
  final String title;

  /// 订阅源地址（必填）。
  final String xmlUrl;

  /// 站点主页地址（可选）。
  final String? htmlUrl;

  /// 所属分组名（来自父级 outline，可为 null）。
  final String? category;

  const OpmlEntry({
    required this.title,
    required this.xmlUrl,
    this.htmlUrl,
    this.category,
  });
}

/// 导入预览用的解析结果。
class OpmlParseResult {
  /// 解析出的订阅条目（已按 xmlUrl 去重，保持原顺序）。
  final List<OpmlEntry> entries;

  /// 因缺少 / 空 xmlUrl 而被跳过的节点数。
  final int skipped;

  const OpmlParseResult({required this.entries, this.skipped = 0});

  bool get isEmpty => entries.isEmpty;
}

/// OPML 解析与生成。
class RssOpml {
  RssOpml._();

  /// 常见 feed MIME 类型（用于判断一条候选链接是不是订阅源）。
  static const Set<String> _feedTypes = <String>{
    'application/rss+xml',
    'application/atom+xml',
    'application/rdf+xml',
    'application/rss',
    'application/atom',
    'text/xml',
    'application/xml',
  };

  /// 解析 OPML 文本。
  ///
  /// 递归遍历 `<body>` 下的 `<outline>` 树：
  /// - 有非空 `xmlUrl` → 记为一条订阅；
  /// - 无 `xmlUrl` → 视为分组节点，递归其子节点并把 `text`/`title` 作为分类名。
  ///
  /// 解析失败（非 XML / 无 body）时抛出 `FormatException`，由调用方提示用户。
  static OpmlParseResult parse(String text) {
    if (text.trim().isEmpty) {
      throw const FormatException('OPML is empty');
    }
    final doc = XmlDocument.parse(text);
    final body = doc.findAllElements('body').firstOrNull;
    if (body == null) {
      throw const FormatException('OPML has no <body>');
    }

    final entries = <OpmlEntry>[];
    final seen = <String>{};
    var skipped = 0;

    void walk(XmlElement node, String? category) {
      for (final child in node.findElements('outline')) {
        final url = child.getAttribute('xmlUrl')?.trim() ?? '';
        final label = (child.getAttribute('text')?.trim().isNotEmpty ?? false)
            ? child.getAttribute('text')!.trim()
            : (child.getAttribute('title')?.trim() ?? '');

        if (url.isEmpty) {
          // 分组节点：带上自己的名字递归（名字为空则沿用上层分类）。
          final hasChild = child.findElements('outline').isNotEmpty;
          if (hasChild) {
            walk(child, label.isNotEmpty ? label : category);
          } else {
            skipped++;
          }
          continue;
        }

        // 只收 feed 类型；type 缺失时宽容放行（不少导出工具不写 type）。
        final type = child.getAttribute('type')?.trim().toLowerCase() ?? '';
        if (type.isNotEmpty && !_feedTypes.contains(type)) {
          skipped++;
          continue;
        }

        if (seen.add(url)) {
          entries.add(OpmlEntry(
            title: label.isNotEmpty ? label : url,
            xmlUrl: url,
            htmlUrl: child.getAttribute('htmlUrl'),
            category: category,
          ));
        }
      }
    }

    walk(body, null);
    return OpmlParseResult(entries: entries, skipped: skipped);
  }

  /// 生成 OPML 2.0 文本。
  ///
  /// [feeds] 全部订阅；[docTitle] 文件标题（写在 `<head><title>`）。
  /// 按分组输出：属于 N 个分组的订阅会在每个分组下各出现一次（分组是标签语义，
  /// 不是单亲文件夹），无分组的订阅直接放在 `<body>` 顶层。
  static String build(List<RssFeed> feeds, {String docTitle = 'NexHub RSS'}) {
    final builder = XmlBuilder();
    builder.processing('xml', 'version="1.0" encoding="UTF-8"');
    builder.element('opml', nest: () {
      builder.attribute('version', '2.0');
      builder.element('head', nest: () {
        builder.element('title', nest: docTitle);
        builder.element('dateCreated', nest: _rfc822(DateTime.now()));
      });
      builder.element('body', nest: () {
        // 收集所有分组名（保持首次出现顺序），多分组订阅会重复出现。
        final groupNames = <String>[];
        for (final f in feeds) {
          for (final g in f.groups) {
            if (g.trim().isNotEmpty && !groupNames.contains(g)) {
              groupNames.add(g);
            }
          }
        }

        void outlineFor(RssFeed f) {
          builder.element('outline', nest: () {
            builder.attribute('type', 'rss');
            builder.attribute('text', f.title);
            builder.attribute('title', f.title);
            builder.attribute('xmlUrl', f.url);
            if (f.siteUrl != null && f.siteUrl!.isNotEmpty) {
              builder.attribute('htmlUrl', f.siteUrl!);
            }
          });
        }

        for (final name in groupNames) {
          builder.element('outline', nest: () {
            builder.attribute('text', name);
            builder.attribute('title', name);
            for (final f in feeds) {
              if (f.groups.contains(name)) {
                outlineFor(f);
              }
            }
          });
        }

        // 未分组的订阅放顶层。
        for (final f in feeds) {
          if (f.groups.isEmpty) {
            outlineFor(f);
          }
        }
      });
    });
    return builder.buildDocument().toXmlString(pretty: true);
  }

  /// RFC 822 时间（OPML 的 dateCreated 惯例格式）。
  static String _rfc822(DateTime dt) {
    const days = <String>['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = <String>[
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final offset = dt.timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    final abs = offset.abs();
    final hh = abs.inHours.toString().padLeft(2, '0');
    final mm = (abs.inMinutes % 60).toString().padLeft(2, '0');
    return '${days[dt.weekday - 1]}, ${dt.day.toString().padLeft(2, '0')} '
        '${months[dt.month - 1]} ${dt.year} '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}:'
        '${dt.second.toString().padLeft(2, '0')} $sign$hh$mm';
  }
}

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

  /// 所属分组（标签语义）：OPML 里同一订阅可能出现在多个分组节点下，
  /// 解析时按 xmlUrl 聚合到同一条目（否则往返导入只保留首个分组）。
  final List<String> categories;

  const OpmlEntry({
    required this.title,
    required this.xmlUrl,
    this.htmlUrl,
    this.categories = const <String>[],
  });

  /// 首个分组（兼容旧的单分组读取方，可为 null）。
  String? get category => categories.isEmpty ? null : categories.first;
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

  /// 解析 OPML 文本。
  ///
  /// 递归遍历 `<body>` 下的 `<outline>` 树：
  /// - 有非空 `xmlUrl` → 记为一条订阅；
  /// - 无 `xmlUrl` → 视为分组节点，递归其子节点并把 `text`/`title` 作为分类名。
  ///
  /// 容错（导入显示「无可导入的内容」的修复要点）：
  /// - **`type` 属性不作否决条件**。OPML 惯例写短词 `type="rss"`（Feedly /
  ///   Inoreader / FreshRSS / ReadYou 等主流导出皆如此），此前误按 MIME 集合
  ///   校验，`rss` 不在集合里 → 每条订阅都被跳过 → 永远「无可导入」；
  /// - 属性名大小写容错：部分工具写 `xmlurl` / `TEXT` 等（XML 属性大小写
  ///   敏感，精确匹配会拿空）；
  /// - 剥 UTF-8 BOM（Windows 记事本保存的文件带 BOM，xml 包解析会失败）；
  /// - feed 节点自带子 outline 时一并递归（少数导出把子源挂在 feed 节点下）。
  ///
  /// 解析失败（非 XML / 无 body）时抛出 `FormatException`，由调用方提示用户。
  static OpmlParseResult parse(String rawText) {
    // BOM 剥除：XmlDocument.parse 对 \uFEFF 开头的文本抛 FormatException。
    final text = rawText.replaceFirst('\uFEFF', '').trim();
    if (text.isEmpty) {
      throw const FormatException('OPML is empty');
    }
    final doc = XmlDocument.parse(text);
    final body = doc.findAllElements('body').firstOrNull;
    if (body == null) {
      throw const FormatException('OPML has no <body>');
    }

    final entries = <OpmlEntry>[];
    final indexByUrl = <String, int>{};
    var skipped = 0;

    // 属性读取：精确名优先，回退为「局部名小写比对」（xmlurl vs xmlUrl）。
    String? attr(XmlElement e, String name) {
      final exact = e.getAttribute(name);
      if (exact != null) return exact;
      final lower = name.toLowerCase();
      for (final a in e.attributes) {
        if (a.name.local.toLowerCase() == lower) return a.value;
      }
      return null;
    }

    void walk(XmlElement node, String? category) {
      for (final child in node.findElements('outline')) {
        final url = attr(child, 'xmlUrl')?.trim() ?? '';
        final text = attr(child, 'text')?.trim() ?? '';
        final title = attr(child, 'title')?.trim() ?? '';
        final label = text.isNotEmpty ? text : title;

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

        // 同一 xmlUrl 的多个出现聚合为一条目（分组取并集、去重、保序）。
        final int? existingIdx = indexByUrl[url];
        final String? cat =
            (category != null && category.isNotEmpty) ? category : null;
        if (existingIdx != null) {
          final prev = entries[existingIdx];
          if (cat != null && !prev.categories.contains(cat)) {
            entries[existingIdx] = OpmlEntry(
              title: prev.title,
              xmlUrl: prev.xmlUrl,
              htmlUrl: prev.htmlUrl,
              categories: <String>[...prev.categories, cat],
            );
          }
          continue;
        }
        indexByUrl[url] = entries.length;
        entries.add(OpmlEntry(
          title: label.isNotEmpty ? label : url,
          xmlUrl: url,
          htmlUrl: attr(child, 'htmlUrl'),
          categories: cat != null ? <String>[cat] : const <String>[],
        ));

        // feed 节点自带子级：一并递归（子源沿用当前分类）。
        if (child.findElements('outline').isNotEmpty) {
          walk(child, category);
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
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
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

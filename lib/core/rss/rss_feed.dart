/// RSS 订阅源与条目模型（文档 §10.2）。
///
/// 支持 RSS 2.0 和 Atom 两种主流格式。
library;

import 'dart:convert';

import '../models/plugin_config.dart';

/// RSS 订阅源配置。
class RssFeed {
  final String id;
  final String title;
  final String url;
  final String? description;
  final String? siteUrl;
  final String? iconUrl;
  /// 条件 GET 校验值（HTTP `ETag`），由抓取响应回写，下次请求带
  /// `If-None-Match` 以拿到 304 省流量（P2-1）。
  final String? etag;
  /// 条件 GET 校验值（HTTP `Last-Modified`），与 [etag] 正交，二者任一命中
  /// 即返回 304（P2-1）。
  final String? lastModified;
  final SourceType? moduleType;
  /// 用户自定义分组（文件夹 / 标签）。
  ///
  /// 与 [moduleType] 是两个正交维度：[moduleType] 是「绑定到哪个内容模块」
  /// （单值，决定出现在哪个模块分类页），[groups] 是用户自由建的分组，
  /// 一份订阅可以同时属于多个分组。
  final List<String> groups;
  final int addedAt;

  const RssFeed({
    required this.id,
    required this.title,
    required this.url,
    this.description,
    this.siteUrl,
    this.iconUrl,
    this.etag,
    this.lastModified,
    this.moduleType,
    this.groups = const <String>[],
    required this.addedAt,
  });

  RssFeed copyWith({
    String? title,
    String? url,
    String? description,
    String? siteUrl,
    String? iconUrl,
    String? etag,
    String? lastModified,
    SourceType? moduleType,
    List<String>? groups,
  }) =>
      RssFeed(
        id: id,
        title: title ?? this.title,
        url: url ?? this.url,
        description: description ?? this.description,
        siteUrl: siteUrl ?? this.siteUrl,
        iconUrl: iconUrl ?? this.iconUrl,
        etag: etag ?? this.etag,
        lastModified: lastModified ?? this.lastModified,
        moduleType: moduleType ?? this.moduleType,
        groups: groups ?? this.groups,
        addedAt: addedAt,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'title': title,
        'url': url,
        'description': description,
        'siteUrl': siteUrl,
        'iconUrl': iconUrl,
        'etag': etag,
        'lastModified': lastModified,
        'moduleType': moduleType?.apiName,
        'groups': groups,
        'addedAt': addedAt,
      };

  factory RssFeed.fromJson(Map<String, dynamic> json) => RssFeed(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        url: json['url'] as String? ?? '',
        description: json['description'] as String?,
        siteUrl: json['siteUrl'] as String?,
        iconUrl: json['iconUrl'] as String?,
        etag: json['etag'] as String?,
        lastModified: json['lastModified'] as String?,
        moduleType: SourceType.parse(json['moduleType'] as String?),
        // 向后兼容：旧备份没有 groups 字段 → 空列表。
        groups: (json['groups'] as List<dynamic>?)
                ?.whereType<String>()
                .toList() ??
            const <String>[],
        addedAt: json['addedAt'] as int? ?? 0,
      );

  /// 用于 UI 展示的图标地址：优先用解析到的 [iconUrl]，缺失时回退到站点根
  /// `/favicon.ico`（修复 B8：此前 favicon 永不填充，订阅列表只显示通用 RSS 图标）。
  String? get effectiveIconUrl {
    if (iconUrl != null && iconUrl!.isNotEmpty) return iconUrl;
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return null;
    return '${uri.origin}/favicon.ico';
  }
}

/// RSS 条目附件（播客音频 / 视频 / 文件等，对应 RSS `<enclosure>`、
/// Atom `<link rel="enclosure">`、JSON Feed `attachments`）。
class RssEnclosure {
  final String url;
  final String? type; // MIME 类型，如 audio/mpeg
  final int? length; // 字节数
  final String? title;

  const RssEnclosure({
    required this.url,
    this.type,
    this.length,
    this.title,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'url': url,
        'type': type,
        'length': length,
        'title': title,
      };

  factory RssEnclosure.fromJson(Map<String, dynamic> json) => RssEnclosure(
        url: json['url'] as String? ?? '',
        type: json['type'] as String?,
        length: json['length'] as int?,
        title: json['title'] as String?,
      );

  /// 常见音频扩展名（MIME 缺失或不明确时按 URL 后缀兜底判定）。
  static const List<String> _audioExt = <String>[
    '.mp3', '.m4a', '.aac', '.ogg', '.oga', '.opus',
    '.wav', '.flac', '.wma', '.aiff', '.alac',
  ];

  /// 常见视频扩展名（同上，用于 [isVideo]）。
  static const List<String> _videoExt = <String>[
    '.mp4', '.m4v', '.webm', '.mkv', '.mov', '.avi',
    '.flv', '.wmv', '.m3u8', '.ts', '.ogv',
  ];

  /// 用于后缀判定的 URL 路径（去查询串、小写）。
  String get _urlPathForExt {
    final Uri? uri = Uri.tryParse(url);
    return (uri?.path ?? url).toLowerCase();
  }

  /// 是否为音频附件（交给内置播客播放器）。
  ///
  /// 三级判定：MIME 以 `audio/` 开头直接成立 → MIME 为空时**保守纳入**
  /// （JSON Feed 的 `attachments` 常不写 `mime_type`，此前这类附件被整批
  /// 丢弃、播放器永远 0:00）→ MIME 写了别的但实际是音频后缀（如
  /// `application/octet-stream` + `.mp3`）也纳入。
  bool get isAudio {
    final String t = type?.toLowerCase().trim() ?? '';
    if (t.isEmpty) return true;
    if (t.startsWith('audio')) return true;
    if (t.startsWith('video')) return false;
    final String p = _urlPathForExt;
    return _audioExt.any(p.endsWith);
  }

  /// 是否为视频附件（交给内置视频播放器）。
  ///
  /// MIME 为空时**不**判为视频：与 [isAudio] 的「未知→当音频」保守策略保持
  /// 一致，避免同一份附件被两边同时认领。
  bool get isVideo {
    final String t = type?.toLowerCase().trim() ?? '';
    if (t.startsWith('video')) return true;
    if (t.startsWith('audio')) return false;
    if (t.isEmpty) return false;
    final String p = _urlPathForExt;
    return _videoExt.any(p.endsWith);
  }
}

/// RSS 条目（单篇文章 / 更新通知）。
class RssItem {
  final String title;
  final String url;
  final String? description;
  final String? author;
  final DateTime? publishedAt;
  final String? coverUrl;
  final String? content;
  final List<RssEnclosure> enclosures;

  const RssItem({
    required this.title,
    required this.url,
    this.description,
    this.author,
    this.publishedAt,
    this.coverUrl,
    this.content,
    this.enclosures = const <RssEnclosure>[],
  });

  RssItem copyWith({
    String? title,
    String? url,
    String? description,
    String? author,
    DateTime? publishedAt,
    String? coverUrl,
    String? content,
    List<RssEnclosure>? enclosures,
  }) =>
      RssItem(
        title: title ?? this.title,
        url: url ?? this.url,
        description: description ?? this.description,
        author: author ?? this.author,
        publishedAt: publishedAt ?? this.publishedAt,
        coverUrl: coverUrl ?? this.coverUrl,
        content: content ?? this.content,
        enclosures: enclosures ?? this.enclosures,
      );

  /// 从 RSS 2.0 <item> 解析。
  factory RssItem.fromXml(Map<String, String> fields) {
    DateTime? published;
    final dateStr = fields['pubDate'] ?? fields['dc:date'];
    if (dateStr != null) {
      published = _parseDate(dateStr);
    }

    return RssItem(
      title: fields['title'] ?? '',
      url: fields['link'] ?? '',
      description: fields['description'],
      author: fields['author'] ?? fields['dc:creator'],
      publishedAt: published,
      content: fields['content:encoded'] ?? fields['encoded'],
      coverUrl: extractCoverFromHtml(fields['content:encoded'] ??
          fields['encoded'] ??
          fields['description'] ??
          ''),
    );
  }

  /// 解析 RFC 822（RSS 2.0）和 ISO 8601（Atom）日期。
  static DateTime? _parseDate(String raw) {
    // 尝试 ISO 8601（Atom 格式）
    try {
      return DateTime.parse(raw);
    } catch (_) {
      // 继续尝试 RFC 822
    }

    // RFC 822: "Sat, 07 Sep 2002 09:42:31 GMT"
    try {
      final cleaned = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
      // 移除星期前缀 "Sat, "
      final withoutDay = cleaned.contains(',')
          ? cleaned.substring(cleaned.indexOf(',') + 2)
          : cleaned;
      final parts = withoutDay.split(' ');
      final day = parts[0].padLeft(2, '0');
      final month = _monthToInt(parts[1]);
      final year = parts[2].length == 2 ? '20${parts[2]}' : parts[2];
      final time = parts[3];
      if (parts.length >= 5) {
        // 含时区段：解析为对应偏移（命名时区经 [_tzToIso] 映射，未知默认 UTC）。
        final tz = parts[4];
        final iso = '$year-$month-${day}T$time${_tzToIso(tz)}';
        return DateTime.parse(iso);
      } else if (parts.length == 4) {
        // 无显式时区（如 "07 Sep 2002 09:42:31"）：按本地时区解析（B4 兜底），
        // 避免返回 null 导致列表不显示时间、无法排序。
        final iso = '$year-$month-${day}T$time';
        return DateTime.parse(iso);
      }
    } catch (_) {
      // 忽略
    }
    return null;
  }

  static String _monthToInt(String month) {
    const months = <String, String>{
      'Jan': '01', 'Feb': '02', 'Mar': '03', 'Apr': '04',
      'May': '05', 'Jun': '06', 'Jul': '07', 'Aug': '08',
      'Sep': '09', 'Oct': '10', 'Nov': '11', 'Dec': '12',
    };
    return months[month] ?? '01';
  }

  static String _tzToIso(String tz) {
    if (tz == 'GMT' || tz == 'UTC' || tz == 'Z') return 'Z';
    // 命名时区 → UTC 偏移（B4：此前未知命名时区默认 'Z' 导致数小时偏差）。
    // 仅覆盖常见缩写；夏令时(EDT/PDT/CEST 等)已按夏令时偏移处理。
    const named = <String, String>{
      'UT': 'Z', 'Z': 'Z',
      'EST': '-05:00', 'EDT': '-04:00',
      'CST': '-06:00', 'CDT': '-05:00',
      'MST': '-07:00', 'MDT': '-06:00',
      'PST': '-08:00', 'PDT': '-07:00',
      'CET': '+01:00', 'CEST': '+02:00',
      'EET': '+02:00', 'EEST': '+03:00',
      'BST': '+01:00', 'WET': '+00:00', 'WEST': '+01:00',
      'JST': '+09:00', 'KST': '+09:00', 'CSTChina': '+08:00',
      'AEST': '+10:00', 'AEDT': '+11:00', 'NZST': '+12:00', 'NZDT': '+13:00',
      'IST': '+05:30', 'MSK': '+03:00', 'HKT': '+08:00', 'SGT': '+08:00',
    };
    final mapped = named[tz.toUpperCase()];
    if (mapped != null) return mapped;
    if (tz.startsWith('+') || tz.startsWith('-')) {
      final sign = tz.substring(0, 1);
      final rest = tz.substring(1);
      if (rest.length == 4) {
        return '$sign${rest.substring(0, 2)}:${rest.substring(2)}';
      }
    }
    return 'Z'; // 未知默认 UTC
  }

  /// 从 description 中提取第一张图片作为封面。
  ///
  /// 优先取懒加载属性（`data-src` / `data-original` / `data-lazy-src`，
  /// 大量站点把真图藏在这些属性里、`src` 只是 1x1 占位图），回退到 `src`；
  /// `data:` 内联占位图直接跳过（否则取到的是透明占位而非真封面）。
  /// 返回的地址可能是相对地址——展示侧需按文章页地址绝对化。
  static String? extractCoverFromHtml(String html) {
    final tagMatch =
        RegExp(r'<img\b[^>]*>', caseSensitive: false).firstMatch(html);
    if (tagMatch == null) return null;
    final tag = tagMatch.group(0)!;
    for (final attr in const [
      'data-src',
      'data-original',
      'data-lazy-src',
      'src',
    ]) {
      final m = RegExp('$attr=["\']([^"\']+)["\']', caseSensitive: false)
          .firstMatch(tag);
      final v = m?.group(1);
      if (v != null && v.isNotEmpty && !v.startsWith('data:')) return v;
    }
    return null;
  }
}

/// RSS 解析后的结果。
class ParsedFeed {
  final String title;
  final String? description;
  final String? siteUrl;
  final String? iconUrl;
  final List<RssItem> items;

  const ParsedFeed({
    required this.title,
    this.description,
    this.siteUrl,
    this.iconUrl,
    required this.items,
  });
}

/// 从 [ParsedFeed] 生成 feed ID（URL 的简单哈希）。
String feedIdFromUrl(String url) {
  final bytes = utf8.encode(url);
  final digest = bytes.fold<int>(0, (prev, b) => (prev * 31 + b) & 0x7FFFFFFF);
  return 'feed_$digest';
}

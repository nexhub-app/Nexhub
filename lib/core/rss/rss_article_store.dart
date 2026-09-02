/// RSS 文章本地状态与缓存（文档 §10.2 P1-3）。
///
/// 两部分数据，均经 [PrefsBackend]（SharedPreferences）持久化，
/// 与 RSS 子系统现有 `rss_feeds_v1` / `rss_feed_states_v1` 保持一致，不新增 Hive box：
/// - `rss_feed_cache_v1`：每个订阅源最近一次抓到的条目元数据（有序），
///   用于断网时仍能展示列表。
/// - `rss_article_state_v1`：每篇文章的 `read` / `favorite` / 全文缓存 `content`
///   及渲染所需元数据，键为 `feedId::itemUrl`（url 为空回退标题，
///   与 [RssUpdateChecker] 的 seen 判定一致）。
library;

import 'dart:convert';

import '../comic/models/reader_preferences.dart';
import '../network/network_config_service.dart';
import '../scraper/http_fetcher.dart';
import 'rss_feed.dart';

/// 单篇 RSS 文章的本地记录。
class RssArticleRecord {
  final String feedId;
  final String itemUrl;
  final String title;
  final String? author;
  final String? coverUrl;
  final int? publishedAtMs;
  final String? description;
  final bool read;
  final bool favorite;
  final int? readAt;
  final String? content;
  final int? cachedAt;
  final List<RssEnclosure> enclosures;

  const RssArticleRecord({
    required this.feedId,
    required this.itemUrl,
    required this.title,
    this.author,
    this.coverUrl,
    this.publishedAtMs,
    this.description,
    this.read = false,
    this.favorite = false,
    this.readAt,
    this.content,
    this.cachedAt,
    this.enclosures = const <RssEnclosure>[],
  });

  /// 稳定键：`feedId::itemUrl`，url 为空时回退标题。
  static String key(String feedId, String itemUrl, String title) =>
      itemUrl.isNotEmpty ? '$feedId::$itemUrl' : '$feedId::$title';

  RssArticleRecord copyWith({
    bool? read,
    bool? favorite,
    int? readAt,
    String? content,
    int? cachedAt,
    List<RssEnclosure>? enclosures,
  }) =>
      RssArticleRecord(
        feedId: feedId,
        itemUrl: itemUrl,
        title: title,
        author: author,
        coverUrl: coverUrl,
        publishedAtMs: publishedAtMs,
        description: description,
        read: read ?? this.read,
        favorite: favorite ?? this.favorite,
        readAt: readAt ?? this.readAt,
        content: content ?? this.content,
        cachedAt: cachedAt ?? this.cachedAt,
        enclosures: enclosures ?? this.enclosures,
      );

  /// 还原为 [RssItem]（含缓存全文），供阅读器离线打开。
  RssItem toItem() => RssItem(
        title: title,
        url: itemUrl,
        description: description,
        author: author,
        publishedAt: publishedAtMs == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(publishedAtMs!),
        coverUrl: coverUrl,
        content: content,
        enclosures: enclosures,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'feedId': feedId,
        'itemUrl': itemUrl,
        'title': title,
        'author': author,
        'coverUrl': coverUrl,
        'publishedAtMs': publishedAtMs,
        'description': description,
        'read': read,
        'favorite': favorite,
        'readAt': readAt,
        'content': content,
        'cachedAt': cachedAt,
        'enclosures': enclosures.map((e) => e.toJson()).toList(),
      };

  factory RssArticleRecord.fromJson(Map<String, dynamic> json) => RssArticleRecord(
        feedId: json['feedId'] as String? ?? '',
        itemUrl: json['itemUrl'] as String? ?? '',
        title: json['title'] as String? ?? '',
        author: json['author'] as String?,
        coverUrl: json['coverUrl'] as String?,
        publishedAtMs: json['publishedAtMs'] as int?,
        description: json['description'] as String?,
        read: json['read'] as bool? ?? false,
        favorite: json['favorite'] as bool? ?? false,
        readAt: json['readAt'] as int?,
        content: json['content'] as String?,
        cachedAt: json['cachedAt'] as int?,
        enclosures: (json['enclosures'] as List<dynamic>?)
                ?.whereType<Map>()
                .map((e) => RssEnclosure.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const <RssEnclosure>[],
      );
}

/// RSS 文章本地存储（单例，懒加载）。
class RssArticleStore {
  RssArticleStore._();

  static final RssArticleStore instance = RssArticleStore._();

  final PrefsBackend _backend = const SharedPrefsBackend();
  static const String _cacheKey = 'rss_feed_cache_v1';
  static const String _stateKey = 'rss_article_state_v1';

  final Map<String, List<RssItem>> _feedCache = {};
  final Map<String, RssArticleRecord> _states = {};
  bool _loaded = false;

  /// 懒加载持久化数据（幂等）。
  Future<void> init() async {
    if (_loaded) return;
    try {
      final rawCache = await _backend.get(_cacheKey);
      if (rawCache != null) {
        final map = jsonDecode(rawCache) as Map<String, dynamic>;
        for (final entry in map.entries) {
          final list = (entry.value as List<dynamic>)
              .map((e) => _itemFromMeta(e as Map<String, dynamic>))
              .toList();
          _feedCache[entry.key] = list;
        }
      }
      final rawState = await _backend.get(_stateKey);
      if (rawState != null) {
        final map = jsonDecode(rawState) as Map<String, dynamic>;
        for (final entry in map.entries) {
          _states[entry.key] =
              RssArticleRecord.fromJson(entry.value as Map<String, dynamic>);
        }
      }
    } on Object {
      // 损坏数据忽略
    }
    _loaded = true;
  }

  // ---- 订阅源条目缓存（断网可看列表） ----

  /// 写入某订阅源最近一次抓到的条目（有序），并 upsert 每篇状态记录
  /// （保留已有的 read/favorite/content，仅刷新元数据）。
  Future<void> cacheFeed(String feedId, List<RssItem> items) async {
    _feedCache[feedId] = items;
    for (final item in items) {
      _upsert(feedId, item);
    }
    await _persistCache();
    await _persistState();
  }

  List<RssItem> getFeedItems(String feedId) =>
      List.unmodifiable(_feedCache[feedId] ?? const <RssItem>[]);

  bool hasFeedCache(String feedId) =>
      (_feedCache[feedId]?.isNotEmpty ?? false);

  // ---- 每篇状态 ----

  RssArticleRecord? _record(String feedId, RssItem item) =>
      _states[RssArticleRecord.key(feedId, item.url, item.title)];

  bool isRead(String feedId, RssItem item) => _record(feedId, item)?.read ?? false;

  bool isFavorite(String feedId, RssItem item) =>
      _record(feedId, item)?.favorite ?? false;

  String? getContent(String feedId, RssItem item) =>
      _record(feedId, item)?.content;

  /// 标记已读（内存同步更新，后台持久化）。
  Future<void> markRead(String feedId, RssItem item) async {
    final k = RssArticleRecord.key(feedId, item.url, item.title);
    final prev = _states[k] ?? _recordFromItem(feedId, item);
    _states[k] = prev.copyWith(
      read: true,
      readAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _persistState();
  }

  /// 切换收藏，返回切换后的状态。
  Future<bool> toggleFavorite(String feedId, RssItem item) async {
    final k = RssArticleRecord.key(feedId, item.url, item.title);
    final prev = _states[k] ?? _recordFromItem(feedId, item);
    final next = !prev.favorite;
    _states[k] = prev.copyWith(favorite: next);
    await _persistState();
    return next;
  }

  /// 按已有记录切换收藏（收藏页用）。
  Future<bool> toggleFavoriteByRecord(RssArticleRecord rec) async {
    final k = RssArticleRecord.key(rec.feedId, rec.itemUrl, rec.title);
    _states[k] = rec.copyWith(favorite: !rec.favorite);
    await _persistState();
    return !rec.favorite;
  }

  /// 批量标记某订阅源全部条目为已读。
  Future<void> markAllRead(String feedId, List<RssItem> items) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final item in items) {
      final k = RssArticleRecord.key(feedId, item.url, item.title);
      final prev = _states[k] ?? _recordFromItem(feedId, item);
      _states[k] = prev.copyWith(read: true, readAt: now);
    }
    await _persistState();
  }

  /// 所有收藏文章（跨源），按缓存/已读时间倒序。
  List<RssArticleRecord> getAllFavorites() {
    final list = _states.values.where((r) => r.favorite).toList();
    list.sort((a, b) =>
        (b.cachedAt ?? b.readAt ?? 0).compareTo(a.cachedAt ?? a.readAt ?? 0));
    return list;
  }

  /// 抓取文章全文并缓存（之后断网亦可离线阅读）。url 为空跳过。
  Future<void> fetchFullText(String feedId, RssItem item) async {
    final k = RssArticleRecord.key(feedId, item.url, item.title);
    if (item.url.isEmpty) return;
    try {
      final html = await HttpFetcher.instance.getHtml(
        item.url,
        net: NetworkConfigService.instance.globalProfile,
      );
      final readable = extractReadableHtml(html);
      final prev = _states[k] ?? _recordFromItem(feedId, item);
      _states[k] = prev.copyWith(
        content: readable,
        cachedAt: DateTime.now().millisecondsSinceEpoch,
      );
      await _persistState();
    } on Object {
      // 抓取失败不影响已有内容
    }
  }

  // ---- 持久化 ----

  Future<void> _persistCache() async {
    final map = <String, dynamic>{};
    for (final entry in _feedCache.entries) {
      map[entry.key] = entry.value.map(_itemToMeta).toList();
    }
    try {
      await _backend.set(_cacheKey, jsonEncode(map));
    } on Object {
      // 忽略持久化异常，保留内存状态
    }
  }

  Future<void> _persistState() async {
    final map = <String, dynamic>{};
    for (final entry in _states.entries) {
      map[entry.key] = entry.value.toJson();
    }
    try {
      await _backend.set(_stateKey, jsonEncode(map));
    } on Object {
      // 忽略持久化异常，保留内存状态
    }
  }

  // ---- 辅助 ----

  RssArticleRecord _upsert(String feedId, RssItem item) {
    final k = RssArticleRecord.key(feedId, item.url, item.title);
    final prev = _states[k];
    final merged = RssArticleRecord(
      feedId: feedId,
      itemUrl: item.url,
      title: item.title,
      author: item.author,
      coverUrl: item.coverUrl,
      publishedAtMs: item.publishedAt?.millisecondsSinceEpoch,
      description: item.description,
      read: prev?.read ?? false,
      favorite: prev?.favorite ?? false,
      readAt: prev?.readAt,
      content: prev?.content,
      cachedAt: prev?.cachedAt,
      enclosures: item.enclosures,
    );
    _states[k] = merged;
    return merged;
  }

  RssArticleRecord _recordFromItem(String feedId, RssItem item) => RssArticleRecord(
        feedId: feedId,
        itemUrl: item.url,
        title: item.title,
        author: item.author,
        coverUrl: item.coverUrl,
        publishedAtMs: item.publishedAt?.millisecondsSinceEpoch,
        description: item.description,
        enclosures: item.enclosures,
      );

  static Map<String, dynamic> _itemToMeta(RssItem item) => <String, dynamic>{
        'title': item.title,
        'url': item.url,
        'author': item.author,
        'coverUrl': item.coverUrl,
        'publishedAtMs': item.publishedAt?.millisecondsSinceEpoch,
        'description': item.description,
        'enclosures': item.enclosures.map((e) => e.toJson()).toList(),
      };

  static RssItem _itemFromMeta(Map<String, dynamic> m) => RssItem(
        title: m['title'] as String? ?? '',
        url: m['url'] as String? ?? '',
        author: m['author'] as String?,
        coverUrl: m['coverUrl'] as String?,
        publishedAt: m['publishedAtMs'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(m['publishedAtMs'] as int),
        description: m['description'] as String?,
        enclosures: (m['enclosures'] as List<dynamic>?)
                ?.whereType<Map>()
                .map((e) => RssEnclosure.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const <RssEnclosure>[],
      );

  /// 从 HTML 抽取可读正文（保留图片/链接，去除脚本/样式/导航/页眉/页脚/侧栏）。
  static String extractReadableHtml(String html) {
    var s = html;
    s = s.replaceAll(RegExp(r'<!--[\s\S]*?-->', caseSensitive: false), '');
    s = s.replaceAll(
        RegExp(r'<script[\s\S]*?</script>', caseSensitive: false), '');
    s = s.replaceAll(
        RegExp(r'<style[\s\S]*?</style>', caseSensitive: false), '');
    s = s.replaceAll(
        RegExp(r'<noscript[\s\S]*?</noscript>', caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'<head[\s\S]*?</head>', caseSensitive: false), '');
    // 渲染型/交互型危险标签：整段移除（含闭合），避免 XSS/追踪/钓鱼表单。
    s = s.replaceAll(RegExp(r'<iframe[\s\S]*?</iframe>', caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'<object[\s\S]*?</object>', caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'<embed[\s\S]*?</embed>', caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'<form[\s\S]*?</form>', caseSensitive: false), '');
    final bodyMatch =
        RegExp(r'<body[\s\S]*?>(.*)</body>', caseSensitive: false).firstMatch(s);
    final inner = bodyMatch?.group(1) ?? s;
    final cleaned = inner
        .replaceAll(RegExp(r'<nav[\s\S]*?</nav>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<header[\s\S]*?</header>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<footer[\s\S]*?</footer>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<aside[\s\S]*?</aside>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<iframe[\s\S]*?</iframe>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<object[\s\S]*?</object>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<embed[\s\S]*?</embed>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<form[\s\S]*?</form>', caseSensitive: false), '');
    return cleaned.trim();
  }
}

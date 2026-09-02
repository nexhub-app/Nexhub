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

import 'package:html/dom.dart' as html_dom;
import 'package:html/parser.dart' as html_parser;

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
  /// 返回是否成功取得正文，供调用方区分「已更新 / 抓取失败」给出反馈
  /// （此前失败被静默吞掉，用户点了按钮毫无反应，分不清是抓着还是挂了）。
  ///
  /// 防止频繁抓取：已有缓存且距上次抓取不足 [_fullTextMinInterval] 时直接
  /// 复用缓存（不再请求原站）；超过间隔或从未抓过才重新抓取。
  static const Duration _fullTextMinInterval = Duration(minutes: 10);
  Future<bool> fetchFullText(String feedId, RssItem item) async {
    if (item.url.isEmpty) return false;
    final k = RssArticleRecord.key(feedId, item.url, item.title);
    final prev = _states[k];
    if (prev?.content != null && prev!.content!.isNotEmpty) {
      final cachedAt = prev.cachedAt ?? 0;
      if (DateTime.now().millisecondsSinceEpoch - cachedAt <
          _fullTextMinInterval.inMilliseconds) {
        return prev.content!.trim().isNotEmpty;
      }
    }
    try {
      final html = await HttpFetcher.instance.getHtml(
        item.url,
        net: NetworkConfigService.instance.globalProfile,
      );
      final readable = extractReadableHtml(html);
      if (readable.trim().isEmpty) return false;
      final prev = _states[k] ?? _recordFromItem(feedId, item);
      _states[k] = prev.copyWith(
        content: readable,
        cachedAt: DateTime.now().millisecondsSinceEpoch,
      );
      await _persistState();
      return true;
    } on Object {
      // 抓取失败不影响已有内容
      return false;
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

  /// 从 HTML 抽取可读正文：启发式 Readability 评分，保留图片/链接/标题，
  /// 去除脚本/样式/导航/页眉/页脚/侧栏/评论区/推荐位等非正文区块。
  ///
  /// 流程（package:html 解析，容错残缺 HTML5）：
  /// 1. 整类剔除噪音标签（script/style/iframe/表单控件 + nav/header/footer/aside）；
  /// 2. 按 class/id 关键词剔除疑似噪音容器（评论/侧栏/推荐/分享/广告等）；
  /// 3. 候选容器（article/main/[role=main] + 正文关键词 class/id）按
  ///    「纯文本量 + 图片加权 − 链接密度惩罚」评分取最优；
  /// 4. 无明显正文容器或解析失败时回退正则清洗的整个 body（老行为）。
  static String extractReadableHtml(String html) {
    try {
      final html_dom.Document doc = html_parser.parse(html);
      final html_dom.Element? body = doc.body;
      if (body == null) return _extractReadableHtmlFallback(html);

      // 1) 噪音标签整类剔除（渲染型/交互型/结构型）。
      body.querySelectorAll(
        'script, style, noscript, iframe, object, embed, form, button, '
        'input, select, textarea, svg, canvas, nav, header, footer, aside, '
        'link, meta',
      ).forEach((html_dom.Element e) => e.remove());

      // 2) class/id 关键词疑似噪音容器。
      // 注意关键词均为「区块语义」而非「正文语义」：header/footer 会误伤
      // .post-header（丢标题/署名），但标题已在顶栏展示，可接受。
      final RegExp junk = RegExp(
        r'(nav|menu|sidebar|side-bar|comment|footer|header|banner|advert|'
        r'ads?-|-ads|promo|share|social|related|recommend|breadcrumb|'
        r'pagination|pager|popup|modal|tooltip|subscribe|newsletter|login|'
        r'signup|donate|copyright|widget|archive|taglist|jump|seo)',
        caseSensitive: false,
      );
      for (final html_dom.Element e
          in List<html_dom.Element>.from(body.querySelectorAll(
        'div, section, ul, ol, dl',
      ))) {
        final String sig = '${e.id} ${e.classes.join(' ')}';
        if (sig.trim().isNotEmpty && junk.hasMatch(sig)) e.remove();
      }

      // 3) 候选容器评分。
      final RegExp contentKeyword = RegExp(
        r'(article|content|post|entry|story|main|body|text)',
        caseSensitive: false,
      );
      final List<html_dom.Element> candidates = <html_dom.Element>[];
      void addCandidate(html_dom.Element e) {
        if (!candidates.contains(e) && e.parent != null) candidates.add(e);
      }

      body.querySelectorAll('article, main, [role="main"], [itemprop="articleBody"]')
          .forEach(addCandidate);
      body.querySelectorAll('div, section').forEach((html_dom.Element e) {
        final String sig = '${e.id} ${e.classes.join(' ')}';
        if (contentKeyword.hasMatch(sig)) addCandidate(e);
      });

      html_dom.Element best = body;
      double bestScore = -1;
      for (final html_dom.Element e in candidates) {
        final String text = e.text.replaceAll(RegExp(r'\s+'), '');
        final int textLen = text.length;
        if (textLen == 0) continue;
        final int imgs = e.querySelectorAll('img').length;
        // 链接文本占比过高 → 目录/索引/聚合页，不是正文。
        int linkTextLen = 0;
        for (final html_dom.Element a in e.querySelectorAll('a')) {
          linkTextLen += a.text.replaceAll(RegExp(r'\s+'), '').length;
        }
        final double linkDensity = textLen == 0 ? 1.0 : linkTextLen / textLen;
        double score = textLen + (imgs > 10 ? 10 : imgs) * 150;
        if (linkDensity > 0.3) score *= 0.4;
        if (score > bestScore) {
          bestScore = score;
          best = e;
        }
      }

      // 正文量过低（评分阈值）：识别不可靠，回退整 body 保底。
      if (identical(best, body) || bestScore < 300) return body.innerHtml;
      return best.innerHtml;
    } on Object {
      return _extractReadableHtmlFallback(html);
    }
  }

  /// 兜底：package:html 解析失败（极端残缺文档）时的正则清洗，即老实现。
  static String _extractReadableHtmlFallback(String html) {
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

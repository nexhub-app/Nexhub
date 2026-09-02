/// RSS 订阅管理器（文档 §10.2）。
///
/// 管理订阅源列表的 CRUD + 持久化，按 [SourceType] 隔离。
/// 抓取和解析通过 [RssParser] + [HttpFetcher] 完成。
/// UI 通过 [ChangeNotifier] 驱动。
library;

import 'dart:convert';
import 'dart:developer' as dev;

import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter/foundation.dart';

import '../comic/models/reader_preferences.dart';
import '../models/plugin_config.dart';
import '../network/network_config_service.dart';
import '../scraper/http_fetcher.dart';
import 'rss_article_store.dart';
import 'rss_feed.dart';
import 'rss_parser.dart';

/// RSS 订阅管理器——全应用单例（Provider 注入）。
class RssManager extends ChangeNotifier {
  RssManager({PrefsBackend? backend})
      : _backend = backend ?? const SharedPrefsBackend();

  final PrefsBackend _backend;
  static const String _key = 'rss_feeds_v1';
  /// 独立分组注册表键（与订阅源分开存）。
  ///
  /// 为什么需要它：分组原本是从各订阅的 [RssFeed.groups] 求并集「派生」出来的，
  /// 于是**空分组无法存在**——新分组必须先挂到某个订阅上才显示得出来，用户在
  /// 「管理分组」里点了「新建」却看不到任何反馈。注册表让分组成为一等公民：
  /// 可以先建空分组，之后再把订阅勾选进去。
  static const String _keyGroups = 'rss_groups_v1';

  final List<RssFeed> _feeds = [];
  /// 用户显式创建的分组名（去重、去空白、保序）。
  final List<String> _standaloneGroups = <String>[];

  /// 所有订阅源（只读）。
  List<RssFeed> get feeds => List.unmodifiable(_feeds);

  /// 某模块的订阅源。
  List<RssFeed> feedsFor(SourceType? type) {
    if (type == null) return feeds;
    return List.unmodifiable(_feeds.where((f) => f.moduleType == type));
  }

  /// 未绑定模块的订阅源（浏览页全局 RSS）。
  List<RssFeed> get globalFeeds =>
      List.unmodifiable(_feeds.where((f) => f.moduleType == null));

  /// 所有用户分组名（按首次出现顺序，去重、去空白）。
  ///
  /// 分组是「标签」语义：一份订阅可属于多个分组，因此不是树形目录，而是
  /// ① 独立注册表里的分组 ∪ ② 各订阅 [RssFeed.groups] 派生的分组。
  ///
  /// 两者并集而非只取其一：注册表让**空分组**能存在（见 [_keyGroups] 说明）；
  /// 派生保证 OPML 导入等「直接给订阅打标签」的路径无需先建分组也能显示。
  List<String> get allGroups {
    final names = <String>[];
    void add(String raw) {
      final t = raw.trim();
      if (t.isNotEmpty && !names.contains(t)) names.add(t);
    }

    for (final g in _standaloneGroups) {
      add(g);
    }
    for (final f in _feeds) {
      for (final g in f.groups) {
        add(g);
      }
    }
    return names;
  }

  /// 属于某分组的订阅；[group] 为空串时返回未分组的订阅。
  List<RssFeed> feedsInGroup(String group) {
    if (group.isEmpty) {
      return List.unmodifiable(_feeds.where((f) => f.groups.isEmpty));
    }
    return List.unmodifiable(_feeds.where((f) => f.groups.contains(group)));
  }

  /// 初始化：加载持久化数据（订阅源 + 独立分组注册表）。
  Future<void> init() async {
    final raw = await _backend.get(_key);
    if (raw != null) {
      try {
        final list = jsonDecode(raw) as List<dynamic>;
        _feeds.clear();
        _feeds.addAll(
          list.map((e) => RssFeed.fromJson(e as Map<String, dynamic>)),
        );
      } catch (_) {
        // 损坏数据忽略
      }
    }
    final rawGroups = await _backend.get(_keyGroups);
    if (rawGroups != null) {
      try {
        final list = jsonDecode(rawGroups) as List<dynamic>;
        _standaloneGroups
          ..clear()
          ..addAll(list.whereType<String>().map((g) => g.trim()).where((g) => g.isNotEmpty));
      } catch (_) {
        // 损坏数据忽略
      }
    }
    notifyListeners();
  }

  /// 添加订阅源。
  ///
  /// [url] RSS/Atom 链接；[title] 自定义标题（可选，缺省时从 feed 获取）；
  /// [moduleType] 绑定的模块类型（null = 全局浏览页）。
  Future<RssFeed> addFeed({
    required String url,
    String? title,
    String? description,
    SourceType? moduleType,
    List<String>? groups,
  }) async {
    final id = feedIdFromUrl(url);

    // 去重：已存在同一 URL 的订阅时，若本次传入的 moduleType 不同则合并更新
    // （B9：此前直接返回原订阅，无法为重绑模块而「重新添加」）。
    final existingIdx = _feeds.indexWhere((f) => f.id == id);
    if (existingIdx >= 0) {
      final existing = _feeds[existingIdx];
      // 分组合并：OPML 导入时同一订阅可能出现在多个分组下，取并集保留全部。
      final List<String>? merged = (groups == null || groups.isEmpty)
          ? null
          : <String>{
              ...existing.groups,
              ...groups.map((g) => g.trim()).where((g) => g.isNotEmpty),
            }.toList();
      if (moduleType != existing.moduleType || merged != null) {
        // 仅合并分组（moduleType 传 null）时不动原有模块绑定，避免 OPML 导入
        // 把已绑定模块的订阅意外打回全局；显式传 moduleType 时仍按 B9 重绑。
        final effectiveModule =
            (merged != null && moduleType == null) ? existing.moduleType : moduleType;
        final updated =
            existing.copyWith(moduleType: effectiveModule, groups: merged);
        _feeds[existingIdx] = updated;
        // 持久化失败仍通知 UI 刷新（见 updateFeed 说明）。
        try {
          await _persist();
        } on Object {
          // 忽略持久化异常，保留内存状态。
        }
        notifyListeners();
        return updated;
      }
      return existing;
    }

    final feed = RssFeed(
      id: id,
      title: title ?? url,
      url: url,
      description: description,
      moduleType: moduleType,
      groups: groups ?? const <String>[],
      addedAt: DateTime.now().millisecondsSinceEpoch,
    );

    _feeds.add(feed);
    try {
      await _persist();
    } on Object {
      // 忽略持久化异常，保留内存状态。
    }
    notifyListeners();
    return feed;
  }

  /// 移除订阅源。
  Future<void> removeFeed(String id) async {
    _feeds.removeWhere((f) => f.id == id);
    await _persist();
    notifyListeners();
  }

  /// 更新订阅源。
  Future<void> updateFeed(RssFeed updated) async {
    final idx = _feeds.indexWhere((f) => f.id == updated.id);
    if (idx < 0) {
      // 早退：传入的 id 在内存列表里找不到（理论上不应发生，仅用于诊断）。
      dev.log('[RssManager] updateFeed MISS id=${updated.id} '
          '(moduleType=${updated.moduleType}); _feeds 共 ${_feeds.length} 条');
      return;
    }
    _feeds[idx] = updated;
    // 持久化失败不应阻断内存更新与 UI 刷新（notifyListeners 始终执行），
    // 否则 unbind/bind 等操作在 _persist 抛错时会静默失败、列表不刷新。
    try {
      await _persist();
    } on Object {
      // 持久化异常：保留内存状态，UI 仍应刷新。
    }
    notifyListeners();
    dev.log('[RssManager] updateFeed OK id=${updated.id} '
        'moduleType=${updated.moduleType} -> feedsFor(该分类) 剩 '
        '${feedsFor(updated.moduleType).length} 条');
  }

  /// 强制通知所有监听者（UI 兜底刷新用，避免 watch 时序未触发重建）。
  void notifyChanged() => notifyListeners();

  /// 将某订阅移回全局（moduleType 置空）。
  ///
  /// 优先按 [id] 查找；若未命中（理论不应发生）则按 [url] 兜底，
  /// 确保「移回全局」在任何 id 边界情况下都能生效，避免列表不刷新。
  Future<void> unbindFeed(String id, String url) async {
    var idx = _feeds.indexWhere((f) => f.id == id);
    if (idx < 0) idx = _feeds.indexWhere((f) => f.url == url);
    if (idx < 0) {
      dev.log('[RssManager] unbindFeed MISS id=$id url=$url; '
          '_feeds 共 ${_feeds.length} 条');
      return;
    }
    _feeds[idx] = _feeds[idx].copyWith(moduleType: null);
    try {
      await _persist();
    } on Object {
      // 忽略持久化异常，保留内存状态。
    }
    notifyListeners();
    dev.log('[RssManager] unbindFeed OK id=$id -> 全局视图 ${globalFeeds.length} 条');
  }

  /// 设置某订阅的分组（整体覆盖，传空列表即移出所有分组）。
  Future<void> setFeedGroups(String feedId, List<String> groups) async {
    final idx = _feeds.indexWhere((f) => f.id == feedId);
    if (idx < 0) return;
    _feeds[idx] = _feeds[idx].copyWith(
      groups: groups
          .map((g) => g.trim())
          .where((g) => g.isNotEmpty)
          .toList(),
    );
    try {
      await _persist();
    } on Object {
      // 忽略持久化异常，保留内存状态。
    }
    notifyListeners();
  }

  /// 新建分组（写入独立注册表，**允许是空分组**）。
  ///
  /// 返回是否真的新建：重名或空名返回 false，不产生重复项。
  /// 分组从此不依赖「必须挂到某个订阅上才存在」——可以先建空壳，之后再把
  /// 订阅勾选进去（此前只能在订阅项里顺带命名，管理页「新建」点了没反应）。
  Future<bool> createGroup(String name) async {
    final t = name.trim();
    if (t.isEmpty) return false;
    if (_standaloneGroups.any((g) => g == t)) return false;
    _standaloneGroups.add(t);
    try {
      await _persistGroups();
    } on Object {
      // 忽略持久化异常，保留内存状态。
    }
    notifyListeners();
    return true;
  }

  /// 重命名分组：把所有订阅里的旧名替换为新名，并同步独立注册表。
  ///
  /// 新名已存在时合并（两份订阅归入同一分组）；新名为空视为无操作。
  Future<void> renameGroup(String oldName, String newName) async {
    final to = newName.trim();
    if (to.isEmpty || to == oldName) return;
    for (var i = 0; i < _feeds.length; i++) {
      final f = _feeds[i];
      if (!f.groups.contains(oldName)) continue;
      final merged = <String>{
        ...f.groups.where((g) => g != oldName),
        to,
      }.toList();
      _feeds[i] = f.copyWith(groups: merged);
    }
    // 注册表同步：旧名换为新名；新名已存在则只删旧名，避免留下重复项。
    final idx = _standaloneGroups.indexWhere((g) => g == oldName);
    if (idx >= 0) {
      _standaloneGroups.removeAt(idx);
      if (!_standaloneGroups.contains(to)) {
        _standaloneGroups.insert(idx, to);
      }
    }
    try {
      await _persist();
      await _persistGroups();
    } on Object {
      // 忽略持久化异常，保留内存状态。
    }
    notifyListeners();
  }

  /// 删除分组：仅移除「分组标记」，不删订阅本身。
  ///
  /// 同时从独立注册表移除——否则删掉的空分组下次启动会「复活」。
  Future<void> deleteGroup(String name) async {
    for (var i = 0; i < _feeds.length; i++) {
      final f = _feeds[i];
      if (!f.groups.contains(name)) continue;
      _feeds[i] = f.copyWith(
        groups: f.groups.where((g) => g != name).toList(),
      );
    }
    _standaloneGroups.removeWhere((g) => g == name);
    try {
      await _persist();
      await _persistGroups();
    } on Object {
      // 忽略持久化异常，保留内存状态。
    }
    notifyListeners();
  }

  /// 抓取并解析订阅源内容。
  ///
  /// [net] 显式传全局网络档案，使代理/SNI/DNS/hosts 对 RSS 生效（B1 铁律）。
  /// [force] 为 true 时不带条件请求头（强制整篇重新抓取），用于手动刷新绕过
  /// 304 缓存校验。
  ///
  /// 条件 GET（P2-1）：若本订阅已缓存 [etag]/[lastModified]，则带上
  /// `If-None-Match`/`If-Modified-Since`；服务端返回 304 时直接复用本地缓存条目，
  /// 省去重复下载。响应头里的 `ETag`/`Last-Modified` 会回写进订阅并持久化。
  Future<ParsedFeed> fetchFeed(RssFeed feed, {bool force = false}) async {
    final headers = <String, String>{};
    if (!force) {
      if (feed.etag != null && feed.etag!.isNotEmpty) {
        headers['If-None-Match'] = feed.etag!;
      }
      if (feed.lastModified != null && feed.lastModified!.isNotEmpty) {
        headers['If-Modified-Since'] = feed.lastModified!;
      }
    }

    final resp = await HttpFetcher.instance.fetchBytes(
      feed.url,
      headers: headers.isEmpty ? null : headers,
      net: NetworkConfigService.instance.globalProfile,
    );

    // 304 Not Modified：复用本地缓存条目（离线/省流量）。
    if (resp['status'] == 304) {
      await RssArticleStore.instance.init();
      final cached = RssArticleStore.instance.getFeedItems(feed.id);
      if (cached.isNotEmpty) {
        dev.log('[RssManager] fetchFeed 304 命中缓存 id=${feed.id} '
            '(${cached.length} 条)');
        return ParsedFeed(title: feed.title, items: cached);
      }
      // 极端情况：服务端说没变但本地缓存为空（缓存被清），清除校验值下次整取。
      if (feed.etag != null || feed.lastModified != null) {
        await updateFeed(feed.copyWith(etag: null, lastModified: null));
      }
      return ParsedFeed(title: feed.title, items: const <RssItem>[]);
    }

    // 按 feed 声明的字符集解码原始字节（B12：非 UTF-8 feed 不乱码），
    // 再交给解析器。此前走 HttpFetcher.fetch 的共享解码会漏掉 RSS 的
    // `<?xml encoding=?>` 声明，且不支持 Latin-1 等西欧编码。
    final rh =
        (resp['headers'] as Map<String, String>? ?? const <String, String>{});
    final bytes = resp['bytes'] as List<int>? ?? const <int>[];
    final body = _decodeFeedBytes(bytes, rh['content-type']);
    final parsed = _normalizeFeedUrls(RssParser.parse(body), feed.url);

    // 回写条件 GET 校验值（响应头大小写不固定，逐个忽略大小写匹配）。
    String? newEtag;
    String? newLastModified;
    for (final entry in rh.entries) {
      final k = entry.key.toLowerCase();
      if (k == 'etag') {
        newEtag = entry.value;
      } else if (k == 'last-modified') {
        newLastModified = entry.value;
      }
    }
    if (newEtag != null || newLastModified != null) {
      await updateFeed(feed.copyWith(etag: newEtag, lastModified: newLastModified));
    }
    return parsed;
  }

  /// 抓取并尝试自动发现 feed 元信息（标题/描述/站点地址）。
  Future<ParsedFeed> discoverFeed(String url) async {
    final resp = await HttpFetcher.instance.fetchBytes(
      url,
      net: NetworkConfigService.instance.globalProfile,
    );
    final rh =
        (resp['headers'] as Map<String, String>? ?? const <String, String>{});
    final bytes = resp['bytes'] as List<int>? ?? const <int>[];
    return RssParser.parse(_decodeFeedBytes(bytes, rh['content-type']));
  }

  /// 后台补全订阅源元信息（标题 / 描述 / 站点地址 / 图标）：抓取解析后回填，
  /// 失败静默保留原记录。
  ///
  /// 用于「先入库后校验」流程，使添加订阅即时返回、不阻塞主线程。
  Future<void> discoverAndUpdate(RssFeed feed) async {
    try {
      final parsed = _normalizeFeedUrls(await discoverFeed(feed.url), feed.url);
      await updateFeed(feed.copyWith(
        title: parsed.title,
        description: parsed.description,
        siteUrl: parsed.siteUrl,
        iconUrl: _resolveIconUrl(parsed, feed.url),
      ));
    } on Object {
      // 后台补全失败不影响已添加的订阅。
    }
  }

  /// 解析 feed 图标地址：优先用 feed 自带的 [ParsedFeed.iconUrl]，缺失时回退到
  /// 站点根 `/favicon.ico`（修复 B8：此前 favicon 永不填充）。
  static String? _resolveIconUrl(ParsedFeed parsed, String feedUrl) {
    if (parsed.iconUrl != null && parsed.iconUrl!.isNotEmpty) {
      return parsed.iconUrl;
    }
    final uri = Uri.tryParse(feedUrl);
    if (uri == null || uri.host.isEmpty) return null;
    return '${uri.origin}/favicon.ico';
  }

  /// 把 feed 内条目的相对 URL（link / coverUrl / enclosure）按 feed 地址解析为
  /// 绝对地址（B5）。
  ///
  /// 同时保留并解析附件地址——此前重建 [RssItem] 时漏传 [RssItem.enclosures]，
  /// 导致播客附件在相对 URL 归一化后被静默丢弃（P2-3 附件功能依赖该字段）。
  ParsedFeed _normalizeFeedUrls(ParsedFeed parsed, String baseUrl) {
    final base = Uri.tryParse(baseUrl);
    if (base == null) return parsed;
    final items = parsed.items.map((item) {
      final absUrl = item.url.isNotEmpty ? base.resolve(item.url).toString() : item.url;
      final absCover = item.coverUrl != null && item.coverUrl!.isNotEmpty
          ? base.resolve(item.coverUrl!).toString()
          : item.coverUrl;
      // 附件地址同样按 feed 地址绝对化（播客 enclosure 偶见相对路径）。
      final absEnclosures = item.enclosures.map((e) {
        final absEncUrl = e.url.isNotEmpty ? base.resolve(e.url).toString() : e.url;
        return RssEnclosure(
          url: absEncUrl,
          type: e.type,
          length: e.length,
          title: e.title,
        );
      }).toList();
      return RssItem(
        title: item.title,
        url: absUrl,
        description: item.description,
        author: item.author,
        publishedAt: item.publishedAt,
        coverUrl: absCover,
        content: item.content,
        enclosures: absEnclosures,
      );
    }).toList();
    // feed 级元信息中的相对地址也一并绝对化（站点地址 / 图标）。
    final absSiteUrl = parsed.siteUrl != null && parsed.siteUrl!.isNotEmpty
        ? base.resolve(parsed.siteUrl!).toString()
        : parsed.siteUrl;
    final absIconUrl = parsed.iconUrl != null && parsed.iconUrl!.isNotEmpty
        ? base.resolve(parsed.iconUrl!).toString()
        : parsed.iconUrl;
    return ParsedFeed(
      title: parsed.title,
      description: parsed.description,
      siteUrl: absSiteUrl,
      iconUrl: absIconUrl,
      items: items,
    );
  }

  /// 按 feed 声明的字符集把原始字节解码为字符串（B12 修复：非 UTF-8 feed 不乱码）。
  ///
  /// 字符集探测优先级（与 `HttpFetcher._detectCharset` 互补，额外识别 XML 声明）：
  /// ① HTTP Content-Type 的 `charset=`；② XML 声明 `<?xml ... encoding="..."?>`
  /// （RSS/RDF/Atom 经此声明，共享解码层只识别 HTML `<meta charset>` 会漏掉）；
  /// ③ HTML `<meta charset>`（兼容以 `text/html` 返回的 feed）；④ 默认 UTF-8。
  ///
  /// 解码分支：utf-8（含 US-ASCII）走 [utf8]；GBK 系列
  /// （GBK/GB2312/GB18030）走 [gbk]（fast_gbk）；西欧 Latin 系列
  /// （ISO-8859-1/Latin1/Windows-1252）走 [latin1]（Dart 内置，近似还原，远优于
  /// 乱码）。其余字符集兜底 UTF-8（`allowMalformed` 避免整篇炸成替换符）。
  /// 注：日文(Shift-JIS)/韩文(EUC-KR)/西里尔(Windows-1251) 等未在范围内，按 UTF-8
  /// 兜底（此类 feed 在本应用受众中极罕见），如需支持需引入通用 charset 库。
  static String _decodeFeedBytes(List<int> bytes, String? contentType) {
    if (bytes.isEmpty) return '';
    final charset = _detectFeedCharset(bytes, contentType);
    if (charset != null && _isGbkFamily(charset)) {
      try {
        return gbk.decode(bytes);
      } on Object {
        // GBK 解码失败（极罕见非法序列）→ 退回 UTF-8。
      }
    }
    if (charset != null && _isLatin1Family(charset)) {
      try {
        return latin1.decode(bytes);
      } on Object {
        // Latin-1 解码失败 → 退回 UTF-8。
      }
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// 从 Content-Type 头、XML 声明、`<meta charset>` 探测字符集声明。
  static String? _detectFeedCharset(List<int> bytes, String? contentType) {
    if (contentType != null) {
      final m = RegExp(r'charset=([^\s;]+)', caseSensitive: false)
          .firstMatch(contentType);
      if (m != null) return m.group(1)?.trim();
    }
    // 仅扫头部前 2KB，非 ASCII 字节映射为空格以便用 ASCII 正则匹配声明。
    final headLen = bytes.length < 2048 ? bytes.length : 2048;
    final headAscii = String.fromCharCodes(
      bytes.sublist(0, headLen).map((b) => b < 128 ? b : 0x20),
    );
    final lower = headAscii.toLowerCase();
    // XML 声明：<?xml ... encoding="..."?>（RSS/RDF/Atom 经此声明编码）。
    final xml =
        RegExp(r'encoding[^\w]*=[^\w]*([a-z0-9_-]+)').firstMatch(lower);
    if (xml != null) return xml.group(1);
    // HTML <meta charset> / <meta http-equiv="Content-Type" ...charset=...>。
    final meta =
        RegExp(r'charset[^\w]*=[^\w]*([a-z0-9_-]+)').firstMatch(lower);
    return meta?.group(1);
  }

  /// 是否为 GBK 系列字符集（GBK/GB2312/GB18030 等），统一用 [gbk] 解码。
  static bool _isGbkFamily(String charset) {
    final c = charset.toLowerCase().replaceAll('_', '-');
    return c == 'gbk' ||
        c == 'gb2312' ||
        c == 'gb-2312' ||
        c == 'gb18030' ||
        c == 'gb_2312' ||
        c == 'csgb2312' ||
        c == 'csiso58bgb231280';
  }

  /// 是否为西欧 Latin 系列字符集（ISO-8859-1/Latin1/Windows-1252 等），
  /// 统一用 [latin1] 解码（Windows-1252 与 Latin-1 在 0x80–0x9F 略有差异，
  /// 用 latin1 近似还原已远优于乱码，RSS 场景可接受）。
  static bool _isLatin1Family(String charset) {
    final c = charset.toLowerCase().replaceAll('_', '-');
    return c == 'iso-8859-1' ||
        c == 'iso8859-1' ||
        c == 'latin1' ||
        c == 'latin-1' ||
        c == 'windows-1252' ||
        c == 'cp1252' ||
        c == 'cp-1252' ||
        c == 'csisolatin1' ||
        c == 'ibm819' ||
        c == 'iso-ir-100';
  }

  /// 测速单个订阅源，返回延迟（毫秒）；失败返回 -1（P8.2.3 §廿二 RSS 一键测速）。
  Future<int> testFeedSpeed(RssFeed feed) async {
    final sw = Stopwatch()..start();
    try {
      await HttpFetcher.instance.getHtml(
        feed.url,
        net: NetworkConfigService.instance.globalProfile,
      );
      sw.stop();
      return sw.elapsedMilliseconds;
    } on Object {
      sw.stop();
      return -1;
    }
  }

  /// 测速全部订阅源，返回 `feedId → 延迟毫秒`（-1 表示失败）。
  /// 每次测速完成后通过 [onProgress] 回调通知 UI 更新（P8.2.3 §廿二）。
  Future<Map<String, int>> testAllFeeds({
    void Function(String feedId, int latencyMs)? onProgress,
  }) async {
    final results = <String, int>{};
    for (final feed in _feeds) {
      final ms = await testFeedSpeed(feed);
      results[feed.id] = ms;
      onProgress?.call(feed.id, ms);
    }
    return results;
  }

  Future<void> _persist() async {
    final list = _feeds.map((f) => f.toJson()).toList();
    await _backend.set(_key, jsonEncode(list));
  }

  /// 持久化独立分组注册表（与订阅源分开存，见 [_keyGroups] 说明）。
  Future<void> _persistGroups() async {
    await _backend.set(_keyGroups, jsonEncode(_standaloneGroups));
  }
}

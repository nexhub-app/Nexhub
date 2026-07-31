/// 收藏管理器（文档 §10.2）。
///
/// 三模块共用，按 [SourceType] 隔离收藏列表。
/// 持久化到 [PrefsBackend]，UI 通过 [ChangeNotifier] 驱动。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../comic/models/reader_preferences.dart';
import '../models/media_item.dart';
import '../models/plugin_config.dart';
import 'favorite_group.dart';

/// 收藏条目——精简版 MediaItem，只保留书架展示所需字段。
class FavoriteEntry {
  final String id;
  final String title;
  final String? coverUrl;
  final String? sourceId;
  final SourceType sourceType;
  final String? author;
  final String? detailUrl;
  final int favoritedAt;

  /// 最后阅读时间（毫秒），0 表示未读过（P8.1.3 §廿一 收藏切换不丢 dateAdded/lastRead）。
  final int lastRead;

  /// 分类（取自 MediaItem.tags 首项），用于书架筛选。
  final String? category;

  /// 状态（连载中 / 已完结），用于书架筛选。
  final String? status;

  /// 所属分组 id 列表（多分组标签），空表示未分组。
  final List<String> groupIds;

  /// 本地评分（0=未评，1-10），随 Bangumi 同步推送为 rate。
  final int myRating;

  /// 本地短评，随 Bangumi 同步推送为 comment。
  final String? myComment;

  const FavoriteEntry({
    required this.id,
    required this.title,
    required this.sourceType,
    this.coverUrl,
    this.sourceId,
    this.author,
    this.detailUrl,
    required this.favoritedAt,
    this.lastRead = 0,
    this.category,
    this.status,
    this.groupIds = const <String>[],
    this.myRating = 0,
    this.myComment,
  });

  factory FavoriteEntry.fromMediaItem(MediaItem item, {int? favoritedAt}) =>
      FavoriteEntry(
        id: item.id,
        title: item.title,
        coverUrl: item.coverUrl,
        sourceId: item.sourceId,
        sourceType: item.sourceType ?? SourceType.animeSource,
        author: item.author,
        detailUrl: item.detailUrl,
        favoritedAt: favoritedAt ?? DateTime.now().millisecondsSinceEpoch,
        lastRead: 0,
        category: item.tags?.isNotEmpty == true ? item.tags!.first : null,
        status: item.status,
      );

  /// 返回一个更新了 lastRead 的副本。
  FavoriteEntry withLastRead(int timestamp) => FavoriteEntry(
        id: id,
        title: title,
        coverUrl: coverUrl,
        sourceId: sourceId,
        sourceType: sourceType,
        author: author,
        detailUrl: detailUrl,
        favoritedAt: favoritedAt,
        lastRead: timestamp,
        category: category,
        status: status,
        groupIds: groupIds,
        myRating: myRating,
        myComment: myComment,
      );

  /// 返回一个更新了 coverUrl 的副本（用于"设为书架封面"）。
  FavoriteEntry withCoverUrl(String? newCoverUrl) => FavoriteEntry(
        id: id,
        title: title,
        coverUrl: newCoverUrl,
        sourceId: sourceId,
        sourceType: sourceType,
        author: author,
        detailUrl: detailUrl,
        favoritedAt: favoritedAt,
        lastRead: lastRead,
        category: category,
        status: status,
        groupIds: groupIds,
        myRating: myRating,
        myComment: myComment,
      );

  /// 返回一个更新了 groupIds 的副本（分组指定面板调用）。
  FavoriteEntry withGroupIds(List<String> newGroupIds) => FavoriteEntry(
        id: id,
        title: title,
        coverUrl: coverUrl,
        sourceId: sourceId,
        sourceType: sourceType,
        author: author,
        detailUrl: detailUrl,
        favoritedAt: favoritedAt,
        lastRead: lastRead,
        category: category,
        status: status,
        groupIds: List<String>.unmodifiable(newGroupIds),
        myRating: myRating,
        myComment: myComment,
      );

  /// 返回一个更新了本地评分 / 短评的副本（Bangumi 绑定面板调用）。
  FavoriteEntry withBangumiMeta({int? myRating, String? myComment}) =>
      FavoriteEntry(
        id: id,
        title: title,
        coverUrl: coverUrl,
        sourceId: sourceId,
        sourceType: sourceType,
        author: author,
        detailUrl: detailUrl,
        favoritedAt: favoritedAt,
        lastRead: lastRead,
        category: category,
        status: status,
        groupIds: groupIds,
        myRating: myRating ?? this.myRating,
        myComment: myComment ?? this.myComment,
      );

  MediaItem toMediaItem() => MediaItem(
        id: id,
        title: title,
        coverUrl: coverUrl,
        sourceId: sourceId,
        sourceType: sourceType,
        author: author,
        detailUrl: detailUrl,
        tags: category != null ? <String>[category!] : null,
        status: status,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'title': title,
        'coverUrl': coverUrl,
        'sourceId': sourceId,
        'sourceType': sourceType.apiName,
        'author': author,
        'detailUrl': detailUrl,
        'favoritedAt': favoritedAt,
        'lastRead': lastRead,
        'category': category,
        'status': status,
        'groupIds': groupIds,
        'myRating': myRating,
        'myComment': myComment,
      };

  factory FavoriteEntry.fromJson(Map<String, dynamic> json) => FavoriteEntry(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        coverUrl: json['coverUrl'] as String?,
        sourceId: json['sourceId'] as String?,
        sourceType:
            SourceType.parse(json['sourceType'] as String?) ?? SourceType.animeSource,
        author: json['author'] as String?,
        detailUrl: json['detailUrl'] as String?,
        favoritedAt: json['favoritedAt'] as int? ?? 0,
        lastRead: json['lastRead'] as int? ?? 0,
        category: json['category'] as String?,
        status: json['status'] as String?,
        groupIds:
            (json['groupIds'] as List?)?.cast<String>() ?? const <String>[],
        myRating: json['myRating'] as int? ?? 0,
        myComment: json['myComment'] as String?,
      );
}

/// 收藏管理器——全应用单例（Provider 注入）。
class FavoritesManager extends ChangeNotifier {
  FavoritesManager({PrefsBackend? backend})
      : _backend = backend ?? const SharedPrefsBackend();

  final PrefsBackend _backend;
  static const String _key = 'favorites_v1';
  static const String _groupsKey = 'favorite_groups_v1';

  final Map<SourceType, List<FavoriteEntry>> _cache = {};

  /// 分组列表（内存态，按 sortOrder 排序后缓存）。
  final List<FavoriteGroup> _groups = <FavoriteGroup>[];

  /// 加载持久化数据（收藏 + 分组）。
  Future<void> init() async {
    final raw = await _backend.get(_key);
    if (raw != null) {
      try {
        final list = jsonDecode(raw) as List<dynamic>;
        for (final item in list) {
          final entry = FavoriteEntry.fromJson(item as Map<String, dynamic>);
          _cache.putIfAbsent(entry.sourceType, () => <FavoriteEntry>[]).add(entry);
        }
      } catch (_) {
        // 损坏数据忽略
      }
    }
    final rawGroups = await _backend.get(_groupsKey);
    if (rawGroups != null) {
      try {
        final list = jsonDecode(rawGroups) as List<dynamic>;
        _groups
          ..clear()
          ..addAll(list.map(
              (e) => FavoriteGroup.fromJson(e as Map<String, dynamic>)));
        _groups.sortByOrder();
      } catch (_) {
        // 损坏数据忽略
      }
    }
    notifyListeners();
  }

  /// 获取某模块的收藏列表（按收藏时间倒序）。
  List<FavoriteEntry> favoritesFor(SourceType type) =>
      List.unmodifiable(_cache[type]?.reversed.toList() ?? const <FavoriteEntry>[]);

  /// 是否已收藏。
  bool isFavorite(String contentId, SourceType type) =>
      _cache[type]?.any((e) => e.id == contentId) ?? false;

  /// 切换收藏状态。重新收藏时保留原始 favoritedAt（P8.1.3 §廿一 不丢 dateAdded）。
  Future<void> toggleFavorite(MediaItem item) async {
    final type = item.sourceType ?? SourceType.animeSource;
    final list = _cache.putIfAbsent(type, () => <FavoriteEntry>[]);

    final idx = list.indexWhere((e) => e.id == item.id);
    if (idx >= 0) {
      // 取消收藏：保留原 favoritedAt 和 lastRead，以便重新收藏时不丢
      final old = list[idx];
      _removedFavoriteCache[item.id] = old;
      list.removeAt(idx);
    } else {
      // 检查是否有刚被移除的缓存（保留原 favoritedAt + lastRead）
      final cached = _removedFavoriteCache.remove(item.id);
      if (cached != null) {
        // 重新收藏：保留原 favoritedAt 和 lastRead，但更新封面/作者等字段
        list.add(FavoriteEntry.fromMediaItem(item,
            favoritedAt: cached.favoritedAt));
        // 保留 lastRead + groupIds（fromMediaItem 会重置）
        final newIdx = list.length - 1;
        list[newIdx] = list[newIdx]
            .withLastRead(cached.lastRead)
            .withGroupIds(cached.groupIds);
      } else {
        list.add(FavoriteEntry.fromMediaItem(item));
      }
    }
    await _persist();
    notifyListeners();
  }

  /// 更新某收藏条目的 lastRead 时间戳（阅读器内调用）。
  Future<void> updateLastRead(String contentId, SourceType type) async {
    final list = _cache[type];
    if (list == null) return;
    final idx = list.indexWhere((e) => e.id == contentId);
    if (idx < 0) return;
    list[idx] = list[idx].withLastRead(DateTime.now().millisecondsSinceEpoch);
    await _persist();
    notifyListeners();
  }

  /// 更新某收藏条目的本地评分 / 短评（Bangumi 绑定面板调用）。
  Future<bool> updateBangumiMeta(
    String contentId,
    SourceType type, {
    int? myRating,
    String? myComment,
  }) async {
    final list = _cache[type];
    if (list == null) return false;
    final idx = list.indexWhere((e) => e.id == contentId);
    if (idx < 0) return false;
    list[idx] =
        list[idx].withBangumiMeta(myRating: myRating, myComment: myComment);
    await _persist();
    notifyListeners();
    return true;
  }

  /// 更新某收藏条目的封面 URL（"设为书架封面"调用）。
  Future<bool> updateCover(
    String contentId,
    SourceType type,
    String? newCoverUrl,
  ) async {
    final list = _cache[type];
    if (list == null) return false;
    final idx = list.indexWhere((e) => e.id == contentId);
    if (idx < 0) return false;
    list[idx] = list[idx].withCoverUrl(newCoverUrl);
    await _persist();
    notifyListeners();
    return true;
  }

  /// 已移除收藏的临时缓存（key=contentId），用于重新收藏时保留原 favoritedAt/lastRead。
  /// 仅内存态，应用重启后不保留。
  final Map<String, FavoriteEntry> _removedFavoriteCache = {};

  /// 移除收藏。
  Future<void> removeFavorite(String contentId, SourceType type) async {
    final list = _cache[type];
    if (list == null) return;
    list.removeWhere((e) => e.id == contentId);
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    final all = <Map<String, dynamic>>[];
    for (final list in _cache.values) {
      all.addAll(list.map((e) => e.toJson()));
    }
    await _backend.set(_key, jsonEncode(all));
  }

  /// Export all favorites as a JSON-serializable list.
  List<Map<String, dynamic>> exportToJson() {
    final all = <Map<String, dynamic>>[];
    for (final list in _cache.values) {
      all.addAll(list.map((e) => e.toJson()));
    }
    return all;
  }

  /// Import favorites from a parsed JSON list (merge, dedup by id).
  Future<void> importFromList(List<dynamic> items) async {
    for (final item in items) {
      if (item is! Map<String, dynamic>) continue;
      final entry = FavoriteEntry.fromJson(item);
      final list =
          _cache.putIfAbsent(entry.sourceType, () => <FavoriteEntry>[]);
      if (list.any((e) => e.id == entry.id)) continue;
      list.add(entry);
    }
    await _persist();
    notifyListeners();
  }

  // ────────────────────── 分组 API ──────────────────────

  /// 全部分组（按 sortOrder 升序，不可变视图）。
  List<FavoriteGroup> get groups => List.unmodifiable(_groups);

  /// 按 id 查分组（不存在返回 null）。
  FavoriteGroup? groupById(String id) {
    for (final g in _groups) {
      if (g.id == id) return g;
    }
    return null;
  }

  /// 某分组下的收藏条目总数（跨三模块）。
  int entryCountInGroup(String groupId) {
    int count = 0;
    for (final list in _cache.values) {
      count += list.where((e) => e.groupIds.contains(groupId)).length;
    }
    return count;
  }

  /// 创建分组。重名（trim 后）拒绝并返回 null，成功返回新分组。
  Future<FavoriteGroup?> createGroup(String name) async {
    final String trimmed = name.trim();
    if (trimmed.isEmpty) return null;
    if (_groups.any((g) => g.name == trimmed)) return null;
    final group = FavoriteGroup(
      id: FavoriteGroup.newId(),
      name: trimmed,
      sortOrder: _groups.isEmpty ? 0 : _groups.last.sortOrder + 1,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    _groups.add(group);
    await _persistGroups();
    notifyListeners();
    return group;
  }

  /// 重命名分组。重名 / 空名 / 分组不存在时返回 false。
  Future<bool> renameGroup(String id, String name) async {
    final String trimmed = name.trim();
    if (trimmed.isEmpty) return false;
    final int idx = _groups.indexWhere((g) => g.id == id);
    if (idx < 0) return false;
    if (_groups.any((g) => g.id != id && g.name == trimmed)) return false;
    _groups[idx] = _groups[idx].copyWith(name: trimmed);
    await _persistGroups();
    notifyListeners();
    return true;
  }

  /// 删除分组：级联从所有条目的 groupIds 中移除该 id，条目本身保留。
  Future<void> deleteGroup(String id) async {
    final int before = _groups.length;
    _groups.removeWhere((g) => g.id == id);
    if (_groups.length == before) return;
    bool entriesChanged = false;
    for (final list in _cache.values) {
      for (int i = 0; i < list.length; i++) {
        if (list[i].groupIds.contains(id)) {
          list[i] = list[i].withGroupIds(
              list[i].groupIds.where((g) => g != id).toList());
          entriesChanged = true;
        }
      }
    }
    await _persistGroups();
    if (entriesChanged) await _persist();
    notifyListeners();
  }

  /// 按给定 id 顺序重排分组（未出现的 id 保持相对顺序排在末尾）。
  Future<void> reorderGroups(List<String> orderedIds) async {
    final Map<String, int> order = <String, int>{
      for (int i = 0; i < orderedIds.length; i++) orderedIds[i]: i,
    };
    for (int i = 0; i < _groups.length; i++) {
      final int? pos = order[_groups[i].id];
      _groups[i] = _groups[i]
          .copyWith(sortOrder: pos ?? (orderedIds.length + i));
    }
    _groups.sortByOrder();
    // 归一化 sortOrder 为连续序号
    for (int i = 0; i < _groups.length; i++) {
      _groups[i] = _groups[i].copyWith(sortOrder: i);
    }
    await _persistGroups();
    notifyListeners();
  }

  /// 设置某收藏条目的分组（覆盖式，自动过滤不存在的分组 id）。
  Future<bool> setEntryGroups(
    String contentId,
    SourceType type,
    List<String> groupIds,
  ) async {
    final list = _cache[type];
    if (list == null) return false;
    final int idx = list.indexWhere((e) => e.id == contentId);
    if (idx < 0) return false;
    final Set<String> valid = _groups.map((g) => g.id).toSet();
    list[idx] = list[idx]
        .withGroupIds(groupIds.where(valid.contains).toList());
    await _persist();
    notifyListeners();
    return true;
  }

  Future<void> _persistGroups() async {
    await _backend.set(
        _groupsKey, jsonEncode(_groups.map((g) => g.toJson()).toList()));
  }

  /// Export all groups as a JSON-serializable list.
  List<Map<String, dynamic>> exportGroups() =>
      _groups.map((g) => g.toJson()).toList();

  /// Import groups from a parsed JSON list (merge, dedup by id & name).
  Future<void> importGroups(List<dynamic> items) async {
    for (final item in items) {
      if (item is! Map<String, dynamic>) continue;
      final group = FavoriteGroup.fromJson(item);
      if (group.id.isEmpty || group.name.isEmpty) continue;
      if (_groups.any((g) => g.id == group.id || g.name == group.name)) {
        continue;
      }
      _groups.add(group);
    }
    _groups.sortByOrder();
    await _persistGroups();
    notifyListeners();
  }
}

extension on List<FavoriteGroup> {
  /// 按 sortOrder 升序排序（同序号按创建时间兼容）。
  void sortByOrder() => sort((a, b) {
        final int c = a.sortOrder.compareTo(b.sortOrder);
        return c != 0 ? c : a.createdAt.compareTo(b.createdAt);
      });
}

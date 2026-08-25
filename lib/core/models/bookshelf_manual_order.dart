/// 书架手动排序持久化（M2 手动排序）。
///
/// 以 `${sourceType.apiName}:${id}` 为键保存自定义顺序索引（0 起递增）。
/// 仅对曾手动排序过的条目写入索引；未写入的条目在排序时回退到当前相对顺序。
library;

import 'dart:convert';

import '../comic/models/reader_preferences.dart'
    show PrefsBackend, SharedPrefsBackend;
import 'package:nexhub/core/models/plugin_config.dart' show SourceType;

/// 书架手动排序存储（SharedPreferences 持久化）。
///
/// 单例 [instance] 在首次读取时惰性加载本地索引表，写入即持久化。
class BookshelfManualOrderStore {
  static final BookshelfManualOrderStore instance =
      BookshelfManualOrderStore();

  static const String _key = 'bookshelf_manual_order_v1';

  final PrefsBackend _backend;
  final Map<String, int> _indexById = <String, int>{};
  bool _loaded = false;

  BookshelfManualOrderStore({PrefsBackend? backend})
      : _backend = backend ?? const SharedPrefsBackend();

  String _k(SourceType type, String id) => '${type.apiName}:$id';

  /// 加载本地索引表（幂等）。首次读取 [indexFor] 会自动触发。
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final String? raw = await _backend.get(_key);
    if (raw == null || raw.isEmpty) return;
    try {
      final Map<String, dynamic> map =
          jsonDecode(raw) as Map<String, dynamic>;
      for (final MapEntry<String, dynamic> e in map.entries) {
        if (e.value is int) _indexById[e.key] = e.value as int;
      }
    } on Object {
      // 损坏数据忽略
    }
  }

  /// 读取某条目在当前模块下的手动顺序索引；未排序过返回 null。
  ///
  /// 若尚未加载，会触发后台加载，下次渲染生效（首次切换手动排序可能有一次未排序）。
  int? indexFor(SourceType type, String id) {
    if (!_loaded) {
      load();
    }
    return _indexById[_k(type, id)];
  }

  /// 应用某模块下可见条目的新顺序（按传入列表顺序写 0..n-1）。
  ///
  /// 仅更新本模块条目，其它模块索引不受影响（键含 sourceType）。
  Future<void> applyOrder(SourceType type, List<String> idsInOrder) async {
    for (var i = 0; i < idsInOrder.length; i++) {
      _indexById[_k(type, idsInOrder[i])] = i;
    }
    await _persist();
  }

  /// 移除某条目的手动顺序（取消收藏/删除时调用，避免脏数据堆积）。
  Future<void> remove(SourceType type, String id) async {
    if (_indexById.remove(_k(type, id)) != null) await _persist();
  }

  /// 清空全部手动顺序。
  Future<void> clear() async {
    _indexById.clear();
    await _backend.set(_key, '');
  }

  Future<void> _persist() async {
    await _backend.set(_key, jsonEncode(_indexById));
  }
}

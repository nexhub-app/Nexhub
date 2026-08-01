/// 源库订阅地址书签存储（库导入页常用地址）。
///
/// 持久化到 Hive box `source_library_bookmarks`：以单个 key `urls` 存储一个
/// JSON 编码的 `List<String>`。提供 [all] / [add] / [remove] 三个方法，
/// 继承 [ChangeNotifier] 供 UI 通过 Provider 监听变化后刷新书签列表。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

class SourceLibraryBookmarks extends ChangeNotifier {
  SourceLibraryBookmarks();

  /// Hive box 名。
  static const String boxName = 'source_library_bookmarks';

  /// box 内存储书签列表的 key。
  static const String _key = 'urls';

  Box<dynamic>? _box;

  /// 内存缓存：避免每次 [all] 都异步开 box。加载后驻留，写操作同步更新。
  List<String> _urls = const <String>[];

  Future<Box<dynamic>> _openBox() async {
    if (_box != null) return _box!;
    if (Hive.isBoxOpen(boxName)) {
      _box = Hive.box(boxName);
    } else {
      _box = await Hive.openBox(boxName);
    }
    return _box!;
  }

  /// 从 Hive 加载书签到内存缓存。应在应用启动阶段（box 已打开后）调用一次。
  Future<void> load() async {
    final box = await _openBox();
    final raw = box.get(_key);
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          _urls = decoded.whereType<String>().toList(growable: true);
          return;
        }
      } on Object catch (e) {
        debugPrint('[SourceLibraryBookmarks] load parse failed: $e');
      }
    }
    _urls = <String>[];
  }

  /// 当前书签列表（不可变视图）。
  List<String> all() => List<String>.unmodifiable(_urls);

  /// 添加书签（去重，已存在则移动到末尾并刷新）。空值忽略。
  Future<void> add(String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return;
    if (_urls.contains(trimmed)) {
      if (_urls.last == trimmed) return; // 已在末尾，无需变更
      _urls.remove(trimmed);
      _urls.add(trimmed);
    } else {
      _urls.add(trimmed);
    }
    await _persist();
    notifyListeners();
  }

  /// 移除书签。不存在则无操作。
  Future<void> remove(String url) async {
    if (_urls.remove(url.trim())) {
      await _persist();
      notifyListeners();
    }
  }

  Future<void> _persist() async {
    final box = await _openBox();
    await box.put(_key, jsonEncode(_urls));
  }
}

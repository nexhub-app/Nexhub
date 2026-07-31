/// 源级网络覆盖存储：用户对某个源的网络配置覆盖，持久化到 Hive。
///
/// 仿 [ConfigLoader] 的 `source_mirrors` 模式：box `source_network_overrides`，
/// key=sourceId，值=覆盖 JSON 字符串。使内置源无需改 asset 也能被用户覆盖。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import 'model/source_network_config.dart';

/// 源级网络覆盖存储（进程内单例）。
class SourceNetworkOverrideStore {
  SourceNetworkOverrideStore._();
  static final SourceNetworkOverrideStore instance =
      SourceNetworkOverrideStore._();

  /// Hive box 名。
  static const String boxName = 'source_network_overrides';

  final Map<String, SourceNetworkConfig> _cache =
      <String, SourceNetworkConfig>{};
  bool _loaded = false;
  Box<dynamic>? _box;

  /// 从 Hive 加载持久化覆盖。
  Future<void> init() async {
    if (_loaded) return;
    _box = await Hive.openBox(boxName);
    for (final key in _box!.keys) {
      if (key is! String) continue;
      final val = _box!.get(key);
      if (val is String && val.isNotEmpty) {
        try {
          _cache[key] = SourceNetworkConfig.fromJson(
            jsonDecode(val) as Map<String, dynamic>,
          );
        } on Object catch (e) {
          debugPrint('SourceNetworkOverrideStore load($key) failed: $e');
        }
      }
    }
    _loaded = true;
  }

  /// 取某源的用户覆盖（无则返回 null）。
  SourceNetworkConfig? get(String sourceId) => _cache[sourceId];

  /// 设置某源的覆盖并持久化。空覆盖等价于删除。
  Future<void> set(String sourceId, SourceNetworkConfig? config) async {
    if (config == null || config.isEmpty) {
      return remove(sourceId);
    }
    _cache[sourceId] = config;
    await _box?.put(sourceId, jsonEncode(config.toJson()));
  }

  /// 删除某源的覆盖。
  Future<void> remove(String sourceId) async {
    _cache.remove(sourceId);
    await _box?.delete(sourceId);
  }
}

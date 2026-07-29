/// 弹幕显示设置持久化存储。
///
/// 全局「弹幕显示设置」页与播放器内设置面板**共用同一个存储实例**
/// （key: `danmaku_display_settings_v1`），保证两处编辑的是同一份数据、
/// 单一数据源、互不割裂。底层走 [SharedPrefsBackend]（`SharedPreferences.getInstance()`），
/// 跨平台稳定可靠，不依赖文件写入。
library;

import 'dart:convert';

import 'package:nexhub/core/comic/models/reader_preferences.dart';
import 'danmaku_settings.dart';

class DanmakuDisplaySettingsStore {
  static const String _key = 'danmaku_display_settings_v1';

  final PrefsBackend _backend;

  DanmakuDisplaySettingsStore({PrefsBackend? backend})
      : _backend = backend ?? const SharedPrefsBackend();

  /// 是否已保存过设置（用于判断是否需要从旧方案迁移）。
  Future<bool> hasData() async {
    final raw = await _backend.get(_key);
    return raw != null && raw.isNotEmpty;
  }

  Future<DanmakuSettings> load() async {
    final raw = await _backend.get(_key);
    if (raw == null || raw.isEmpty) return const DanmakuSettings();
    try {
      return DanmakuSettings.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } on Object {
      return const DanmakuSettings();
    }
  }

  Future<void> save(DanmakuSettings settings) async {
    await _backend.set(_key, jsonEncode(settings.toJson()));
  }
}

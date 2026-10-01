/// 高级设置（key: `advanced_settings_v1`）。
///
/// 持久化到 SharedPreferences，复用 [PrefsBackend] 抽象以便测试注入。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../comic/models/reader_preferences.dart';

/// 高级设置模型。
class AdvancedSettings {
  /// 详细日志：开启后 [HttpFetcher] 记录每个请求/响应（调试用）。
  final bool detailedLogging;

  /// 默认 UA：空字符串表示「自动（内置指纹轮换）」；
  /// 非空时全局 HTTP 请求固定使用该 UA（覆盖内置指纹档案）。
  final String defaultUserAgent;

  /// 缓存自动清理总开关（默认开启：启动时后台按年龄/容量清理缓存）。
  final bool autoCacheCleanEnabled;

  /// 缓存年龄上限（天）：超过该天数未使用的缓存文件被自动清理。
  /// 范围 1–365，默认 30。
  final int cacheMaxAgeDays;

  /// 缓存总容量上限（MB）：清理年龄策略后若仍超限，按最旧优先继续删除。
  /// 范围 128–10240，默认 1024（1GB）。
  final int cacheMaxTotalMb;

  const AdvancedSettings({
    this.detailedLogging = false,
    this.defaultUserAgent = '',
    this.autoCacheCleanEnabled = true,
    this.cacheMaxAgeDays = 30,
    this.cacheMaxTotalMb = 1024,
  });

  /// 缓存总容量上限（字节）。
  int get cacheMaxTotalBytes => cacheMaxTotalMb * 1024 * 1024;

  AdvancedSettings copyWith({
    bool? detailedLogging,
    String? defaultUserAgent,
    bool? autoCacheCleanEnabled,
    int? cacheMaxAgeDays,
    int? cacheMaxTotalMb,
  }) =>
      AdvancedSettings(
        detailedLogging: detailedLogging ?? this.detailedLogging,
        defaultUserAgent: defaultUserAgent ?? this.defaultUserAgent,
        autoCacheCleanEnabled:
            autoCacheCleanEnabled ?? this.autoCacheCleanEnabled,
        cacheMaxAgeDays: cacheMaxAgeDays ?? this.cacheMaxAgeDays,
        cacheMaxTotalMb: cacheMaxTotalMb ?? this.cacheMaxTotalMb,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'detailedLogging': detailedLogging,
        'defaultUserAgent': defaultUserAgent,
        'autoCacheCleanEnabled': autoCacheCleanEnabled,
        'cacheMaxAgeDays': cacheMaxAgeDays,
        'cacheMaxTotalMb': cacheMaxTotalMb,
      };

  factory AdvancedSettings.fromJson(Map<String, dynamic> json) =>
      AdvancedSettings(
        detailedLogging: (json['detailedLogging'] as bool?) ?? false,
        defaultUserAgent: (json['defaultUserAgent'] as String?) ?? '',
        autoCacheCleanEnabled:
            (json['autoCacheCleanEnabled'] as bool?) ?? true,
        cacheMaxAgeDays:
            ((json['cacheMaxAgeDays'] as num?)?.toInt() ?? 30).clamp(1, 365),
        cacheMaxTotalMb:
            ((json['cacheMaxTotalMb'] as num?)?.toInt() ?? 1024)
                .clamp(128, 10240),
      );
}

/// 高级设置持久化存储 + 变更广播（key: `advanced_settings_v1`）。
class AdvancedSettingsStore extends ChangeNotifier {
  static const String _key = 'advanced_settings_v1';

  final PrefsBackend _backend;
  AdvancedSettings _settings = const AdvancedSettings();
  bool _loaded = false;

  AdvancedSettingsStore({PrefsBackend? backend})
      : _backend = backend ?? const SharedPrefsBackend();

  /// 全局共享单例。
  static AdvancedSettingsStore? _instance;
  static AdvancedSettingsStore get instance {
    _instance ??= AdvancedSettingsStore();
    if (!_instance!._loaded) {
      _instance!.load();
    }
    return _instance!;
  }

  AdvancedSettings get settings => _settings;
  bool get loaded => _loaded;

  bool get detailedLogging => _settings.detailedLogging;
  String get defaultUserAgent => _settings.defaultUserAgent;

  /// 缓存自动清理开关（默认开启）。
  bool get autoCacheCleanEnabled => _settings.autoCacheCleanEnabled;

  /// 缓存年龄上限（天）。
  int get cacheMaxAgeDays => _settings.cacheMaxAgeDays;

  /// 缓存总容量上限（MB）。
  int get cacheMaxTotalMb => _settings.cacheMaxTotalMb;

  /// 是否应使用固定默认 UA（非空即启用）。
  bool get hasCustomUserAgent => _settings.defaultUserAgent.isNotEmpty;

  Future<AdvancedSettings> load() async {
    // 幂等：已加载（或被 save 抢先标记为已加载）时直接返回当前值。
    if (_loaded) return _settings;
    final String? raw = await _backend.get(_key);
    if (!_loaded) {
      if (raw == null || raw.isEmpty) {
        _settings = const AdvancedSettings();
      } else {
        try {
          _settings = AdvancedSettings.fromJson(
            jsonDecode(raw) as Map<String, dynamic>,
          );
        } catch (_) {
          _settings = const AdvancedSettings();
        }
      }
      _loaded = true;
    }
    return _settings;
  }

  Future<void> save(AdvancedSettings next) async {
    _settings = next;
    _loaded = true;
    notifyListeners();
    await _backend.set(_key, jsonEncode(next.toJson()));
  }

  Future<void> setDetailedLogging(bool v) async {
    if (v == _settings.detailedLogging) return;
    await save(_settings.copyWith(detailedLogging: v));
  }

  Future<void> setDefaultUserAgent(String v) async {
    final value = v.trim();
    if (value == _settings.defaultUserAgent) return;
    await save(_settings.copyWith(defaultUserAgent: value));
  }
}

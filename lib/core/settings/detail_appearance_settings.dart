/// 详情页外观设置（设置 → 详情页外观）。
///
/// 两项能力：
/// 1. 封面动态强调色——从封面（或 detail 回填后的封面）提取主色，
///    在详情页内用该色重建 ColorScheme；
/// 2. 封面模糊背景——把详情页顶部 Hero 背景替换为封面图 + 高斯模糊。
///
/// 持久化到 SharedPreferences（key: `detail_appearance_settings_v1`），
/// 复用 [PrefsBackend] 抽象以便测试注入，结构对齐 [GeneralSettingsStore]。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../comic/models/reader_preferences.dart';

/// 封面模糊背景的强度范围（sigma）。
const double kDetailBlurSigmaMin = 10.0;
const double kDetailBlurSigmaMax = 40.0;

/// 详情页外观设置。
class DetailAppearanceSettings {
  /// 是否根据封面动态取色（默认关闭，保持全局主题的强调色）。
  final bool dynamicAccentEnabled;

  /// 是否把详情页顶部背景替换为封面图 + 高斯模糊（默认关闭）。
  final bool blurredBackgroundEnabled;

  /// 模糊背景强度（sigma，10–40，默认 30）。
  final double backgroundBlurSigma;

  const DetailAppearanceSettings({
    this.dynamicAccentEnabled = false,
    this.blurredBackgroundEnabled = false,
    this.backgroundBlurSigma = 30.0,
  });

  DetailAppearanceSettings copyWith({
    bool? dynamicAccentEnabled,
    bool? blurredBackgroundEnabled,
    double? backgroundBlurSigma,
  }) =>
      DetailAppearanceSettings(
        dynamicAccentEnabled: dynamicAccentEnabled ?? this.dynamicAccentEnabled,
        blurredBackgroundEnabled:
            blurredBackgroundEnabled ?? this.blurredBackgroundEnabled,
        backgroundBlurSigma: backgroundBlurSigma ?? this.backgroundBlurSigma,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'dynamicAccentEnabled': dynamicAccentEnabled,
        'blurredBackgroundEnabled': blurredBackgroundEnabled,
        'backgroundBlurSigma': backgroundBlurSigma,
      };

  factory DetailAppearanceSettings.fromJson(Map<String, dynamic> json) {
    // 布尔字段按类型判断：单字段脏数据不致命（整包 cast 会把其他正常
    // 设置一起丢掉回默认值）。
    final Object? dynamicAccent = json['dynamicAccentEnabled'];
    final Object? blurBg = json['blurredBackgroundEnabled'];
    return DetailAppearanceSettings(
      // 缺省（老用户升级）回落 false：新视觉行为一律显式开启。
      dynamicAccentEnabled: dynamicAccent is bool ? dynamicAccent : false,
      blurredBackgroundEnabled: blurBg is bool ? blurBg : false,
      backgroundBlurSigma:
          ((json['backgroundBlurSigma'] as num?)?.toDouble() ?? 30.0)
              .clamp(kDetailBlurSigmaMin, kDetailBlurSigmaMax),
    );
  }
}

/// 详情页外观设置持久化存储 + 变更广播。
class DetailAppearanceStore extends ChangeNotifier {
  static const String _key = 'detail_appearance_settings_v1';

  final PrefsBackend _backend;
  DetailAppearanceSettings _settings = const DetailAppearanceSettings();
  bool _loaded = false;

  DetailAppearanceStore({PrefsBackend? backend})
      : _backend = backend ?? const SharedPrefsBackend();

  /// 全局共享单例。
  static DetailAppearanceStore? _instance;
  static DetailAppearanceStore get instance {
    _instance ??= DetailAppearanceStore();
    if (!_instance!._loaded) {
      _instance!.load();
    }
    return _instance!;
  }

  DetailAppearanceSettings get settings => _settings;
  bool get loaded => _loaded;

  /// 设置封面动态取色（持久化、广播）。
  Future<void> setDynamicAccentEnabled(bool value) async {
    if (value == _settings.dynamicAccentEnabled) return;
    await save(_settings.copyWith(dynamicAccentEnabled: value));
  }

  /// 设置封面模糊背景（持久化、广播）。
  Future<void> setBlurredBackgroundEnabled(bool value) async {
    if (value == _settings.blurredBackgroundEnabled) return;
    await save(_settings.copyWith(blurredBackgroundEnabled: value));
  }

  /// 设置模糊背景强度（10–40，持久化、广播）。
  Future<void> setBackgroundBlurSigma(double value) async {
    final double clamped =
        value.clamp(kDetailBlurSigmaMin, kDetailBlurSigmaMax);
    if (clamped == _settings.backgroundBlurSigma) return;
    await save(_settings.copyWith(backgroundBlurSigma: clamped));
  }

  Future<DetailAppearanceSettings> load() async {
    // 幂等：已加载（或被 save 抢先标记为已加载）时直接返回当前值，
    // 避免 await 期间 save 的最新值被旧 raw 覆盖（与 GeneralSettingsStore 同款竞态防护）。
    if (_loaded) return _settings;
    final String? raw = await _backend.get(_key);
    if (!_loaded) {
      if (raw == null || raw.isEmpty) {
        _settings = const DetailAppearanceSettings();
      } else {
        try {
          _settings = DetailAppearanceSettings.fromJson(
            jsonDecode(raw) as Map<String, dynamic>,
          );
        } on Object {
          _settings = const DetailAppearanceSettings();
        }
      }
      _loaded = true;
    }
    notifyListeners();
    return _settings;
  }

  Future<void> save(DetailAppearanceSettings settings) async {
    _settings = settings;
    _loaded = true;
    await _backend.set(_key, jsonEncode(settings.toJson()));
    notifyListeners();
  }
}

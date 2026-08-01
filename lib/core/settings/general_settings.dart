/// 通用应用设置（项 2/3：启动界面 + 自定义日期格式）。
///
/// 持久化到 SharedPreferences（key: `general_settings_v1`），
/// 复用 [PrefsBackend] 抽象以便测试注入。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

import '../comic/models/reader_preferences.dart';

/// 启动界面（与首页底部导航顺序一致：浏览→小说→媒体→漫画→设置）。
enum LaunchTab { browse, novel, media, comic, settings }

/// 自定义日期格式（项 3）。
enum AppDateFormat {
  /// 默认：yyyy/mm/dd
  defaultFormat,

  /// mm/dd/yy
  mmddyy,

  /// dd/mm/yy
  ddmmyy,

  /// yyyy-mm-dd
  yyyymmdd,

  /// dd mmm yyyy
  ddmmmyyyy,

  /// mmm dd
  mmmdd,

  /// yyyy
  yyyyOnly;

  /// 仅日期部分的格式串。
  String get datePattern {
    switch (this) {
      case AppDateFormat.defaultFormat:
        return 'yyyy/MM/dd';
      case AppDateFormat.mmddyy:
        return 'MM/dd/yy';
      case AppDateFormat.ddmmyy:
        return 'dd/MM/yy';
      case AppDateFormat.yyyymmdd:
        return 'yyyy-MM-dd';
      case AppDateFormat.ddmmmyyyy:
        return 'dd MMM yyyy';
      case AppDateFormat.mmmdd:
        return 'MMM dd';
      case AppDateFormat.yyyyOnly:
        return 'yyyy';
    }
  }

  /// 按本格式格式化时间。
  ///
  /// [withTime] 为 true 时追加 ` HH:mm`（用于「上次同步」等含时刻的场景）。
  String format(DateTime dt, {bool withTime = false}) {
    final pattern = withTime ? '${datePattern} HH:mm' : datePattern;
    return DateFormat(pattern).format(dt);
  }
}

/// 通用应用设置。
class GeneralSettings {
  final LaunchTab launchTab;
  final AppDateFormat dateFormat;

  /// 「已看」阈值百分比（50–100）。播放/阅读进度达到该比例视为已看。
  final int watchedThresholdPercent;

  const GeneralSettings({
    this.launchTab = LaunchTab.browse,
    this.dateFormat = AppDateFormat.defaultFormat,
    this.watchedThresholdPercent = 90,
  });

  GeneralSettings copyWith({
    LaunchTab? launchTab,
    AppDateFormat? dateFormat,
    int? watchedThresholdPercent,
  }) =>
      GeneralSettings(
        launchTab: launchTab ?? this.launchTab,
        dateFormat: dateFormat ?? this.dateFormat,
        watchedThresholdPercent:
            watchedThresholdPercent ?? this.watchedThresholdPercent,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'launchTab': launchTab.name,
        'dateFormat': dateFormat.name,
        'watchedThresholdPercent': watchedThresholdPercent,
      };

  factory GeneralSettings.fromJson(Map<String, dynamic> json) {
    LaunchTab tab = LaunchTab.browse;
    if (json['launchTab'] is String) {
      tab = LaunchTab.values.firstWhere(
        (e) => e.name == json['launchTab'],
        orElse: () => LaunchTab.browse,
      );
    }
    AppDateFormat fmt = AppDateFormat.defaultFormat;
    if (json['dateFormat'] is String) {
      fmt = AppDateFormat.values.firstWhere(
        (e) => e.name == json['dateFormat'],
        orElse: () => AppDateFormat.defaultFormat,
      );
    }
    return GeneralSettings(
      launchTab: tab,
      dateFormat: fmt,
      watchedThresholdPercent: _clampThreshold(
        (json['watchedThresholdPercent'] as num?)?.toInt() ?? 90,
      ),
    );
  }
}

/// 「已看」阈值百分比合法范围。
const int kWatchedThresholdMin = 50;
const int kWatchedThresholdMax = 100;

/// 将阈值百分比裁剪到合法范围 [kWatchedThresholdMin, kWatchedThresholdMax]。
int _clampThreshold(int value) =>
    value.clamp(kWatchedThresholdMin, kWatchedThresholdMax);

/// 判断进度比例是否达到「已看」阈值。
///
/// [progressRatio] 为 0.0–1.0 的进度比例（如 positionMs/durationMs 或
/// (currentPage+1)/totalPages）；[thresholdPercent] 为 50–100 的百分比阈值。
/// 达到或超过阈值返回 true，用于触发 `MediaWatchedManager.markWatched`。
bool progressReachesWatchedThreshold(double progressRatio, int thresholdPercent) {
  if (thresholdPercent <= 0) return progressRatio >= 0;
  final clamped = thresholdPercent.clamp(kWatchedThresholdMin, kWatchedThresholdMax);
  return progressRatio >= clamped / 100;
}

/// 通用设置持久化存储 + 变更广播（key: `general_settings_v1`）。
class GeneralSettingsStore extends ChangeNotifier {
  static const String _key = 'general_settings_v1';

  final PrefsBackend _backend;
  GeneralSettings _settings = const GeneralSettings();
  bool _loaded = false;

  GeneralSettingsStore({PrefsBackend? backend})
      : _backend = backend ?? const SharedPrefsBackend();

  /// 全局共享单例。
  static GeneralSettingsStore? _instance;
  static GeneralSettingsStore get instance {
    _instance ??= GeneralSettingsStore();
    if (!_instance!._loaded) {
      _instance!.load();
    }
    return _instance!;
  }

  GeneralSettings get settings => _settings;
  bool get loaded => _loaded;

  /// 「已看」阈值百分比（已裁剪到 50–100）。
  int get watchedThresholdPercent => _settings.watchedThresholdPercent;

  /// 设置「已看」阈值百分比（自动裁剪到 50–100 并持久化、广播）。
  Future<void> setWatchedThresholdPercent(int value) async {
    final clamped = _clampThreshold(value);
    if (clamped == _settings.watchedThresholdPercent) return;
    await save(_settings.copyWith(watchedThresholdPercent: clamped));
  }

  Future<GeneralSettings> load() async {
    // 幂等：已加载（或被 save 抢先标记为已加载）时直接返回当前值，
    // 避免首次异步 load 完成过晚、用旧值覆盖用户刚保存的设置（导致
    // “改了日期格式却没生效”的竞态）。
    if (_loaded) return _settings;
    final String? raw = await _backend.get(_key);
    // 二次校验：若在 await 期间发生了 save（save 会置 _loaded=true），
    // 说明最新值已被 save 写入，此处不再用旧 raw 覆盖。
    if (!_loaded) {
      if (raw == null || raw.isEmpty) {
        _settings = const GeneralSettings();
      } else {
        try {
          _settings = GeneralSettings.fromJson(
            jsonDecode(raw) as Map<String, dynamic>,
          );
        } on Object {
          _settings = const GeneralSettings();
        }
      }
      _loaded = true;
    }
    notifyListeners();
    return _settings;
  }

  Future<void> save(GeneralSettings settings) async {
    _settings = settings;
    _loaded = true;
    await _backend.set(_key, jsonEncode(settings.toJson()));
    notifyListeners();
  }
}

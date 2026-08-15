import 'dart:convert';

import 'package:flutter/material.dart';
import '../comic/models/reader_preferences.dart';
import 'app_tokens.dart';
import 'app_theme.dart';

/// 运行时主题状态（亮 / 暗 / 跟随 + 自定义主色 + 莫奈开关）。
///
/// 使用方式（见 lib/app.dart）：
/// ```dart
/// ChangeNotifierProvider<ThemeController>.value(
///   value: ThemeController(),
///   child: const App(),
/// )
/// ```
///
/// 莫奈取色（Monet / Material You）：当 [useMonet] 为 true 且系统提供了动态
/// ColorScheme 时，优先使用系统动态色；否则回退到 [seed] 生成的浅蓝主题。
///
/// 持久化：三项状态（mode / seed / useMonet）整体 JSON 存入
/// SharedPreferences（key: [storageKey]）。冷启动时由 splash 在初始化管线
/// **之前** 调用 [load] 恢复，避免加载页先用默认「跟随系统」主题渲染，
/// 在用户已选深色而系统为浅色时闪出白底。
class ThemeController extends ChangeNotifier {
  /// SharedPreferences 存储键。
  static const String storageKey = 'theme_settings_v1';

  ThemeController({
    ThemeMode mode = ThemeMode.system,
    Color seed = AppTokens.seedYouthfulPrimary,
    bool useMonet = true,
    PrefsBackend? backend,
  })  : _mode = mode,
        _seed = seed,
        _useMonet = useMonet,
        _backend = backend ?? const SharedPrefsBackend();

  final PrefsBackend _backend;

  ThemeMode _mode;
  Color _seed;
  bool _useMonet;
  bool _loaded = false;

  ThemeMode get mode => _mode;

  /// 当前自定义主色（非莫奈时生效）。
  Color get seed => _seed;

  /// 是否优先使用系统莫奈动态色。
  bool get useMonet => _useMonet;

  /// 持久化状态是否已恢复完成。
  bool get loaded => _loaded;

  /// 从持久化存储恢复主题偏好（幂等；失败时保持当前默认值）。
  Future<void> load() async {
    if (_loaded) return;
    String? raw;
    try {
      raw = await _backend.get(storageKey);
    } on Object {
      raw = null;
    }
    // 二次校验：await 期间若用户已手动改主题（会置 _loaded=true），
    // 不用旧值覆盖。
    if (_loaded) return;
    if (raw != null && raw.isNotEmpty) {
      try {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        final String? modeName = map['mode'] as String?;
        if (modeName != null) {
          _mode = ThemeMode.values.firstWhere(
            (ThemeMode e) => e.name == modeName,
            orElse: () => _mode,
          );
        }
        final int? seedValue = (map['seed'] as num?)?.toInt();
        if (seedValue != null) _seed = Color(seedValue);
        _useMonet = (map['useMonet'] as bool?) ?? _useMonet;
      } on Object {
        // 脏数据：忽略，保持默认。
      }
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _persist() async {
    _loaded = true;
    try {
      await _backend.set(
        storageKey,
        jsonEncode(<String, dynamic>{
          'mode': _mode.name,
          'seed': _seed.toARGB32(),
          'useMonet': _useMonet,
        }),
      );
    } on Object {
      // 持久化失败不影响本次会话内的主题切换。
    }
  }

  void setMode(ThemeMode mode) {
    if (_mode == mode) return;
    _mode = mode;
    notifyListeners();
    _persist();
  }

  /// 选择自定义主色（会自动关闭莫奈，因为指定了显式 seed）。
  void setSeed(Color seed) {
    _seed = seed;
    _useMonet = false;
    notifyListeners();
    _persist();
  }

  void setUseMonet(bool value) {
    if (_useMonet == value) return;
    _useMonet = value;
    notifyListeners();
    _persist();
  }

  /// 当前是否选中「玄色」专属主题（近黑底 + 赤强调色）。
  bool get isXuanSe => _seed == AppTokens.seedXuanSe;

  ThemeData lightTheme([ColorScheme? systemScheme]) {
    if (_useMonet && systemScheme != null) {
      return AppTheme.light(scheme: systemScheme);
    }
    if (isXuanSe) return AppTheme.xuanSe();
    return AppTheme.light(seed: _seed);
  }

  ThemeData darkTheme([ColorScheme? systemScheme]) {
    if (_useMonet && systemScheme != null) {
      return AppTheme.dark(scheme: systemScheme);
    }
    if (isXuanSe) return AppTheme.xuanSe();
    return AppTheme.dark(seed: _seed);
  }
}

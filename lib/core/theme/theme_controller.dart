import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import '../comic/models/reader_preferences.dart';
import 'app_tokens.dart';
import 'app_theme.dart';
import 'palette_style.dart';

/// 运行时主题状态（亮 / 暗 / 跟随 + 自定义主色 + 莫奈开关 + 调色板风格）。
///
/// 使用方式（见 lib/app.dart）：
/// ```dart
/// ChangeNotifierProvider<ThemeController>.value(
/// value: ThemeController(),
/// child: const App(),
/// )
/// ```
///
/// 莫奈取色（Monet / Material You）：当 [useMonet] 为 true 且系统提供了动态
/// ColorScheme 时，以系统动态色为准——风格为 [PaletteStyle.tonalSpot] 时
/// 直接使用系统 scheme；其余风格取系统 scheme 的 primary 作 seed，按所选
/// [PaletteStyle] 重新 `fromSeed`，实现「壁纸 + 风格」组合。
/// 否则回退到 [seed] 生成的浅蓝主题。
///
/// 优先级（从高到低）：玄色手工主题 > 莫奈动态色 > 自定义 seed。
/// 玄色是唯一的手工主题，一旦选中即覆盖前两者（历史 bug：莫奈分支在前，
/// 导致「选玄色 + 开莫奈」时玄色不生效）。
///
/// 持久化：状态（mode / seed / useMonet / paletteStyle）整体 JSON 存入
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
    PaletteStyle paletteStyle = PaletteStyle.tonalSpot,
    PrefsBackend? backend,
  })  : _mode = mode,
        _seed = seed,
        _useMonet = useMonet,
        _paletteStyle = paletteStyle,
        _backend = backend ?? const SharedPrefsBackend();

  final PrefsBackend _backend;

  ThemeMode _mode;
  Color _seed;
  bool _useMonet;
  PaletteStyle _paletteStyle;
  bool _loaded = false;

  ThemeMode get mode => _mode;

  /// 当前自定义主色（非莫奈时生效）。
  Color get seed => _seed;

  /// 是否优先使用系统莫奈动态色。
  bool get useMonet => _useMonet;

  /// 调色板风格（莫奈与自定义 seed 路径共同生效；玄色除外）。
  PaletteStyle get paletteStyle => _paletteStyle;

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
        // 旧版本数据无 paletteStyle 字段 → 保持默认 tonalSpot（向后兼容）。
        final String? styleName = map['paletteStyle'] as String?;
        if (styleName != null) {
          _paletteStyle = PaletteStyle.values.firstWhere(
            (PaletteStyle e) => e.name == styleName,
            orElse: () => _paletteStyle,
          );
        }
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
          'paletteStyle': _paletteStyle.name,
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

  /// 切换调色板风格（莫奈 / 自定义 seed 两条路径都即时生效）。
  void setPaletteStyle(PaletteStyle style) {
    if (_paletteStyle == style) return;
    _paletteStyle = style;
    notifyListeners();
    _persist();
  }

  /// 当前是否选中「玄色」专属主题（近黑底 + 赤强调色）。
  bool get isXuanSe => _seed == AppTokens.seedXuanSe;

  ThemeData lightTheme([ColorScheme? systemScheme]) {
    // 玄色优先：显式手工主题不被莫奈动态色覆盖。
    if (isXuanSe) return AppTheme.xuanSe();
    if (_useMonet && systemScheme != null) {
      if (_paletteStyle == PaletteStyle.tonalSpot) {
        return AppTheme.light(scheme: systemScheme);
      }
      // 壁纸 + 风格：取系统动态色 primary 作 seed，按所选风格重建配色。
      return AppTheme.light(
        seed: systemScheme.primary,
        variant: _paletteStyle.variant,
      );
    }
    return AppTheme.light(seed: _seed, variant: _paletteStyle.variant);
  }

  ThemeData darkTheme([ColorScheme? systemScheme]) {
    if (isXuanSe) return AppTheme.xuanSe();
    if (_useMonet && systemScheme != null) {
      if (_paletteStyle == PaletteStyle.tonalSpot) {
        return AppTheme.dark(scheme: systemScheme);
      }
      return AppTheme.dark(
        seed: systemScheme.primary,
        variant: _paletteStyle.variant,
      );
    }
    return AppTheme.dark(seed: _seed, variant: _paletteStyle.variant);
  }
}

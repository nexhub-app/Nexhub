import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show FontLoader;
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../comic/models/reader_preferences.dart';
import 'app_fonts.dart';
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
/// 持久化：状态（mode / seed / useMonet / paletteStyle / appFont 及自定义
/// 字体三元组）整体 JSON 存入 SharedPreferences（key: [storageKey]）。冷启动
/// 时由 splash 在初始化管线**之前**调用 [load] 恢复，避免加载页先用默认
/// 「跟随系统」主题渲染，在用户已选深色而系统为浅色时闪出白底。自定义字体
/// 也在 [load] 内注册（FontLoader），保证首帧即可用新字体渲染。
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
  String _appFontId = kAppFontSystemId;
  String? _appFontCustomPath;
  String? _appFontCustomFamily;
  String? _appFontCustomName;
  bool _loaded = false;

  ThemeMode get mode => _mode;

  /// 当前自定义主色（非莫奈时生效）。
  Color get seed => _seed;

  /// 是否优先使用系统莫奈动态色。
  bool get useMonet => _useMonet;

  /// 调色板风格（莫奈与自定义 seed 路径共同生效；玄色除外）。
  PaletteStyle get paletteStyle => _paletteStyle;

  /// 界面字体标识（[kAppFontSystemId] / 内置字体 id / [kAppFontCustomId]）。
  String get appFontId => _appFontId;

  /// 自定义字体文件在应用私有目录内的路径（未启用自定义字体时为 null）。
  String? get appFontCustomPath => _appFontCustomPath;

  /// 自定义字体的展示名（导入时的文件名）。
  String? get appFontCustomName => _appFontCustomName;

  /// 当前界面字体的字族名（null = 跟随系统默认字体）。
  String? get appFontFamily {
    final AppFontOption? builtin = builtInAppFontById(_appFontId);
    if (builtin != null) return builtin.family;
    if (_appFontId == kAppFontCustomId) return _appFontCustomFamily;
    return null;
  }

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
        // 界面字体（旧版本数据无该字段 → 跟随系统）。
        final String? fontId = map['appFont'] as String?;
        if (fontId == kAppFontCustomId) {
          await _restoreCustomFont(
            path: map['appFontCustomPath'] as String?,
            family: map['appFontCustomFamily'] as String?,
            name: map['appFontCustomName'] as String?,
          );
        } else if (builtInAppFontById(fontId) != null) {
          _appFontId = fontId!;
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
          'appFont': _appFontId,
          'appFontCustomPath': _appFontCustomPath,
          'appFontCustomFamily': _appFontCustomFamily,
          'appFontCustomName': _appFontCustomName,
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

  /// 已通过 [loadFontFamily] 注册过的运行时字族，避免同一 family 重复 load。
  static final Set<String> _loadedFontFamilies = <String>{};

  /// 从字体文件注册运行时字族（.ttf / .otf）。同一 family 只加载一次；
  /// 与小说阅读器各自的注册互不影响（family 名不同）。
  static Future<void> loadFontFamily(String family, String path) async {
    if (_loadedFontFamilies.contains(family)) return;
    final Uint8List bytes = await File(path).readAsBytes();
    final FontLoader loader = FontLoader(family);
    loader.addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
    await loader.load();
    _loadedFontFamilies.add(family);
  }

  /// 切换为「跟随系统」或某款内置开源字体（id 见 [kBuiltInAppFonts]）。
  Future<void> setAppFont(String id) async {
    if (_appFontId == id) return;
    _appFontId = id;
    notifyListeners();
    _persist();
  }

  /// 导入并启用自定义字体：复制进应用私有目录（源文件日后被移动 / 删除也
  /// 不断链），以「NexhubAppCustomFont + 时间戳」为字族注册。每次导入都用
  /// 新字族名——引擎对同一字族名的重复注册不会刷新字形。成功返回 true，
  /// 文件复制 / 读取 / 注册失败返回 false（不改动当前字体状态）。
  Future<bool> setAppFontCustom({
    required String sourcePath,
    required String displayName,
  }) async {
    final Directory supportDir = await getApplicationSupportDirectory();
    final Directory fontDir = Directory(p.join(supportDir.path, 'app_fonts'));
    await fontDir.create(recursive: true);
    final String ext = p.extension(sourcePath).toLowerCase();
    final String targetPath = p.join(
      fontDir.path,
      'custom${DateTime.now().millisecondsSinceEpoch}$ext',
    );
    final File target = await File(sourcePath).copy(targetPath);
    final String family =
        'NexhubAppCustomFont${DateTime.now().millisecondsSinceEpoch}';
    try {
      await loadFontFamily(family, target.path);
    } on Object {
      // 字体文件损坏 / 格式不受支持：删掉拷贝，保持原字体不变。
      try {
        await target.delete();
      } on Object {
        // 清理半途产物，失败无碍。
      }
      return false;
    }
    // 旧自定义字体文件清理（仅删受管目录内的，不动用户源文件）。
    final String? oldPath = _appFontCustomPath;
    if (oldPath != null &&
        oldPath != target.path &&
        p.dirname(oldPath) == fontDir.path) {
      try {
        await File(oldPath).delete();
      } on Object {
        // 删不掉旧文件不影响切换。
      }
    }
    _appFontId = kAppFontCustomId;
    _appFontCustomPath = target.path;
    _appFontCustomFamily = family;
    _appFontCustomName = displayName;
    notifyListeners();
    _persist();
    return true;
  }

  /// 清除自定义字体并回到跟随系统，受管字体文件一并删除。
  Future<void> clearAppFontCustom() async {
    final String? oldPath = _appFontCustomPath;
    if (_appFontId == kAppFontSystemId && oldPath == null) return;
    _appFontId = kAppFontSystemId;
    _appFontCustomPath = null;
    _appFontCustomFamily = null;
    _appFontCustomName = null;
    notifyListeners();
    _persist();
    if (oldPath != null) {
      try {
        await File(oldPath).delete();
      } on Object {
        // 删不掉旧文件不影响清除。
      }
    }
  }

  /// 冷启动恢复自定义字体：文件仍在且注册成功则沿用，否则回退跟随系统。
  Future<void> _restoreCustomFont({
    required String? path,
    required String? family,
    required String? name,
  }) async {
    if (family == null ||
        family.isEmpty ||
        path == null ||
        path.isEmpty ||
        !File(path).existsSync()) {
      _appFontId = kAppFontSystemId;
      _appFontCustomPath = null;
      _appFontCustomFamily = null;
      _appFontCustomName = null;
      return;
    }
    try {
      await loadFontFamily(family, path);
      _appFontId = kAppFontCustomId;
      _appFontCustomPath = path;
      _appFontCustomFamily = family;
      _appFontCustomName = name;
    } on Object {
      _appFontId = kAppFontSystemId;
      _appFontCustomPath = null;
      _appFontCustomFamily = null;
      _appFontCustomName = null;
    }
  }

  /// 当前是否选中「玄色」专属主题（近黑底 + 赤强调色）。
  bool get isXuanSe => _seed == AppTokens.seedXuanSe;

  ThemeData lightTheme([ColorScheme? systemScheme]) {
    // 玄色优先：显式手工主题不被莫奈动态色覆盖。
    if (isXuanSe) return AppTheme.xuanSe(fontFamily: appFontFamily);
    if (_useMonet && systemScheme != null) {
      if (_paletteStyle == PaletteStyle.tonalSpot) {
        return AppTheme.light(
          scheme: systemScheme,
          fontFamily: appFontFamily,
        );
      }
      // 壁纸 + 风格：取系统动态色 primary 作 seed，按所选风格重建配色。
      return AppTheme.light(
        seed: systemScheme.primary,
        variant: _paletteStyle.variant,
        fontFamily: appFontFamily,
      );
    }
    return AppTheme.light(
      seed: _seed,
      variant: _paletteStyle.variant,
      fontFamily: appFontFamily,
    );
  }

  ThemeData darkTheme([ColorScheme? systemScheme]) {
    if (isXuanSe) return AppTheme.xuanSe(fontFamily: appFontFamily);
    if (_useMonet && systemScheme != null) {
      if (_paletteStyle == PaletteStyle.tonalSpot) {
        return AppTheme.dark(scheme: systemScheme, fontFamily: appFontFamily);
      }
      return AppTheme.dark(
        seed: systemScheme.primary,
        variant: _paletteStyle.variant,
        fontFamily: appFontFamily,
      );
    }
    return AppTheme.dark(
      seed: _seed,
      variant: _paletteStyle.variant,
      fontFamily: appFontFamily,
    );
  }
}

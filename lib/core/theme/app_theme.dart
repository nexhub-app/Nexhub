import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'package:material_ui/material_ui.dart';
import 'app_tokens.dart';

/// 应用主题工厂。
///
/// - `useMaterial3: true`。
/// - 默认主色为蓝青（[AppTokens.seedYouthfulPrimary]，#0EA5E9）；[AppTokens.seedLightBlue] 仅作可选预设，
/// 可通过 `scheme` 注入莫奈动态色或自定义 seed 生成的 ColorScheme。
/// - `app.dart` 中：`theme: AppTheme.light()`、`darkTheme: AppTheme.dark()`，
/// 并删除任何内联 `ThemeData(colorSchemeSeed: ...)`。
/// 全局页面切换转场：无动画瞬间切换。
///
/// 历史：先后尝试「滑入+回弹缩放」与「 fade-through 干净淡入」，
/// 用户均认为拖沓/难看，最终明确选择「干脆不要转场」（2026-07-25）。
/// 直接返回 child = 零动画瞬切，最快最干脆。
/// 注意：若未来恢复带透明度的转场，exitFade 必须是 1→0 的反向映射
/// （secondaryAnimation 常态为 0，直接当 opacity 用会整页隐形→全局黑屏）。
class AppPageTransitionsBuilder extends PageTransitionsBuilder {
  const AppPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return child;
  }
}

class AppTheme {
  const AppTheme._();

  /// 全局系统栏样式：状态栏与导航栏（手势条区域）透明、关闭系统对比度
  /// 蒙层，两栏图标亮度随主题明暗切换。
  ///
  /// 挂在 `MaterialApp.builder` 的 `AnnotatedRegion` 上（`app.dart` /
  /// `splash_screen.dart`），深浅色切换即时生效。AppBar 页面会推送自己的
  /// 状态栏样式，但其导航栏字段为 null（引擎对 null 字段不修改），不会
  /// 覆盖此处；阅读器/播放器全屏切换只动 SystemUiMode，退出后同样回到
  /// 这份透明样式。
  ///
  /// 背景：Android 15+ 强制 edge-to-edge，导航栏恒透明、内容延伸到其后，
  /// 颜色天然等于页面背景；Android 10-14 上需同时把
  /// [SystemUiOverlayStyle.systemNavigationBarContrastEnforced] 关掉，
  /// 否则系统会给透明导航栏叠一层对比度蒙层（灰黑半透明条），既与页面
  /// 背景色不符，又把底部内容遮住一条。
  static SystemUiOverlayStyle systemOverlayStyle(ThemeData theme) {
    final Brightness bar = theme.brightness;
    // 浅色背景配深色图标，深色背景配浅色图标（状态栏 Android 语义）。
    final Brightness icon =
        bar == Brightness.dark ? Brightness.light : Brightness.dark;
    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: icon,
      statusBarBrightness: bar,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: icon,
      systemNavigationBarDividerColor: Colors.transparent,
      systemNavigationBarContrastEnforced: false,
    );
  }

  /// 卡面填充槽位（Legado MD3 观感的「单一真源」）：
  /// 容器基准浅色取 surfaceContainerLowest、深色取 surfaceContainerHighest
  /// （卡面比页面底色亮一档），再叠一层 [ColorScheme.primaryContainer]——
  /// 强调色的**亮档**变体（浅色模式约 tone 90 的饱和浅桃色）：
  /// 亮而明显带色，且随壁纸 / 调色板风格自动偏色。用 primary 本体染色会
  /// 「越浓越暗」，用 primaryContainer 则亮度与浓度解耦。
  /// cardTheme / AppCard / Settings* 组件统一取本值。
  static Color cardContainer(ColorScheme scheme) {
    final Color base = scheme.brightness == Brightness.dark
        ? scheme.surfaceContainerHighest
        : scheme.surfaceContainerLowest;
    return Color.alphaBlend(
      scheme.primaryContainer.withValues(alpha: 0.45),
      base,
    );
  }

  /// 浅色主题。
  ///
  /// - 传入 [scheme]（莫奈系统动态色）时直接使用（系统动态色本身即
  /// tonalSpot 算法的结果）；此时 [variant] / [contrastLevel] 不参与。
  /// - 否则用 [seed]（缺省青春蓝）经 `ColorScheme.fromSeed` 生成，
  /// [variant] 为调色板风格变体（[PaletteStyle.variant]），
  /// [contrastLevel] 对应 Android 14+ 的无障碍对比度档位（预留，默认 0）。
  static ThemeData light({
    ColorScheme? scheme,
    Color? seed,
    DynamicSchemeVariant variant = DynamicSchemeVariant.tonalSpot,
    double contrastLevel = 0.0,
  }) {
    final ColorScheme colorScheme = scheme ??
        ColorScheme.fromSeed(
          seedColor: seed ?? AppTokens.seedYouthfulPrimary,
          brightness: Brightness.light,
          dynamicSchemeVariant: variant,
          contrastLevel: contrastLevel,
        );
    return _build(colorScheme);
  }

  /// 深色主题。参数含义同 [light]。
  static ThemeData dark({
    ColorScheme? scheme,
    Color? seed,
    DynamicSchemeVariant variant = DynamicSchemeVariant.tonalSpot,
    double contrastLevel = 0.0,
  }) {
    final ColorScheme colorScheme = scheme ??
        ColorScheme.fromSeed(
          seedColor: seed ?? AppTokens.seedYouthfulPrimary,
          brightness: Brightness.dark,
          dynamicSchemeVariant: variant,
          contrastLevel: contrastLevel,
        );
    return _build(colorScheme);
  }

  /// 玄色专属主题：近黑背景 + 一抹"赤"强调色（黑中扬赤）。
  /// 选中玄色时由 [ThemeController] 调用，覆盖默认的 `fromSeed` 灰阶结果，
  /// 使玄色在浅色 / 深色模式下都呈现清晰可辨的墨黑主题。
  static ThemeData xuanSe() {
    final ColorScheme base = ColorScheme.fromSeed(
      seedColor: AppTokens.seedXuanSeAccent,
      brightness: Brightness.dark,
    );
    final ColorScheme scheme = base.copyWith(
      surface: AppTokens.xuanSeInk,
      onSurface: const Color(0xFFEDE6E2),
      surfaceContainerLowest: const Color(0xFF000000),
      surfaceContainerLow: AppTokens.xuanSeInk,
      surfaceContainer: const Color(0xFF161616),
      surfaceContainerHigh: const Color(0xFF1F1F1F),
      surfaceContainerHighest: const Color(0xFF272727),
      onSurfaceVariant: const Color(0xFFC9C2BE),
      outline: const Color(0xFF3A3A3A),
      outlineVariant: const Color(0xFF2A2A2A),
      surfaceTint: Colors.transparent,
      shadow: const Color(0xFF000000),
    );
    return _build(scheme);
  }

  /// 统一文本主题：比 Material 3 默认字号整体偏小（约 -10%），
  /// 行高针对中文阅读优化（正文 ≥1.5），字重用 3 档（w400/w500/w600）
  /// 建立清晰层次，减少 默认「字号偏大、行距松散」的 AI 感。
  ///
  /// 颜色取 [colorScheme] 角色：标题/正文用 [ColorScheme.onSurface]，
  /// 辅助档（bodySmall / labelMedium / labelSmall）用 [ColorScheme.onSurfaceVariant]，
  /// 深浅色自动适配，feature 代码仍只需 `Theme.of(context).textTheme`。
  static TextTheme _textTheme(ColorScheme cs) {
    final Color onSurface = cs.onSurface;
    final Color onVariant = cs.onSurfaceVariant;
    return TextTheme(
      // ── 展示 / 大标题（页面首屏主标题，少用） ──
      displayLarge: TextStyle(
        fontSize: 50,
        fontWeight: FontWeight.w600,
        height: 1.12,
        letterSpacing: -0.5,
        color: onSurface,
      ),
      displayMedium: TextStyle(
        fontSize: 40,
        fontWeight: FontWeight.w600,
        height: 1.15,
        letterSpacing: -0.4,
        color: onSurface,
      ),
      displaySmall: TextStyle(
        fontSize: 32,
        fontWeight: FontWeight.w600,
        height: 1.2,
        letterSpacing: -0.3,
        color: onSurface,
      ),
      // ── 标题（区块标题、卡片标题） ──
      headlineLarge: TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.w600,
        height: 1.25,
        letterSpacing: -0.2,
        color: onSurface,
      ),
      headlineMedium: TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        height: 1.3,
        color: onSurface,
      ),
      headlineSmall: TextStyle(
        fontSize: 21,
        fontWeight: FontWeight.w600,
        height: 1.35,
        color: onSurface,
      ),
      // ── 次级标题（AppBar 标题、列表项标题） ──
      titleLarge: TextStyle(
        fontSize: 19,
        fontWeight: FontWeight.w600,
        height: 1.4,
        color: onSurface,
      ),
      titleMedium: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        height: 1.4,
        color: onSurface,
      ),
      titleSmall: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        height: 1.4,
        color: onSurface,
      ),
      // ── 正文 ──
      bodyLarge: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w400,
        height: 1.5,
        color: onSurface,
      ),
      bodyMedium: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w400,
        height: 1.5,
        color: onSurface,
      ),
      bodySmall: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w400,
        height: 1.45,
        color: onVariant,
      ),
      // ── 标签 / 按钮 / 徽章 ──
      labelLarge: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        height: 1.4,
        color: onSurface,
      ),
      labelMedium: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        height: 1.4,
        color: onVariant,
      ),
      labelSmall: TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w600,
        height: 1.4,
        color: onVariant,
      ),
    );
  }

  static ThemeData _build(ColorScheme colorScheme) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      brightness: colorScheme.brightness,
      scaffoldBackgroundColor: colorScheme.surface,
      textTheme: _textTheme(colorScheme),
      appBarTheme: AppBarTheme(
        backgroundColor: colorScheme.surface,
        foregroundColor: colorScheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: AppTokens.radiusSm,
        centerTitle: false,
        titleTextStyle: _textTheme(colorScheme).titleLarge,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        clipBehavior: Clip.antiAlias,
        color: cardContainer(colorScheme),
        // 柔和填充卡（Legado MD3 观感）：无描边无投影，色值完全由
        // ColorScheme 派生（暖壁纸 → 暖卡面），靠色阶与圆角划界。
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusLg),
        ),
      ),
      // 图标体系统一：默认尺寸 22、默认色 onSurfaceVariant（三级文字层次的
      // 「图标/副标题」档）。强调色/反色场景由各组件主题或显式 color 覆盖。
      iconTheme: IconThemeData(size: 22, color: colorScheme.onSurfaceVariant),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTokens.radiusSm),
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: AppTokens.spaceLg,
            vertical: AppTokens.spaceMd,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTokens.radiusSm),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTokens.radiusSm),
          ),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusFull),
        ),
        padding: const EdgeInsets.symmetric(horizontal: AppTokens.spaceSm),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTokens.radiusFull),
          ),
        ),
      ),
      listTileTheme: ListTileThemeData(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: AppTokens.spaceLg),
        iconColor: colorScheme.onSurfaceVariant,
        // 图标尺寸由全局 iconTheme(size: 22) 统一，ListTile 不再单设。
      ),
      dividerTheme: DividerThemeData(
        color: colorScheme.outlineVariant,
        thickness: 1,
        space: AppTokens.spaceLg,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        ),
        backgroundColor: colorScheme.inverseSurface,
        contentTextStyle: TextStyle(color: colorScheme.onInverseSurface),
      ),
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusLg),
        ),
        elevation: 0,
      ),
      // 底部列表弹层（showModalBottomSheet）：全局去阴影 + 圆角。
      // 默认 modal 底部弹层带 elevation 1 的投影且仅在显式传 shape 时有
      // 圆角；未传 shape 的弹层靠 theme 兜底。clipBehavior 让 ListTile 等
      // 贴边内容裁剪进圆角内，避免方角溢出。
      bottomSheetTheme: const BottomSheetThemeData(
        elevation: 0,
        modalElevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppTokens.radiusLg),
          ),
        ),
        clipBehavior: Clip.antiAlias,
      ),
      // 浮层菜单（PopupMenuButton 三点菜单等）：同列表弹窗设计语言，
      // 去阴影 + 圆角（默认 4dp 圆角 + elevation 3 投影）。
      popupMenuTheme: const PopupMenuThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(AppTokens.radiusMd)),
        ),
      ),
      progressIndicatorTheme:
          ProgressIndicatorThemeData(color: colorScheme.primary),
      visualDensity: VisualDensity.adaptivePlatformDensity,
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.android: AppPageTransitionsBuilder(),
          TargetPlatform.iOS: AppPageTransitionsBuilder(),
          TargetPlatform.macOS: AppPageTransitionsBuilder(),
          TargetPlatform.windows: AppPageTransitionsBuilder(),
          TargetPlatform.linux: AppPageTransitionsBuilder(),
          TargetPlatform.fuchsia: AppPageTransitionsBuilder(),
        },
      ),
    );
  }
}

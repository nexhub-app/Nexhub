import 'package:flutter/material.dart';
import 'app_tokens.dart';

/// 应用主题工厂。
///
/// - `useMaterial3: true`。
/// - 默认主色为蓝青（[AppTokens.seedYouthfulPrimary]，#0EA5E9）；[AppTokens.seedLightBlue] 仅作可选预设，
///   可通过 `scheme` 注入莫奈动态色或自定义 seed 生成的 ColorScheme。
/// - `app.dart` 中：`theme: AppTheme.light()`、`darkTheme: AppTheme.dark()`，
///   并删除任何内联 `ThemeData(colorSchemeSeed: ...)`。
/// 全局页面切换转场：无动画瞬间切换。
///
/// 历史：先后尝试「滑入+回弹缩放」与「M3 fade-through 干净淡入」，
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

  static ThemeData light({ColorScheme? scheme, Color? seed}) {
    final ColorScheme colorScheme = scheme ??
        ColorScheme.fromSeed(
          seedColor: seed ?? AppTokens.seedYouthfulPrimary,
          brightness: Brightness.light,
        );
    return _build(colorScheme);
  }

  static ThemeData dark({ColorScheme? scheme, Color? seed}) {
    final ColorScheme colorScheme = scheme ??
        ColorScheme.fromSeed(
          seedColor: seed ?? AppTokens.seedYouthfulPrimary,
          brightness: Brightness.dark,
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
  /// 建立清晰层次，减少 M3 默认「字号偏大、行距松散」的 AI 感。
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
        fontSize: 50, fontWeight: FontWeight.w600, height: 1.12,
        letterSpacing: -0.5, color: onSurface,
      ),
      displayMedium: TextStyle(
        fontSize: 40, fontWeight: FontWeight.w600, height: 1.15,
        letterSpacing: -0.4, color: onSurface,
      ),
      displaySmall: TextStyle(
        fontSize: 32, fontWeight: FontWeight.w600, height: 1.2,
        letterSpacing: -0.3, color: onSurface,
      ),
      // ── 标题（区块标题、卡片标题） ──
      headlineLarge: TextStyle(
        fontSize: 28, fontWeight: FontWeight.w600, height: 1.25,
        letterSpacing: -0.2, color: onSurface,
      ),
      headlineMedium: TextStyle(
        fontSize: 24, fontWeight: FontWeight.w600, height: 1.3,
        color: onSurface,
      ),
      headlineSmall: TextStyle(
        fontSize: 21, fontWeight: FontWeight.w600, height: 1.35,
        color: onSurface,
      ),
      // ── 次级标题（AppBar 标题、列表项标题） ──
      titleLarge: TextStyle(
        fontSize: 19, fontWeight: FontWeight.w600, height: 1.4,
        color: onSurface,
      ),
      titleMedium: TextStyle(
        fontSize: 15, fontWeight: FontWeight.w600, height: 1.4,
        color: onSurface,
      ),
      titleSmall: TextStyle(
        fontSize: 13, fontWeight: FontWeight.w600, height: 1.4,
        color: onSurface,
      ),
      // ── 正文 ──
      bodyLarge: TextStyle(
        fontSize: 15, fontWeight: FontWeight.w400, height: 1.5,
        color: onSurface,
      ),
      bodyMedium: TextStyle(
        fontSize: 13, fontWeight: FontWeight.w400, height: 1.5,
        color: onSurface,
      ),
      bodySmall: TextStyle(
        fontSize: 11, fontWeight: FontWeight.w400, height: 1.45,
        color: onVariant,
      ),
      // ── 标签 / 按钮 / 徽章 ──
      labelLarge: TextStyle(
        fontSize: 13, fontWeight: FontWeight.w600, height: 1.4,
        color: onSurface,
      ),
      labelMedium: TextStyle(
        fontSize: 11, fontWeight: FontWeight.w600, height: 1.4,
        color: onVariant,
      ),
      labelSmall: TextStyle(
        fontSize: 10, fontWeight: FontWeight.w600, height: 1.4,
        color: onVariant,
      ),
    );
  }

  static ThemeData _build(ColorScheme colorScheme) {
    final bool isDark = colorScheme.brightness == Brightness.dark;
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
        color: isDark
            ? colorScheme.surfaceContainerHighest
            : colorScheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        ),
      ),
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
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        selectedItemColor: colorScheme.primary,
        unselectedItemColor: colorScheme.onSurfaceVariant,
        backgroundColor: colorScheme.surface,
        elevation: 0,
        type: BottomNavigationBarType.fixed,
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
      progressIndicatorTheme: ProgressIndicatorThemeData(color: colorScheme.primary),
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

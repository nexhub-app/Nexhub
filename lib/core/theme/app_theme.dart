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
      surfaceVariant: const Color(0xFF272727),
      onSurfaceVariant: const Color(0xFFC9C2BE),
      outline: const Color(0xFF3A3A3A),
      outlineVariant: const Color(0xFF2A2A2A),
      surfaceTint: Colors.transparent,
      shadow: const Color(0xFF000000),
    );
    return _build(scheme);
  }

  static ThemeData _build(ColorScheme colorScheme) {
    final bool isDark = colorScheme.brightness == Brightness.dark;
    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      brightness: colorScheme.brightness,
      scaffoldBackgroundColor: colorScheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: colorScheme.surface,
        foregroundColor: colorScheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: AppTokens.radiusSm,
        centerTitle: false,
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

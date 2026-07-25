import 'package:flutter/material.dart';
import 'app_tokens.dart';

/// 应用主题工厂。
///
/// - `useMaterial3: true`。
/// - 默认主色为蓝青（[AppTokens.seedYouthfulPrimary]，#0EA5E9）；[AppTokens.seedLightBlue] 仅作可选预设，
///   可通过 `scheme` 注入莫奈动态色或自定义 seed 生成的 ColorScheme。
/// - `app.dart` 中：`theme: AppTheme.light()`、`darkTheme: AppTheme.dark()`，
///   并删除任何内联 `ThemeData(colorSchemeSeed: ...)`。
/// 全局页面切换「灵动」转场。
///
/// 新页从右侧轻微滑入 + 淡入 + 回弹缩放（[Curves.easeOutCubic] 平滑 / [Curves.easeOutBack] 弹簧），
/// 旧页被覆盖时轻微左移淡出。接入 [ThemeData.pageTransitionsTheme] 后，所有
/// `Navigator.push` 的 `MaterialPageRoute` 与对话框统一获得该动效，与底栏/卡片同源。
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
    final Curve ease = Curves.easeOutCubic;
    final enterSlide = Tween<Offset>(
      begin: const Offset(0.06, 0),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: animation, curve: ease));
    final enterFade = CurvedAnimation(parent: animation, curve: ease);
    final enterScale = Tween<double>(begin: 0.98, end: 1.0).animate(
      CurvedAnimation(parent: animation, curve: Curves.easeOutBack),
    );
    final exitSlide = Tween<Offset>(
      begin: Offset.zero,
      end: const Offset(-0.05, 0),
    ).animate(CurvedAnimation(parent: secondaryAnimation, curve: ease));
    // 注意：secondaryAnimation 在页面「正常显示（未被覆盖）」时值为 0，
    // 被新页覆盖过程中 0→1。因此淡出透明度必须是 1→0 的反向映射；
    // 若直接把 CurvedAnimation 当 opacity 用，页面常态 opacity=0 → 整页隐形
    // （曾导致 Windows 全局黑屏且无任何异常，见 2026-07-25 复盘）。
    final exitFade = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(parent: secondaryAnimation, curve: ease),
    );
    return SlideTransition(
      position: enterSlide,
      child: FadeTransition(
        opacity: enterFade,
        child: ScaleTransition(
          scale: enterScale,
          child: SlideTransition(
            position: exitSlide,
            child: FadeTransition(opacity: exitFade, child: child),
          ),
        ),
      ),
    );
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

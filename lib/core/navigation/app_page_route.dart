import 'package:flutter/material.dart';

/// 零时长页面路由。
///
/// `MaterialPageRoute` 自带的 `transitionDuration` 默认约 300ms——即使
/// [PageTransitionsTheme] 的 builder 已返回 `child`（无动画），pop 时这条路由
/// 仍会在屏幕上「定格」约 300ms 才被移除，表现为返回时的短暂卡顿。
///
/// 这里把 `transitionDuration` / `reverseTransitionDuration` 都设为 0，让
/// push/pop 真正瞬时完成，与「干脆瞬切」的偏好一致。
///
/// 仅作用于**页面路由**（[Navigator.push] 的匿名路由）。对话框走 [DialogRoute]、
/// 底部抽屉走 [ModalBottomSheetRoute]，二者各自保留动画，不受此影响。
class AppPageRoute<T> extends MaterialPageRoute<T> {
  AppPageRoute({
    required super.builder,
    super.settings,
    super.maintainState = true,
    super.fullscreenDialog = false,
    super.allowSnapshotting = true,
  });

  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Duration get reverseTransitionDuration => Duration.zero;
}

/// 带共享元素（Hero）飞行的页面路由。
///
/// 与 [AppPageRoute] 的区别：保留约 320ms 的转场时长，让封面图能「飞」过去；
/// 但 [buildTransitions] 直接返回 `child`（不叠加淡入/滑动），页面本体仍瞬时
/// 呈现，只有 Hero 元素在飞。用于「列表卡片 → 详情页」这类带封面的跳转。
///
/// 非 Hero 路由（普通页面、底栏切换）继续用 [AppPageRoute]，保持零时长瞬切，
/// 与「干脆瞬切」偏好一致，互不干扰。
class AppHeroPageRoute<T> extends MaterialPageRoute<T> {
  AppHeroPageRoute({
    required super.builder,
    super.settings,
    super.maintainState = true,
    super.fullscreenDialog = false,
    super.allowSnapshotting = true,
  });

  @override
  Duration get transitionDuration => const Duration(milliseconds: 320);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 320);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // 页面本体瞬时呈现；Hero 共享元素自行沿路由动画飞行。
    return child;
  }
}

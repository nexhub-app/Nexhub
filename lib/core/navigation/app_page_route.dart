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

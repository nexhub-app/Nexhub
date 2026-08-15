import 'package:flutter/material.dart';
import 'app_loading_indicator.dart';

/// 主题化的下拉刷新指示器。
///
/// 当前 Flutter 3.32 的 [RefreshIndicator] 不支持自定义 indicator builder，
/// 因此这里用原生指示器并统一主题（主色圈、浅底、加粗描边），弹性手感由
/// 各列表已加的 [BouncingScrollPhysics] 下拉拉伸回弹提供。
///
/// 用法与 [RefreshIndicator] 一致：`AppRefreshIndicator(onRefresh: ..., child: ...)`。
class AppRefreshIndicator extends StatelessWidget {
  const AppRefreshIndicator({
    super.key,
    required this.child,
    required this.onRefresh,
  });

  final Widget child;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return RefreshIndicator(
      onRefresh: onRefresh,
      color: scheme.primary,
      backgroundColor: scheme.surfaceContainerHighest,
      strokeWidth: 3,
      displacement: 44,
      child: child,
    );
  }
}

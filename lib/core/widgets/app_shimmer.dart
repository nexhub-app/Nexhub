/// 轻量微光骨架（shimmer）组件，基于 [AppTokens] 配色，保持与现有
/// Material 3 / 极简风格一致。用于加载态占位（替代纯灰块），营造灵动感。
library;

import 'package:flutter/material.dart';
import '../theme/app_tokens.dart';

/// 单个微光块。宽高通过 [width]/[height] 控制；[borderRadius] 默认 8。
class AppShimmer extends StatefulWidget {
  final double? width;
  final double? height;
  final double borderRadius;
  final EdgeInsetsGeometry? margin;
  final BoxShape shape;

  /// 相位偏移（0..1）。同屏多个骨架块传入不同值可错开呼吸节奏，
  /// 避免整屏同频闪烁产生的机械感。默认 0（同相）。
  final double phase;

  const AppShimmer({
    super.key,
    this.width,
    this.height,
    this.borderRadius = 8,
    this.margin,
    this.shape = BoxShape.rectangle,
    this.phase = 0,
  });

  @override
  State<AppShimmer> createState() => _AppShimmerState();
}

class _AppShimmerState extends State<AppShimmer>
    with SingleTickerProviderStateMixin {
  /// 单向循环（非 reverse），三角波映射在 [build] 中完成，
  /// 这样 [AppShimmer.phase] 才能真正参与相位计算。
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  )..repeat();

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color base = scheme.onSurfaceVariant.withValues(alpha: 0.10);
    final Color mid = scheme.onSurfaceVariant.withValues(alpha: 0.20);
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (BuildContext context, Widget? child) {
        // 0→1→0 三角波，等价于原 repeat(reverse: true) 的观感。
        final double raw = (_ctrl.value + widget.phase) % 1.0;
        final double t = raw < 0.5 ? raw * 2 : (1 - raw) * 2;
        final Color color = Color.lerp(base, mid, t) ?? base;
        return Container(
          width: widget.width,
          height: widget.height,
          margin: widget.margin,
          decoration: BoxDecoration(
            color: color,
            shape: widget.shape,
            borderRadius: widget.shape == BoxShape.rectangle
                ? BorderRadius.circular(widget.borderRadius)
                : null,
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }
}

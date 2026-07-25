import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../theme/app_tokens.dart';

/// 统一加载指示器：三点弹跳「灵动」动画。
///
/// 替代原来的 [CircularProgressIndicator] 转圈：三个主题色圆点依次
/// 弹跳（正弦上抛 + 顶点微放大），错峰 160ms，形成活泼的波浪节奏。
/// API 与旧版兼容（message / center），所有调用点无需改动。
class AppLoadingIndicator extends StatelessWidget {
  final String? message; // 来自 l10n
  final bool center;
  const AppLoadingIndicator({
    super.key,
    this.message,
    this.center = true,
  });

  @override
  Widget build(BuildContext context) {
    final Widget child = Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const AppBouncingDots(),
        if (message != null) ...<Widget>[
          const SizedBox(height: AppTokens.spaceMd),
          Text(message!, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ],
    );
    return center ? Center(child: child) : child;
  }
}

/// 三点弹跳动画本体（可单独嵌入按钮 / 行内等紧凑场景）。
class AppBouncingDots extends StatefulWidget {
  const AppBouncingDots({
    super.key,
    this.dotSize = 9,
    this.color,
  });

  /// 单个圆点直径。
  final double dotSize;

  /// 圆点颜色；默认主题主色。
  final Color? color;

  @override
  State<AppBouncingDots> createState() => _AppBouncingDotsState();
}

class _AppBouncingDotsState extends State<AppBouncingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color color = widget.color ?? Theme.of(context).colorScheme.primary;
    final double size = widget.dotSize;
    // 弹跳高度约 1.1 倍点径，视觉轻快不夸张。
    final double bounce = size * 1.1;
    return SizedBox(
      height: size + bounce + 4,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: List<Widget>.generate(3, (int i) {
              // 每个点错峰 0.145（≈160ms），只在前 55% 周期内完成一次上抛，
              // 其余时间停在地面，形成「哒-哒-哒…停」的波浪节奏。
              final double t = (_ctrl.value - i * 0.145) % 1.0;
              final double phase = t < 0 ? t + 1.0 : t;
              double lift = 0;
              if (phase < 0.55) {
                // 正弦上抛：0→1→0，天然的加速/减速手感。
                lift = math.sin(phase / 0.55 * math.pi);
              }
              // 顶点轻微放大 + 提亮，落地还原。
              final double scale = 1.0 + 0.18 * lift;
              return Padding(
                padding: EdgeInsets.symmetric(horizontal: size * 0.28),
                child: Transform.translate(
                  offset: Offset(0, -bounce * lift),
                  child: Transform.scale(
                    scale: scale,
                    child: Container(
                      width: size,
                      height: size,
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.55 + 0.45 * lift),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}

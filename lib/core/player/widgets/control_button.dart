import 'package:flutter/material.dart';
import '../../widgets/app_animations.dart';

/// 播放器控制按钮。
///
/// 统一封装 [IconButton]，保持一致的尺寸与配色，
/// 用于播放 / 暂停 / 上一集 / 下一集等播放器控制栏。
/// 内部已包 [AppTapScale] 按压回弹（禁用态不缩放）。
class ControlButton extends StatelessWidget {
  const ControlButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.size,
  });

  /// 按钮图标。
  final IconData icon;

  /// 点击回调。
  final VoidCallback? onPressed;

  /// 悬停 / 长按提示文本（应来自 l10n）。
  final String? tooltip;

  /// 图标尺寸，默认 24。
  final double? size;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurface;
    return AppTapScale(
      enable: onPressed != null,
      child: IconButton(
        icon: Icon(icon, size: size ?? 24),
        color: color,
        onPressed: onPressed,
        tooltip: tooltip,
      ),
    );
  }
}

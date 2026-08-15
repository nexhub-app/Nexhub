import 'package:flutter/material.dart';
import 'app_animations.dart';

/// 统一图标按钮。tooltip 必须来自 l10n。
///
/// 内部已包 [AppTapScale] 按压回弹（禁用态不缩放），全站图标按钮手感与底栏一致。
class AppIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip; // 来自 l10n
  final VoidCallback? onPressed;
  final bool filled;
  final Color? color;
  const AppIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.filled = false,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final Widget btn = filled
        ? IconButton.filledTonal(
            onPressed: onPressed,
            tooltip: tooltip,
            icon: Icon(icon),
          )
        : IconButton(
            onPressed: onPressed,
            tooltip: tooltip,
            color: color,
            icon: Icon(icon),
          );
    return AppTapScale(enable: onPressed != null, child: btn);
  }
}

import 'package:material_ui/material_ui.dart';
import '../theme/app_tokens.dart';

/// 统一卡片容器（token 圆角 + 阴影）。点击态可选。
class AppCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final VoidCallback? onTap;
  final Color? color;
  const AppCard({
    super.key,
    required this.child,
    this.padding,
    this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // 背景色由 Material 直接承载：ListTile 等墨水组件嵌在卡内时，
    // 最近 Material 祖先须先于带背景的容器出现（3.44 debug 断言），墨水落点才正确。
    final Widget content = Material(
      color: color ?? scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: padding ?? const EdgeInsets.all(AppTokens.spaceMd),
        child: child,
      ),
    );
    return onTap != null
        ? InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(AppTokens.radiusMd),
            child: content,
          )
        : Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppTokens.radiusMd),
              boxShadow: AppShadows.card(scheme),
            ),
            child: content,
          );
  }
}

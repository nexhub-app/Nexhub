import 'package:material_ui/material_ui.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';

/// 统一卡片容器（柔和填充卡：token 圆角 + 无描边无投影）。点击态可选。
class AppCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final VoidCallback? onTap;

  /// 覆盖卡底色（默认 surfaceContainerLow，随 ColorScheme 动态取色）。
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
    // 柔和填充卡（Legado MD3 观感）：elevation 0，靠色阶与圆角划界，不靠线框。
    final Widget content = Material(
      color: color ?? AppTheme.cardContainer(scheme),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTokens.radiusLg),
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
            borderRadius: BorderRadius.circular(AppTokens.radiusLg),
            child: content,
          )
        : content;
  }
}

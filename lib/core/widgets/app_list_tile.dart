import 'package:flutter/material.dart';
import '../theme/app_tokens.dart';
import 'app_animations.dart';

/// 列表项统一封装：强制 token 间距，保证全应用列表视觉一致（单一真源）。
///
/// [entranceKey] 非空时，列表项首屏淡入上滑（灵动入场），相同 key 只播一次。
class AppListTile extends StatelessWidget {
  final Widget? leading;
  final Widget? title;
  final Widget? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool selected;
  final String? entranceKey;
  const AppListTile({
    super.key,
    this.leading,
    this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.selected = false,
    this.entranceKey,
  });

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Widget tile = ListTile(
      leading: leading,
      title: title,
      subtitle: subtitle,
      trailing: trailing,
      onTap: onTap,
      onLongPress: onLongPress,
      selected: selected,
      selectedColor: scheme.primary,
      selectedTileColor: scheme.primaryContainer.withValues(alpha: 0.3),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: AppTokens.spaceLg),
      minLeadingWidth: AppTokens.spaceLg,
    );
    if (entranceKey == null) return tile;
    return Entrance(onceKey: entranceKey, child: tile);
  }
}

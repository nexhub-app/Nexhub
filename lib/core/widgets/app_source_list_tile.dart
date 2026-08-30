import 'package:flutter/material.dart';
import '../theme/app_tokens.dart';
import '../utils/app_haptics.dart';
import 'app_icon_button.dart';
import 'app_animations.dart';

/// 源列表项（源管理页专用）。统一布局：名称 + 地址 + 状态标签 + 操作按钮。
///
/// [entranceKey] 非空时，列表项首屏淡入上滑（灵动入场），相同 key 只播一次。
class AppSourceListTile extends StatelessWidget {
  final String name;
  final String? url;
  final bool enabled;
  final bool deprecated;
  final String deprecatedLabel;
  final String healthyLabel;
  final String disabledLabel;
  final String mirrorSettingsTooltip;
  final VoidCallback? onTap;
  final VoidCallback? onMirrorSettings;
  final ValueChanged<bool>? onToggle;
  final String? entranceKey;

  const AppSourceListTile({
    super.key,
    required this.name,
    this.url,
    this.enabled = true,
    this.deprecated = false,
    required this.deprecatedLabel,
    required this.healthyLabel,
    required this.disabledLabel,
    required this.mirrorSettingsTooltip,
    this.onTap,
    this.onMirrorSettings,
    this.onToggle,
    this.entranceKey,
  });

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    Widget statusChip() {
      if (deprecated) {
        return Chip(
          label: Text(deprecatedLabel,
              style: TextStyle(color: scheme.onErrorContainer, fontSize: 11)),
          backgroundColor: scheme.errorContainer,
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: EdgeInsets.zero,
        );
      }
      if (!enabled) {
        return Chip(
          label: Text(disabledLabel,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11)),
          backgroundColor: scheme.surfaceContainerHighest,
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: EdgeInsets.zero,
        );
      }
      final Color healthy = AppStatusColors.ok(scheme);
      return Chip(
        label:
            Text(healthyLabel, style: TextStyle(color: healthy, fontSize: 11)),
        backgroundColor: AppStatusColors.containerOf(healthy),
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: EdgeInsets.zero,
      );
    }

    final Widget tile = ListTile(
      leading: CircleAvatar(
        backgroundColor: scheme.primaryContainer,
        child: Text(
          name.isNotEmpty ? name[0].toUpperCase() : '?',
          style: TextStyle(color: scheme.onPrimaryContainer),
        ),
      ),
      title: Text(name),
      subtitle: url != null
          ? Text(url!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: scheme.onSurfaceVariant))
          : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          statusChip(),
          if (onMirrorSettings != null)
            Padding(
              padding: const EdgeInsets.only(left: AppTokens.spaceSm),
              child: AppIconButton(
                icon: Icons.settings_ethernet,
                tooltip: mirrorSettingsTooltip,
                onPressed: onMirrorSettings,
              ),
            ),
          if (onToggle != null)
            Padding(
              padding: const EdgeInsets.only(left: AppTokens.spaceSm),
              child: Switch(
                value: enabled,
                onChanged: (v) {
                  AppHaptics.selectionClick();
                  onToggle!(v);
                },
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
        ],
      ),
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: AppTokens.spaceLg),
    );
    if (entranceKey == null) return tile;
    return Entrance(onceKey: entranceKey, child: tile);
  }
}

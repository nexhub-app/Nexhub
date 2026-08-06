/// 设置子页公共组件。
///
/// 把散落在播放器 / 阅读器 / 布局 / 弹幕等设置页里重复的
/// "分组标题 + 滑块 + 开关 + 分段单选"代码收敛到一处，统一风格：
/// - [SettingsLeadingIcon]：动态主色图标瓦（入口行 leading）；
/// - [SettingsSection]：分组标题 + 可选说明；
/// - [SettingsCard]：带标题的卡片容器（圆角 + 阴影 + 统一内边距）；
/// - [SettingsSliderTile]：带当前值的滑块；
/// - [SettingsSwitchTile]：开关项；
/// - [SettingsSegmentedTile]：分段单选（SegmentedButton 包装）；
/// - [SettingsChoiceChips]：单选 Chip。
library;

import 'package:flutter/material.dart';

import '../../../../core/theme/app_tokens.dart';
import '../../../../core/widgets/app_animations.dart';

/// 动态主色图标瓦：用于设置子页入口行的 leading。
///
/// 背景取 `primaryContainer`、图标取 `onPrimaryContainer`，随用户选择的
/// 种子色（Monet / 预设 / 自定义）实时变化，实现全设置层级色彩统一。
class SettingsLeadingIcon extends StatelessWidget {
  final IconData icon;
  final double iconSize;
  final double containerSize;

  const SettingsLeadingIcon({
    super.key,
    required this.icon,
    this.iconSize = 20,
    this.containerSize = 40,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: containerSize,
      height: containerSize,
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(AppTokens.radiusSm),
      ),
      child: Icon(icon, color: scheme.onPrimaryContainer, size: iconSize),
    );
  }
}

/// 分组标题（不含卡片背景）。用于卡片外部的独立小标题。
class SettingsSection extends StatelessWidget {
  final String title;
  final String? description;
  final EdgeInsetsGeometry? padding;

  const SettingsSection({
    super.key,
    required this.title,
    this.description,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: padding ??
          const EdgeInsets.symmetric(
            horizontal: AppTokens.spaceXs,
            vertical: AppTokens.spaceXs,
          ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (description != null) ...<Widget>[
            const SizedBox(height: AppTokens.spaceXs),
            Text(
              description!,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}

/// 带标题的卡片容器。把所有同类设置项收进一个 [AppCard]，视觉分组更清晰。
///
/// 支持可展开/折叠：传 [expandable] = true（默认）时，标题栏可点击切换
/// 内容区的显示/隐藏，使用 [AnimatedSize] 实现平滑过渡动画。
class SettingsCard extends StatefulWidget {
  final String? title;
  final String? description;
  final List<Widget> children;
  final EdgeInsetsGeometry? margin;
  final Color? backgroundColor;

  /// 是否可展开/折叠（默认 true）。无标题时强制不展开。
  final bool expandable;

  /// 初始状态是否展开（默认 true）。仅在 [expandable] = true 时生效。
  final bool initiallyExpanded;

  /// 交错入场序列索引。传此值后卡片按 index*80ms 延迟入场。
  final int? index;

  const SettingsCard({
    super.key,
    this.title,
    this.description,
    required this.children,
    this.margin,
    this.backgroundColor,
    this.expandable = true,
    this.initiallyExpanded = true,
    this.index,
  });

  @override
  State<SettingsCard> createState() => _SettingsCardState();
}

class _SettingsCardState extends State<SettingsCard> {
  late bool _expanded;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasTitle = widget.title != null;
    final canExpand = widget.expandable && hasTitle;

    // 标题栏（可点击展开/折叠）
    final List<Widget> columnChildren = <Widget>[];
    if (hasTitle) {
      columnChildren.add(
        InkWell(
          onTap: canExpand ? () => setState(() => _expanded = !_expanded) : null,
          borderRadius: BorderRadius.circular(AppTokens.radiusSm),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppTokens.spaceXs),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        widget.title!,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (widget.description != null) ...<Widget>[
                        const SizedBox(height: AppTokens.spaceXs),
                        Text(
                          widget.description!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (canExpand)
                  // 折叠箭头随展开状态平滑旋转（180°），点标题时有「翻开」的灵动感。
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0.0,
                    duration: AppTokens.durBase,
                    curve: AppCurves.smooth,
                    child: Icon(
                      Icons.expand_more,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
      if (canExpand) {
        columnChildren.add(
          AnimatedSize(
            duration: AppTokens.durBase,
            curve: Curves.easeInOutCubic,
            alignment: Alignment.topCenter,
            child: _expanded
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const SizedBox(height: AppTokens.spaceMd),
                      ..._spaced(widget.children, AppTokens.spaceMd),
                    ],
                  )
                : const SizedBox.shrink(),
          ),
        );
      } else {
        columnChildren.add(const SizedBox(height: AppTokens.spaceMd));
        columnChildren.add(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: _spaced(widget.children, AppTokens.spaceMd),
          ),
        );
      }
    } else {
      // 无标题：直接显示内容，不可展开
      columnChildren.add(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: _spaced(widget.children, AppTokens.spaceMd),
        ),
      );
    }

    // 「灵动」入场：设置卡片淡入 + 轻微上滑。onceKey 用 title 或 widget.key，
    // 保证同一卡片在生命周期内只播一次，避免滚动 / 重建时抖动重播。
    final String? onceKey = widget.title ?? widget.key?.toString();
    return Entrance(
      onceKey: onceKey,
      index: widget.index,
      offset: 10,
      child: Container(
        margin: widget.margin ?? const EdgeInsets.only(bottom: AppTokens.spaceMd),
        padding: const EdgeInsets.all(AppTokens.spaceMd),
        decoration: BoxDecoration(
          color: widget.backgroundColor ?? theme.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: columnChildren,
        ),
      ),
    );
  }

  static List<Widget> _spaced(List<Widget> children, double gap) {
    if (children.isEmpty) return children;
    final List<Widget> out = <Widget>[children.first];
    for (var i = 1; i < children.length; i++) {
      out
        ..add(const SizedBox(height: AppTokens.spaceMd))
        ..add(children[i]);
    }
    return out;
  }
}

/// 带当前显示值的滑块。
class SettingsSliderTile extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String display;
  final ValueChanged<double> onChanged;

  const SettingsSliderTile({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.display,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppTokens.spaceXs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
              // 数值变化时轻弹一下，给「正在调」的即时反馈。
              AppValuePulse(
                trigger: display,
                from: 0.7,
                child: Text(
                  display,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.primary),
                ),
              ),
            ],
          ),
          Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

/// 开关项。
class SettingsSwitchTile extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const SettingsSwitchTile({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    // 切换时整行轻微弹性脉冲（力度收敛，避免大面积晃动）。
    return AppValuePulse(
      trigger: value,
      from: 0.985,
      child: SwitchListTile(
        title: Text(title),
        subtitle: subtitle != null ? Text(subtitle!) : null,
        value: value,
        onChanged: onChanged,
        contentPadding: EdgeInsets.zero,
      ),
    );
  }
}

/// 分段单选（SegmentedButton 包装）。标题在上、选项在下。
class SettingsSegmentedTile<T extends Object> extends StatelessWidget {
  final String title;
  final String? description;
  final Set<T> selected;
  final void Function(Set<T>) onSelectionChanged;
  final List<ButtonSegment<T>> segments;
  final EdgeInsetsGeometry? margin;

  const SettingsSegmentedTile({
    super.key,
    required this.title,
    this.description,
    required this.selected,
    required this.onSelectionChanged,
    required this.segments,
    this.margin,
  });

  @override
  Widget build(BuildContext context) {
    return SettingsCard(
      title: title,
      description: description,
      margin: margin,
      children: <Widget>[
        // 选项切换时轻微弹性脉冲。
        AppValuePulse(
          trigger: selected.isEmpty ? null : selected.first,
          from: 0.97,
          child: SegmentedButton<T>(
            selected: selected,
            onSelectionChanged: onSelectionChanged,
            segments: segments,
          ),
        ),
      ],
    );
  }
}

/// 单选 Chip 组。
class SettingsChoiceChips<T> extends StatelessWidget {
  final String title;
  final String? description;
  final T selected;
  final void Function(T) onSelected;
  final List<SettingsChoiceChipData<T>> options;
  final EdgeInsetsGeometry? margin;

  const SettingsChoiceChips({
    super.key,
    required this.title,
    this.description,
    required this.selected,
    required this.onSelected,
    required this.options,
    this.margin,
  });

  @override
  Widget build(BuildContext context) {
    return SettingsCard(
      title: title,
      description: description,
      margin: margin,
      children: <Widget>[
        Wrap(
          spacing: AppTokens.spaceSm,
          runSpacing: AppTokens.spaceXs,
          children: <Widget>[
            for (final opt in options)
              // 选中状态变化时该 Chip 弹一下（选中与取消都有反馈）。
              AppValuePulse(
                trigger: opt.value == selected,
                from: 0.9,
                child: ChoiceChip(
                  label: Text(opt.label),
                  selected: opt.value == selected,
                  onSelected: (_) => onSelected(opt.value),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// [SettingsChoiceChips] 的单选项。
class SettingsChoiceChipData<T> {
  final T value;
  final String label;
  const SettingsChoiceChipData({required this.value, required this.label});
}

/// 条件展开区域：依赖开关/选项显隐的子设置项组。
///
/// 包住「开启某开关后才会出现」的一组设置项，[visible] 变化时高度平滑
/// 过渡（[AnimatedSize]）+ 内容淡入上滑（[AnimatedSwitcher]），避免生硬
/// 地"啪"一下出现/消失，与卡片折叠手感一致。
class SettingsExpand extends StatelessWidget {
  final bool visible;
  final Widget child;

  /// 展开时内容区顶部留白（与卡片内其它项拉开距离）。
  final EdgeInsetsGeometry? padding;

  const SettingsExpand({
    super.key,
    required this.visible,
    required this.child,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: AppTokens.durBase,
      curve: AppCurves.smooth,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: AppTokens.durBase,
        switchInCurve: AppCurves.smooth,
        switchOutCurve: Curves.easeOutCubic,
        transitionBuilder: (Widget child, Animation<double> animation) {
          return FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, -0.04),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
          );
        },
        child: visible
            ? Padding(
                key: const ValueKey<String>('settings-expand-open'),
                padding:
                    padding ?? const EdgeInsets.only(top: AppTokens.spaceMd),
                child: child,
              )
            : const SizedBox(
                key: ValueKey<String>('settings-expand-closed'),
                width: double.infinity,
              ),
      ),
    );
  }
}

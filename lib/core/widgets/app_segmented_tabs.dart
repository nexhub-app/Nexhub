import 'package:flutter/material.dart';
import '../theme/app_tokens.dart';

/// 顶部分段切换（M3 风格等宽分段按钮）。
///
/// 用于「本地 / 历史记录 / 收藏」等互斥单选项。
///
/// 默认 [equalWidth]=true，所有分段严格等宽平铺，
/// 解决「本地」「历史记录」「收藏」因文字长度不同导致的视觉不齐。
///
/// [T] 允许为可空类型（如 `SourceType?`），以支持「全部」这类 null 语义的选项。
class AppSegmentedTabs<T> extends StatelessWidget {
  final Set<T> selected;
  final ValueChanged<Set<T>> onSelectionChanged;
  final List<ButtonSegment<T>> segments;
  final String? label; // 来自 l10n（可选辅助说明）
  final bool equalWidth;

  const AppSegmentedTabs({
    super.key,
    required this.selected,
    required this.onSelectionChanged,
    required this.segments,
    this.label,
    this.equalWidth = true,
  });

  @override
  Widget build(BuildContext context) {
    // 非等宽或空列表时回退到原生 SegmentedButton
    if (!equalWidth || segments.isEmpty) {
      return SegmentedButton<T>(
        selected: selected,
        onSelectionChanged: onSelectionChanged,
        segments: segments,
      );
    }

    // 等宽模式：自定义实现，保证每个分段宽度一致。
    // 选中项用「滑动胶囊」指示：切换时胶囊弹性滑动跟随（与底部导航栏同一套灵动语言）。
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final int n = segments.length;
    final int selIdx =
        segments.indexWhere((ButtonSegment<T> s) => selected.contains(s.value));

    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (BuildContext ctx, BoxConstraints c) {
          final double w = c.maxWidth;
          final double segW = w / n;
          final double pillLeft = selIdx < 0 ? -segW : selIdx * segW;
          return Stack(
            children: <Widget>[
              AnimatedPositioned(
                duration: AppTokens.durBase,
                curve: Curves.easeOutBack,
                left: pillLeft,
                top: 4,
                bottom: 4,
                width: segW,
                child: AnimatedOpacity(
                  opacity: selIdx < 0 ? 0.0 : 1.0,
                  duration: AppTokens.durFast,
                  child: Container(
                    decoration: BoxDecoration(
                      color: scheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.max,
                children: segments.asMap().entries.map((entry) {
                  final int idx = entry.key;
                  final ButtonSegment<T> seg = entry.value;
                  final T value = seg.value;
                  final bool isSelected = selected.contains(value);
                  final bool isFirst = idx == 0;
                  final bool isLast = idx == segments.length - 1;

                  return Expanded(
                    child: _EqualSegment(
                      label: seg.label,
                      icon: seg.icon,
                      selected: isSelected,
                      isFirst: isFirst,
                      isLast: isLast,
                      onTap: () => onSelectionChanged(<T>{value}),
                    ),
                  );
                }).toList(),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 等宽分段中的单个分段项。
class _EqualSegment<T> extends StatelessWidget {
  final Widget? label;
  final Widget? icon;
  final bool selected;
  final bool isFirst;
  final bool isLast;
  final VoidCallback onTap;

  const _EqualSegment({
    required this.label,
    this.icon,
    required this.selected,
    this.isFirst = false,
    this.isLast = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bool isSelected = selected;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        alignment: Alignment.center,
        // 背景由外层滑动胶囊提供，这里只负责文字/图标的颜色过渡。
        child: AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 200),
          style: Theme.of(context).textTheme.labelLarge!.copyWith(
                color: isSelected
                    ? scheme.onSecondaryContainer
                    : scheme.onSurfaceVariant,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              ),
          child: icon != null && label != null
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconTheme(
                      data: IconThemeData(
                        size: 18,
                        color: isSelected
                            ? scheme.onSecondaryContainer
                            : scheme.onSurfaceVariant,
                      ),
                      child: icon!,
                    ),
                    const SizedBox(width: 4),
                    label!,
                  ],
                )
              : label ?? icon ?? const SizedBox.shrink(),
        ),
      ),
    );
  }
}

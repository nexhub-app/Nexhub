import 'package:flutter/material.dart';
import '../theme/app_tokens.dart';

/// 统一设计常量（仅本组件内部使用）。
const double _kPillW = 36; // 选中胶囊宽度（只罩图标）
const double _kPillH = 24; // 选中胶囊高度
const double _kIconBox = 44; // 图标占位盒（留足缩放空间）
const double _kLabelGap = 4; // 图标与文字间距
const double _kLabelH = 12; // 文字估算高度（用于把胶囊对准图标中心）

/// 图标中心相对「单元格」的纵向偏移：列整体居中，图标盒在上、文字在下，
/// 故图标中心比单元格中心上移 (文字高 + 间距)/2。
double _iconCenterOffset(double cellMain) =>
    (cellMain - (_kIconBox + _kLabelGap + _kLabelH)) / 2 + _kIconBox / 2;

/// 应用导航栏统一封装。
///
/// 宽屏（≥ [AppTokens.desktopBreakpoint]）与窄屏共用**同一套视觉与动效**：
/// - 选中指示为图标背后的**小圆角胶囊**（[AppTokens.navRailWidth] 内居中），
///   选中项切换时胶囊**平滑滑动跟随**（[AnimatedPositioned]）。
/// - **所有项**都有按压反馈：选中项图标弹性放大 1.18，未选中项按下轻微回弹 0.9；
///   点击带 Material 水波纹；文字颜色/字重平滑过渡。
/// 胶囊与图标配色：
/// - 选中：`colorScheme.primary` 14% 淡主题色胶囊（不鲜艳）/ 图标文字 `primary`。
/// - 预点击（未选中项悬停/按下）：`onSurfaceVariant` 半透明灰色胶囊（仅小胶囊，无大背景）。
///
/// API 保持与 [NavigationBar] 一致：
/// [selectedIndex] / [onDestinationSelected] / [destinations]。
class AppNavBar extends StatelessWidget {
  const AppNavBar({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<NavigationDestination> destinations;

  @override
  Widget build(BuildContext context) {
    final double width = MediaQuery.sizeOf(context).width;
    if (width >= AppTokens.desktopBreakpoint) {
      return _buildRail(context);
    }
    return _buildBar(context);
  }

  /// 窄屏：底部横向导航。
  Widget _buildBar(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final int n = destinations.length;
    return Material(
      color: cs.surface,
      elevation: 2,
      // 安全区移到固定高度之外：底部导航栏总高 = 固定高 + 系统手势条，
      // 内容始终位于手势条上方，不再被遮挡（修复退出全屏后底栏被挡）。
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: AppTokens.bottomNavHeight,
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints c) {
              final double w = c.maxWidth;
              final double h = c.maxHeight;
              final double itemW = w / n;
              final double iconCenterY = _iconCenterOffset(h);
              final double pillLeft =
                  selectedIndex * itemW + (itemW - _kPillW) / 2;
              final double pillTop = iconCenterY - _kPillH / 2;
              return _NavStack(
                axis: Axis.horizontal,
                cs: cs,
                pillLeft: pillLeft,
                pillTop: pillTop,
                children: List<Widget>.generate(n, (int i) {
                  return SizedBox(
                    width: itemW,
                    height: h,
                    child: _AppNavItem(
                      destination: destinations[i],
                      selected: i == selectedIndex,
                      onTap: () => onDestinationSelected(i),
                    ),
                  );
                }),
              );
            },
          ),
        ),
      ),
    );
  }

/// 宽屏：左侧竖向导航（同套视觉与动效），项固定高度、顶部集中排列，
/// 避免整屏均分导致过散。
Widget _buildRail(BuildContext context) {
  final ColorScheme cs = Theme.of(context).colorScheme;
  final int n = destinations.length;
  const double itemH = AppTokens.navRailItemHeight;
  return Material(
    color: cs.surface,
    child: SizedBox(
      width: AppTokens.navRailWidth,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints c) {
          final double w = c.maxWidth;
          final double iconCenterYinCell = _iconCenterOffset(itemH);
          final double pillTop =
              selectedIndex * itemH + iconCenterYinCell - _kPillH / 2;
          final double pillLeft = (w - _kPillW) / 2;
          return _NavStack(
            axis: Axis.vertical,
            cs: cs,
            pillLeft: pillLeft,
            pillTop: pillTop,
            children: List<Widget>.generate(n, (int i) {
              return SizedBox(
                width: w,
                height: itemH,
                child: _AppNavItem(
                  destination: destinations[i],
                  selected: i == selectedIndex,
                  onTap: () => onDestinationSelected(i),
                ),
              );
            }),
          );
        },
      ),
    ),
  );
}
}

/// 导航主体：底层是滑动胶囊，上层是可点击项。
class _NavStack extends StatelessWidget {
  const _NavStack({
    required this.axis,
    required this.cs,
    required this.pillLeft,
    required this.pillTop,
    required this.children,
  });

  final Axis axis;
  final ColorScheme cs;
  final double pillLeft;
  final double pillTop;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final Widget pill = AnimatedPositioned(
      duration: AppTokens.durBase,
      curve: Curves.easeOutCubic,
      left: pillLeft,
      top: pillTop,
      width: _kPillW,
      height: _kPillH,
      child: Container(
        decoration: BoxDecoration(
          color: cs.primary.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(_kPillH / 2),
        ),
      ),
    );

    return Stack(
      children: <Widget>[
        pill,
        axis == Axis.horizontal
            ? Row(children: children)
            : Column(children: children),
      ],
    );
  }
}

/// 单个导航项：图标弹性缩放 + 按压回弹 + 水波纹 + 文字平滑过渡。
class _AppNavItem extends StatefulWidget {
  const _AppNavItem({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final NavigationDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_AppNavItem> createState() => _AppNavItemState();
}

class _AppNavItemState extends State<_AppNavItem> {
  bool _pressed = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Color active = cs.primary; // 选中：主题色（淡，不鲜艳）
    final Color inactive = cs.onSurfaceVariant;
    final Widget icon = widget.selected && widget.destination.selectedIcon != null
        ? widget.destination.selectedIcon!
        : widget.destination.icon;

    // 选中放大、按下回弹、松开复位。
    final double scale = widget.selected ? 1.18 : (_pressed ? 0.9 : 1.0);
    // 预点击：未选中项被悬停/按下时显示带主题色调的浅灰胶囊。
    final bool showGray = !widget.selected && (_pressed || _hovered);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: InkWell(
        onTap: widget.onTap,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(
              width: _kIconBox,
              height: _kIconBox,
              child: Stack(
                alignment: Alignment.center,
                children: <Widget>[
                  // 预点击浅灰胶囊（非中性灰，带主题色调）。
                  AnimatedOpacity(
                    opacity: showGray ? 1.0 : 0.0,
                    duration: AppTokens.durFast,
                    child: Container(
                      width: _kPillW,
                      height: _kPillH,
                      decoration: BoxDecoration(
                        color: cs.onSurfaceVariant.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(_kPillH / 2),
                      ),
                    ),
                  ),
                  AnimatedScale(
                    scale: scale,
                    duration: AppTokens.durFast,
                    curve: Curves.easeOutBack,
                    child: IconTheme.merge(
                      data: IconThemeData(
                        color: widget.selected ? active : inactive,
                        size: 24,
                      ),
                      child: icon,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: _kLabelGap),
            AnimatedDefaultTextStyle(
              duration: AppTokens.durFast,
              style: TextStyle(
                fontSize: 12,
                color: widget.selected ? active : inactive,
                fontWeight:
                    widget.selected ? FontWeight.w600 : FontWeight.w400,
              ),
              child: Text(widget.destination.label),
            ),
          ],
        ),
      ),
    );
  }
}

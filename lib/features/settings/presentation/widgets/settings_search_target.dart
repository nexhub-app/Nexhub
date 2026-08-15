/// 设置搜索的「滚动到具体设置」机制。
///
/// 设计目的：让设置搜索结果不只能跳转到设置页，还能直接滚动到页内具体某项
/// （如搜索「主题色」直接滚到「自定义取色器」那一行，而不是只打开外观页）。
///
/// 用法：
/// 1. 各设置页把每个有意义的可设置项包一个 `ValueKey<String>(id)`，
///    id 在全应用内唯一（推荐命名空间：`appearance.colors`、`playback.danmaku`）。
/// 2. 把页面 body 用 [SettingsAutoScroll] 包裹（替换原 ListView 外层）。
/// 3. 搜索注册表中的 [SettingEntry.scrollKeyId] 设成目标 id；搜索结果
///    跳转前调用 [requestSettingsScroll]，目标页 initState 后自动滚到该 Key。
///
/// 实现要点：
/// - 用全局变量 [pendingSettingsScrollKeyId] 暂存 id（避免给每个屏加构造参数）。
/// - [SettingsAutoScroll] 在首帧后查找子树里匹配的 [ValueKey]，未命中则
///   扫掠整个滚动范围的多个锚点强制构建懒列表的全部子项后重试。扫掠期间列表
///   仅布局、不绘制（[Offstage]），因此用户看不到跳变。
/// - 命中后改用 viewport 直接算偏移把目标顶对齐，并以弹性曲线平滑滑入视口，
///   到站后再给目标项叠加一次柔和的高亮脉冲，引导视线、增强「灵动感」。
/// - 页面 body 用 `ListView` 或 `SingleChildScrollView` 均可，无需改造。
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// 等待被消费的「待滚动 Key id」。搜索设置页跳转前 set；新页面 initState 后 consume。
String? _pendingSettingsScrollKeyId;

/// 标记下次进入设置页时滚动到 [id] 对应的 [ValueKey] 位置。
///
/// 搜索结果点击时调用，再立即 `Navigator.push` 进设置页。
void requestSettingsScroll(String id) {
  _pendingSettingsScrollKeyId = id;
}

/// 由 [SettingsAutoScroll] 在首帧后调用，消费并返回待滚动的 id。
String? consumePendingSettingsScrollKey() {
  final id = _pendingSettingsScrollKeyId;
  _pendingSettingsScrollKeyId = null;
  return id;
}

/// 在子树中查找首个 widget.key == [target] 的 [BuildContext]，找不到返回 null。
BuildContext? findContextWithValueKey(BuildContext root, ValueKey<String> target) {
  BuildContext? result;
  bool found = false;
  void visit(Element e) {
    if (found) return;
    final Key? k = e.widget.key;
    if (k is ValueKey<String> && k.value == target.value) {
      result = e;
      found = true;
      return;
    }
    e.visitChildren(visit);
  }

  visit(root as Element);
  return result;
}

/// 轻微回弹的弹性曲线：滑入视口时在终点前微微过冲再归位，比纯 ease 更有「灵动感」。
class _SoftSpringCurve extends Curve {
  const _SoftSpringCurve();

  @override
  double transform(double t) {
    const double c1 = 1.02;
    const double c3 = c1 + 1;
    final double p = t - 1;
    return 1 + c3 * p * p * p + c1 * p * p;
  }
}

/// 包裹设置页 body：在首帧后若有 pending 滚动请求，自动滚到对应 [ValueKey]。
///
/// 关键难点：设置页多使用 `ListView`，它**懒构建**子项——目标项若在当前视口
/// 之外，首帧时尚未挂载，`findContextWithValueKey` 会找不到，导致滚动静默失败。
/// 本组件在首帧后尝试定位；若未命中（懒构建所致），先扫掠整个滚动范围的多个
/// 锚点强制构建全部子项（扫掠时列表置于 [Offstage] 仅布局不绘制，无可见跳变），
/// 再重新定位，命中即用 viewport 直接算偏移把目标顶对齐、以弹性曲线平滑滑入，
/// 到站后给目标项叠一次高亮脉冲。无需页面做任何改造。
class SettingsAutoScroll extends StatefulWidget {
  final Widget child;

  const SettingsAutoScroll({super.key, required this.child});

  @override
  State<SettingsAutoScroll> createState() => _SettingsAutoScrollState();
}

class _SettingsAutoScrollState extends State<SettingsAutoScroll> {
  ValueKey<String>? _target;
  bool _hidden = false;
  static const Curve _softSpring = _SoftSpringCurve();

  @override
  void initState() {
    super.initState();
    final String? id = consumePendingSettingsScrollKey();
    if (id == null) return;
    _target = ValueKey<String>(id);
    // 首帧后定位；未命中（ListView 懒构建）则扫掠全程强制构建后重试。
    WidgetsBinding.instance.addPostFrameCallback((_) => _tick(0));
  }

  /// 在子树中找到首个**纵向** [Scrollable] 的 state（主列表）。
  /// 跳过横向嵌套滚动视图，避免误把容器内的横向列表当主滚动体。
  ScrollableState? _findScrollable(BuildContext root) {
    ScrollableState? result;
    void visit(Element e) {
      if (result != null) return;
      if (e.widget is Scrollable) {
        final StatefulElement se = e as StatefulElement;
        final State state = se.state;
        if (state is ScrollableState && state.position.axis == Axis.vertical) {
          result = state;
          return;
        }
      }
      e.visitChildren(visit);
    }

    visit(root as Element);
    return result;
  }

  /// 扫掠整个滚动范围的若干锚点，确保任意深度的目标子项都被挂载。
  /// 仅 jump 到末端会漏掉中间的懒构建项，故多锚点覆盖。
  static const List<double> _sweepFractions =
      <double>[1.0, 0.0, 0.5, 0.25, 0.75, 0.125, 0.375, 0.625, 0.875];

  void _hide() {
    if (!_hidden) setState(() => _hidden = true);
  }

  void _reveal() {
    if (_hidden) setState(() => _hidden = false);
  }

  void _tick(int attempt) {
    if (!mounted || _target == null) return;
    final ScrollableState? scrollable = _findScrollable(context);
    if (scrollable == null) {
      // 无滚动体（内容已一次性构建）：直接显示即可。
      _reveal();
      return;
    }

    final BuildContext? ctx = findContextWithValueKey(context, _target!);
    if (ctx != null) {
      _reveal();
      _scrollTo(ctx, scrollable);
      return;
    }

    // 目标未挂载：隐藏状态下扫掠强制构建后重试，避免可见跳变。
    if (attempt >= _sweepFractions.length) {
      _reveal();
      return;
    }
    _hide();
    final ScrollPosition pos = scrollable.position;
    if (pos.hasContentDimensions && pos.maxScrollExtent > 0) {
      final double max = pos.maxScrollExtent;
      pos.jumpTo((max * _sweepFractions[attempt]).clamp(0.0, max));
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _tick(attempt + 1));
  }

  /// 将目标精确滚动到视口顶部（顶对齐，普通 AppBar 不遮挡），弹性曲线滑入，
  /// 到站后给目标项叠一次高亮脉冲引导视线。
  void _scrollTo(BuildContext ctx, ScrollableState scrollable) {
    final RenderObject? obj = ctx.findRenderObject();
    if (obj is! RenderBox) return;
    final ScrollPosition pos = scrollable.position;
    // 顶对齐：把目标项顶部贴到视口顶部。用 viewport 直接算偏移，避免
    // ensureVisible 固定 alignment 对高卡片落点偏移的问题。
    final RenderAbstractViewport viewport = RenderAbstractViewport.of(obj);
    final double offset = viewport.getOffsetToReveal(obj, 0.0).offset;
    final double max = pos.maxScrollExtent;
    final OverlayState? overlay = Overlay.maybeOf(ctx);

    pos
        .animateTo(
          offset.clamp(0.0, max),
          duration: const Duration(milliseconds: 650),
          curve: _softSpring,
        )
        .then((_) {
          if (!mounted || overlay == null) return;
          // 滚动结束后再测量目标卡片的真实全局矩形：此时卡片已落到最终位置，
          // 高亮精确贴合该设置项本身，而不是用滚动前的近似值（会因页面顶部
          // 标题/分组头等错位而把高亮范围放大成「整片」）。
          final BuildContext? landed = findContextWithValueKey(context, _target!);
          final RenderObject? landedObj = landed?.findRenderObject();
          if (landedObj is RenderBox) {
            final Offset topLeft = landedObj.localToGlobal(Offset.zero);
            _showPulse(topLeft & landedObj.size, overlay);
          }
        });
  }

  /// 给目标项叠加一次柔和的高亮脉冲（主题色淡入淡出 + 轻微放大），不拦截点击。
  void _showPulse(Rect rect, OverlayState overlay) {
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _PulseHighlight(
        rect: rect,
        onDone: () => entry.remove(),
      ),
    );
    overlay.insert(entry);
  }

  @override
  Widget build(BuildContext context) => Offstage(
        offstage: _hidden,
        child: widget.child,
      );
}

/// 目标项落到位置后的高亮脉冲：主题色以缓出曲线淡入再淡出，并轻微放大，
/// 形成「到站提示」的灵动反馈。自身不参与命中测试。
class _PulseHighlight extends StatefulWidget {
  final Rect rect;
  final VoidCallback onDone;

  const _PulseHighlight({required this.rect, required this.onDone});

  @override
  State<_PulseHighlight> createState() => _PulseHighlightState();
}

class _PulseHighlightState extends State<_PulseHighlight>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  late final Animation<double> _opacity = TweenSequence<double>(<TweenSequenceItem<double>>[
    TweenSequenceItem<double>(
      tween: Tween<double>(begin: 0.0, end: 0.30),
      weight: 35,
    ),
    TweenSequenceItem<double>(
      tween: Tween<double>(begin: 0.30, end: 0.0),
      weight: 65,
    ),
  ]).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
  late final Animation<double> _scale = Tween<double>(begin: 1.0, end: 1.03)
      .animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));

  @override
  void initState() {
    super.initState();
    _controller.forward().then((_) => widget.onDone());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color primary = Theme.of(context).colorScheme.primary;
    // Positioned 必须直接是 Stack（Overlay）的子节点，故放在最外层；
    // IgnorePointer 包在内部仅用于不拦截点击。
    return Positioned(
      left: widget.rect.left,
      top: widget.rect.top,
      width: widget.rect.width,
      height: widget.rect.height,
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (_, __) => Transform.scale(
            scale: _scale.value,
            child: Container(
              decoration: BoxDecoration(
                color: primary.withValues(alpha: _opacity.value),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: primary.withValues(alpha: (_opacity.value * 2.2).clamp(0.0, 1.0)),
                  width: 2,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import '../theme/app_tokens.dart';

/// 应用统一「灵动」动效原语。
///
/// 设计语言（与底部导航栏保持一致）：
/// - 弹簧回弹用 [AppCurves.spring]（比 [Curves.easeOutBack] 过冲更明显、更活泼），
///   平滑滑动用 [AppCurves.smooth]（末段更缓、更顺滑）。
/// - 时长走 [AppTokens.durFast] (150ms) / [AppTokens.durBase] (250ms) /
///   [AppTokens.durSpring] (420ms，给弹簧回落留时间)。
/// - 入场：淡入 + 上滑 + 轻微放大弹入，支持按 key「只播一次」避免滚动重播。
///
/// 用法：
/// - 按钮 / 图标按压回弹：[AppTapScale]
/// - 列表 / 卡片入场：[Entrance]
/// - 弹窗 / 抽屉内容弹出：[AppSheetBody]

/// 统一「灵动」缓动曲线库。
///
/// 比 Flutter 内置曲线过冲更明显、末段更顺，是全应用弹簧手感的唯一来源。
class AppCurves {
  AppCurves._();

  /// 弹簧回弹（过冲约 +18%，比 easeOutBack 的 +10% 更活泼）。
  /// 用于缩放弹入、按压松手复位、入场卡片放大。
  static const Cubic spring = Cubic(0.34, 1.7, 0.46, 1.0);

  /// 更强弹簧（过冲更大），用于需要「弹一下」强调的场合（如 FAB、弹窗）。
  static const Cubic springStrong = Cubic(0.22, 1.85, 0.36, 1.0);

  /// 平滑减速（easeOutQuint 手感），末段极缓，用于淡入 / 位移，顺滑不生硬。
  static const Cubic smooth = Cubic(0.16, 1.0, 0.3, 1.0);
}

// ────────────────────── 按压回弹（按钮 / 图标） ──────────────────────

/// 按压回弹：包裹任意可点击控件（[IconButton]、[ElevatedButton]、[InkWell] 等），
/// 按下时轻微缩小、松开弹性复位。
///
/// 仅做视觉缩放，不拦截子控件的点击与涟漪（用 [Listener] 探测指针，不抢占手势）。
class AppTapScale extends StatefulWidget {
  const AppTapScale({
    super.key,
    required this.child,
    this.scale = 0.90,
    this.duration,
    this.enable = true,
  });

  final Widget child;
  final double scale; // 按下时的缩放比例（<1 缩小）
  final Duration? duration;
  final bool enable; // false 时直接透传子控件，不做任何动效

  @override
  State<AppTapScale> createState() => _AppTapScaleState();
}

class _AppTapScaleState extends State<AppTapScale> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    if (!widget.enable) return widget.child;
    return Listener(
      onPointerDown: (_) => setState(() => _pressed = true),
      onPointerUp: (_) => setState(() => _pressed = false),
      onPointerCancel: (_) => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? widget.scale : 1.0,
        // 松手复位走弹簧曲线，轻微过冲到 1.0 之上再回落，形成「弹一下」的手感。
        duration: widget.duration ?? AppTokens.durBase,
        curve: _pressed ? Curves.easeOutCubic : AppCurves.spring,
        child: widget.child,
      ),
    );
  }
}

// ────────────────────── 入场（列表 / 卡片） ──────────────────────

/// 全局已播放过入场动画的 key 集合（按 key 去重，避免滚动时重复播放）。
// ignore: prefer_const_declarations — 集合需可变（add/clear），不能用 const。
final Set<String> _entrancePlayed = <String>{};

/// 入场动画：淡入 + 轻微上滑（+ 可选回弹缩放）。
///
/// [onceKey] 非空时，相同 key 在应用生命周期内只播放一次；
/// 之后该卡片 / 项再次进入视口（如列表滚动回来）将直接以终态显示，不再重播，
/// 避免滚动抖动。key 为空则每次挂载都播放（适合数量少、不滚动复用的场景）。
class Entrance extends StatefulWidget {
  const Entrance({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.duration,
    this.offset = 16, // 上滑像素
    this.fromScale = 0.96, // 起始缩放（<1 表示从更小放大弹入，默认带轻微放大）
    this.onceKey,
  });

  final Widget child;
  final Duration delay;
  final Duration? duration;
  final double offset;
  final double fromScale;
  final String? onceKey;

  @override
  State<Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<Entrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _opacity;
  late final Animation<Offset> _slide;
  late final Animation<double> _scale;
  late final bool _play;

  @override
  void initState() {
    super.initState();

    if (widget.onceKey != null) {
      if (_entrancePlayed.contains(widget.onceKey)) {
        _play = false;
      } else {
        if (_entrancePlayed.length > 500) _entrancePlayed.clear();
        _entrancePlayed.add(widget.onceKey!);
        _play = true;
      }
    } else {
      _play = true;
    }

    _ctrl = AnimationController(
      vsync: this,
      duration: widget.duration ?? AppTokens.durSpring,
    );
    // 淡入 + 上滑走平滑减速（末段极缓、顺滑）；缩放走弹簧（放大略过冲再回落）。
    _opacity = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.0, 0.6, curve: AppCurves.smooth),
    );
    _slide = Tween<Offset>(
      begin: Offset(0, widget.offset / 100),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _ctrl, curve: AppCurves.smooth));
    _scale = Tween<double>(begin: widget.fromScale, end: 1.0)
        .animate(CurvedAnimation(parent: _ctrl, curve: AppCurves.spring));

    if (_play) {
      Future.delayed(widget.delay, () {
        if (mounted) _ctrl.forward();
      });
    } else {
      _ctrl.value = 1.0; // 已播放过：直接终态，不播动画
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_play) return widget.child;
    return FadeTransition(
      opacity: _opacity,
      child: SlideTransition(
        position: _slide,
        child: ScaleTransition(scale: _scale, child: widget.child),
      ),
    );
  }
}

// ────────────────────── 悬停微抬（桌面端） ──────────────────────

/// 桌面端悬停微抬：鼠标悬停在卡片 / 按钮上时轻轻放大并上浮，移开平滑复位。
///
/// 仅在检测到鼠标指针时生效（触摸屏无 hover 事件，天然不触发），
/// 用 [MouseRegion] 探测、不拦截子控件手势与涟漪。
class AppHoverLift extends StatefulWidget {
  const AppHoverLift({
    super.key,
    required this.child,
    this.scale = 1.02,
    this.lift = 3,
    this.enable = true,
  });

  final Widget child;
  final double scale; // 悬停时的放大比例（>1）
  final double lift; // 悬停时的上浮像素
  final bool enable;

  @override
  State<AppHoverLift> createState() => _AppHoverLiftState();
}

class _AppHoverLiftState extends State<AppHoverLift> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    if (!widget.enable) return widget.child;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: AppTokens.durFast,
        curve: Curves.easeOutCubic,
        transform: Matrix4.identity()
          ..translate(0.0, _hovered ? -widget.lift : 0.0),
        child: AnimatedScale(
          scale: _hovered ? widget.scale : 1.0,
          duration: AppTokens.durFast,
          curve: Curves.easeOutCubic,
          child: widget.child,
        ),
      ),
    );
  }
}

// ────────────────────── 值变化弹性脉冲（开关 / 分段 / Chip） ──────────────────────

/// 值变化弹性脉冲：当 [trigger] 变化时，让子控件从 0.94 弹性放大回 1.0，
/// 形成「咚」一下的确认反馈。适合开关、分段选择、选择芯片等取值型控件。
///
/// 首次挂载也会播一次轻微脉冲（与卡片入场动画自然融合）；之后仅在值变化时播放。
class AppValuePulse extends StatelessWidget {
  const AppValuePulse({
    super.key,
    required this.trigger,
    required this.child,
    this.from = 0.94,
  });

  /// 触发脉冲的值：值变化 → 播放一次脉冲（用 [ValueKey] 驱动重建实现）。
  final Object? trigger;
  final Widget child;

  /// 脉冲起始缩放（越小力度越大）。整行大控件建议 0.98，小徽标可 0.8。
  final double from;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      // key 变化时 TweenAnimationBuilder 重建并从 begin 重新播放。
      key: ValueKey<Object?>(trigger),
      tween: Tween<double>(begin: from, end: 1.0),
      duration: AppTokens.durSpring,
      curve: AppCurves.spring,
      child: child,
      builder: (context, scale, child) =>
          Transform.scale(scale: scale, child: child),
    );
  }
}

// ────────────────────── 顶栏标题滚动渐隐 ──────────────────────

/// 顶栏标题滚动渐隐收缩：包裹 [Scaffold]，body 内任何垂直滚动 0→64px
/// 时，AppBar 标题淡至 60% 并轻微缩小，回到顶部还原——页面更有层次感。
///
/// 用法：把原来的 `Scaffold(appBar: AppBar(title: ...), body: ...)` 换成
/// `AppShrinkTitleScaffold(title: ..., body: ..., actions: ...)`。
/// 仅重建标题本身（ValueNotifier 驱动），滚动零额外整页重建。
class AppShrinkTitleScaffold extends StatefulWidget {
  const AppShrinkTitleScaffold({
    super.key,
    required this.title,
    required this.body,
    this.actions,
    this.leading,
    this.centerTitle,
    this.floatingActionButton,
  });

  final Widget title;
  final Widget body;
  final List<Widget>? actions;
  final Widget? leading;
  final bool? centerTitle;
  final Widget? floatingActionButton;

  @override
  State<AppShrinkTitleScaffold> createState() => _AppShrinkTitleScaffoldState();
}

class _AppShrinkTitleScaffoldState extends State<AppShrinkTitleScaffold> {
  final ValueNotifier<double> _shrink = ValueNotifier<double>(0);

  @override
  void dispose() {
    _shrink.dispose();
    super.dispose();
  }

  bool _onScroll(ScrollNotification n) {
    if (n.depth == 0 && n.metrics.axis == Axis.vertical) {
      _shrink.value = (n.metrics.pixels / 64).clamp(0.0, 1.0);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: widget.leading,
        centerTitle: widget.centerTitle,
        actions: widget.actions,
        title: ValueListenableBuilder<double>(
          valueListenable: _shrink,
          builder: (context, t, child) => Opacity(
            opacity: 1.0 - 0.4 * t,
            child: Transform.scale(scale: 1.0 - 0.08 * t, child: child),
          ),
          child: widget.title,
        ),
      ),
      floatingActionButton: widget.floatingActionButton,
      body: NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: widget.body,
      ),
    );
  }
}

// ────────────────────── 弹窗 / 抽屉内容入场 ──────────────────────

/// 弹窗 / 抽屉内容入场：配合 [showModalBottomSheet] 自带的上滑，额外叠加
/// 轻微回弹放大 + 淡入，形成「灵动」弹出感。包在 sheet 的 content 根部即可。
///
/// 弹窗每次打开都是全新挂载，故每次都会播放（无需 onceKey）。
class AppSheetBody extends StatelessWidget {
  const AppSheetBody({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Entrance(
      offset: 10,
      fromScale: 0.95,
      duration: AppTokens.durSpring,
      child: child,
    );
  }
}

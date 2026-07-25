import 'package:flutter/material.dart';
import '../theme/app_tokens.dart';

/// 应用统一「灵动」动效原语。
///
/// 设计语言（与底部导航栏保持一致）：
/// - 弹簧缓动用 [Curves.easeOutBack]，平滑滑动用 [Curves.easeOutCubic]。
/// - 时长走 [AppTokens.durFast] (150ms) / [AppTokens.durBase] (250ms)。
/// - 入场：淡入 + 轻微上滑（+ 可选回弹缩放），支持按 key「只播一次」避免滚动重播。
///
/// 用法：
/// - 按钮 / 图标按压回弹：[AppTapScale]
/// - 列表 / 卡片入场：[Entrance]
/// - 弹窗 / 抽屉内容弹出：[AppSheetBody]

// ────────────────────── 按压回弹（按钮 / 图标） ──────────────────────

/// 按压回弹：包裹任意可点击控件（[IconButton]、[ElevatedButton]、[InkWell] 等），
/// 按下时轻微缩小、松开弹性复位。
///
/// 仅做视觉缩放，不拦截子控件的点击与涟漪（用 [Listener] 探测指针，不抢占手势）。
class AppTapScale extends StatefulWidget {
  const AppTapScale({
    super.key,
    required this.child,
    this.scale = 0.92,
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
        duration: widget.duration ?? AppTokens.durFast,
        curve: Curves.easeOutBack,
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
    this.offset = 12, // 上滑像素
    this.fromScale = 1.0, // 起始缩放（<1 表示从更小放大入场）
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
      duration: widget.duration ?? AppTokens.durBase,
    );
    final Curve curve = Curves.easeOutCubic;
    _opacity = CurvedAnimation(parent: _ctrl, curve: curve);
    _slide = Tween<Offset>(
      begin: Offset(0, widget.offset / 100),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _ctrl, curve: curve));
    _scale = Tween<double>(begin: widget.fromScale, end: 1.0)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutBack));

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
      offset: 8,
      fromScale: 0.97,
      duration: AppTokens.durBase,
      child: child,
    );
  }
}

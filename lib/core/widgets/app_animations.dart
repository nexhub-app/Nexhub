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

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/comic/models/reader_preferences.dart';

/// 点击区域动作。
enum _TapAction { prev, next, toggle }

/// 单个点击热区（坐标为相对于阅读区的比例 0..1）。
class _Region {
  final double left;
  final double top;
  final double width;
  final double height;
  final _TapAction action;
  const _Region(this.left, this.top, this.width, this.height, this.action);
}

/// 阅读器点击区域覆盖层（文档 7.3）。
///
/// 用一个铺满阅读区的 [Listener] 监听指针 down / up，按抬起坐标命中对应热区
/// 分发到 prev / next / toggle。之所以不用 [GestureDetector]：在 widget 测试中
/// 验证发现，[GestureDetector] 的识别器由 `RawGestureDetector` 内部的
/// `Listener`（deferToChild）在命中测试时喂入指针，而该内部 Listener 在以
/// `SizedBox.expand()` 之类「自身不可命中」的 child 作下层时不会进入命中路径，
/// 导致识别器拿不到指针、单击永远不触发（即便覆盖层几何与 behavior 都正确）。
/// 直接用 [Listener] 的 `onPointerDown` / `onPointerUp` 则稳定可靠。
///
/// 双击（仅切换热区）触发 `onZoom` 缩放，与单击导航互不冲突。支持 5 种布局。
///
/// 在布局之上叠加 [TapZoneInvert] 方向反转：leftRight 反转横向翻页（竖向
/// webtoon 模式下不生效），upDown 反转竖向滚动，all 两者都反转。
class ReaderTapZones extends StatefulWidget {
  final ReaderTapZoneLayout layout;
  final TapZoneInvert tapZoneInvert;
  final bool isVertical; // webtoon / 竖向：prev=上滚，next=下滚
  final bool isWebtoon; // 条漫：拖拽交给原生 ListView 滚动，不在此翻页
  final bool isRTL; // 翻页 RTL：拖拽方向反转
  /// 拖拽（滑动）翻页回调：拖拽超过阈值时调用，[next]=true 下一页 / false 上一页。
  /// 仅翻页模式生效；条漫不触发（交给原生连续滚动）。
  final void Function(bool next)? onDragPage;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onToggleUi;
  final VoidCallback? onZoom;

  /// 在指定位置缩放（桌面 Shift+左键 兜底双击缩放）。为 null 时由调用方回退到 [onZoom]。
  final void Function(Offset)? onZoomAt;

  /// 长按回调（用于弹出图片「保存 / 分享」菜单等）。为 null 时不检测长按。
  final VoidCallback? onLongPress;

  /// 单击拦截：每次命中热区的单击（含双击 / Shift+点击前的首次抬起）都会先调用，
  /// 返回 true 则吞掉本次单击（不执行 prev/next/toggle、不触发缩放）。
  /// 用于内联设置面板打开时「点阅读区任意处关闭面板」，与小说阅读器行为一致。
  /// 为 null 时不拦截。
  final bool Function()? onTapIntercept;

  /// 是否渲染点击区域预览（彩色块 + 标签）。用于设置页预览，开启时不响应手势。
  final bool showPreview;

  /// 预览标签（key 为 'prev' / 'next' / 'toggle'）。
  final Map<String, String>? previewLabels;

  const ReaderTapZones({
    super.key,
    required this.layout,
    this.tapZoneInvert = TapZoneInvert.none,
    required this.isVertical,
    this.isWebtoon = false,
    this.isRTL = false,
    this.onDragPage,
    required this.onPrev,
    required this.onNext,
    required this.onToggleUi,
    this.onZoom,
    this.onZoomAt,
    this.onLongPress,
    this.onTapIntercept,
    this.showPreview = false,
    this.previewLabels,
  });

  @override
  State<ReaderTapZones> createState() => _ReaderTapZonesState();
}

class _ReaderTapZonesState extends State<ReaderTapZones> {
  int? _activePointer;
  Offset? _downPos;
  DateTime? _downTime;
  bool _downShift = false;

  // 双击检测：记录上一次「已分发的单击」时间与位置。
  DateTime? _lastTapTime;
  Offset? _lastTapPos;

  // 长按检测：按下后启动定时器，到阈值仍未抬起且未明显移动则触发。
  Timer? _longPressTimer;
  bool _longPressFired = false;

  static const double _tapSlop = 18.0; // 移动超过此值不算 tap
  static const Duration _tapTimeout = Duration(milliseconds: 400);
  static const Duration _doubleTapTimeout = Duration(milliseconds: 300);
  static const double _doubleTapSlop = 36.0;
  static const Duration _longPressThreshold = Duration(milliseconds: 500);

  @override
  void dispose() {
    _longPressTimer?.cancel();
    super.dispose();
  }

  /// 启动长按定时器（仅在 [widget.onLongPress] 非空时）。
  void _startLongPressTimer(int pointer) {
    if (widget.onLongPress == null) return;
    _longPressTimer?.cancel();
    _longPressFired = false;
    _longPressTimer = Timer(_longPressThreshold, () {
      if (_activePointer == pointer) {
        _longPressFired = true;
        widget.onLongPress!();
      }
    });
  }

  /// 指针移动超过 slop 则取消长按（避免拖拽误触发）。
  void _maybeCancelLongPress(Offset pos) {
    final Offset? down = _downPos;
    if (down == null) return;
    if ((pos - down).distance > _tapSlop) {
      _longPressTimer?.cancel();
    }
  }

  List<_Region> _buildRegions() {
    switch (widget.layout) {
      case ReaderTapZoneLayout.leftRight:
        return const <_Region>[
          _Region(0, 0, 0.45, 1, _TapAction.prev),
          _Region(0.45, 0, 0.1, 1, _TapAction.toggle),
          _Region(0.55, 0, 0.45, 1, _TapAction.next),
        ];
      case ReaderTapZoneLayout.lShape:
        // 两个 L 形 + 中心 toggle（与小说 tap_zone_resolver.dart 保持一致）：
        // prev = 左列 + 下中条；next = 右列 + 上中条；toggle = 中心方块。
        return const <_Region>[
          _Region(0, 0, 0.33, 1, _TapAction.prev), // 左列（全高）
          _Region(0.67, 0, 0.33, 1, _TapAction.next), // 右列（全高）
          _Region(0.33, 0, 0.34, 0.33, _TapAction.next), // 上中条
          _Region(0.33, 0.67, 0.34, 0.33, _TapAction.prev), // 下中条
          _Region(0.33, 0.33, 0.34, 0.34, _TapAction.toggle), // 中心
        ];
      case ReaderTapZoneLayout.kindle:
        return const <_Region>[
          _Region(0, 0, 1, 0.15, _TapAction.toggle),
          _Region(0, 0.15, 0.35, 0.85, _TapAction.prev),
          _Region(0.35, 0.15, 0.65, 0.85, _TapAction.next),
        ];
      case ReaderTapZoneLayout.bothSides:
        return const <_Region>[
          _Region(0, 0.15, 0.33, 0.7, _TapAction.next),
          _Region(0.67, 0.15, 0.33, 0.7, _TapAction.next),
          _Region(0.33, 0.7, 0.34, 0.3, _TapAction.prev),
          _Region(0.33, 0, 0.34, 0.15, _TapAction.toggle),
        ];
      case ReaderTapZoneLayout.off:
        return const <_Region>[_Region(0, 0, 1, 1, _TapAction.toggle)];
    }
  }

  Rect _rect(_Region r, double w, double h) =>
      Rect.fromLTWH(r.left * w, r.top * h, r.width * w, r.height * h);

  _TapAction? _actionAt(Offset p, double w, double h) {
    for (final r in _buildRegions()) {
      if (_rect(r, w, h).contains(p)) return r.action;
    }
    return null;
  }

  void _onPointerDown(PointerDownEvent e) {
    _activePointer = e.pointer;
    _downPos = e.localPosition;
    _downTime = DateTime.now();
    _downShift = HardwareKeyboard.instance.isShiftPressed;
    _startLongPressTimer(e.pointer);
  }

  void _onPointerMove(PointerMoveEvent e) {
    _maybeCancelLongPress(e.localPosition);
  }

  void _onPointerUp(PointerUpEvent e) {
    _longPressTimer?.cancel();
    if (_activePointer != e.pointer || _downPos == null || _downTime == null) {
      return;
    }
    final Offset downPos = _downPos!;
    final move = (e.localPosition - downPos).distance;
    final dt = DateTime.now().difference(_downTime!);
    final fired = _longPressFired;
    _activePointer = null;
    _downPos = null;
    _downTime = null;
    _longPressFired = false;
    final bool shifted = _downShift;
    _downShift = false;
    if (fired) return;
    // 拖拽（滑动）翻页优先判定：移动超过 tap slop 即视为拖拽，不触发单击导航 / 缩放。
    // 条漫交给原生 ListView 连续滚动，不在此翻页。
    if (move > _tapSlop) {
      if (!widget.isWebtoon) {
        final double dx = e.localPosition.dx - downPos.dx;
        final double dy = e.localPosition.dy - downPos.dy;
        final bool vertical = widget.isVertical;
        bool next;
        if (vertical) {
          next = dy < 0; // 上滑 = 下一页
          if (widget.tapZoneInvert == TapZoneInvert.upDown ||
              widget.tapZoneInvert == TapZoneInvert.all) {
            next = !next;
          }
        } else {
          // 标准习惯（主流漫画 App）：左到右模式向左滑→下一页；右到左模式向右滑→下一页。
          next = dx < 0;
          if (widget.isRTL) next = !next; // RTL 反转（向右滑=下一页）
          if (widget.tapZoneInvert == TapZoneInvert.leftRight ||
              widget.tapZoneInvert == TapZoneInvert.all) {
            next = !next; // 用户手动反转热区时同步反转拖拽方向
          }
        }
        widget.onDragPage?.call(next);
      }
      return;
    }
    if (dt > _tapTimeout) return;

    // 内联设置面板打开时，任意单击都用来关闭面板（吞掉导航 / 缩放）。
    if (widget.onTapIntercept?.call() ?? false) return;

    // 桌面 Shift+左键：在点击处缩放（兜底双击缩放），不触发导航 / 双击。
    // 此分支优先于区域命中，任意位置按下 Shift 均可定点缩放。
    if (shifted) {
      final at = widget.onZoomAt;
      if (at != null) {
        at(e.localPosition);
      } else {
        widget.onZoom?.call();
      }
      return;
    }

    final size = MediaQuery.sizeOf(context);
    final action = _actionAt(e.localPosition, size.width, size.height);
    if (action == null) return;

    final now = DateTime.now();
    final isDouble = _lastTapTime != null &&
        now.difference(_lastTapTime!) <= _doubleTapTimeout &&
        _lastTapPos != null &&
        (_lastTapPos! - e.localPosition).distance <= _doubleTapSlop;
    if (isDouble) {
      // 双击：任意位置都触发缩放（双击放大 / 再双击还原），不再限定于中心
      // 「切换」热区——否则条漫 / 触屏用户很难点到中心，会感觉「放缩没作用」。
      // 仍不抑制本次单击的导航/切换：双击时先按首次单击的区域导航一次，再缩放，
      // 与原有行为一致（widget 测试里两次单击间隔仅约 80ms，抑制会丢一次切换）。
      _lastTapTime = null;
      _lastTapPos = null;
      widget.onZoom?.call();
    } else {
      _lastTapTime = now;
      _lastTapPos = e.localPosition;
    }
    _dispatch(action);
  }

  void _dispatch(_TapAction a) {
    switch (_effectiveAction(a)) {
      case _TapAction.prev:
        widget.onPrev();
      case _TapAction.next:
        widget.onNext();
      case _TapAction.toggle:
        widget.onToggleUi();
    }
  }

  /// 按 [widget.tapZoneInvert] 与 [widget.isVertical] 决定实际触发的动作。
  ///
  /// - 横向模式 + leftRight/all → 反转 prev/next
  /// - 竖向模式 + upDown/all → 反转 prev/next（上下滚动方向反转）
  /// - none → 不反转
  ///
  /// 预览也复用此方法，让彩色块与标签实时反映反转后的真实热区。
  _TapAction _effectiveAction(_TapAction action) {
    if (action == _TapAction.toggle) return action;
    final invert = widget.tapZoneInvert;
    bool shouldInvert = false;
    switch (invert) {
      case TapZoneInvert.none:
        shouldInvert = false;
      case TapZoneInvert.leftRight:
        shouldInvert = !widget.isVertical;
      case TapZoneInvert.upDown:
        shouldInvert = widget.isVertical;
      case TapZoneInvert.all:
        shouldInvert = true;
    }
    if (!shouldInvert) return action;
    return action == _TapAction.prev ? _TapAction.next : _TapAction.prev;
  }

  /// 点击区域预览：彩色块 + 标签，不响应手势。用于设置页。
  Widget _buildPreview() {
    final regions = _buildRegions();
    return LayoutBuilder(
      builder: (ctx, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        return Stack(
          children: <Widget>[
            for (final r in regions)
              Positioned(
                left: r.left * w,
                top: r.top * h,
                width: r.width * w,
                height: r.height * h,
                child: Container(
                  color: _previewColor(_effectiveAction(r.action))
                      .withValues(alpha: 0.22),
                  child: Center(
                    child: Text(
                      _previewLabel(_effectiveAction(r.action)),
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Color _previewColor(_TapAction a) => switch (a) {
        _TapAction.prev => Colors.blue,
        _TapAction.next => Colors.green,
        _TapAction.toggle => Colors.orange,
      };

  String _previewLabel(_TapAction a) {
    final key = switch (a) {
      _TapAction.prev => 'prev',
      _TapAction.next => 'next',
      _TapAction.toggle => 'toggle',
    };
    return widget.previewLabels?[key] ?? key;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.showPreview) return _buildPreview();
    // 覆盖层铺满父级 Stack；用 translucent（而非 opaque）让它在处理单击 / 双击
    // 热区的同时，把【拖拽 / 滚动】事件透传给底层 PageView / ListView：
    // - opaque 会独占命中，导致翻页滑动、条漫滚动等手势全部失效；
    // - translucent 仍能接收指针（单击照常分发 prev/next/toggle、双击缩放），
    //   同时底层可滚动内容照常响应拖拽。
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      child: const SizedBox.expand(),
    );
  }
}

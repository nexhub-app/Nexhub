import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

import '../../../core/novel/novel_page_animation.dart';
import '../../../core/theme/app_tokens.dart';

/// 小说翻页视图（Task 19）。
///
/// 在单一组件中支持 6 种翻页效果（对应 [NovelPageAnimation]）：
/// - [NovelPageAnimation.fade]       — 交叉淡入（默认动画）。
/// - [NovelPageAnimation.cover]      — 新页从侧边滑入覆盖旧页。
/// - [NovelPageAnimation.slide]      — 新旧页同时相向平移。
/// - [NovelPageAnimation.simulation] — 简化仿真卷页，跟手拖拽。
/// - [NovelPageAnimation.scroll]     — 垂直连续滚动（委托给 [scrollBuilder]）。
/// - [NovelPageAnimation.none]       — 无动画即时切换。
///
/// 动画时长统一为 [AppTokens.durPageTurn]（450ms）。simulation 模式下进度跟随手指，
/// 松手后按阈值完成或回弹。State 通过 [nextPage] / [previousPage] / [jumpToPage]
/// 暴露编程式翻页，供点击区域与设置面板调用。
class NovelAnimatedPageView extends StatefulWidget {
  /// 翻页动画类型。
  final NovelPageAnimation animation;

  /// 分页总数（paged 模式使用）。
  final int pageCount;

  /// 按索引构建单页内容（paged 模式使用）。
  final IndexedWidgetBuilder pageBuilder;

  /// 初始页索引。
  final int initialPage;

  /// 页码变化回调（仅在实际翻页成功时触发）。
  final ValueChanged<int>? onPageChanged;

  /// 在最后一页继续向后翻时请求下一章。
  final VoidCallback? onRequestNextChapter;

  /// 在第一页继续向前翻时请求上一章。
  final VoidCallback? onRequestPrevChapter;

  /// 背景色（防止动画过程中出现透明）。不传时回退到主题 surface。
  final Color? background;

  /// scroll 模式下构建完整滚动视图。
  final WidgetBuilder? scrollBuilder;

  /// 内容版本号：章节 / 动画等导致分页内容变化时自增。
  /// 用于在不改变 [GlobalKey]（保持外部可经 [nextPage] 等编程式翻页）的前提下，
  /// 触发内部页码重置回到 [initialPage]。
  final int contentVersion;

  /// 单击抬起回调（用于点击区域翻页 / 切换 UI）。
  /// 单击抬起的回调。第二个参数为手势识别器自身尺寸，供调用方在
  /// 与 [TapUpDetails.localPosition] 同一坐标系下解析点击热区，避免「用屏幕
  /// 尺寸去量页面局部坐标」导致的热区错位（翻页手势有时失灵的根因）。
  final void Function(TapUpDetails, Size)? onTapUp;

  /// 竖向拖拽起始回调（用于左侧 1/3 亮度手势）。
  final void Function(DragStartDetails)? onVerticalDragStart;

  /// 竖向拖拽更新回调（用于左侧 1/3 亮度手势）。
  final void Function(DragUpdateDetails)? onVerticalDragUpdate;

  /// 竖向拖拽结束回调（用于左侧 1/3 亮度手势）。
  final void Function(DragEndDetails)? onVerticalDragEnd;

  /// N4 下滑切书签手势：主区域纵向下滑手势回调组。
  /// 三者非空时启用（与左侧 1/3 亮度手势区域互斥，见 _wrapGestures）。
  final void Function(DragStartDetails)? onBookmarkSwipeStart;
  final void Function(DragUpdateDetails)? onBookmarkSwipeUpdate;
  final void Function(DragEndDetails)? onBookmarkSwipeEnd;

  /// 鼠标滚轮翻页方向反转（仅翻页模式生效）。向下滚默认 = 下一页；
  /// 为 true 时翻转（向上滚 = 下一页）。滚动模式由底层 Scrollable 接管滚轮，
  /// 此参数不参与。
  final bool scrollWheelInverted;

  /// 选区激活时返回 true（长按拖拽选区中或已有活动选区）。
  /// 为真时屏蔽横向翻页拖拽，避免选区拖动手势被翻页抢走。
  final bool Function()? selectionActive;

  const NovelAnimatedPageView({
    super.key,
    required this.animation,
    required this.pageCount,
    required this.pageBuilder,
    this.initialPage = 0,
    this.onPageChanged,
    this.onRequestNextChapter,
    this.onRequestPrevChapter,
    this.background,
    this.scrollBuilder,
    this.contentVersion = 0,
    this.onTapUp,
    this.onVerticalDragStart,
    this.onVerticalDragUpdate,
    this.onVerticalDragEnd,
    this.onBookmarkSwipeStart,
    this.onBookmarkSwipeUpdate,
    this.onBookmarkSwipeEnd,
    this.scrollWheelInverted = false,
    this.selectionActive,
  });

  @override
  State<NovelAnimatedPageView> createState() => NovelAnimatedPageViewState();
}

class NovelAnimatedPageViewState extends State<NovelAnimatedPageView>
    with SingleTickerProviderStateMixin {
  late int _index;
  int? _fromIndex;
  late AnimationController _controller;
  bool _forward = true;
  bool _animating = false;
  /// 标记一次「真实的拖拽回弹反向」，用于区分 status listener 的 dismissed
  /// 回调到底是拖拽回弹（应恢复来源页）还是单纯把 `value` 复位为 0 时（例如
  /// [_animateTo] 开头）被 Flutter 同步触发的 incidental dismissed（应忽略）。
  bool _reversing = false;

  bool _dragging = false;
  bool? _dragForward;
  double _dragDelta = 0;
  double _dragProgress = 0;

  // ── 平滑自动翻页（O5）──
  /// none/scroll 模式的累计过渡比例（满 1 落页）。
  double _autoAccum = 0;
  /// 自定义动画模式是否正处于一次手动驱动的翻页过渡中。
  bool _autoTurning = false;

  // ── 翻页过渡页缓存 ──
  /// 过渡期间 from/to 两页的构建结果按「(fromIdx,toIdx,contentVersion)」
  /// 缓存复用。此前每帧都调用 [widget.pageBuilder] 全量重建两页
  /// （几十个行 widget + 文本排版），是翻页掉帧的主因；一次过渡内页面
  /// 内容不变，缓存后动画期间只重排 Transform/Opacity/裁剪层。
  String? _turnCacheKey;
  Widget? _turnFromPage;
  Widget? _turnToPage;

  void _invalidateTurnCache() {
    _turnCacheKey = null;
    _turnFromPage = null;
    _turnToPage = null;
  }

  @override
  void initState() {
    super.initState();
    final max = (widget.pageCount - 1).clamp(0, 1 << 30);
    _index = widget.initialPage.clamp(0, max);
    _controller = AnimationController(
      vsync: this,
      duration: AppTokens.durPageTurn,
    )
      // 注意：动画期间不能在这里 setState 重建整棵 widget 树（手势树 +
      // LayoutBuilder + 翻页层每帧全重建，是真机动画掉帧主因）。进度渲染改由
      // build 中 turning 分支的 AnimatedBuilder 局部驱动（见 build），
      // 这里只挂状态监听，不 setState。
      ..addStatusListener((AnimationStatus s) {
        if (s == AnimationStatus.completed) {
          _animating = false;
          _fromIndex = null;
          _invalidateTurnCache();
          if (mounted) setState(() {});
        } else if (s == AnimationStatus.dismissed) {
          // 只有在真实拖拽回弹（_reversing==true）时才恢复来源页。
          // [_animateTo] 开头把 `value` 复位为 0 会同步触发一次 incidental
          // dismissed，此时必须忽略——否则会把刚前进到的目标页又退回来源页、
          // 并清掉 _animating，导致「翻一次就卡死 / 按钮点第二次无反应」。
          if (!_reversing) return;
          _reversing = false;
          _invalidateTurnCache();
          // 回弹：恢复到来源页。
          if (_fromIndex != null) {
            _index = _fromIndex!;
            _fromIndex = null;
          }
          _animating = false;
          if (mounted) setState(() {});
        }
      });
  }

  @override
  void didUpdateWidget(NovelAnimatedPageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 内容版本变化（切章 / 改动画 / 重载）：复用同一 State（key 稳定，
    // 以便外部持有 GlobalKey 调用 nextPage 等），但需把页码重置回 initialPage。
    if (oldWidget.contentVersion != widget.contentVersion) {
      final max = (widget.pageCount - 1).clamp(0, 1 << 30);
      _index = widget.initialPage.clamp(0, max);
      _fromIndex = null;
      _animating = false;
      _reversing = false;
      _dragging = false;
      _dragForward = null;
      _dragDelta = 0;
      _dragProgress = 0;
      _autoAccum = 0;
      _autoTurning = false;
      _invalidateTurnCache();
      _controller.stop();
      _controller.value = 0;
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _isScroll => widget.animation == NovelPageAnimation.scroll;
  bool get _isNone => widget.animation == NovelPageAnimation.none;
  bool get _isCustom =>
      widget.animation == NovelPageAnimation.fade ||
      widget.animation == NovelPageAnimation.cover ||
      widget.animation == NovelPageAnimation.slide ||
      widget.animation == NovelPageAnimation.simulation;

  // ─────────────────────── 公共 API ───────────────────────

  /// 当前页索引。
  int get currentPage => _index;

  /// 翻到下一页（越界时请求下一章）。
  void nextPage() {
    if (_dragging) return;
    // 防御：若 _animating 卡住（controller 已停止/完成/回弹/未在活跃动画），
    // 强制复位，避免按钮「永久失灵」。
    if (_animating &&
        (_controller.isCompleted ||
            _controller.isDismissed ||
            !_controller.isAnimating)) {
      _animating = false;
      _fromIndex = null;
    }
    if (_animating) return;
    if (_index < widget.pageCount - 1) {
      if (_isNone || _isScroll) {
        _setIndex(_index + 1);
      } else {
        _animateTo(_index + 1, forward: true);
      }
    } else {
      widget.onRequestNextChapter?.call();
    }
  }

  /// 翻到上一页（越界时请求上一章）。
  void previousPage() {
    if (_dragging) return;
    // 防御：同 [nextPage]，若 _animating 卡住则强制复位。
    if (_animating &&
        (_controller.isCompleted ||
            _controller.isDismissed ||
            !_controller.isAnimating)) {
      _animating = false;
      _fromIndex = null;
    }
    if (_animating) return;
    if (_index > 0) {
      if (_isNone || _isScroll) {
        _setIndex(_index - 1);
      } else {
        _animateTo(_index - 1, forward: false);
      }
    } else {
      widget.onRequestPrevChapter?.call();
    }
  }

  /// 无动画跳转到指定页。
  void jumpToPage(int page) {
    _controller.stop();
    _animating = false;
    _fromIndex = null;
    final max = (widget.pageCount - 1).clamp(0, 1 << 30);
    final clamped = page.clamp(0, max);
    if (clamped == _index) return;
    _index = clamped;
    widget.onPageChanged?.call(_index);
    if (mounted) setState(() {});
  }

  // ─────────────────── 平滑自动翻页（O5） ───────────────────

  /// 自动翻页推进一个增量 [delta]（本帧应推进的页面过渡比例，如
  /// 50ms 帧 / 间隔秒数）。返回 true 表示本次调用完成了一次落页。
  ///
  /// - none / scroll 动画：累计满 1 调用 [nextPage]（滚动视图的像素级
  ///   平滑由外层直接驱动滚动控制器）；
  /// - 自定义动画：复用拖拽跟手的过渡渲染管线，`_controller.value`
  ///   由外部逐帧推进（手动 set value 不触发 status listener），跨过
  ///   1.0 时自行复位过渡态并落页；到达本章末页时请求下一章。
  bool advanceAutoPage(double delta) {
    if (delta <= 0 || _dragging) return false;
    if (_isNone || _isScroll) {
      _autoAccum += delta;
      if (_autoAccum >= 1.0) {
        _autoAccum = 0;
        nextPage();
        return true;
      }
      return false;
    }
    if (!_autoTurning) {
      final rawTarget = _index + 1;
      if (rawTarget >= widget.pageCount) {
        widget.onRequestNextChapter?.call();
        return true;
      }
      _controller.stop();
      _reversing = false;
      _controller.value = 0;
      _fromIndex = _index;
      _index = rawTarget;
      _forward = true;
      _animating = true;
      _autoTurning = true;
      widget.onPageChanged?.call(_index);
      if (mounted) setState(() {});
    }
    final double v = (_controller.value + delta).clamp(0.0, 1.0);
    _controller.value = v;
    if (v >= 1.0) {
      _finishAutoTurn();
      return true;
    }
    return false;
  }

  void _finishAutoTurn() {
    _autoTurning = false;
    _animating = false;
    _fromIndex = null;
    if (mounted) setState(() {});
  }

  /// 中止进行中的平滑自动翻页过渡（暂停 / 切章时调用）：停在目标页静态态，
  /// 避免残留半程过渡画面。
  void cancelAutoTurn() {
    if (!_autoTurning) return;
    _autoTurning = false;
    _animating = false;
    _fromIndex = null;
    _autoAccum = 0;
    _controller.stop();
    _controller.value = 0;
    if (mounted) setState(() {});
  }

  void _setIndex(int target) {
    _index = target;
    widget.onPageChanged?.call(_index);
    if (mounted) setState(() {});
  }

  void _animateTo(int target, {required bool forward}) {
    // P3.1.2 修复：连续翻页时先 stop() 旧动画，避免控制器状态残留导致
    // 下一次 forward() 在 value=1.0 的脏状态上启动，出现动画跳帧/卡顿。
    // 关键顺序：先复位控制器（stop + 清 _reversing + value=0），再赋值状态。
    // 否则 value=0 会同步触发 status listener 的 dismissed，在状态赋值前就把
    // 旧 _index 当成回弹目标写回，造成「翻一次就卡死」。
    _controller.stop();
    _reversing = false;
    _controller.value = 0;
    _fromIndex = _index;
    _index = target;
    _forward = forward;
    _animating = true;
    widget.onPageChanged?.call(_index);
    // 关键性能修复：动画第一帧会同步构建 from/to 两整页（pageBuilder 几十行
    // 文本 + 手势），叠加 reader 的 onPageChanged → setState 重建，首帧 build
    // 高达 150~300ms，表现为「点击后动画卡顿」。这里**先 setState 构建一帧**
    // （两页就绪 + reader 重建），下一帧再 forward 启动动画——构建成本被挪到
    // 用户感知不到的"点击后极短停顿"，动画时间线内每帧只重排变换层。
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_animating || _fromIndex == null) return;
      _controller.forward();
    });
  }

  // ─────────────────────── 拖拽跟手 ───────────────────────

  void _onHorizontalDragStart(DragStartDetails d) {
    if (_isScroll || _isNone || _animating) return;
    // 选区激活时让出指针，避免选区拖动手势被翻页抢走。
    if (widget.selectionActive?.call() == true) {
      _dragging = false;
      return;
    }
    _dragging = true;
    _dragForward = null;
    _dragDelta = 0;
    _dragProgress = 0;
  }

  void _onHorizontalDragUpdate(DragUpdateDetails d) {
    if (!_dragging || _animating) return;
    final width = context.size?.width ?? 0;
    if (width <= 0) return;
    _dragDelta += d.delta.dx;
    if (_dragForward == null) {
      if (_dragDelta.abs() < 8) return;
      final wantsForward = _dragDelta < 0; // 左滑 -> 下一页
      if (wantsForward && _index >= widget.pageCount - 1) return;
      if (!wantsForward && _index <= 0) return;
      _dragForward = wantsForward;
    }
    _dragProgress = (_dragDelta.abs() / width).clamp(0.0, 1.0);
    setState(() {});
  }

  void _onHorizontalDragEnd(DragEndDetails d) {
    if (!_dragging) return;
    _dragging = false;
    final forward = _dragForward;
    final progress = _dragProgress;
    _dragForward = null;
    _dragProgress = 0;
    _dragDelta = 0;
    if (forward == null) {
      if (mounted) setState(() {});
      return;
    }
    final rawTarget = forward ? _index + 1 : _index - 1;
    // 安全clamp：防止极端时序下 target 越界（如拖拽期间外部改变了 _index），
    // 导致 onPageChanged 收到负数或超范围值，污染阅读器 _currentPage 为 -2/-3。
    final maxPage = (widget.pageCount - 1).clamp(0, 1 << 30);
    final target = rawTarget.clamp(0, maxPage);
    // 越界时视为边界请求（同按钮行为：上一页越界→请求上一章）。
    if (rawTarget != target) {
      if (rawTarget < 0) {
        widget.onRequestPrevChapter?.call();
      } else {
        widget.onRequestNextChapter?.call();
      }
      if (mounted) setState(() {});
      return;
    }
    _fromIndex = _index;
    _index = target;
    _forward = forward;
    _animating = true;
    _controller.value = progress;
    if (progress >= 0.5) {
      _controller.forward();
      widget.onPageChanged?.call(_index);
    } else {
      // 回弹：dismissed 后恢复 _index 为 _fromIndex。
      _reversing = true;
      _controller.reverse();
    }
    setState(() {});
  }

  // ─────────────────────── 构建 ───────────────────────

  @override
  Widget build(BuildContext context) {
    // scroll 模式：构建连续滚动视图，仍包裹统一手势以支持点击 / 亮度拖拽。
    if (_isScroll) {
      return _wrapGestures(
        widget.scrollBuilder?.call(context) ?? const SizedBox.shrink(),
      );
    }

    // translucent：点击 / 竖向拖拽（亮度）穿透到回调，水平拖拽用于翻页。
    return _wrapGestures(
      ColoredBox(
        color: widget.background ?? Theme.of(context).colorScheme.surface,
        child: LayoutBuilder(
          builder: (BuildContext ctx, BoxConstraints c) {
            final w = c.maxWidth;
            final h = c.maxHeight;

            // 非动画模式 / 不在翻页过渡中：直接构建当前页。
            // 注意：动画期间不能执行该分支——`pageBuilder` 会全量构建一页
            // （几十行文本 + 手势识别器），每帧调用一次是翻页掉帧主因；
            // 过渡页内容由下方 from/to 缓存复用，动画帧只重排变换/合成层。
            if (!_isCustom || (!_animating && !_dragging)) {
              return widget.pageBuilder(context, _index);
            }

            final fromIdx = _dragging ? _index : (_fromIndex ?? _index);
            final forward = _dragging ? (_dragForward ?? _forward) : _forward;
            final toIdx = _dragging ? (forward ? _index + 1 : _index - 1) : _index;
            if (toIdx < 0 || toIdx >= widget.pageCount) {
              return widget.pageBuilder(context, _index);
            }

            // 过渡页缓存：同一对 (from,to) 只构建一次子树，动画帧仅重绘
            // 变换/透明度/裁剪层（翻页卡顿主修复）。
            // 这里就包好 RepaintBoundary：整页几十行文本位图离线缓存，动画帧
            // 的 Transform/Opacity/裁剪只做图层合成/平移，不重绘内部文本——
            // 若不加隔离，每帧都会强制重绘整页（中低端安卓掉帧主因）。
            final turnKey =
                '$fromIdx|$toIdx|${widget.contentVersion}|${widget.animation}';
            if (_turnCacheKey != turnKey) {
              _turnFromPage = RepaintBoundary(
                child: widget.pageBuilder(context, fromIdx),
              );
              _turnToPage = RepaintBoundary(
                child: widget.pageBuilder(context, toIdx),
              );
              _turnCacheKey = turnKey;
            }

            // 拖拽跟手：进度由手指驱动，直接渲染当前 _dragProgress（drag 事件
            // 每次触发一次 build，无需动画控制器）。
            if (_dragging) {
              return _StackPageTurner(
                fromPage: _turnFromPage!,
                toPage: _turnToPage!,
                forward: forward,
                progress: _dragProgress,
                animation: widget.animation,
                width: w,
                height: h,
                background: widget.background,
              );
            }

            // 自动动画：进度由 _controller 驱动，用 AnimatedBuilder 只重建翻页层，
            // 不重建外层手势树 / ColoredBox / LayoutBuilder（动画期间整树 setState
            // 是真机翻页掉帧主因——每帧重建 GestureDetector + 布局）。
            return AnimatedBuilder(
              animation: _controller,
              builder: (BuildContext ctx, Widget? _) => _StackPageTurner(
                fromPage: _turnFromPage!,
                toPage: _turnToPage!,
                forward: forward,
                progress: _controller.value,
                animation: widget.animation,
                width: w,
                height: h,
                background: widget.background,
              ),
            );
          },
        ),
      ),
    );
  }

  /// 统一包裹手势识别器。横向翻页拖拽与单击区域由主 [GestureDetector] 处理；
  /// 竖向亮度拖拽单独放在**左侧 1/3** 的覆盖层，避免两种识别器在同一
  /// GestureDetector 中争夺手势竞技场（arena）——横向翻页滑动常因轻微竖向抖动
  /// 被误判为亮度拖拽，导致「翻页手势有时不起作用」。
  /// scroll 模式下不注册亮度拖拽（ListView 自身占用竖向滚动）。
  Widget _wrapGestures(Widget child) {
    final brightnessEnabled = !_isScroll &&
        widget.onVerticalDragStart != null &&
        widget.onVerticalDragUpdate != null &&
        widget.onVerticalDragEnd != null;
    final base = GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: _onHorizontalDragStart,
      onHorizontalDragUpdate: _onHorizontalDragUpdate,
      onHorizontalDragEnd: _onHorizontalDragEnd,
      onHorizontalDragCancel: () {
        // 水平拖拽被外部取消（如被竖向亮度拖拽抢走）时，必须复位 _dragging
        // 等标志，否则会一直卡在 dragging 状态，导致 nextPage/previousPage
        // 的 `_dragging` 守卫直接 return（按钮失灵）。
        _dragging = false;
        _dragForward = null;
        _dragDelta = 0;
        _dragProgress = 0;
      },
      onTapUp: (TapUpDetails d) =>
          widget.onTapUp?.call(d, context.size ?? MediaQuery.sizeOf(context)),
      child: child,
    );
    final Widget inner = brightnessEnabled
        ? Stack(
            children: <Widget>[
              base,
              Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: 1 / 3,
                  heightFactor: 1,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onVerticalDragStart: widget.onVerticalDragStart,
                    onVerticalDragUpdate: widget.onVerticalDragUpdate,
                    onVerticalDragEnd: widget.onVerticalDragEnd,
                  ),
                ),
              ),
            ],
          )
        : base;
    // N4 下滑切书签：主区域纵向下滑。与横向翻页手势共存于同一
    // GestureDetector——Flutter 手势竞技场按位移方向自动裁决横/纵拖拽，
    // 横向滑动走翻页、纵向下滑走书签，无需额外分区。
    final bookmarkSwipeEnabled = !_isScroll &&
        widget.onBookmarkSwipeStart != null &&
        widget.onBookmarkSwipeUpdate != null &&
        widget.onBookmarkSwipeEnd != null;
    final Widget withSwipe = bookmarkSwipeEnabled
        ? GestureDetector(
            behavior: HitTestBehavior.translucent,
            onVerticalDragStart: widget.onBookmarkSwipeStart,
            onVerticalDragUpdate: widget.onBookmarkSwipeUpdate,
            onVerticalDragEnd: widget.onBookmarkSwipeEnd,
            child: inner,
          )
        : inner;
    // 翻页模式：拦截鼠标滚轮翻页。scroll 模式不拦截（底层 Scrollable 接管滚轮）。
    return Listener(
      onPointerSignal: (signal) {
        if (_isScroll) return;
        if (signal is PointerScrollEvent) {
          // 消费信号，避免继续透传给不存在的底层滚动视图（paged 模式无 Scrollable）。
          GestureBinding.instance.pointerSignalResolver.register(signal, (_) {});
          final bool down = signal.scrollDelta.dy > 0;
          final bool next = widget.scrollWheelInverted ? !down : down;
          if (next) {
            nextPage();
          } else {
            previousPage();
          }
        }
      },
      child: withSwipe,
    );
  }
}

/// 堆叠式翻页渲染器：底层为「被揭开/被覆盖」的页，上层为「移动中」的页，
/// 顶层为效果阴影 / 卷边 CustomPaint。4 种 paged 动画共用此结构。
class _StackPageTurner extends StatelessWidget {
  final Widget fromPage;
  final Widget toPage;
  final bool forward;
  final double progress;
  final NovelPageAnimation animation;
  final double width;
  final double height;
  /// 不透明背景：无论翻页内容是否透明，底层始终铺满阅读背景色，
  /// 杜绝仿真/覆盖/滑动动画首帧透出灰屏（旧应用「仿真初始灰屏」坑）。
  final Color? background;

  const _StackPageTurner({
    required this.fromPage,
    required this.toPage,
    required this.forward,
    required this.progress,
    required this.animation,
    required this.width,
    required this.height,
    required this.background,
  });

  @override
  Widget build(BuildContext context) {
    final p = progress.clamp(0.0, 1.0);
    final Widget child;
    // from/to 页已在 turn 缓存构建时包好 RepaintBoundary（见
    // NovelAnimatedPageViewState.build 的 turnKey 分支），这里不再每帧新建
    // boundary——动画帧只重排 Transform/Opacity/裁剪层，内部文本位图缓存复用。
    switch (animation) {
      case NovelPageAnimation.fade:
        child = _buildFade(p, fromPage, toPage);
      case NovelPageAnimation.cover:
        child = _buildCover(p, fromPage, toPage);
      case NovelPageAnimation.slide:
        child = _buildSlide(p, fromPage, toPage);
      case NovelPageAnimation.simulation:
        child = _buildSimulation(p, fromPage, toPage);
      case NovelPageAnimation.none:
      case NovelPageAnimation.scroll:
        child = toPage;
    }
    // 不透明底色：确保翻页过程中任何未覆盖区域都显示正确背景，而非系统默认灰。
    return ColoredBox(
      color: background ?? Theme.of(context).colorScheme.surface,
      child: child,
    );
  }

  /// 交叉淡入：旧页在下，新页淡入覆盖；过渡中点轻微压暗增加层次。
  Widget _buildFade(double p, Widget fromPage, Widget toPage) {
    return Stack(
      children: <Widget>[
        Positioned.fill(child: fromPage),
        Positioned.fill(child: Opacity(opacity: p, child: toPage)),
        Positioned.fill(child: CustomPaint(painter: _FadePagePainter(progress: p))),
      ],
    );
  }

  /// 覆盖：新页从侧边滑入，覆盖静止的旧页；移动页前缘投阴影。
  Widget _buildCover(double p, Widget fromPage, Widget toPage) {
    final offset = forward ? width * (1 - p) : -width * (1 - p);
    return Stack(
      children: <Widget>[
        Positioned.fill(child: fromPage),
        Positioned.fill(
          child: Transform.translate(offset: Offset(offset, 0), child: toPage),
        ),
        Positioned.fill(
          child: CustomPaint(
            painter: _CoverPagePainter(progress: p, forward: forward, width: width),
          ),
        ),
      ],
    );
  }

  /// 滑动：新旧页同时平移；两页交界处投阴影。
  Widget _buildSlide(double p, Widget fromPage, Widget toPage) {
    final fromOffset = forward ? -width * p : width * p;
    final toOffset = forward ? width * (1 - p) : -width * (1 - p);
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: Transform.translate(offset: Offset(fromOffset, 0), child: fromPage),
        ),
        Positioned.fill(
          child: Transform.translate(offset: Offset(toOffset, 0), child: toPage),
        ),
        Positioned.fill(
          child: CustomPaint(
            painter: _SlidePagePainter(progress: p, forward: forward, width: width),
          ),
        ),
      ],
    );
  }

  /// 仿真卷页：目标页在下铺满，来源页按 creaseX 裁剪并卷离；卷边投阴影 + 折痕高光。
  Widget _buildSimulation(double p, Widget fromPage, Widget toPage) {
    final creaseX = forward ? width * (1 - p) : width * p;
    return Stack(
      children: <Widget>[
        Positioned.fill(child: toPage),
        Positioned.fill(
          child: ClipPath(
            clipper: _SimulationClipper(
              creaseX: creaseX,
              forward: forward,
            ),
            child: fromPage,
          ),
        ),
        Positioned.fill(
          child: CustomPaint(
            painter: _SimulationPagePainter(
              progress: p,
              forward: forward,
              width: width,
              height: height,
              creaseX: creaseX,
            ),
          ),
        ),
      ],
    );
  }
}

/// 仿真卷页裁剪路径：保留未卷离的部分，边缘为轻微外凸贝塞尔（卷边唇）。
class _SimulationClipper extends CustomClipper<Path> {
  final double creaseX;
  final bool forward;

  const _SimulationClipper({required this.creaseX, required this.forward});

  @override
  Path getClip(Size size) {
    const double curl = 18.0;
    final path = Path();
    if (forward) {
      // 保留 creaseX 左侧。
      path.moveTo(0, 0);
      path.lineTo(creaseX, 0);
      path.quadraticBezierTo(creaseX + curl, size.height / 2, creaseX, size.height);
      path.lineTo(0, size.height);
      path.close();
    } else {
      // 保留 creaseX 右侧。
      path.moveTo(size.width, 0);
      path.lineTo(creaseX, 0);
      path.quadraticBezierTo(creaseX - curl, size.height / 2, creaseX, size.height);
      path.lineTo(size.width, size.height);
      path.close();
    }
    return path;
  }

  @override
  bool shouldReclip(_SimulationClipper old) =>
      creaseX != old.creaseX || forward != old.forward;
}

/// 淡入效果阴影：过渡中点轻微压暗（0 → 0.18 → 0）。
class _FadePagePainter extends CustomPainter {
  final double progress;
  const _FadePagePainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final dim = (1 - (2 * progress - 1).abs()) * 0.18;
    if (dim <= 0) return;
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = Colors.black.withValues(alpha: dim),
    );
  }

  @override
  bool shouldRepaint(_FadePagePainter old) => old.progress != progress;
}

/// 覆盖效果阴影：移动页前缘向旧页投射渐变阴影。
class _CoverPagePainter extends CustomPainter {
  final double progress;
  final bool forward;
  final double width;
  const _CoverPagePainter({
    required this.progress,
    required this.forward,
    required this.width,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final p = progress.clamp(0.0, 1.0);
    if (p <= 0 || p >= 1) return;
    const double shadowWidth = 36.0;
    final edge = forward ? width * (1 - p) : width * p;
    final rect = forward
        ? Rect.fromLTWH(edge - shadowWidth, 0, shadowWidth, size.height)
        : Rect.fromLTWH(edge, 0, shadowWidth, size.height);
    final paint = Paint()
      ..shader = LinearGradient(
        begin: forward ? Alignment.centerLeft : Alignment.centerRight,
        end: forward ? Alignment.centerRight : Alignment.centerLeft,
        colors: <Color>[
          Colors.black.withValues(alpha: 0.0),
          Colors.black.withValues(alpha: 0.28),
        ],
      ).createShader(rect);
    canvas.drawRect(rect, paint);
  }

  @override
  bool shouldRepaint(_CoverPagePainter old) =>
      old.progress != progress || old.forward != forward;
}

/// 滑动效果阴影：两页交界处双向渐变阴影。
class _SlidePagePainter extends CustomPainter {
  final double progress;
  final bool forward;
  final double width;
  const _SlidePagePainter({
    required this.progress,
    required this.forward,
    required this.width,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final p = progress.clamp(0.0, 1.0);
    if (p <= 0 || p >= 1) return;
    const double shadowWidth = 24.0;
    final boundary = forward ? width * (1 - p) : width * p;
    final rect = Rect.fromLTWH(
      boundary - shadowWidth / 2,
      0,
      shadowWidth,
      size.height,
    );
    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: <Color>[
          Colors.black.withValues(alpha: 0.0),
          Colors.black.withValues(alpha: 0.22),
          Colors.black.withValues(alpha: 0.0),
        ],
      ).createShader(rect);
    canvas.drawRect(rect, paint);
  }

  @override
  bool shouldRepaint(_SlidePagePainter old) =>
      old.progress != progress || old.forward != forward;
}

/// 仿真卷页阴影：卷边向被揭开侧投射渐变阴影，并描出折痕。
class _SimulationPagePainter extends CustomPainter {
  final double progress;
  final bool forward;
  final double width;
  final double height;
  final double creaseX;
  const _SimulationPagePainter({
    required this.progress,
    required this.forward,
    required this.width,
    required this.height,
    required this.creaseX,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final p = progress.clamp(0.0, 1.0);
    if (p <= 0 || p >= 1) return;
    const double shadowWidth = 28.0;
    final rect = forward
        ? Rect.fromLTWH(creaseX, 0, shadowWidth, size.height)
        : Rect.fromLTWH(creaseX - shadowWidth, 0, shadowWidth, size.height);
    final paint = Paint()
      ..shader = LinearGradient(
        begin: forward ? Alignment.centerLeft : Alignment.centerRight,
        end: forward ? Alignment.centerRight : Alignment.centerLeft,
        colors: <Color>[
          Colors.black.withValues(alpha: 0.30),
          Colors.black.withValues(alpha: 0.0),
        ],
      ).createShader(rect);
    canvas.drawRect(rect, paint);

    // 折痕高光线（与裁剪边缘一致）。
    final creasePaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.18)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    const double curl = 18.0;
    final path = Path();
    if (forward) {
      path.moveTo(creaseX, 0);
      path.quadraticBezierTo(creaseX + curl, size.height / 2, creaseX, size.height);
    } else {
      path.moveTo(creaseX, 0);
      path.quadraticBezierTo(creaseX - curl, size.height / 2, creaseX, size.height);
    }
    canvas.drawPath(path, creasePaint);
  }

  @override
  bool shouldRepaint(_SimulationPagePainter old) =>
      old.progress != progress ||
      old.forward != forward ||
      old.creaseX != creaseX;
}

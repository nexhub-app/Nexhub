part of 'video_player_screen.dart';

class _DanmakuToggle extends StatelessWidget {
  const _DanmakuToggle({
    super.key,
    required this.isOn,
    required this.l10n,
    required this.onToggle,
    this.onSend,
    this.onSettings,
    this.onLongPressSettings,
  });

  final bool isOn;
  final AppLocalizations l10n;
  final VoidCallback onToggle;
  final VoidCallback? onSend;
  final VoidCallback? onSettings;
  final VoidCallback? onLongPressSettings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!isOn) {
      // 关闭态：仅显示空心开关按钮，紧凑尺寸
      return IconButton(
        icon: const Icon(Icons.comment_outlined, color: Colors.white54),
        iconSize: 22,
        tooltip: l10n.danmaku,
        onPressed: onToggle,
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        padding: const EdgeInsets.all(AppTokens.spaceXs),
      );
    }

    // 开启态：高亮背景 + 实心图标 + 发送 + 设置
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: AppTokens.spaceXxs),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(AppTokens.radiusLg),
        border: Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // 弹幕开关（开启态，实心图标）
          IconButton(
            icon: Icon(Icons.comment, color: theme.colorScheme.primary, size: 20),
            tooltip: l10n.danmaku,
            onPressed: onToggle,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            padding: EdgeInsets.zero,
          ),
          // 发送弹幕按钮（仅开启时显示）
          if (onSend != null)
            IconButton(
              icon: const Icon(Icons.send, color: Colors.white70, size: 18),
              tooltip: l10n.danmakuSend ?? 'Send danmaku',
              onPressed: onSend,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              padding: EdgeInsets.zero,
            ),
          // 弹幕设置（长按=弹幕源选择）
          if (onSettings != null)
            IconButton(
              icon: const Icon(Icons.settings, color: Colors.white70, size: 18),
              tooltip: l10n.danmakuSettings,
              onPressed: onSettings,
              onLongPress: onLongPressSettings,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              padding: EdgeInsets.zero,
            ),
        ],
      ),
    );
  }
}

/// 中央播放/暂停按钮（毛玻璃圆形 + 弹性入场动画 + 按压缩放反馈）。
///
/// 仅暂停态显示，视觉特征：
/// - 半透明圆形背景 + BackdropFilter 模糊（毛玻璃）
/// - 外阴影增加浮起感
/// - 弹性缩放入场动画（Curves.elasticOut）
/// - 按下时微缩放反馈

class _CenterPlayButton extends StatefulWidget {
  const _CenterPlayButton({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  State<_CenterPlayButton> createState() => _CenterPlayButtonState();
}

class _CenterPlayButtonState extends State<_CenterPlayButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  double _pressScale = 1.0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressScale = 0.88),
      onTapUp: (_) => setState(() => _pressScale = 1.0),
      onTapCancel: () => setState(() => _pressScale = 1.0),
      onTap: widget.onTap,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (BuildContext context, Widget? child) {
          // 弹性曲线：0.3→1.0，带过冲回弹
          final double elasticValue =
              Curves.elasticOut.transform(_controller.value);
          return Transform.scale(
            scale: elasticValue * _pressScale,
            child: child,
          );
        },
        child: Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withValues(alpha: 0.18),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 20,
                spreadRadius: 2,
              ),
            ],
          ),
          child: ClipOval(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: Center(
                  child: Icon(
                    Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 28,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 控制按钮（透明背景圆形，紧凑尺寸）。

class _ControlButton extends StatelessWidget {
  const _ControlButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.tooltip,
    this.onLongPress,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, color: Colors.white, size: 22),
      tooltip: tooltip,
      onPressed: onTap,
      onLongPress: onLongPress,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      padding: const EdgeInsets.all(8),
    );
  }
}

/// 横向滚动文字（Marquee）：当文本超出可用宽度时自动循环滚动；
/// 文本能完整显示时静止不动（无动画开销）。
///
/// 跳过片头/片尾悬浮按钮（F-3）：半透明胶囊，浮在画面右下角。

class _SkipChip extends StatelessWidget {
  const _SkipChip({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.inverseSurface.withValues(alpha: 0.85),
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 18, color: scheme.onInverseSurface),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: scheme.onInverseSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 用 [SingleChildScrollView] 承载文本，由 [AnimationController] 驱动
/// [_scrollController] 手动滚动；避免 ListView.builder(itemCount:null) 在
/// 顶栏 Row 内触发无限高度布局崩溃。

class _MarqueeText extends StatefulWidget {
  const _MarqueeText({
    required this.text,
    required this.style,
  });

  final String text;
  final TextStyle style;

  @override
  State<_MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<_MarqueeText>
    with SingleTickerProviderStateMixin {
  final ScrollController _scrollController = ScrollController();
  // 必须在 initState（context 仍有效）创建，禁止用 late final 懒初始化——
  // 若文本从未滚动、dispose 时首次访问该字段会现场 createTicker 并读取已失活的
  // TickerMode 祖先，抛「Looking up a deactivated widget's ancestor is unsafe」。
  late AnimationController _animController;

  /// 文本是否需要滚动（测量后确定）。
  bool _scrollable = false;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    )..addListener(_onAnimTick);
    // 延迟一帧测量文本宽度，决定是否需要滚动。
    WidgetsBinding.instance.addPostFrameCallback(_measure);
  }

  void _measure(_) {
    final renderer = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();
    // 容器可用宽度估算（减去返回键 + 右侧图标的大致占用）。
    final maxWidth = MediaQuery.of(context).size.width - 160;
    if (mounted && renderer.width > maxWidth) {
      // 标记需要滚动并启动动画（setState 异步，故动画启动不依赖刚刚写入的 _scrollable）。
      if (mounted) setState(() => _scrollable = true);
      if (!_animController.isAnimating) {
        _animController.repeat();
      }
    }
    // TextPainter 用完即释放（B-19）：仅测量用，不常驻，避免小规模资源泄漏。
    renderer.dispose();
  }

  void _onAnimTick() {
    if (!_scrollable || !_scrollController.hasClients) return;
    final max = _scrollController.position.maxScrollExtent;
    if (max <= 0) return;
    // 滚到末尾（留 40px 间隙）后回环到起点，形成循环滚动。
    final span = max + 40;
    final v = (_animController.value * span) % span;
    _scrollController.jumpTo(v);
  }

  @override
  void didUpdateWidget(covariant _MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.style != widget.style) {
      _scrollable = false;
      _animController.stop();
      WidgetsBinding.instance.addPostFrameCallback(_measure);
    }
  }

  @override
  void dispose() {
    _animController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      controller: _scrollController,
      physics: const NeverScrollableScrollPhysics(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppTokens.spaceSm),
        child: Text(widget.text, style: widget.style),
      ),
    );
  }
}

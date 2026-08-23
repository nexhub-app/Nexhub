part of 'video_player_screen.dart';

/// window_manager 没有「解除最大尺寸约束」的 API：原生侧只有 {-1,-1} 表示
/// 无约束，但 Dart 传不进去；传 Size(0, 0) 会在 WM_GETMINMAXINFO 里把
/// ptMaxTrackSize 钳成 0×0，之后任何 setSize / 手动缩放都被压成极小窗口
/// （「再次进入画中画变得特别小」的根因）。用超大值近似「无约束」。
const Size _kWindowMaxUnconstrained = Size(10000, 10000);

extension _VideoCastPip on _VideoPlayerScreenState {
  /// 是否桌面平台（Windows/macOS/Linux）。
  bool get _isDesktop {
    try {
      return Platform.isWindows || Platform.isMacOS || Platform.isLinux;
    } on Object {
      return false;
    }
  }

  void _showCastSheet(AppLocalizations l10n) {
    // F-16：设备选择面板打开期间持有控制栏。
    _acquirePanelHold();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext ctx) => SafeArea(
        child: ConstrainedBox(
          constraints:
              BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
          child: SingleChildScrollView(
            child: FutureBuilder<List<CastDevice>>(
              future: _castService.discover(),
              builder: (BuildContext _, AsyncSnapshot<List<CastDevice>> snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                final List<CastDevice> devices = snap.data ?? <CastDevice>[];
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.all(AppTokens.spaceMd),
                      child: Text(
                        l10n.castToDevice,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    if (_isCasting)
                      ListTile(
                        leading: const Icon(Icons.cast_connected),
                        title:
                            Text(l10n.castingTo(_castService.deviceName ?? '')),
                        trailing: TextButton(
                          onPressed: () {
                            Navigator.pop(context);
                            _disconnectCast(l10n);
                          },
                          child: Text(l10n.castDisconnect),
                        ),
                      ),
                    if (!_isCasting && snap.hasError)
                      Padding(
                        padding: const EdgeInsets.all(AppTokens.spaceMd),
                        child: Text(l10n.castNotSupportedOnDevice),
                      ),
                    if (!_isCasting && !snap.hasError && devices.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(AppTokens.spaceMd),
                        child: Text(l10n.castNoDevices),
                      ),
                    for (final CastDevice d in devices)
                      ListTile(
                        leading: const Icon(Icons.tv),
                        title: Text(d.name),
                        onTap: () {
                          Navigator.pop(ctx);
                          _connectCast(d, l10n);
                        },
                      ),
                    const SizedBox(height: AppTokens.spaceSm),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    )
        // F-16：面板关闭后释放控制栏租约。
        .whenComplete(_releasePanelHold);
  }

  Future<void> _connectCast(CastDevice device, AppLocalizations l10n) async {
    final String url = _playUrl ?? widget.episode.url;
    // 乐观置位投屏中（UI 反馈）；连接失败（超时无握手确认）回滚状态并提示（B-8）。
    if (mounted) setState(() => _isCasting = true);
    try {
      await _castService.connectAndPlay(device, url, title: _episodeTitle);
      await _controller.pause();
      // F-26：订阅投屏位置同步与断开事件。
      _castPositionSub = _castService.positionStream.listen(_onCastPosition);
      _castErrorSub = _castService.errorStream.listen((Object error) {
        if (_disposed || !mounted) return;
        _onCastDisconnected(l10n);
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.castingTo(device.name))),
        );
      }
    } on Object {
      if (mounted) {
        setState(() => _isCasting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.castNotSupportedOnDevice)),
        );
      }
    }
  }

  /// 投屏位置同步回调（F-26）：接收器 MEDIA_STATUS 中的 currentTime。
  /// 不做本地进度 seek（投屏端独立播放），仅刷新 UI 显示。
  void _onCastPosition(Duration position) {
    _castPosition = position;
    // 若需要显示投屏进度，可在此触发 setState（当前 UI 暂不显示投屏进度条，
    // 仅在投屏工具栏显示，后续可扩展）
  }

  /// 投屏意外断开处理（F-26）：自动暂停本地播放，恢复本地控制。
  void _onCastDisconnected(AppLocalizations l10n) {
    _castPositionSub?.cancel();
    _castPositionSub = null;
    _castErrorSub?.cancel();
    _castErrorSub = null;
    if (_isCasting && mounted) {
      setState(() => _isCasting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.castDisconnected)),
      );
    }
  }

  Future<void> _disconnectCast(AppLocalizations l10n) async {
    await _castService.disconnect();
    _castPositionSub?.cancel();
    _castPositionSub = null;
    _castErrorSub?.cancel();
    _castErrorSub = null;
    _castPosition = Duration.zero;
    if (mounted) {
      setState(() => _isCasting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.castDisconnect)),
      );
    }
  }

  Future<void> _togglePip(AppLocalizations l10n) async {
    // 桌面端：用 window_manager 缩小窗口置顶，实现应用内 PiP（F-24）。
    if (_isDesktop) {
      // 进出进行中忽略再次点击：防止并发进入把 PiP 小尺寸存成「原始尺寸」。
      if (_pipSwitching) return;
      if (_desktopPipActive) {
        await _exitDesktopPip();
      } else {
        await _enterDesktopPip(l10n);
      }
      return;
    }
    // Android 系统 PiP（F-23）。
    final floating = Floating();
    try {
      final bool available = await floating.isPipAvailable;
      if (!available) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.pipNotSupportedOnDevice)),
          );
        }
        return;
      }
      // F-23 条件进入：投屏中 / 媒体未就绪时不进入（canEnterPiP 守卫）。
      if (_isCasting) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.pipNotWhileCasting)),
          );
        }
        return;
      }
      if (!_controllerCreated ||
          _controller.duration <= Duration.zero ||
          _controller.isLocked) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.pipNotReady)),
          );
        }
        return;
      }
      // F-23 窗口三动作（播放/暂停、快退 10s、快进 30s）：进入前下发动作列表。
      await _configurePipActions(l10n);
      _pipActionSub ??=
          PipActionsBridge.instance.actionStream.listen(_onPipEvent);
      await floating.enable(ImmediatePiP());
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.pipNotSupportedOnDevice)),
        );
      }
    }
  }

  /// 桌面 PiP：隐藏标题栏 + 缩小窗口置顶播放（F-24）。
  ///
  /// 窗口内拖动视频区域可移动窗口（见 build 中手势层），边缘 8px 保留缩放。
  Future<void> _enterDesktopPip(AppLocalizations l10n) async {
    if (_isCasting) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.pipNotWhileCasting)),
        );
      }
      return;
    }
    if (!_controllerCreated || _controller.duration <= Duration.zero) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.pipNotReady)),
        );
      }
      return;
    }
    if (_desktopPipActive || _pipSwitching) return;
    _pipSwitching = true;
    try {
      // 保存原窗口状态。若原窗口是最大化，先还原为普通态再读 bounds——
      // 否则存下的是最大化后的位置/大小，退出时无法回到真正的原始状态。
      _savedWindowMaximized = await windowManager.isMaximized();
      if (_savedWindowMaximized) {
        await windowManager.unmaximize();
      }
      _savedWindowPos = await windowManager.getPosition();
      _savedWindowSize = await windowManager.getSize();
      _savedWindowTitle = await windowManager.getTitle();
      // 先清掉残留的最小/最大尺寸约束再 setSize（见 _kWindowMaxUnconstrained
      // 注释：传 0 会被钳成 0×0 上限，是重复缩小 bug 的根因）。
      await windowManager.setMinimumSize(const Size(0, 0));
      await windowManager.setMaximumSize(_kWindowMaxUnconstrained);
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
      // 16:9 小窗（保留四边 8px 隐形缩放边）。
      await windowManager.setSize(const Size(480, 270));
      await windowManager.setMinimumSize(const Size(320, 180));
      await windowManager.setMaximumSize(const Size(960, 540));
      await windowManager.setAspectRatio(16 / 9);
      if (mounted) {
        setState(() {
          _desktopPipActive = true;
          // 进入即显示紧凑控件（发现性）：鼠标在窗内则悬停维持，
          // 播放中 4s 无操作自动隐藏，无需先移出再移入。
          _uiVisible = true;
        });
        _scheduleUiHide();
      }
    } on Object catch (e) {
      debugPrint('_enterDesktopPip failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.pipNotSupportedOnDevice)),
        );
      }
    } finally {
      _pipSwitching = false;
    }
  }

  /// 退出桌面 PiP：恢复窗口原始标题栏、大小、位置与最大化状态。
  Future<void> _exitDesktopPip() async {
    if (!_desktopPipActive || _pipSwitching) return;
    _pipSwitching = true;
    try {
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setTitleBarStyle(TitleBarStyle.normal);
      await windowManager.setAspectRatio(0);
      // 必须先解除 PiP 期的最小/最大尺寸约束再恢复大小：否则 setSize 被
      // 仍生效的 maximumSize(960×540) 钳制，原窗口大于该值时恢复失败
      // （「点击关闭没有恢复原始大小」的根因之一）。
      await windowManager.setMinimumSize(const Size(0, 0));
      await windowManager.setMaximumSize(_kWindowMaxUnconstrained);
      await windowManager.setPosition(_savedWindowPos);
      await windowManager.setSize(_savedWindowSize);
      if (_savedWindowMaximized) {
        await windowManager.maximize();
      }
      await windowManager.setTitle(_savedWindowTitle);
    } on Object catch (e) {
      debugPrint('_exitDesktopPip failed: $e');
    } finally {
      _pipSwitching = false;
    }
    if (mounted) {
      setState(() {
        _desktopPipActive = false;
        _uiVisible = true;
      });
    }
  }

  /// 桌面 PiP 内拖动视频区域 = 移动整个窗口（隐藏标题栏后的移动入口）。
  void _pipDragWindow() {
    unawaited(windowManager.startDragging());
  }

  /// 鼠标移入 PiP 窗口：显示紧凑控件并重启自动隐藏倒计时。
  void _pipHoverEnter() {
    if (_disposed || !mounted || !_desktopPipActive) return;
    setState(() => _uiVisible = true);
    _scheduleUiHide();
  }

  /// 鼠标移出 PiP 窗口：播放中收起控件；暂停时保留（用户需要播放键）。
  void _pipHoverExit() {
    if (_disposed || !mounted || !_desktopPipActive) return;
    if (_isPlaying) {
      setState(() => _uiVisible = false);
      _uiHideTimer?.cancel();
    }
  }

  /// 桌面 PiP 紧凑控件层（F-24）：替代被抑制的完整顶栏/底栏。
  ///
  /// 仅在 [_uiVisible] 时可见且可点（隐藏时 IgnorePointer 放行点击到视频区，
  /// 避免挡住拖动移动窗口的手势）。内容：
  /// - 右上角：关闭（退出 PiP 并恢复窗口）；
  /// - 底部：播放/暂停 + 时间 + SeekBar。
  Widget _buildDesktopPipControls(AppLocalizations l10n) {
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: !_uiVisible,
        child: AnimatedOpacity(
          opacity: _uiVisible ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 150),
          child: Stack(
            children: <Widget>[
              // 顶部渐变 + 右上角关闭按钮（独立占位，不再与顶栏「更多」
              // 按钮重叠——PiP 模式下完整顶栏已被抑制）。
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: <Color>[Colors.black54, Colors.transparent],
                    ),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 2,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: <Widget>[
                      _pipControlButton(
                        icon: Icons.close,
                        onTap: () => unawaited(_exitDesktopPip()),
                      ),
                    ],
                  ),
                ),
              ),
              // 底部：SeekBar + 播放/暂停 + 时间。
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: <Color>[Colors.black54, Colors.transparent],
                    ),
                  ),
                  padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      SeekBar(
                        position: _position,
                        duration: _duration,
                        onSeek: _onSeek,
                        // 拖动期间持有控制栏，防止自动隐藏打断拖拽。
                        onDragStart: _acquirePanelHold,
                        onDragEnd: _releasePanelHold,
                      ),
                      Row(
                        children: <Widget>[
                          _pipControlButton(
                            icon: _isPlaying ? Icons.pause : Icons.play_arrow,
                            size: 30,
                            onTap: _togglePlayPause,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${_formatDuration(_position)} / '
                            '${_formatDuration(_duration)}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// PiP 紧凑控件按钮（小触控区适配 480×270 小窗）。
  Widget _pipControlButton({
    required IconData icon,
    required VoidCallback onTap,
    double size = 28,
  }) {
    return SizedBox(
      width: size,
      height: size,
      child: IconButton(
        padding: EdgeInsets.zero,
        iconSize: size - 8,
        visualDensity: VisualDensity.compact,
        icon: Icon(icon, color: Colors.white),
        onPressed: onTap,
      ),
    );
  }

  /// 下发 PiP 窗口动作（F-23）：播放/暂停（图标随当前播放态）、快退 10s、快进 30s。
  ///
  /// 原生侧经 `setPictureInPictureParams` 刷新；进入 PiP 时 floating 传入的
  /// 参数会把动作顶掉，原生在转场结束后延迟重放恢复（见 MainActivity）。
  Future<void> _configurePipActions(AppLocalizations l10n) async {
    final bool playing = _controller.isPlaying;
    await PipActionsBridge.instance.setActions(<Map<String, String>>[
      <String, String>{
        'id': 'play_pause',
        'title': playing ? l10n.pipActionPause : l10n.pipActionPlay,
        'icon': playing ? 'pause' : 'play',
      },
      <String, String>{
        'id': 'rewind_10',
        'title': l10n.pipActionRewind,
        'icon': 'rewind',
      },
      <String, String>{
        'id': 'forward_30',
        'title': l10n.pipActionForward,
        'icon': 'forward',
      },
    ]);
  }

  /// PiP 事件统一处理（F-23 + B-9）：
  /// - `action:<id>`：PiP 窗口动作按钮点击（播放/暂停、快退、快进）；
  /// - `pip:enabled` / `pip:disabled`：进出 PiP 的生命周期事件（原生
  ///   onPictureInPictureModeChanged 推送，替代 floating 的 10ms 轮询流）。
  void _onPipEvent(String event) {
    if (_disposed || !mounted || !_controllerCreated) return;
    switch (event) {
      case 'pip:enabled':
        _inPip = true;
        _pipEnterPosition = _controller.position;
        // 小窗内强制隐藏整层控制 UI（顶栏/底栏/中央按钮/边缘按钮），
        // 否则这些浮层会按全屏尺寸渲染进小窗，挤满画面。
        if (_uiVisible) setState(() => _uiVisible = false);
        break;
      case 'pip:disabled':
        _inPip = false;
        setState(() => _uiVisible = true);
        // PiP 期间被系统回收导致进度回退 → 续播。
        if (_pipEnterPosition > Duration.zero &&
            _controller.position <
                _pipEnterPosition - const Duration(seconds: 5)) {
          unawaited(_controller.seek(_pipEnterPosition));
        }
        break;
      case 'action:play_pause':
        _togglePlayPause();
        break;
      case 'action:rewind_10':
        final target = _controller.position - const Duration(seconds: 10);
        unawaited(
            _controller.seek(target < Duration.zero ? Duration.zero : target));
        break;
      case 'action:forward_30':
        unawaited(_controller.seek(
          _controller.position + const Duration(seconds: 30),
        ));
        break;
    }
  }
}

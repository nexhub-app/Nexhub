part of 'video_player_screen.dart';

extension _VideoCastPip on _VideoPlayerScreenState {
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
                    title: Text(l10n.castingTo(_castService.deviceName ?? '')),
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

  Future<void> _disconnectCast(AppLocalizations l10n) async {
    await _castService.disconnect();
    if (mounted) {
      setState(() => _isCasting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.castDisconnect)),
      );
    }
  }

  Future<void> _togglePip(AppLocalizations l10n) async {
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
      // F-23 窗口三动作（播放/暂停、弹幕、快进）：进入前下发动作列表并订阅点击。
      await _configurePipActions(l10n);
      _pipActionSub ??= PipActionsBridge.instance.actionStream
          .listen(_onPipAction);
      await floating.enable(ImmediatePiP());
      // 进入/退出系统 PiP 的生命周期处理（B-9）：监听 PiP 状态变化，
      // 进入时记录位置并隐藏控制层，退出时恢复控制层、必要时续播。
      _listenPipStatus(floating);
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.pipNotSupportedOnDevice)),
        );
      }
    }
  }

  /// 下发 PiP 窗口动作（F-23）：播放/暂停（图标随当前播放态）、弹幕开关、快进 30s。
  ///
  /// 原生侧经 `setPictureInPictureParams` 动态刷新，PiP 窗口内即时生效；
  /// 非 PiP 模式下调用仅更新参数、无副作用。

  /// 下发 PiP 窗口动作（F-23）：播放/暂停（图标随当前播放态）、弹幕开关、快进 30s。
  ///
  /// 原生侧经 `setPictureInPictureParams` 动态刷新，PiP 窗口内即时生效；
  /// 非 PiP 模式下调用仅更新参数、无副作用。
  Future<void> _configurePipActions(AppLocalizations l10n) async {
    final bool playing = _controller.isPlaying;
    await PipActionsBridge.instance.setActions(<Map<String, String>>[
      <String, String>{
        'id': 'play_pause',
        'title': playing ? l10n.pipActionPause : l10n.pipActionPlay,
        'icon': playing ? 'pause' : 'play',
      },
      <String, String>{
        'id': 'danmaku',
        'title': l10n.pipActionDanmaku,
        'icon': 'danmaku',
      },
      <String, String>{
        'id': 'forward_30',
        'title': l10n.pipActionForward,
        'icon': 'forward',
      },
    ]);
  }

  /// PiP 窗口动作点击处理（F-23）。

  /// PiP 窗口动作点击处理（F-23）。
  void _onPipAction(String event) {
    if (_disposed || !mounted || !_controllerCreated) return;
    switch (event) {
      case 'action:play_pause':
        _togglePlayPause();
        break;
      case 'action:danmaku':
        _toggleDanmaku();
        break;
      case 'action:forward_30':
        unawaited(_controller.seek(
          _controller.position + const Duration(seconds: 30),
        ));
        break;
    }
  }

  /// 订阅系统 PiP 状态（B-9）。
  ///
  /// floating 的 [Floating.pipStatusStream] 以 ~100ms 轮询探测 PiP 模式
  /// （broadcast + distinct，仅变化时推送）。行为：
  /// - 进入 PiP（[PiPStatus.enabled]）：记录进入时的播放位置、隐藏控制层
  ///   （小窗无控制栏，避免 UI 堆叠）；
  /// - 退出 PiP（[PiPStatus.disabled]）：恢复控制层；若 PiP 期间被系统回收
  ///   （Activity 重建 / 进程回收）导致进度明显回退（< 进入位置 - 5s），
  ///   seek 回进入位置续播，避免用户回到播放页却从头开始。
  /// 进入 PiP 不主动暂停：小窗内继续播放是主流体验。

  /// 订阅系统 PiP 状态（B-9）。
  ///
  /// floating 的 [Floating.pipStatusStream] 以 ~100ms 轮询探测 PiP 模式
  /// （broadcast + distinct，仅变化时推送）。行为：
  /// - 进入 PiP（[PiPStatus.enabled]）：记录进入时的播放位置、隐藏控制层
  ///   （小窗无控制栏，避免 UI 堆叠）；
  /// - 退出 PiP（[PiPStatus.disabled]）：恢复控制层；若 PiP 期间被系统回收
  ///   （Activity 重建 / 进程回收）导致进度明显回退（< 进入位置 - 5s），
  ///   seek 回进入位置续播，避免用户回到播放页却从头开始。
  /// 进入 PiP 不主动暂停：小窗内继续播放是主流体验。
  void _listenPipStatus(Floating floating) {
    _pipStatusSub?.cancel();
    _pipStatusSub = floating.pipStatusStream.listen((PiPStatus status) {
      if (_disposed || !mounted || !_controllerCreated) return;
      switch (status) {
        case PiPStatus.enabled:
          _inPip = true;
          _pipEnterPosition = _controller.position;
          if (_uiVisible) setState(() => _uiVisible = false);
          break;
        case PiPStatus.disabled:
          _inPip = false;
          setState(() => _uiVisible = true);
          // PiP 期间被系统回收导致进度回退 → 续播。
          if (_pipEnterPosition > Duration.zero &&
              _controller.position <
                  _pipEnterPosition - const Duration(seconds: 5)) {
            unawaited(_controller.seek(_pipEnterPosition));
          }
          break;
        case PiPStatus.automatic:
        case PiPStatus.unavailable:
          break;
      }
    });
  }
}

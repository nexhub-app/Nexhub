/// RSS 文章正文内嵌视频播放器（B4 增强：按钮 → 内嵌播放 + 全屏）。
///
/// 正文里的直链视频（`<video>` / `<source>` / `<img src="xxx.mp4">`）不再跳
/// 全屏页，而是在文章流中 16:9 内嵌播放，功能对齐主视频播放器的核心控制：
/// 播放/暂停、进度拖动、当前/总时长、倍速（0.5–2.0）、音量、全屏。
///
/// 全屏复用**同一个** [Player] / [VideoController]（进度不丢），只是把视频
/// 视图放大到全屏路由；内嵌页仍在路由栈下方但被覆盖，退出全屏回到原进度。
///
/// 与播客/全屏视频播放器同链路：代理注入 + Referer/UA 防盗链头 + 20s 超时
/// 判失败兜底（部分失败不抛 error，只表现为永远 0 进度）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/media/media_kit_network.dart';
import '../../../core/player/player_controller.dart';
import '../../../core/player/widgets/seek_bar.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/utils/app_log.dart';
import '../../browser/presentation/http_browser_screen.dart';

/// 正文内嵌直链视频（16:9）。
class RssInlineVideoPlayer extends StatefulWidget {
  final String url;
  final String? title;

  /// 视频所在文章页地址（防盗链 Referer）。
  final String? pageUrl;

  const RssInlineVideoPlayer({
    super.key,
    required this.url,
    this.title,
    this.pageUrl,
  });

  @override
  State<RssInlineVideoPlayer> createState() => _RssInlineVideoPlayerState();
}

class _RssInlineVideoPlayerState extends State<RssInlineVideoPlayer> {
  static const Duration _loadTimeout = Duration(seconds: 20);

  /// 用户点击播放后才创建（与旧「点击播放按钮」行为一致）：页面 build 时
  /// 不自动 open，避免与正文抓取等请求并发、以及多个内嵌视频同时创建
  /// Player 的时序竞态（此前自动 open 表现为 mpv 报 tcp 连接失败）。
  ///
  /// 走主播放器同款 [PlayerController] 封装：复用其 open（HLS demuxer /
  /// file:// 归一化 / 字幕记忆）、seek 宽限、stall 检测、解码降级等能力。
  PlayerController? _pc;
  VideoController? _vc;
  bool _started = false;
  bool _failed = false;
  bool _retried = false;
  Timer? _loadTimer;
  StreamSubscription<String>? _errorSub;
  StreamSubscription<Duration>? _durSub;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<bool>? _completedSub;
  Timer? _posSaveTimer;
  static const String _posPrefsPrefix = 'rss_video_pos_v1:';

  @override
  void initState() {
    super.initState();
    MediaKit.ensureInitialized();
  }

  /// 进度记忆（重开续播）：按视频 URL 持久化播放位置，dispose 时保存；
  /// 打开媒体后若上次未播完则 seek 到保存位置。播完清除记录。
  Future<void> _restorePosition(Player player) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final int? saved = prefs.getInt('$_posPrefsPrefix${widget.url}');
      if (saved == null || saved <= 0) return;
      // 等 duration 就绪再 seek（媒体未就绪时 seek 无效）。
      final Duration d = await player.stream.duration.first;
      if (d > Duration.zero && saved < d.inMilliseconds - 2000) {
        await player.seek(Duration(milliseconds: saved));
      }
    } on Object {
      // 进度恢复失败不影响播放。
    }
  }

  Future<void> _savePosition(Player player) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final int pos = player.state.position.inMilliseconds;
      if (pos > 0) {
        await prefs.setInt('$_posPrefsPrefix${widget.url}', pos);
      }
    } on Object {
      // 忽略持久化失败。
    }
  }

  Future<void> _startPlayback() async {
    if (_started) return;
    // 与主播放器同款封装：PlayerController 负责 Player 生命周期、open
    // （HLS demuxer / file:// 归一化 / 字幕记忆）、seek 宽限与 stall 检测。
    final PlayerController pc = PlayerController();
    final VideoController vc = VideoController(pc.player);
    _pc = pc;
    _vc = vc;
    _started = true;
    final Player player = pc.player;
    _durSub = player.stream.duration.listen((Duration d) {
      if (!mounted) return;
      if (d > Duration.zero) {
        _loadTimer?.cancel();
        _loadTimer = null;
        if (_failed) setState(() => _failed = false);
      }
    });
    _errorSub = player.stream.error.listen((String message) {
      AppLog.instance.w('RSS 内嵌视频内核报错: ${widget.url} — $message');
      if (!mounted) return;
      _loadTimer?.cancel();
      _loadTimer = null;
      // 自动重试一次（部分防盗链/瞬时失败重试可恢复）。
      if (!_retried) {
        _retried = true;
        unawaited(_open());
        return;
      }
      setState(() => _failed = true);
    });
    // 播完：停止并清除进度记录（重开从头播）。
    _completedSub = player.stream.completed.listen((bool c) {
      if (!c || !mounted) return;
      player.pause();
      unawaited(_clearPosition());
    });
    // 进度记忆：播放中定期保存位置。
    _posSub = player.stream.position.listen((Duration d) {
      _posSaveTimer ??= Timer(const Duration(seconds: 5), () {
        _posSaveTimer = null;
        final PlayerController? pc = _pc;
        if (pc != null) unawaited(_savePosition(pc.player));
      });
    });
    if (mounted) setState(() {});
    await _open();
  }

  Future<void> _clearPosition() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('$_posPrefsPrefix${widget.url}');
    } on Object {
      // 忽略。
    }
  }

  Future<void> _open() async {
    final PlayerController? pc = _pc;
    if (pc == null || !mounted) return;
    setState(() => _failed = false);
    // fire-and-forget：Player 刚创建时 await setProperty 有内核未就绪的时序
    // 风险，绝不能阻塞 open（否则表现为永远 0 进度 → 超时判失败）。
    unawaited(applyAppProxyToPlayer(pc.player));
    unawaited(_setNetworkTimeout());
    await pc.open(
      widget.url,
      headers: buildMediaHeaders(
        pageUrl: widget.pageUrl,
        mediaUrl: widget.url,
      ),
    );
    await pc.play();
    // 进度记忆：媒体就绪后恢复上次位置（重开续播）。
    unawaited(_restorePosition(pc.player));
    _loadTimer?.cancel();
    _loadTimer = Timer(_loadTimeout, () {
      if (!mounted) return;
      if (pc.player.state.duration > Duration.zero ||
          pc.player.state.playing) {
        return;
      }
      AppLog.instance.w('RSS 内嵌视频加载超时(20s 无时长未起播): ${widget.url}');
      setState(() => _failed = true);
    });
  }

  Future<void> _setNetworkTimeout() async {
    final Object? platform = _pc?.player.platform;
    if (platform is! NativePlayer) return;
    try {
      await platform.setProperty('network-timeout', '60');
    } on Object {
      // 注入失败不阻塞播放。
    }
  }

  Future<void> _openFullscreen() async {
    final PlayerController? pc = _pc;
    final VideoController? vc = _vc;
    if (!mounted || pc == null || vc == null) return;
    // 全屏复用同一 controller（进度不丢）；全屏页退出不释放 Player，
    // 由本组件持有直到 dispose。
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RssVideoFullscreen(
          controller: pc,
          videoController: vc,
          url: widget.url,
          title: widget.title,
          pageUrl: widget.pageUrl,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _loadTimer?.cancel();
    _posSaveTimer?.cancel();
    _errorSub?.cancel();
    _durSub?.cancel();
    _posSub?.cancel();
    _completedSub?.cancel();
    final PlayerController? pc = _pc;
    if (pc != null) {
      unawaited(_savePosition(pc.player));
    }
    pc?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        child: ColoredBox(
          color: Colors.black,
          child: !_started
              // 未点击：16:9 占位 + 播放按钮（与旧按钮版一致，点击才建连）。
              ? _PlayPlaceholder(
                  onPlay: () => unawaited(_startPlayback()),
                )
              : Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    Video(
                      controller: _vc!,
                      controls: NoVideoControls,
                      fit: BoxFit.contain,
                    ),
                    if (_failed)
                      _FailureOverlay(
                        onRetry: () => unawaited(_open()),
                        onBrowser: () => _openInAppBrowser(context),
                        onExternal: () => _openExternally(context),
                      )
                    else
                      RssVideoControls(
                        controller: _pc!,
                        videoController: _vc!,
                        onToggleFullscreen: () =>
                            unawaited(_openFullscreen()),
                      ),
                  ],
                ),
        ),
      ),
    );
  }

  Future<void> _openInAppBrowser(BuildContext context) async {
    if (!context.mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => HttpBrowserScreen(initialUrl: widget.url),
      ),
    );
  }

  Future<void> _openExternally(BuildContext context) async {
    final Uri? uri = Uri.tryParse(widget.url);
    if (uri == null) return;
    final AppLocalizations l10n = AppLocalizations.of(context);
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on Object {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.loadFailed)),
        );
      }
    }
  }
}

/// 全屏播放页：复用同一 [VideoController]（进度不丢），不创建新 Player。
class RssVideoFullscreen extends StatelessWidget {
  /// 主播放器同款 [PlayerController] 封装（控制走封装方法）。
  final PlayerController controller;

  /// 渲染用 [VideoController]（与 controller.player 绑定）。
  final VideoController videoController;

  final String url;
  final String? title;
  final String? pageUrl;

  const RssVideoFullscreen({
    super.key,
    required this.controller,
    required this.videoController,
    required this.url,
    this.title,
    this.pageUrl,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            Video(
              controller: videoController,
              controls: NoVideoControls,
              fit: BoxFit.contain,
            ),
            // 顶部返回条。
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
                child: Row(
                  children: <Widget>[
                    IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      tooltip:
                          MaterialLocalizations.of(context).closeButtonTooltip,
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    Expanded(
                      child: Text(
                        title ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            RssVideoControls(
              controller: controller,
              videoController: videoController,
              onToggleFullscreen: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }
}

/// 视频控制条（内嵌与全屏共用）：播放/暂停、进度拖动、时间、倍速、音量、全屏。
class RssVideoControls extends StatefulWidget {
  /// 主播放器同款 [PlayerController] 封装（播放控制走封装方法）。
  final PlayerController controller;

  /// 渲染用 [VideoController]（与 controller.player 绑定）。
  final VideoController videoController;

  final VoidCallback onToggleFullscreen;

  const RssVideoControls({
    super.key,
    required this.controller,
    required this.videoController,
    required this.onToggleFullscreen,
  });

  @override
  State<RssVideoControls> createState() => _RssVideoControlsState();
}

class _RssVideoControlsState extends State<RssVideoControls> {
  static const List<double> _speeds = <double>[0.5, 1.0, 1.5, 2.0];
  static const List<String> _aspects = <String>['default', '16:9', '4:3', 'fill'];

  bool _playing = false;
  bool _buffering = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _speed = 1.0;
  bool _muted = false;
  bool _controlsVisible = true;
  bool _seeking = false;
  double _dragValue = 0;
  Timer? _hideTimer;

  // ── 手势 / 锁屏 / 比例（同步主视频播放器）──
  bool _locked = false;
  int _aspectIndex = 0;
  int _doubleTapCount = 0;
  DateTime _lastDoubleTap = DateTime.fromMillisecondsSinceEpoch(0);
  String? _gestureText;
  bool _gestureVisible = false;
  Timer? _gestureTimer;
  double _gestureStartValue = 0;

  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool>? _bufferingSub;
  StreamSubscription<double>? _rateSub;
  StreamSubscription<double>? _volumeSub;

  Player get _player => widget.controller.player;

  @override
  void initState() {
    super.initState();
    // 关键：Player 可能在控制条挂载前就已 open，duration/position 流的早期
    // 事件会错过（广播流错过即丢），必须从 player.state 读初始值，
    // 否则总时长永远 00:00、进度条无法拖动。
    _muted = _player.state.volume <= 0.001;
    _position = _player.state.position;
    _duration = _player.state.duration;
    _playing = _player.state.playing;
    _speed = _player.state.rate;
    _dragValue = _duration.inMilliseconds > 0
        ? _position.inMilliseconds.toDouble()
        : 0;
    _posSub = _player.stream.position.listen((Duration d) {
      if (!_seeking && mounted) setState(() => _position = d);
    });
    _durSub = _player.stream.duration.listen((Duration d) {
      if (mounted) setState(() => _duration = d);
    });
    _playingSub = _player.stream.playing.listen((bool p) {
      if (mounted) setState(() => _playing = p);
    });
    _bufferingSub = _player.stream.buffering.listen((bool b) {
      if (mounted) setState(() => _buffering = b);
    });
    _rateSub = _player.stream.rate.listen((double r) {
      if (mounted) setState(() => _speed = r);
    });
    _volumeSub = _player.stream.volume.listen((double v) {
      if (mounted) setState(() => _muted = v <= 0.001);
    });
    _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (!_controlsVisible) return;
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _playing) setState(() => _controlsVisible = false);
    });
  }

  void _toggleControls() {
    setState(() {
      _controlsVisible = !_controlsVisible;
      if (_controlsVisible) _scheduleHide();
    });
  }

  void _togglePlay() {
    if (_playing) {
      unawaited(widget.controller.pause());
    } else {
      unawaited(widget.controller.play());
    }
    _scheduleHide();
  }

  void _cycleSpeed() {
    final int i = _speeds.indexOf(_speed);
    final double next = _speeds[(i + 1) % _speeds.length];
    unawaited(widget.controller.setPlaybackSpeed(next));
    _scheduleHide();
  }

  void _toggleMute() {
    unawaited(widget.controller.setVolume(_muted ? 50.0 : 0.0));
    _scheduleHide();
  }

  void _toggleLock() {
    widget.controller.toggleLock();
    setState(() => _locked = widget.controller.isLocked);
    if (_locked) {
      // 锁定时隐藏控制条防误触。
      _hideTimer?.cancel();
      _controlsVisible = false;
    }
  }

  void _cycleAspect() {
    final int next = (_aspectIndex + 1) % _aspects.length;
    _aspectIndex = next;
    final String ratio = _aspects[next];
    // 走 PlayerController 封装（内部映射为 mpv video-aspect-override）。
    unawaited(widget.controller.setAspectRatio(ratio));
    _showGesture(_aspects[next]);
    _scheduleHide();
  }

  /// 显示中央手势指示器（双击快进/快退 / 横滑 seek 目标 / 比例切换）。
  void _showGesture(String text) {
    _gestureTimer?.cancel();
    setState(() {
      _gestureText = text;
      _gestureVisible = true;
    });
    _gestureTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _gestureVisible = false);
    });
  }

  /// 双击：左半屏快退 10s、右半屏快进 10s（连点累计 10/20/30s）。
  void _handleDoubleTap(Offset localPosition) {
    if (_locked || _duration == Duration.zero) return;
    final bool right = localPosition.dx >= (context.size?.width ?? 0) / 2;
    final now = DateTime.now();
    final bool recent = now.difference(_lastDoubleTap) <
        const Duration(milliseconds: 900);
    _lastDoubleTap = now;
    _doubleTapCount = recent ? _doubleTapCount + 1 : 1;
    final int seconds = 10 * _doubleTapCount.clamp(1, 3);
    final Duration target = right
        ? (_position + Duration(seconds: seconds))
        : (_position - Duration(seconds: seconds));
    final Duration clamped = target < Duration.zero
        ? Duration.zero
        : (target > _duration ? _duration : target);
    unawaited(widget.controller.seek(clamped));
    _showGesture('${right ? '+' : '-'}$seconds s');
  }

  /// 左右滑 seek（按宽度比例换算成 60s 范围）。
  void _startHorizontalDrag(DragStartDetails d) {
    _gestureStartValue = _position.inMilliseconds.toDouble();
  }

  void _updateHorizontalDrag(DragUpdateDetails d, double width) {
    if (_duration == Duration.zero || width <= 0) return;
    final double deltaMs = d.delta.dx / width * 60000;
    final double target =
        (_gestureStartValue + deltaMs).clamp(0, _duration.inMilliseconds.toDouble());
    _showGesture(_fmt(Duration(milliseconds: target.round())));
    if (!_seeking) {
      setState(() {
        _seeking = true;
        _dragValue = target;
      });
    }
  }

  void _endHorizontalDrag() {
    if (_seeking) {
      unawaited(widget.controller.seek(
          Duration(milliseconds: _dragValue.round())));
      setState(() {
        _seeking = false;
        _position = Duration(milliseconds: _dragValue.round());
      });
    }
    _scheduleHide();
  }

  String _fmt(Duration d) {
    final int h = d.inHours;
    final int m = d.inMinutes.remainder(60);
    final int s = d.inSeconds.remainder(60);
    final String mm = m.toString().padLeft(2, '0');
    final String ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _posSub?.cancel();
    _durSub?.cancel();
    _playingSub?.cancel();
    _bufferingSub?.cancel();
    _rateSub?.cancel();
    _volumeSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _toggleControls,
      // 手势（同步主视频播放器）：双击快进/快退、左右滑 seek。
      onDoubleTapDown: (TapDownDetails d) => _handleDoubleTap(d.localPosition),
      onHorizontalDragStart: _startHorizontalDrag,
      onHorizontalDragUpdate: (DragUpdateDetails d) => _updateHorizontalDrag(
          d, context.size?.width ?? MediaQuery.of(context).size.width),
      onHorizontalDragEnd: (_) => _endHorizontalDrag(),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          // 缓冲指示（同步主视频播放器）：缓冲时中央显示 spinner。
          if (_buffering && _controlsVisible)
            const Center(
              child: SizedBox(
                width: 36,
                height: 36,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Colors.white70,
                ),
              ),
            ),
          // 手势指示器（中央浮层）。
          if (_gestureVisible)
            IgnorePointer(
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppTokens.spaceMd,
                    vertical: AppTokens.spaceSm,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(AppTokens.spaceSm),
                  ),
                  child: Text(
                    _gestureText ?? '',
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                  ),
                ),
              ),
            ),
          // 锁定时仅显示解锁按钮（右上角），控制条隐藏防误触。
          if (_locked)
            Positioned(
              top: 0,
              right: 0,
              child: IconButton(
                icon: const Icon(Icons.lock_open_rounded, color: Colors.white),
                tooltip: 'Unlock',
                onPressed: _toggleLock,
              ),
            )
          else if (_controlsVisible)
            // 显式钉底：控制条始终贴视频下沿（修复「控制栏在中央」）。
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: <Color>[Colors.black87, Colors.transparent],
                  ),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Row(
                  children: <Widget>[
                    IconButton(
                      icon: Icon(
                        _buffering
                            ? Icons.hourglass_top
                            : (_playing
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded),
                        color: Colors.white,
                      ),
                      tooltip: _playing ? 'Pause' : 'Play',
                      onPressed: _togglePlay,
                    ),
                    Text(_fmt(_position),
                        style: const TextStyle(color: Colors.white, fontSize: 12)),
                    Expanded(
                      child: SeekBar(
                        position: _seeking
                            ? Duration(milliseconds: _dragValue.round())
                            : _position,
                        duration: _duration,
                        onDragStart: () {
                          _hideTimer?.cancel();
                          setState(() {
                            _seeking = true;
                            _dragValue = _position.inMilliseconds.toDouble();
                          });
                        },
                        onDragEnd: _scheduleHide,
                        onSeek: (Duration v) {
                          unawaited(widget.controller.seek(v));
                          setState(() {
                            _seeking = false;
                            _position = v;
                          });
                        },
                      ),
                    ),
                    Text(_fmt(_duration),
                        style: const TextStyle(color: Colors.white, fontSize: 12)),
                    const SizedBox(width: 4),
                    // 倍速（0.5x / 1.0x / 1.5x / 2.0x 循环）。
                    TextButton(
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white,
                        minimumSize: const Size(0, 36),
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                      ),
                      onPressed: _cycleSpeed,
                      child: Text(
                        '${_speed.toStringAsFixed(1)}x',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                    // 画面比例（默认 / 16:9 / 4:3 / 拉伸 循环）。
                    TextButton(
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white,
                        minimumSize: const Size(0, 36),
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                      ),
                      onPressed: _cycleAspect,
                      child: Text(
                        _aspects[_aspectIndex],
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    IconButton(
                      icon: Icon(
                        _muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                        color: Colors.white,
                      ),
                      tooltip: _muted ? 'Unmute' : 'Mute',
                      onPressed: _toggleMute,
                    ),
                    IconButton(
                      icon: const Icon(Icons.lock_outline_rounded,
                          color: Colors.white),
                      tooltip: 'Lock',
                      onPressed: _toggleLock,
                    ),
                    IconButton(
                      icon: const Icon(Icons.fullscreen_rounded,
                          color: Colors.white),
                      tooltip: 'Fullscreen',
                      onPressed: widget.onToggleFullscreen,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 未点击播放前的 16:9 占位：黑底 + 居中播放按钮（与旧「点击播放按钮」
/// 行为一致——点击才建连，避免页面打开即自动 open 的时序竞态）。
class _PlayPlaceholder extends StatelessWidget {
  final VoidCallback onPlay;

  const _PlayPlaceholder({required this.onPlay});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black,
      child: InkWell(
        onTap: onPlay,
        child: const Center(
          child: Icon(
            Icons.play_circle_outline,
            size: 56,
            color: Colors.white70,
          ),
        ),
      ),
    );
  }
}

/// 加载失败覆盖层：重试 / 内置浏览器 / 外部打开三条出路。
class _FailureOverlay extends StatelessWidget {
  final VoidCallback onRetry;
  final VoidCallback onBrowser;
  final VoidCallback onExternal;

  const _FailureOverlay({
    required this.onRetry,
    required this.onBrowser,
    required this.onExternal,
  });

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Center(
      child: Container(
        margin: const EdgeInsets.all(AppTokens.spaceMd),
        padding: const EdgeInsets.all(AppTokens.spaceMd),
        decoration: BoxDecoration(
          color: scheme.errorContainer.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(Icons.error_outline, size: 18, color: scheme.error),
                const SizedBox(width: AppTokens.spaceXs),
                Flexible(
                  child: Text(
                    l10n.rssVideoFailed,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppTokens.spaceSm),
            Wrap(
              spacing: AppTokens.spaceXs,
              runSpacing: AppTokens.spaceXs,
              alignment: WrapAlignment.center,
              children: <Widget>[
                TextButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: Text(l10n.retry),
                ),
                TextButton.icon(
                  onPressed: onBrowser,
                  icon: const Icon(Icons.language_outlined, size: 18),
                  label: Text(l10n.rssOpenInBrowser),
                ),
                TextButton.icon(
                  onPressed: onExternal,
                  icon: const Icon(Icons.open_in_new_outlined, size: 18),
                  label: Text(l10n.rssOpenExternally),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

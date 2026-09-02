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
import 'package:url_launcher/url_launcher.dart';

import '../../../core/media/media_kit_network.dart';
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

  late final Player _player;
  late final VideoController _controller;
  bool _failed = false;
  Timer? _loadTimer;
  StreamSubscription<String>? _errorSub;
  StreamSubscription<Duration>? _durSub;

  @override
  void initState() {
    super.initState();
    MediaKit.ensureInitialized();
    _player = Player();
    _controller = VideoController(_player);
    _durSub = _player.stream.duration.listen((Duration d) {
      if (!mounted) return;
      if (d > Duration.zero) {
        _loadTimer?.cancel();
        _loadTimer = null;
        if (_failed) setState(() => _failed = false);
      }
    });
    _errorSub = _player.stream.error.listen((String message) {
      AppLog.instance.w('RSS 内嵌视频内核报错: ${widget.url} — $message');
      if (!mounted) return;
      _loadTimer?.cancel();
      _loadTimer = null;
      setState(() => _failed = true);
    });
    unawaited(_open());
  }

  Future<void> _open() async {
    if (mounted) setState(() => _failed = false);
    // fire-and-forget：Player 刚创建时 await setProperty 有内核未就绪的时序
    // 风险，绝不能阻塞 open（否则表现为永远 0 进度 → 超时判失败）。
    unawaited(applyAppProxyToPlayer(_player));
    unawaited(_setNetworkTimeout());
    _player.open(
      Media(
        widget.url,
        httpHeaders: buildMediaHeaders(
          pageUrl: widget.pageUrl,
          mediaUrl: widget.url,
        ),
      ),
      play: true,
    );
    _loadTimer?.cancel();
    _loadTimer = Timer(_loadTimeout, () {
      if (!mounted) return;
      if (_player.state.duration > Duration.zero || _player.state.playing) {
        return;
      }
      AppLog.instance.w('RSS 内嵌视频加载超时(20s 无时长未起播): ${widget.url}');
      setState(() => _failed = true);
    });
  }

  Future<void> _setNetworkTimeout() async {
    final Object? platform = _player.platform;
    if (platform is! NativePlayer) return;
    try {
      await platform.setProperty('network-timeout', '60');
    } on Object {
      // 注入失败不阻塞播放。
    }
  }

  Future<void> _openFullscreen() async {
    if (!mounted) return;
    // 全屏复用同一 controller（进度不丢）；全屏页退出不释放 Player，
    // 由本组件持有直到 dispose。
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RssVideoFullscreen(
          controller: _controller,
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
    _errorSub?.cancel();
    _durSub?.cancel();
    _player.dispose();
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
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              Video(
                controller: _controller,
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
                  controller: _controller,
                  onToggleFullscreen: () => unawaited(_openFullscreen()),
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
  final VideoController controller;
  final String url;
  final String? title;
  final String? pageUrl;

  const RssVideoFullscreen({
    super.key,
    required this.controller,
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
              controller: controller,
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
  final VideoController controller;
  final VoidCallback onToggleFullscreen;

  const RssVideoControls({
    super.key,
    required this.controller,
    required this.onToggleFullscreen,
  });

  @override
  State<RssVideoControls> createState() => _RssVideoControlsState();
}

class _RssVideoControlsState extends State<RssVideoControls> {
  static const List<double> _speeds = <double>[0.5, 1.0, 1.5, 2.0];

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
    _muted = _player.state.volume <= 0.001;
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
      _player.pause();
    } else {
      _player.play();
    }
    _scheduleHide();
  }

  void _cycleSpeed() {
    final int i = _speeds.indexOf(_speed);
    final double next = _speeds[(i + 1) % _speeds.length];
    _player.setRate(next);
    _scheduleHide();
  }

  void _toggleMute() {
    if (_muted) {
      _player.setVolume(50.0);
    } else {
      _player.setVolume(0.0);
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
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          if (_controlsVisible)
            // 点击区域下沿控制条。
            Align(
              alignment: Alignment.bottomCenter,
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
                      child: Slider(
                        value: _dragValue,
                        min: 0,
                        max: _duration.inMilliseconds > 0
                            ? _duration.inMilliseconds.toDouble()
                            : 1,
                        onChangeStart: (double v) {
                          setState(() {
                            _seeking = true;
                            _dragValue = v;
                          });
                        },
                        onChanged: (double v) {
                          setState(() => _dragValue = v);
                        },
                        onChangeEnd: (double v) {
                          _player.seek(Duration(milliseconds: v.toInt()));
                          setState(() {
                            _seeking = false;
                            _position =
                                Duration(milliseconds: v.toInt());
                          });
                          _scheduleHide();
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
                    IconButton(
                      icon: Icon(
                        _muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                        color: Colors.white,
                      ),
                      tooltip: _muted ? 'Unmute' : 'Mute',
                      onPressed: _toggleMute,
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

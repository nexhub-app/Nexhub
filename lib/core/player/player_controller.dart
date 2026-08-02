import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import '../models/episode.dart';
import 'media_kit_backend.dart';
import 'video_player_backend.dart';

/// 播放统计快照（mpv 只读属性），供「播放统计」面板与软/硬解诊断使用。
class PlayerStats {
  const PlayerStats({
    this.hwdecCurrent,
    this.videoCodec,
    this.videoFormat,
    this.width,
    this.height,
    this.frameDropCount,
    this.decoderFrameDropCount,
    this.videoBitrate,
    this.cacheBufferingState,
  });

  /// 实际生效的解码器（mpv `hwdec-current`）：
  /// `no`=软解，`mediacodec`/`mediacodec-copy`/`d3d11va` 等=硬解，null=未知。
  final String? hwdecCurrent;

  /// 视频编码描述（mpv `video-codec`）。
  final String? videoCodec;

  /// 像素格式（mpv `video-format`）。
  final String? videoFormat;

  /// 视频宽度（mpv `width`）。
  final int? width;

  /// 视频高度（mpv `height`）。
  final int? height;

  /// 渲染层掉帧数（mpv `frame-drop-count`）。
  final int? frameDropCount;

  /// 解码层掉帧数（mpv `decoder-frame-drop-count`）。
  final int? decoderFrameDropCount;

  /// 视频码率 bps（mpv `video-bitrate`）。
  final int? videoBitrate;

  /// 缓冲进度 0–100（mpv `cache-buffering-state`）。
  final int? cacheBufferingState;

  /// 是否硬件解码中（`hwdec-current` 非空且非 `no`）。
  bool get isHardwareDecoding =>
      hwdecCurrent != null && hwdecCurrent != 'no' && hwdecCurrent!.isNotEmpty;

  /// 是否软件解码中（`hwdec-current` 明确为 `no`）。
  bool get isSoftwareDecoding => hwdecCurrent == 'no';

  /// 是否一项数据都没拿到（平台不支持或尚未开始解码）。
  bool get isEmpty =>
      hwdecCurrent == null &&
      videoCodec == null &&
      videoFormat == null &&
      width == null &&
      height == null;

  /// 从 mpv 属性名→原始字符串的映射构造（解析失败的字段置 null）。
  factory PlayerStats.fromProperties(Map<String, String?> props) {
    int? parseInt(String? raw) =>
        raw == null ? null : int.tryParse(raw.trim());
    // video-bitrate 可能带小数（bps），先按 double 解再取整。
    int? parseNum(String? raw) => raw == null
        ? null
        : double.tryParse(raw.trim())?.round();
    return PlayerStats(
      hwdecCurrent: props['hwdec-current'],
      videoCodec: props['video-codec'],
      videoFormat: props['video-format'],
      width: parseInt(props['width']),
      height: parseInt(props['height']),
      frameDropCount: parseInt(props['frame-drop-count']),
      decoderFrameDropCount: parseInt(props['decoder-frame-drop-count']),
      videoBitrate: parseNum(props['video-bitrate']),
      cacheBufferingState: parseNum(props['cache-buffering-state']),
    );
  }
}

/// 视频播放器控制器。
///
/// 封装 [MediaKitBackend]（持有底层 [Player]），对外暴露播放控制、状态流、
/// 锁定、倍速、解码 / 音频 / 比例切换与自动连播等能力，作为 Provider 层
/// ChangeNotifier 供 UI 绑定。
class PlayerController extends ChangeNotifier {
  PlayerController({Player? player})
      : _backend = MediaKitBackend(player ?? Player()) {
    _initStallDetection();
    _initDecodeFallbackDetection();
  }

  final MediaKitBackend _backend;

  /// 自动连播开关。
  bool autoPlayNext = true;

  /// 自动连播回调，由外部（剧集管理器）注入。
  VoidCallback? onAutoPlayNext;

  /// 播放器锁定状态，锁定后禁用手势与控制栏交互。
  bool isLocked = false;

  /// 当前倍速。
  double playbackSpeed = 1.0;

  /// 当前音量（0–100，透传底层 [Player.setVolume]）。
  double volume = 50;

  /// 当前媒体可用的播放线路列表（FR-3.4）。
  /// 解析结果含多线路 URL 时由播放器入口填充；为空表示仅单线路或本地/直链模式。
  List<VideoLine> lines = const <VideoLine>[];

  /// 当前选中的播放线路索引（FR-3.4）。
  int currentLineIndex = 0;

  /// 切换线路时由调用方注入的新线路（已解析）。仅一次 selectLine 生效，
  /// 用于解决"全集 N 条线路切换需各自重新解析"：调用方先 resolve 新 ep.url
  /// 并包装为 [VideoLine] 传入，避免在 PlayerController 内持有源/服务依赖。
  VideoLine? _pendingLine;
  void setPendingLine(VideoLine line) {
    _pendingLine = line;
  }

  // ─────────────────────── 静音 / 全屏（P8.3.4 §廿四） ───────────────────────

  /// 是否静音。
  bool _isMuted = false;
  bool get isMuted => _isMuted;

  /// 静音前的音量（取消静音时恢复），默认 100。
  double _volumeBeforeMute = 100.0;

  /// 是否处于全屏模式（横屏锁定 + 沉浸式）。
  bool _isFullscreen = false;
  bool get isFullscreen => _isFullscreen;

  /// 切换静音：静音时缓存当前音量；取消静音时恢复。
  Future<void> toggleMute() async {
    if (_isMuted) {
      await _backend.player.setVolume(_volumeBeforeMute);
      _isMuted = false;
    } else {
      // 缓存当前音量（不低于 0），再静音。
      final cur = _backend.player.state.volume;
      if (cur > 0) _volumeBeforeMute = cur;
      await _backend.player.setVolume(0);
      _isMuted = true;
    }
    notifyListeners();
  }

  /// 切换全屏：进入时锁定横屏 + 隐藏系统 UI；退出时还原。
  Future<void> toggleFullscreen() async {
    _isFullscreen = !_isFullscreen;
    try {
      if (_isFullscreen) {
        await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
        await SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.immersiveSticky,
        );
      } else {
        await SystemChrome.setPreferredOrientations(<DeviceOrientation>[]);
        await SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.edgeToEdge,
        );
      }
    } on Object {
      // 测试环境或当前平台不支持，忽略。
    }
    notifyListeners();
  }

  /// Seek 宽限期：seek（或重连后的 seek）后该时长内不触发 stall（卡顿）检测，
  /// 也不视为需要重连。取较大值以覆盖慢速 CDN 的 seek 重新缓冲——m3u8 重新拉取
  /// 分片可能耗时数秒到十几秒，宽限期过短会误判卡顿、触发重连并导致进度清零。
  /// 此常量是 seek 宽限的「唯一标准」，UI 侧 (_onStall) 通过 [isWithinSeekGrace] 复用，
  /// 避免两侧窗口不一致造成「慢速 seek 缓冲」时仍被误判。
  /// 取值偏长（60s）：慢速 CDN 跳到较远进度点后，m3u8 重新拉取该处分片可能耗时十几到几十秒，
  /// 浏览器对同一链接 seek 能正常缓冲即佐证服务端无问题；宽限期过短会在缓冲未完成时误判卡顿
  /// 并触发重连，反而打断缓冲、形成「重连→缓冲→再重连」死循环。
  static const Duration seekGracePeriod = Duration(seconds: 60);

  /// Stall 超时：播放中位置超过该时长未推进则判定为卡顿。
  final Duration _stallTimeout = const Duration(seconds: 10);

  /// 是否仍处于 seek 宽限期内（seek / 重连 seek 后的重新缓冲期间，不应触发重连）。
  /// 供 UI 侧复用以保持与 [_checkStall] 同一判定标准。
  bool get isWithinSeekGrace {
    final now = DateTime.now();
    return now.difference(_lastSeekAt) < seekGracePeriod;
  }

  // ─────────────────────── Stall 检测（P4.1.4） ───────────────────────
  StreamSubscription<Duration>? _stallPositionSub;
  StreamSubscription<bool>? _stallPlayingSub;
  Timer? _stallCheckTimer;
  Duration _lastStallPosition = Duration.zero;
  DateTime _lastPositionAdvancedAt = DateTime.now();
  DateTime _lastSeekAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _isPlayingForStall = false;
  final StreamController<void> _stallController =
      StreamController<void>.broadcast();

  /// Stall（卡顿）事件流：播放中位置超时未推进（超过 [_stallTimeout]）
  /// 且已过 seek 宽限期（[seekGracePeriod]）时触发一次，UI 可据此提示
  /// 并自动重连。
  Stream<void> get stallStream => _stallController.stream;

  void _initStallDetection() {
    _stallPositionSub = _backend.player.stream.position.listen((pos) {
      if (pos != _lastStallPosition) {
        _lastStallPosition = pos;
        _lastPositionAdvancedAt = DateTime.now();
      }
    });
    _stallPlayingSub = _backend.player.stream.playing.listen((playing) {
      _isPlayingForStall = playing;
      if (playing) {
        _lastPositionAdvancedAt = DateTime.now();
      }
    });
    _stallCheckTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _checkStall(),
    );
  }

  void _checkStall() {
    if (!_isPlayingForStall || _stallController.isClosed) return;
    final now = DateTime.now();
    // seek 宽限期内不检测（覆盖慢速 CDN 的重新缓冲）
    if (now.difference(_lastSeekAt) < seekGracePeriod) return;
    // 位置未推进超过 stallTimeout → 触发 stall
    if (now.difference(_lastPositionAdvancedAt) >= _stallTimeout) {
      _stallController.add(null);
      // 重置基准，避免连续重复触发；待位置再次推进后重新计时
      _lastPositionAdvancedAt = now;
    }
  }

  // ────────── 解码异常自动降级（花屏 / 硬解初始化失败自愈） ──────────

  StreamSubscription<PlayerLog>? _decodeLogSub;
  final StreamController<String> _decodeFallbackController =
      StreamController<String>.broadcast();

  /// 解码自动降级事件流：发生降级时推送新的应用层解码模式（'hw+' / 'sw'）。
  /// UI 据此提示用户并 re-open 当前地址使新 hwdec 对已在播的解码器生效。
  Stream<String> get decodeFallbackStream => _decodeFallbackController.stream;

  /// 本会话内是否已发生过自动降级（auto → hw+ 后置位，允许继续降到 sw；
  /// 用户手动切换解码模式时重置，手动选择不参与自动降级链）。
  bool _autoDowngraded = false;

  /// 上次自动降级时刻；冷却期内忽略后续触发，避免同一批错误日志连续降两级。
  DateTime _lastDecodeFallbackAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 降级冷却期：re-open 后旧解码器的残留错误日志不应立即再触发下一级。
  static const Duration decodeFallbackCooldown = Duration(seconds: 30);

  void _initDecodeFallbackDetection() {
    try {
      _decodeLogSub = _backend.player.stream.log.listen((PlayerLog log) {
        if (isHwdecFailureLog(log.level, log.text)) {
          unawaited(_maybeAutoDowngrade());
        }
      });
    } catch (_) {
      // 当前平台无 mpv 日志流（如 Web），自动降级不可用，忽略。
    }
  }

  /// 判定一条 mpv 日志是否属于硬解失败 / 解码异常（自动降级触发条件）。
  ///
  /// 纯函数，便于单测覆盖（构造 PlayerController 需要原生 libmpv）。
  @visibleForTesting
  static bool isHwdecFailureLog(String level, String text) {
    final t = text.toLowerCase();
    if (t.contains('could not initialize hardware decoding')) return true;
    if (t.contains('failed to initialize decoder')) return true;
    final lv = level.toLowerCase();
    if ((lv == 'error' || lv == 'fatal') && t.contains('hwdec')) return true;
    return false;
  }

  /// 自动降级链：auto → hw+（auto-copy，绕开 mediacodec 直通纹理，修花屏首选）
  /// → sw（纯软解兜底）。仅对默认 auto 模式自动降级；用户手动选定的
  /// hw / hw+ / sw 是明确意图，不自动改动。返回 null 表示不降级。
  @visibleForTesting
  static String? nextFallbackHwdec(String current, {required bool autoDowngraded}) {
    switch (current) {
      case 'auto':
        return 'hw+';
      case 'hw+':
        // 仅当 hw+ 是上一步自动降级的结果时才继续降到 sw。
        return autoDowngraded ? 'sw' : null;
      default:
        return null;
    }
  }

  Future<void> _maybeAutoDowngrade() async {
    final now = DateTime.now();
    if (now.difference(_lastDecodeFallbackAt) < decodeFallbackCooldown) return;
    final next =
        nextFallbackHwdec(currentHwdec, autoDowngraded: _autoDowngraded);
    if (next == null) return;
    _lastDecodeFallbackAt = now;
    _autoDowngraded = true;
    // 直接走后端，不走公开 setHwdec（那会被视作手动切换而重置降级链）。
    await _backend.setHwdec(next);
    if (!_decodeFallbackController.isClosed) {
      _decodeFallbackController.add(next);
    }
    notifyListeners();
  }

  // ────────── 播放统计（软/硬解诊断） ──────────

  /// 「播放统计」面板读取的 mpv 只读属性清单。
  static const List<String> statsProperties = <String>[
    'hwdec-current',
    'video-codec',
    'video-format',
    'width',
    'height',
    'frame-drop-count',
    'decoder-frame-drop-count',
    'video-bitrate',
    'cache-buffering-state',
  ];

  /// 查询当前播放统计快照（实际软/硬解状态、编码、分辨率、掉帧等）。
  ///
  /// 平台不支持或尚未开始解码时各字段为 null（[PlayerStats.isEmpty]）。
  Future<PlayerStats> queryStats() async {
    final props = <String, String?>{};
    for (final name in statsProperties) {
      props[name] = await _backend.getProperty(name);
    }
    return PlayerStats.fromProperties(props);
  }

  /// 暴露底层后端（供 Video 控件获取 [Player]）。
  VideoPlayerBackend get backend => _backend;

  /// 暴露底层 [Player] 实例。
  Player get player => _backend.player;

  // ─────────────────────── 播放控制 ───────────────────────

  /// 打开媒体地址。
  ///
  /// [headers] 透传给 mpv 的 HTTP 请求头（反盗链 Referer / UA 等），
  /// 必须与抓取 m3u8 文本时一致，否则 CDN 返回 403、解不出帧。
  Future<void> open(String url, {Map<String, String>? headers}) async {
    await _backend.player.open(Media(url, httpHeaders: headers));
  }

  /// 继续播放。
  Future<void> play() async {
    await _backend.player.play();
  }

  /// 暂停播放。
  Future<void> pause() async {
    await _backend.player.pause();
  }

  /// 跳转到指定位置。
  Future<void> seek(Duration position) async {
    _lastSeekAt = DateTime.now();
    await _backend.player.seek(position);
  }

  /// 设置音量（0–100，自动 clamp），透传底层 [Player.setVolume]。
  Future<void> setVolume(double v) async {
    final clamped = v.clamp(0.0, 100.0);
    volume = clamped;
    await _backend.player.setVolume(clamped);
    notifyListeners();
  }

  // ─────────────────────── 播放线路（FR-3.4） ───────────────────────

  /// 切换到指定播放线路。
  ///
  /// 更新 [currentLineIndex] 并通过 [_openCurrentLine] 重新打开对应 URL；
  /// 越界索引静默忽略。本地 / 直链模式 [lines] 为空，调用方不应触发。
  ///
  /// 切换前可调用 [setPendingLine] 注入已解析的新线路（用于跨线路重新解析
  /// 场景，如详情页 chips 切换多 lineName），[_openCurrentLine] 会优先使用
  /// 注入的线路而忽略该索引处的旧值。
  Future<void> selectLine(int index) async {
    if (index < 0 || index >= lines.length) return;
    currentLineIndex = index;
    notifyListeners();
    await _openCurrentLine();
  }

  /// 重新打开当前选中线路的 URL（复用现有 `_player.open(Media(url))` 入口）。
  ///
  /// 若已通过 [setPendingLine] 注入新线路，则用注入的 line 替换 [lines]
  /// 中当前索引的项并清除注入标记（仅一次生效），用于"切换线路前已重新解析
  /// 完成"的场景；否则按 [lines] 中现有 URL 打开（兜底，常见于初次解析已
  /// 通过 [VideoResult.lines] 提供全部线路的情况）。
  Future<void> _openCurrentLine() async {
    if (lines.isEmpty) return;
    final pending = _pendingLine;
    if (pending != null) {
      _pendingLine = null;
      lines[currentLineIndex] = pending;
    }
    final line = lines[currentLineIndex];
    if (line.url.isEmpty) return;
    await _backend.player.open(Media(line.url, httpHeaders: line.headers));
  }

  // ─────────────────────── 状态流 ───────────────────────

  /// 播放位置流。
  Stream<Duration> get positionStream => _backend.player.stream.position;

  /// 媒体时长流。
  Stream<Duration> get durationStream => _backend.player.stream.duration;

  /// 播放状态流。
  Stream<bool> get playingStream => _backend.player.stream.playing;

  /// 播放完成流。
  Stream<bool> get completedStream => _backend.player.stream.completed;

  /// 缓冲状态流（true=正在缓冲/加载中）。用于 UI 显示加载动画。
  Stream<bool> get bufferingStream => _backend.player.stream.buffering;

  // ─────────────────────── 瞬时状态 ───────────────────────

  /// 当前播放位置。
  Duration get position => _backend.player.state.position;

  /// 媒体总时长。
  Duration get duration => _backend.player.state.duration;

  /// 是否正在播放。
  bool get isPlaying => _backend.player.state.playing;

  /// 是否播放完成。
  bool get isCompleted => _backend.player.state.completed;

  /// 是否正在缓冲（加载中）。
  bool get isBuffering => _backend.player.state.buffering;

  // ─────────────────────── 锁定 ───────────────────────

  /// 切换播放器锁定状态。
  void toggleLock() {
    isLocked = !isLocked;
    notifyListeners();
  }

  // ─────────────────────── 倍速 ───────────────────────

  /// 设置播放倍速。
  Future<void> setPlaybackSpeed(double speed) async {
    playbackSpeed = speed;
    await _backend.player.setRate(speed);
    notifyListeners();
  }

  // ─────────────────────── 字幕 ───────────────────────

  /// 可用字幕轨道列表（实时快照，来自底层 [Player.state.tracks]）。
  List<SubtitleTrack> get subtitleTracks =>
      _backend.player.state.tracks.subtitle;

  /// 用户选中的字幕轨道（偏好，关闭显示时仍保留以便恢复）。
  SubtitleTrack? _currentSubtitleTrack;
  SubtitleTrack? get currentSubtitleTrack => _currentSubtitleTrack;

  /// 字幕偏移（限制在 ±5s）。
  Duration _subtitleDelay = Duration.zero;
  Duration get subtitleDelay => _subtitleDelay;

  /// 字幕显示开关。
  bool _subtitleVisible = false;
  bool get subtitleVisible => _subtitleVisible;

  /// 可用轨道变更流（含音频 / 视频 / 字幕）。
  Stream<Tracks> get tracksStream => _backend.player.stream.tracks;

  /// 当前选中轨道变更流。
  Stream<Track> get trackStream => _backend.player.stream.track;

  /// 设置字幕轨道。传 null 关闭字幕并清除偏好。
  Future<void> setSubtitleTrack(SubtitleTrack? track) async {
    if (track == null) {
      await _backend.player.setSubtitleTrack(SubtitleTrack.no());
      _currentSubtitleTrack = null;
      _subtitleVisible = false;
    } else {
      await _backend.player.setSubtitleTrack(track);
      _currentSubtitleTrack = track;
      _subtitleVisible = true;
    }
    notifyListeners();
  }

  /// 设置字幕偏移，自动限制在 -5s~+5s（通过 mpv `sub-delay` 属性生效）。
  Future<void> setSubtitleDelay(Duration delay) async {
    final ms = delay.inMilliseconds.clamp(-5000, 5000);
    _subtitleDelay = Duration(milliseconds: ms);
    try {
      final platform = _backend.player.platform;
      if (platform is NativePlayer) {
        await platform.setProperty(
          'sub-delay',
          (ms / 1000.0).toStringAsFixed(3),
        );
      }
    } catch (_) {
      // 当前平台不支持 mpv 属性设置（如 Web），忽略。
    }
    notifyListeners();
  }

  /// 切换字幕显示开关。关闭时记住当前轨道，开启时恢复。
  Future<void> setSubtitleVisible(bool visible) async {
    if (visible == _subtitleVisible) return;
    if (visible) {
      final track = _currentSubtitleTrack;
      if (track != null) {
        await _backend.player.setSubtitleTrack(track);
      }
      _subtitleVisible = true;
    } else {
      await _backend.player.setSubtitleTrack(SubtitleTrack.no());
      _subtitleVisible = false;
    }
    notifyListeners();
  }

  // ─────────────────────── 字幕样式（mpv sub-* 属性） ───────────────────────

  /// 设置字幕属性（透传 mpv sub-* 键值对）。
  ///
  /// 平台不支持时（如 Web）静默忽略。
  Future<void> _setSubProperty(String name, String value) async {
    try {
      final platform = _backend.player.platform;
      if (platform is NativePlayer) {
        await platform.setProperty(name, value);
      }
    } catch (_) {
      // 当前平台不支持 mpv 属性设置，忽略。
    }
  }

  /// 字幕字体名称（如 "Sans", "Serif"）。
  Future<void> setSubtitleFont(String font) async {
    await _setSubProperty('sub-font', font);
    notifyListeners();
  }

  /// 字号（像素值，如 "28", "36"）。
  Future<void> setSubtitleFontSize(double size) async {
    await _setSubProperty('sub-font-size', size.toStringAsFixed(1));
    notifyListeners();
  }

  /// 字幕颜色（BGR 十六进制，如 "FFFFFF"=白, "00FFFF"=黄）。
  Future<void> setSubtitleColor(String color) async {
    await _setSubProperty('sub-color', color);
    notifyListeners();
  }

  /// 字幕边框颜色（BGR 十六进制）。
  Future<void> setSubtitleBorderColor(String color) async {
    await _setSubProperty('sub-border-color', color);
    notifyListeners();
  }

  /// 字幕边框宽度（像素值）。
  Future<void> setSubtitleBorderSize(double size) async {
    await _setSubProperty('sub-border-size', size.toStringAsFixed(1));
    notifyListeners();
  }

  /// 字幕阴影颜色（BGR 十六进制）。
  Future<void> setSubtitleShadowColor(String color) async {
    await _setSubProperty('sub-shadow-color', color);
    notifyListeners();
  }

  /// 字幕阴影偏移（像素值）。
  Future<void> setSubtitleShadowOffset(double offset) async {
    await _setSubProperty('sub-shadow-offset', offset.toStringAsFixed(1));
    notifyListeners();
  }

  /// 字幕缩放比例（如 "1.5" 放大 50%）。
  Future<void> setSubtitleScale(double scale) async {
    await _setSubProperty('sub-scale', scale.toStringAsFixed(2));
    notifyListeners();
  }

  /// 字幕垂直位置（"top", "center", "bottom" 或 0-100 百分比）。
  Future<void> setSubtitlePosition(String pos) async {
    await _setSubProperty('sub-pos', pos);
    notifyListeners();
  }

  /// 是否覆盖 ASS/SSA 样式（"yes"/"no"/"strip"/"force"）。
  Future<void> setSubtitleAssOverride(String mode) async {
    await _setSubProperty('sub-ass-override', mode);
    notifyListeners();
  }

  // ─────────────────────── 后端能力委托 ───────────────────────

  /// 设置硬件解码模式（委托后端）。手动切换会重置自动降级链：
  /// 用户重新选 auto 后若再次检测到解码异常，降级链从头开始。
  Future<void> setHwdec(String mode) async {
    _autoDowngraded = false;
    await _backend.setHwdec(mode);
    notifyListeners();
  }

  /// 设置音频通道（委托后端）。
  Future<void> setAudioChannel(String channel) async {
    await _backend.setAudioChannel(channel);
    notifyListeners();
  }

  /// 设置画面比例（委托后端）。
  Future<void> setAspectRatio(String ratio) async {
    await _backend.setAspectRatio(ratio);
    notifyListeners();
  }

  /// 当前解码模式。
  String get currentHwdec => _backend.currentHwdec;

  /// 当前音频通道。
  String get currentAudioChannel => _backend.currentAudioChannel;

  /// 当前画面比例。
  String get currentAspectRatio => _backend.currentAspectRatio;

  @override
  /// 串行化用：上一次 [Player.dispose()] 的 Future。播放器页面创建新 [VideoController]
  /// 前会 await 它，确保旧原生 VideoOutput（media_kit 纹理）释放完成，避免退出重进时
  /// 新旧 surface 冲突（Lost connection to device）。
  static Future<void>? _pendingDisposal;

  /// 供播放器页面 await：若上一次播放器仍在异步释放，则等待其完成；否则立即返回。
  static Future<void> get pendingDisposal =>
      _pendingDisposal ?? Future<void>.value();

  @override
  void dispose() {
    _stallCheckTimer?.cancel();
    _stallPositionSub?.cancel();
    _stallPlayingSub?.cancel();
    _stallController.close();
    _decodeLogSub?.cancel();
    _decodeFallbackController.close();
    // 退出时若仍处于全屏，还原方向与系统 UI（P8.3.4 §廿四）
    if (_isFullscreen) {
      try {
        SystemChrome.setPreferredOrientations(<DeviceOrientation>[]);
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      } on Object {
        // 测试环境忽略。
      }
    }
    super.dispose();
    // 触发底层 Player.dispose()（含原生 VideoOutput 释放）并记下其 Future，
    // 供下一次进入播放器时 await，避免新旧 surface 冲突。
    _pendingDisposal = _backend.player.dispose();
  }
}

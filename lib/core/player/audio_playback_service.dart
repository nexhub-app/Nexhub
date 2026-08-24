/// 后台播放 + 系统媒体通知（F-25）。
///
/// 通过 audio_service 暴露通知栏 / 锁屏媒体控件（播放/暂停/进度/上一集/下一集），
/// 配合 audio_session 处理音频打断（来电暂停 + 结束恢复）与拔耳机暂停。
///
/// 设计约束：播放器是「每页一个 PlayerController」的生命周期（进入创建 / 退出销毁，
/// 见 video_player_screen 的 pendingDisposal 机制），本服务不持有任何播放器——
/// 播放页通过 [attach] 注册回调与流、退出时 [detach]，handler 仅做转发。
///
/// 代次令牌（token）：跨作品连播用 pushReplacement 换页，新页 attach 可能先于
/// 旧页 dispose 执行，若按「无脑清空」处理会把新会话误清。attach 返回递增 token，
/// detach 仅在 token 与当前代次一致时生效，旧页的迟到 detach 自然作废。
library;

import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';

import '../utils/app_log.dart';

/// 一次后台播放会话：播放页注册的元数据、状态流与控制回调。
///
/// 回调在 handler 收到系统媒体控件指令时被调用（通知栏按钮 / 锁屏 / 耳机线控 /
/// 蓝牙）。所有回调由播放页提供，本层不感知 PlayerController。
///
/// X-5：TTS 朗读等「无进度」会话可传 null 的 [positionStream] / [durationStream]
/// （通知栏不显示进度条，仅标题 + 播放/暂停/上一句/下一句控件）。
class AudioPlaybackSession {
  const AudioPlaybackSession({
    required this.id,
    required this.title,
    required this.artist,
    this.positionStream,
    this.durationStream,
    required this.playingStream,
    required this.onPlay,
    required this.onPause,
    required this.onSeek,
    this.onNext,
    this.onPrev,
  });

  /// 媒体条目 ID（作品 + 剧集维度，切集时变化以刷新通知标题）。
  final String id;

  /// 通知标题（集名 / 文件名 / TTS 章节名）。
  final String title;

  /// 通知副标题（作品名）。
  final String? artist;

  /// 播放进度流；null = 无进度概念（TTS），通知栏不显示进度条。
  final Stream<Duration>? positionStream;
  final Stream<Duration>? durationStream;

  /// 播放/暂停状态流（必须提供，通知栏图标与锁屏控件依赖它）。
  final Stream<bool> playingStream;

  final Future<void> Function() onPlay;
  final Future<void> Function() onPause;
  final Future<void> Function(Duration position) onSeek;

  /// 下一集 / 上一句（TTS）；null 时通知栏不显示对应按钮。
  final Future<void> Function()? onNext;
  final Future<void> Function()? onPrev;
}

/// audio_service handler：转发系统媒体控件指令到当前会话，并按流刷新通知状态。
class _PlaybackHandler extends BaseAudioHandler with SeekHandler {
  AudioPlaybackSession? _session;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<bool>? _playingSub;

  /// 通知进度推送节流（position 流 4-10Hz，通知栏 1Hz 足够）。
  DateTime _lastPositionPushAt = DateTime.fromMillisecondsSinceEpoch(0);
  Duration _lastKnownPosition = Duration.zero;

  /// 是否有活跃会话（供 stop 兜底判断）。
  bool get hasSession => _session != null;

  void updateSession(AudioPlaybackSession session) {
    _cancelSubs();
    _session = session;
    _lastKnownPosition = Duration.zero;
    _lastPositionPushAt = DateTime.fromMillisecondsSinceEpoch(0);
    mediaItem.add(MediaItem(
      id: session.id,
      title: session.title,
      artist: session.artist,
    ));
    // 初始 playing 态未知，先按暂停图标出通知（流首事件很快纠正）。
    _pushState(playing: false, position: Duration.zero);
    // X-5：duration/position 流可为 null（TTS 无进度），此时不订阅进度推送。
    final Stream<Duration>? durationStream = session.durationStream;
    if (durationStream != null) {
      _durationSub = durationStream.listen((d) {
        if (d <= Duration.zero) return;
        final item = mediaItem.valueOrNull;
        // 同一集 duration 反复回调（seek/缓冲都会重发），只在变化时更新。
        if (item == null || item.duration == d) return;
        mediaItem.add(item.copyWith(duration: d));
      });
    }
    final Stream<Duration>? positionStream = session.positionStream;
    if (positionStream != null) {
      _positionSub = positionStream.listen((p) {
        _lastKnownPosition = p;
        final now = DateTime.now();
        if (now.difference(_lastPositionPushAt) < const Duration(seconds: 1)) {
          return;
        }
        _lastPositionPushAt = now;
        _pushState(playing: null, position: p);
      });
    }
    _playingSub = session.playingStream.listen((playing) {
      _pushState(playing: playing, position: _lastKnownPosition);
    });
  }

  void clear() {
    _cancelSubs();
    _session = null;
    mediaItem.add(const MediaItem(id: '_none', title: ''));
    playbackState.add(PlaybackState());
  }

  void _cancelSubs() {
    _positionSub?.cancel();
    _positionSub = null;
    _durationSub?.cancel();
    _durationSub = null;
    _playingSub?.cancel();
    _playingSub = null;
  }

  /// 统一刷新通知栏状态。[playing] 为 null 表示保持当前值（仅更新进度）。
  void _pushState({bool? playing, required Duration position}) {
    final s = _session;
    final prev = playbackState.value;
    final List<MediaControl> controls = <MediaControl>[
      if (s?.onPrev != null) MediaControl.skipToPrevious,
      if (playing ?? prev.playing)
        MediaControl.pause
      else
        MediaControl.play,
      if (s?.onNext != null) MediaControl.skipToNext,
    ];
    playbackState.add(prev.copyWith(
      controls: controls,
      androidCompactActionIndices: const <int>[0, 1, 2],
      updatePosition: position,
      bufferedPosition: position,
      playing: playing ?? prev.playing,
      processingState: AudioProcessingState.ready,
    ));
  }

  @override
  Future<void> play() async {
    final s = _session;
    if (s == null) return;
    // 乐观更新图标，避免慢网络下按钮无反馈。
    _pushState(playing: true, position: _lastKnownPosition);
    await s.onPlay();
  }

  @override
  Future<void> pause() async {
    final s = _session;
    if (s == null) return;
    _pushState(playing: false, position: _lastKnownPosition);
    await s.onPause();
  }

  /// 系统侧重启（通知被划掉后重新点按 / Android 13 重建）：无会话时忽略。
  @override
  Future<void> stop() async {
    // 仅解除通知与前台服务，不回调底层暂停（detach 时播放页正在销毁，
    // 触碰控制器会报错；通知为 ongoing 不可手动划掉，stop 只来自 detach）。
    clear();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) async {
    final s = _session;
    if (s == null) return;
    _lastKnownPosition = position;
    _lastPositionPushAt = DateTime.now();
    _pushState(playing: null, position: position);
    await s.onSeek(position);
  }

  @override
  Future<void> skipToNext() async => _session?.onNext?.call();

  @override
  Future<void> skipToPrevious() async => _session?.onPrev?.call();
}

/// 全局后台播放服务单例。
///
/// 平台支持：audio_service 0.18 支持 Android / iOS / macOS；Windows / Web 不支持，
/// 这些平台上 [attach] / [detach] 为无操作（行为不变，仅无通知栏）。
class AudioPlaybackService {
  AudioPlaybackService._();

  static final AudioPlaybackService instance = AudioPlaybackService._();

  /// 通知渠道名（系统声音设置里可见；非应用 UI，不走 l10n）。
  static const String notificationChannelName = 'NexHub Playback';

  _PlaybackHandler? _handler;
  bool _initStarted = false;
  Future<void>? _initFuture;

  /// 会话代次：attach 自增并作为 token 返回；detach 仅在代次一致时生效。
  int _generation = 0;

  StreamSubscription<void>? _becomingNoisySub;
  StreamSubscription<AudioInterruptionEvent>? _interruptionSub;

  /// 音频打断前是否在播放（打断结束据此决定是否恢复）。
  bool _playingBeforeInterruption = false;

  /// 当前平台是否支持 audio_service（Windows / Web 不支持，静默降级）。
  bool get _supported =>
      !kIsWeb &&
      (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

  /// 幂等初始化。main() 启动期调用一次；attach 内部也会兜底等待。
  Future<void> initialize() {
    if (_initFuture != null) return _initFuture!;
    _initStarted = true;
    _initFuture = _initializeSlow();
    return _initFuture!;
  }

  Future<void> _initializeSlow() async {
    if (!_supported) return;
    try {
      _handler = await AudioService.init(
        builder: () => _PlaybackHandler(),
        config: AudioServiceConfig(
          androidNotificationChannelName: notificationChannelName,
          androidNotificationChannelId: 'nexhub.playback',
          androidNotificationOngoing: true,
          androidStopForegroundOnPause: false,
        ),
      );
      await _configureAudioSession();
    } on Object catch (e, st) {
      // 初始化失败不影响前台播放，仅无后台通知。
      AppLog.instance.eWithStack('[后台播放] audio_service 初始化失败', e, st);
      _handler = null;
    }
  }

  /// audio_session：music 类别 + 拔耳机暂停 + 来电打断自动暂停/恢复。
  Future<void> _configureAudioSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      _becomingNoisySub ??= session.becomingNoisyEventStream.listen((_) {
        // 拔耳机 / 断蓝牙：立即暂停，避免外放尴尬。
        unawaited(_handler?.pause());
      });
      _interruptionSub ??= session.interruptionEventStream.listen((event) {
        final handler = _handler;
        if (handler == null) return;
        if (event.begin) {
          _playingBeforeInterruption = handler.playbackState.value.playing;
          unawaited(handler.pause());
        } else if (_playingBeforeInterruption) {
          // 打断结束（通话挂断）且打断前在播：恢复播放。
          _playingBeforeInterruption = false;
          unawaited(handler.play());
        }
      });
    } on Object catch (e, st) {
      AppLog.instance.eWithStack('[后台播放] audio_session 配置失败', e, st);
    }
  }

  /// 注册当前播放页会话，返回代次 token（供 [detach] 校验）。
  ///
  /// 同步返回 token、内部异步完成初始化与流订阅；若期间被新会话取代
  /// （token 过期），订阅自动作废。
  int attach(AudioPlaybackSession session) {
    _generation++;
    final int token = _generation;
    if (!_supported) return token;
    unawaited(_attachSlow(token, session));
    return token;
  }

  Future<void> _attachSlow(int token, AudioPlaybackSession session) async {
    await initialize();
    final handler = _handler;
    if (handler == null) return;
    if (token != _generation) return;
    handler.updateSession(session);
    // 前台媒体服务（通知栏 + 锁屏控件）由 AudioService.init + 设置 mediaItem/
    // playbackState 自动拉起（audio_service 0.18 无需再调 start()）。前台服务
    // 使应用进后台时不被 OS 挂起，配合 androidStopForegroundOnPause=false，
    // 「后台播放」可持续（音频继续解码）。
  }

  /// 注销会话（播放页 dispose 时调用）。token 与当前代次不一致时忽略
  /// （新播放页已接管，pushReplacement 换页场景）。
  void detach(int token) {
    if (!_supported) return;
    if (token != _generation) return;
    _generation++;
    // 停止前台服务、移除通知（audio_service 0.18 用 handler.stop，而非已废弃的
    // AudioService.stop）。通知为 ongoing 不可手动划掉，故仅此处置调用。
    unawaited(_handler?.stop().catchError((Object _) {}));
  }
}

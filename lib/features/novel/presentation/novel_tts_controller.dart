/// 小说阅读器 TTS 朗读控制器（P3.1）。
///
/// 封装 flutter_tts，提供逐段朗读、暂停/恢复/停止、自动翻段功能。
/// 朗读状态通过 [notifyListeners] 广播，阅读器据此更新 UI。
/// P2-3：支持在线 HTTP TTS 引擎（[novel_http_tts_player.dart]），
/// 由配置 [NovelHttpTtsConfig] 启用时优先走在线管线。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../../core/novel/novel_http_tts_config.dart';
import '../../../core/novel/novel_http_tts_player.dart';
import '../../../core/novel/novel_http_tts_sentence_player.dart';

enum NovelTtsState {
  stopped,
  playing,
  paused,
}

class NovelTtsController extends ChangeNotifier {
  NovelTtsController();

  FlutterTts? _tts;
  NovelTtsState _state = NovelTtsState.stopped;
  int _currentIndex = 0;
  List<String> _paragraphs = const <String>[];

  /// P2-3 在线引擎的活跃播放会话（朗读中非空，用于取消）。
  NovelHttpTtsPlayer? _onlinePlayer;

  double _rate = 1.0;
  Timer? _sleepTimer;
  Duration? _sleepRemaining;
  bool _backgroundMode = false;

  /// 引擎当前是否正在朗读某一句。用于"点按切换段落"时先 [FlutterTts.stop]
  /// 打断旧句、再朗读新句（flutter_tts 4.2.5 无 setQueueMode，用 stop+speak
  /// 模拟 QUEUE_FLUSH，避免旧句播完才接新句——"仍朗读之前的句子"）。
  bool _isSpeaking = false;

  NovelTtsState get state => _state;
  int get currentIndex => _currentIndex;
  bool get isPlaying => _state == NovelTtsState.playing;
  bool get isPaused => _state == NovelTtsState.paused;
  double get rate => _rate;
  Duration? get sleepRemaining => _sleepRemaining;
  bool get hasSleepTimer => _sleepTimer != null;
  bool get backgroundMode => _backgroundMode;

  /// 设置后台朗读开关：true 时应用进入后台仍继续朗读；
  /// false 时进入后台由调用方（AppLifecycle 监听）触发 [pause]。
  void setBackground(bool enabled) {
    if (_backgroundMode == enabled) return;
    _backgroundMode = enabled;
    notifyListeners();
  }

  /// 初始化 TTS 引擎（懒加载）。
  Future<void> _ensureTts() async {
    if (_tts != null) return;
    _tts = FlutterTts();
    // 先挂完成回调，确保初始化任何一步失败也不会漏掉（此前 setQueueMode
    // 在 4.2.5 无原生实现会抛 MissingPluginException，导致回调从未注册、
    // 读完一句即停）。
    _tts!.setCompletionHandler(_onComplete);
    await _tts!.setLanguage('zh-CN');
    await _tts!.setSpeechRate(_rate);
  }

  /// 开始朗读段落列表，从指定索引开始。
  ///
  /// [sleepTimer] 为睡眠定时（分钟）；> 0 时启动后自动开启定时器，
  /// 到时停止朗读。用于 prefs.ttsSleepTimer 持久化恢复。
  ///
  /// P2-3：优先使用在线 HTTP TTS 引擎（配置启用且有模板时）。
  Future<void> speak(List<String> paragraphs,
      {int startIndex = 0, int sleepTimer = 0}) async {
    _paragraphs = paragraphs;
    _currentIndex = startIndex.clamp(0, _paragraphs.length - 1);
    _state = NovelTtsState.playing;
    notifyListeners();
    await _setAwake(true);
    if (sleepTimer > 0) {
      startSleepTimer(sleepTimer);
    }
    // P2-3：在线引擎优先。
    final cfg = await NovelHttpTtsConfigStore().load();
    if (cfg.enabled && cfg.urlTemplate.isNotEmpty) {
      _onlinePlayer = NovelHttpTtsPlayer(
        config: cfg,
        player: buildDefaultTtsSentencePlayer(
          cancelled: () => _state == NovelTtsState.stopped,
        ),
      );
      _onlinePlayer!.onCompleted = () {
        if (_state == NovelTtsState.stopped) return;
        _state = NovelTtsState.stopped;
        _isSpeaking = false;
        notifyListeners();
      };
      await _onlinePlayer!.speak(paragraphs);
      _onlinePlayer = null;
      return;
    }
    await _ensureTts();
    await _speakCurrent();
  }

  /// 朗读当前段落。
  ///
  /// 若已在朗读（点按切换 / 上一段下一段），先 [FlutterTts.stop] 打断旧句
  /// 再朗读新句，使切换立即生效（替代不可用 setQueueMode 的 QUEUE_FLUSH）。
  Future<void> _speakCurrent() async {
    if (_tts == null ||
        _currentIndex < 0 ||
        _currentIndex >= _paragraphs.length) {
      _state = NovelTtsState.stopped;
      _isSpeaking = false;
      notifyListeners();
      return;
    }
    if (_isSpeaking) {
      try {
        await _tts!.stop();
      } on Object {
        // 部分平台 stop 可能抛错，忽略后继续朗读新句。
      }
    }
    _isSpeaking = true;
    await _tts!.speak(_paragraphs[_currentIndex]);
  }

  /// 暂停朗读。
  Future<void> pause() async {
    if (_tts == null || _state != NovelTtsState.playing) return;
    await _tts!.pause();
    _state = NovelTtsState.paused;
    _isSpeaking = false;
    notifyListeners();
  }

  /// 恢复朗读。
  Future<void> resume() async {
    if (_tts == null || _state != NovelTtsState.paused) return;
    _state = NovelTtsState.playing;
    notifyListeners();
    await _setAwake(true);
    await _speakCurrent();
  }

  /// 停止朗读。
  Future<void> stop() async {
    _onlinePlayer?.cancel();
    _onlinePlayer = null;
    if (_tts == null) {
      _state = NovelTtsState.stopped;
      _isSpeaking = false;
      _cancelSleepTimer();
      _sleepRemaining = null;
      await _setAwake(false);
      notifyListeners();
      return;
    }
    await _tts!.stop();
    _state = NovelTtsState.stopped;
    _isSpeaking = false;
    _cancelSleepTimer();
    _sleepRemaining = null;
    await _setAwake(false);
    notifyListeners();
  }

  /// 朗读下一段。
  Future<void> next() async {
    if (_currentIndex < _paragraphs.length - 1) {
      _currentIndex++;
      _state = NovelTtsState.playing;
      notifyListeners();
      await _speakCurrent();
    }
  }

  /// 朗读上一段。
  Future<void> prev() async {
    if (_currentIndex > 0) {
      _currentIndex--;
      _state = NovelTtsState.playing;
      notifyListeners();
      await _speakCurrent();
    }
  }

  /// 设置语速（0.5–2.0）。
  Future<void> setRate(double rate) async {
    _rate = rate.clamp(0.5, 2.0);
    await _ensureTts();
    await _tts!.setSpeechRate(_rate);
    notifyListeners();
  }

  /// 启动睡眠定时（分钟；<=0 取消）。到时自动停止朗读。
  void startSleepTimer(int minutes) {
    _cancelSleepTimer();
    if (minutes <= 0) {
      _sleepRemaining = null;
      notifyListeners();
      return;
    }
    _sleepRemaining = Duration(minutes: minutes);
    _sleepTimer = Timer.periodic(const Duration(seconds: 1), (Timer t) {
      final left =
          (_sleepRemaining ?? Duration.zero) - const Duration(seconds: 1);
      if (left <= Duration.zero) {
        _sleepRemaining = null;
        _cancelSleepTimer();
        stop();
      } else {
        _sleepRemaining = left;
        notifyListeners();
      }
    });
    notifyListeners();
  }

  /// 取消睡眠定时。
  void cancelSleepTimer() {
    _sleepRemaining = null;
    _cancelSleepTimer();
    notifyListeners();
  }

  void _cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
  }

  /// 后台保活：朗读时持有唤醒锁，停止时释放（熄屏 / 退后台仍可继续朗读）。
  Future<void> _setAwake(bool on) async {
    try {
      if (on) {
        await WakelockPlus.enable();
      } else {
        await WakelockPlus.disable();
      }
    } on Object {
      // 部分平台不支持唤醒锁，忽略。
    }
  }

  /// 当前段落朗读完毕回调：自动朗读下一段。
  void _onComplete() {
    if (_state != NovelTtsState.playing) return;
    if (_currentIndex < _paragraphs.length - 1) {
      _currentIndex++;
      _isSpeaking = false;
      notifyListeners();
      // 完成事件可能由原生在非平台线程回调，延后到事件循环再朗读下一段，
      // 规避 flutter_tts 通道线程告警（shell.cc: The ... channel sent a
      // message ... on a non-platform thread）。
      Future.microtask(() => _speakCurrent());
    } else {
      _state = NovelTtsState.stopped;
      _isSpeaking = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _cancelSleepTimer();
    _tts?.stop();
    try {
      WakelockPlus.disable();
    } on Object {
      // 忽略
    }
    super.dispose();
  }
}

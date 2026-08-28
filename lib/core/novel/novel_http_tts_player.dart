/// 在线 TTS 播放管线（/ C3-C7）。
///
/// 流程：段落 → [segmentSpeech] 分句 → [HttpTtsPreloader] 受限并发预下载
/// （无网络拉取能力时由业务侧重试/降级）→ 顺序播放每个成功句 → 全部播完
/// 触发续章回调。
///
/// 顺应「默认不内置云端密钥」的约束（用户自建端点模板），本管线只消费
/// [NovelHttpTtsConfig.urlTemplate]，不绑定任何厂商 SDK。
///
/// 播放内核：media_kit（项目既有播放内核）。应用层传递 [playBytes]，
/// 由调用方决定写入临时文件/流式播音——这里保留纯 Dart 可测的核心：
/// 分句 + 预下载调度 + 失败降级策略 + 顺序播放循环。
library;

import 'dart:typed_data';

import 'novel_http_tts_config.dart';
import 'novel_http_tts_engine.dart';
import 'novel_speech_segmenter.dart';

/// 单句播放结果：成功 / 跳过（静音占位）/ 终止（连续失败达阈值）。
enum TtsSentenceOutcome {
  /// 播放成功（或成功并入队列）。
  played,

  /// 合成失败且配置静音占位：跳过继续。
  skipped,

  /// 合成失败且配置禁止占位（或已达连续失败阈值）：终止本轮。
  aborted,
}

/// 按句播放回调：给定预合成的音频字节，返回该句是否播放成功
/// （回调内部实现实际播放：media_kit / 系统播放器等）。
typedef TtsSentencePlayer = Future<bool> Function(Uint8List bytes);

/// 在线 TTS 播放控制器（与播放内核解耦，核心调度可单测）。
class NovelHttpTtsPlayer {
  NovelHttpTtsPlayer({
    required this.config,
    required this.player,
    HttpTtsPreloader? preloader,
  }) : _preloader = preloader ?? HttpTtsPreloader(config: config);

  final NovelHttpTtsConfig config;
  final TtsSentencePlayer player;
  final HttpTtsPreloader _preloader;

  /// 全部段落播完回调（自动续章 C6 的触发点）。
  void Function()? onCompleted;

  /// 当前句索引（调试 / UI 高亮）。
  int currentIndex = 0;

  bool _cancelled = false;

  /// 取消本轮朗读（停止后续合成与播放）。
  void cancel() => _cancelled = true;

  /// 朗读一组段落。
  ///
  /// 1. 逐段分句（[segmentSpeech]）；
  /// 2. 统一受限并发预下载（Semaphore 1-8）；
  /// 3. 按句调 [player] 播放字节；
  /// 4. 连续失败达阈值 → 终止剩余（C6）；单句失败且允许占位 → 跳过（C7）。
  Future<void> speak(List<String> paragraphs) async {
    _cancelled = false;
    currentIndex = 0;
    // 1) 分句。
    final sentences = <(String, String)>[];
    for (final p in paragraphs) {
      for (final seg in segmentSpeech(p)) {
        sentences.add((seg.text, seg.role));
      }
    }
    if (sentences.isEmpty) return;

    // 2) 预下载（受限并发；失败计入连续计数）。
    final results =
        await _preloader.synthesizeAll(sentences: sentences);

    // 3) 顺序播放。
    for (var i = 0; i < sentences.length; i++) {
      if (_cancelled) return;
      currentIndex = i;
      final bytes = results[i].bytes;
      if (bytes == null) {
        // 合成失败：（顺带计入 `_preloader.consecutiveFailures`，见
        // synthesizeOne 内部递增）。
        if (!config.silentPlaceholderOnFailure) {
          // C7 关闭静音占位 → 严格模式：单句失败立即终止本轮。
          return;
        }
        // C6 连续失败达阈值 → 终止剩余（兜底，即使占位开启）。
        if (_preloader.halted) return;
        // C7 静音占位：跳过该句继续。
        continue;
      }
      final ok = await player(bytes);
      if (!ok) {
        // 播放失败按合成失败同策略降级。
        if (config.silentPlaceholderOnFailure) continue;
        return;
      }
    }
    onCompleted?.call();
  }
}
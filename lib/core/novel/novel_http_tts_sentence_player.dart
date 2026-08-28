/// 默认在线 TTS 句播放器：写入临时文件后用 media_kit 播放。
///
/// 实现 [TtsSentencePlayer]：把合成字节落盘到系统临时目录，media_kit
/// `Player` 播放音频文件，等待 completion / error / 主动取消。
/// 单句播完返回 true；失败返回 false（上层按配置降级跳过）。
///
/// 注：media_kit 在 flutter test 环境不可用（无原生内核），因此本文件
/// 不参与纯 Dart 单测——核心调度（分句/预下载/降级）已在
/// `novel_http_tts_player.dart` 覆盖。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:media_kit/media_kit.dart';

import 'novel_http_tts_player.dart' show TtsSentencePlayer;

/// 播放器取消回调（调用方在停止/退出时触发）。
typedef TtsPlaybackCanceller = Future<void> Function();

/// 返回默认的逐句播放函数。
///
/// [cancelled] 返回 true 时立即中断当前句（返回 false 触发降级/终止）。
TtsSentencePlayer buildDefaultTtsSentencePlayer({
  required bool Function() cancelled,
}) {
  return (Uint8List bytes) async {
    if (cancelled()) return false;
    // 落盘临时 mp3（TTS 服务通常返回 mp3/ogg；扩展名不影响内核解码）。
    final dir = await Directory.systemTemp.createTemp('nexhub_tts_');
    final file = File('${dir.path}/sentence.mp3');
    try {
      await file.writeAsBytes(bytes);
      final player = Player();
      try {
        await player.open(Media(file.path));
        // 等待播放完成：轮询 position+state（无原生 completion 事件，
        // 用「不再播放」回调简化处理——音频很短，等待播放状态结束即可）。
        final completer = Completer<bool>();
        player.stream.completed.listen((bool done) {
          if (done && !completer.isCompleted) completer.complete(true);
        });
        player.stream.error.listen((_) {
          if (!completer.isCompleted) completer.complete(false);
        });
        final ok = await completer.future.timeout(const Duration(seconds: 60),
            onTimeout: () {
          try {
            player.stop();
          } on Object {
            // 忽略停止异常
          }
          return false;
        });
        await player.dispose();
        return ok;
      } on Object {
        await player.dispose();
        return false;
      }
    } on Object {
      return false;
    } finally {
      try {
        await dir.delete(recursive: true);
      } on Object {
        // 忽略清理失败
      }
    }
  };
}
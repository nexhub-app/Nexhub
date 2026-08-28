/// 在线 HTTP TTS 引擎（/ C3-C7）。
///
/// 职责（与播放解耦，核心逻辑可单测）：
/// - **模板渲染**：[renderUrl] 把 `{text}` / `{voice}` / `{rate}` 占位符
///   替换为实际值（文本 URL 编码防止非法字符破坏端点语义）；
/// - **预下载队列**：[HttpTtsPreloader] 用 Dio GET 音频字节，
///   Semaphore 并发上限 1-8（[NovelHttpTtsConfig.concurrency]）；
/// - **失败降级**：连续失败达 [NovelHttpTtsConfig.maxConsecutiveFailures]
///   时返回失败标记停止本轮（C6）；单句失败可配置「静音占位」跳过继续
///   （C7），返回 null 表示该句无音频（调用方以静默跳过占位）。
///
/// 播放层不在本引擎内：引擎产出「可播放音频 URL / 字节」，由 TTS 控制器
/// 决定用 media_kit 还是其它播放器顺序播放。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'novel_http_tts_config.dart';

/// 合成单句音频的请求结果。
class TtsSynthesisResult {
  /// 音频字节（合成成功）；null = 合成失败（应静音占位或停止）。
  final Uint8List? bytes;

  /// 对应句子的角色（用于日志/多角色调试）。
  final String role;

  const TtsSynthesisResult({required this.bytes, required this.role});
}

/// 预下载队列：串行/受限并发拉取一组句子的音频。
///
/// 语义：
/// - 并发上限 = [config.concurrency]（Semaphore，1-8）；
/// - 任一句失败 → 按配置降级：静音占位（跳过继续）/ 立即停止；
/// - 连续失败 ≥ [config.maxConsecutiveFailures] → 停止本轮（C6）。
class HttpTtsPreloader {
  HttpTtsPreloader({
    required this.config,
    Dio Function()? dioFactory,
  }) : _dioFactory = dioFactory ?? _defaultDio;

  final NovelHttpTtsConfig config;
  final Dio Function() _dioFactory;

  /// 当前连续失败句数（引擎/控制器周期复位）。
  int consecutiveFailures = 0;

  /// 是否因连续失败达到阈值而停止（本轮内不再合成）。
  bool get halted => consecutiveFailures >= config.maxConsecutiveFailures;

  static Dio _defaultDio() => Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 60),
      ));

  /// 合成单句（低层：不参与并发/降级决策，仅渲染 URL + GET 字节）。
  Future<TtsSynthesisResult> synthesizeOne({
    required String text,
    required String role,
  }) async {
    final url = renderUrl(
      template: config.urlTemplate,
      text: text,
      voice: config.voiceForRole(role),
      rate: 1.0,
    );
    final dio = _dioFactory();
    try {
      final resp = await dio.get<List<int>>(
        url,
        options: Options(responseType: ResponseType.bytes),
      );
      consecutiveFailures = 0; // 成功复位连续失败计数
      return TtsSynthesisResult(
        bytes: resp.data == null ? null : Uint8List.fromList(resp.data!),
        role: role,
      );
    } on Object {
      consecutiveFailures++;
      return TtsSynthesisResult(bytes: null, role: role);
    } finally {
      dio.close(force: true);
    }
  }

  /// 按顺序批量合成（受限并发），返回与输入同序的结果列表。
  ///
  /// [onProgress] 每完成一句回调（completed/total）；返回前若已因连续失败
  /// 达到阈值而 halt，剩余句将直接以 null 填充（不再发起请求）。
  Future<List<TtsSynthesisResult>> synthesizeAll({
    required List<(String text, String role)> sentences,
    void Function(int completed, int total)? onProgress,
  }) async {
    final total = sentences.length;
    final results = List<TtsSynthesisResult?>.filled(total, null);
    final sem = Semaphore(config.concurrency.clamp(1, 8));
    var completed = 0;

    Future<void> work(int index) async {
      if (halted) {
        results[index] =
            TtsSynthesisResult(bytes: null, role: sentences[index].$2);
        completed++;
        onProgress?.call(completed, total);
        return;
      }
      final r = await synthesizeOne(
        text: sentences[index].$1,
        role: sentences[index].$2,
      );
      results[index] = r;
      completed++;
      onProgress?.call(completed, total);
    }

    final tasks = <Future<void>>[];
    for (var i = 0; i < total; i++) {
      tasks.add(() async {
        await sem.acquire();
        try {
          await work(i);
        } finally {
          sem.release();
        }
      }());
    }
    await Future.wait<void>(tasks);
    return results.map((r) => r!).toList();
  }
}

/// 轻量信号量（预下载并发控制 1-8）。
class Semaphore {
  Semaphore(this._max);
  final int _max;
  int _taken = 0;
  final List<Completer<void>> _waiters = <Completer<void>>[];

  Future<void> acquire() async {
    if (_taken >= _max) {
      final c = Completer<void>();
      _waiters.add(c);
      await c.future;
    } else {
      _taken++;
    }
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete(); // 把许可让给等待者
    } else {
      _taken--;
    }
  }
}

/// 渲染 URL 模板：{text}（URL 编码） / {voice} / {rate}。
///
/// 未替换成功的占位符保持原样（便于用户排查模板错误）。
String renderUrl({
  required String template,
  required String text,
  String voice = '',
  double rate = 1.0,
}) {
  var out = template;
  if (template.isEmpty) return '';
  out = out.replaceAll('{text}', Uri.encodeQueryComponent(text));
  out = out.replaceAll('{voice}', Uri.encodeQueryComponent(voice));
  out = out.replaceAll('{rate}', rate.toStringAsFixed(1));
  return out;
}

/// 便捷：把字节转 UTF-8 字符串（测试 / 调试用）。
String debugBytesToString(Uint8List bytes) => utf8.decode(bytes, allowMalformed: true);
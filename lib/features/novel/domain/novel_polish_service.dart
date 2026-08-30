/// 小说译文润色服务（F5 多阶段质量：翻译 → 润色 二阶段）。
///
/// 仅在设置开启且用户对已定稿章节显式触发时运行（成本护栏，默认关闭）：
/// - 输入：章节原文 + 初译（分段对齐），按分块大小走 [BatchProtocol] 批量；
/// - 输出：与输入等长的润色译文；术语表注入与冲突检测同初译链路；
/// - 结果由调用方写入 [NovelTranslationManager] 的润色独立槽位
///   （`…|polished`），用户可在对照面板切换初译/润色。
library;

import 'package:dio/dio.dart';

import '../../../core/ai/batch_protocol.dart';
import '../../../core/ai/glossary_manager.dart';
import '../../../core/ai/prompt_builder.dart';
import '../../../core/ai/translation_exception.dart';
import '../../../core/utils/app_log.dart';
import 'novel_summary_service.dart' show NovelSummaryConfig;

/// 译文润色服务。
class NovelPolishService {
  NovelPolishService({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  /// 润色分块大小（润色输入含原文+初译两份文本，块取小些防截断）。
  static const int kPolishChunkSize = 8;

  /// 润色整章译文；返回与 [translations] 等长的润色结果。
  ///
  /// [onProgress] 回调 (已完成段数, 总数)；[glossary] 注入术语约束。
  Future<List<String>> polishParagraphs({
    required NovelSummaryConfig cfg,
    required String lang,
    required List<String> sources,
    required List<String> translations,
    List<GlossaryEntry> glossary = const <GlossaryEntry>[],
    void Function(int done, int total)? onProgress,
  }) async {
    if (sources.length != translations.length) {
      throw const TranslationException('润色输入原文与译文长度不一致');
    }
    final result = List<String>.of(translations);
    for (var start = 0; start < translations.length; start += kPolishChunkSize) {
      final end = (start + kPolishChunkSize).clamp(0, translations.length);
      final srcChunk = sources.sublist(start, end);
      final trChunk = translations.sublist(start, end);
      final user = StringBuffer();
      for (var i = 0; i < trChunk.length; i++) {
        user.writeln('<<<${i + 1}>>>');
        user.writeln('【原文】${srcChunk[i]}');
        user.writeln('【初译】${trChunk[i]}');
      }
      final raw = await _requestBatch(
        cfg,
        lang,
        user.toString(),
        trChunk.length,
        glossary: glossary,
      );
      final parsed = BatchProtocol.decode(raw, trChunk.length);
      if (parsed == null) {
        throw const TranslationException('润色返回格式异常');
      }
      for (var i = 0; i < trChunk.length; i++) {
        result[start + i] = parsed[i];
      }
      onProgress?.call(end, translations.length);
    }
    return result;
  }

  Future<String> _requestBatch(
    NovelSummaryConfig cfg,
    String lang,
    String user,
    int count, {
    List<GlossaryEntry> glossary = const <GlossaryEntry>[],
  }) async {
    final trimmedBase = cfg.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    try {
      final resp = await _dio.post<Map<String, dynamic>>(
        '$trimmedBase/chat/completions',
        options: Options(
          headers: <String, dynamic>{
            'Content-Type': 'application/json',
            if (cfg.apiKey.trim().isNotEmpty)
              'Authorization': 'Bearer ${cfg.apiKey.trim()}',
          },
          sendTimeout: const Duration(seconds: 30),
          receiveTimeout: const Duration(seconds: 120),
        ),
        data: <String, dynamic>{
          'model': cfg.model.trim().isNotEmpty
              ? cfg.model.trim()
              : 'gpt-3.5-turbo',
          'messages': <Map<String, dynamic>>[
            <String, dynamic>{
              'role': 'system',
              'content': PromptBuilder.polishSystemPrompt(
                lang: lang,
                paragraphCount: count,
                glossary: glossary,
              ),
            },
            <String, dynamic>{'role': 'user', 'content': user},
          ],
          'temperature': 0.3,
        },
      );
      final choices = resp.data?['choices'] as List?;
      if (choices == null || choices.isEmpty) {
        throw const TranslationException('AI 返回内容为空');
      }
      final content = (choices.first['message'] as Map?)?['content'] as String?;
      if (content == null || content.trim().isEmpty) {
        throw const TranslationException('AI 返回内容为空');
      }
      return content;
    } on Object catch (e) {
      AppLog.instance.w('[小说润色] 请求失败: $e');
      throw TranslationException.from(e);
    }
  }
}

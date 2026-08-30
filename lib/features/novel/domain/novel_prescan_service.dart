/// 全书预扫描服务（F3）：章节摘要批量生成 + 全书概述汇总。
///
/// 纯云端调用层（编排/落盘由调用方完成）：
/// - **章节摘要**：多个章节片段按 [BatchProtocol] 编号拼成一次请求
///   （每批最多 [_kChaptersPerBatch] 章），返回逐章 1–2 句摘要；
/// - **全书概述**：全部章节摘要汇总为一段约 200 字的概述；
/// - 接口读取翻译功能级配置（与小说翻译同端点）；异常经
///   [TranslationException] 归一化，原始细节入 [AppLog]。
library;

import 'package:dio/dio.dart';

import '../../../core/ai/batch_protocol.dart';
import '../../../core/ai/prompt_builder.dart';
import '../../../core/ai/translation_exception.dart';
import '../../../core/utils/app_log.dart';
import 'novel_summary_service.dart' show NovelSummaryConfig;

/// 一章的预扫描输入（章节开头片段）。
class PrescanChapterInput {
  final String chapterId;
  final String title;

  /// 章节开头文字（建议 400–600 字符，成本与信息量平衡）。
  final String head;

  const PrescanChapterInput({
    required this.chapterId,
    required this.title,
    required this.head,
  });
}

/// 预扫描云端调用。
class NovelPrescanService {
  NovelPrescanService({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  /// 每次请求的章节数上限：摘要是生成任务，批太大易截断。
  static const int chaptersPerBatch = 8;

  /// 概述输入的章节摘要上限（超长书按前 N 章汇总，成本封顶）。
  static const int _kOverviewMaxChapters = 40;

  /// 批量生成章节摘要；返回与 [items] 等长的摘要列表（顺序一致）。
  Future<List<String>> summarizeChapters({
    required NovelSummaryConfig cfg,
    required String lang,
    required List<PrescanChapterInput> items,
  }) async {
    final result = <String>[];
    for (var start = 0; start < items.length; start += chaptersPerBatch) {
      final end = (start + chaptersPerBatch).clamp(0, items.length);
      final batch = items.sublist(start, end);
      final user = StringBuffer();
      for (var i = 0; i < batch.length; i++) {
        final head = batch[i].head.trim().isEmpty
            ? '（正文片段缺失，仅依据章节名）'
            : batch[i].head.trim();
        user.writeln('<<<${result.length + i + 1}>>>');
        user.writeln('《${batch[i].title}》：$head');
      }
      final content = await _post(
        cfg,
        system: PromptBuilder.prescanChapterSystemPrompt(lang: lang),
        user: user.toString(),
      );
      final parsed = BatchProtocol.decode(content, batch.length);
      if (parsed == null) {
        throw const TranslationException('预扫描返回格式异常');
      }
      result.addAll(parsed);
    }
    return result;
  }

  /// 汇总全书概述（约 200 字）。
  Future<String> bookOverview({
    required NovelSummaryConfig cfg,
    required String lang,
    required String novelTitle,
    required List<String> chapterSummaries,
  }) async {
    final take = chapterSummaries.take(_kOverviewMaxChapters).toList();
    final user = StringBuffer('《$novelTitle》各章摘要：\n');
    for (var i = 0; i < take.length; i++) {
      user.writeln('${i + 1}. ${take[i]}');
    }
    return _post(
      cfg,
      system: PromptBuilder.prescanOverviewSystemPrompt(lang: lang),
      user: user.toString(),
    );
  }

  Future<String> _post(
    NovelSummaryConfig cfg, {
    required String system,
    required String user,
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
            <String, dynamic>{'role': 'system', 'content': system},
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
      AppLog.instance.w('[预扫描] 请求失败: $e');
      throw TranslationException.from(e);
    }
  }
}

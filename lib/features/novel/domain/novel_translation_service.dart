/// 小说段落翻译服务（O3：双语/段落翻译）。
///
/// 复用 AI 摘要的 OpenAI 兼容配置（[NovelSummarySettings]，baseUrl/apiKey/model），
/// 对当前章节的文本段落逐段翻译：
/// - **批量优先**：全部段落以 `<<<N>>>` 序号分隔拼成一次请求，解析回逐段译文
///   （省 token、快）；
/// - **分块回退**：批量解析段数不齐 / 请求失败时按 [batchSize] 分块重试；
/// - 译文由调用方经 [NovelTranslationManager] 持久化（F5 导出附带同源）。
library;

import 'package:dio/dio.dart';

import '../../../../core/novel/novel_translation_manager.dart';
import 'novel_summary_settings.dart';
import 'novel_summary_service.dart' show NovelSummaryConfig;

/// 段落翻译服务。
class NovelTranslationService {
  NovelTranslationService({
    Dio? dio,
    NovelSummarySettings? settings,
    this.targetLanguage = '中文',
  })  : _dio = dio ?? Dio(),
        _settings = settings ?? NovelSummarySettings.instance;

  final Dio _dio;
  final NovelSummarySettings _settings;

  /// 翻译目标语言描述（提示词用，默认中文）。
  final String targetLanguage;

  /// 批量分隔标记（行首独立出现；正文含该串的概率可忽略）。
  static const String batchMarker = '<<<';

  /// 把段落列表编码为单次请求的用户消息。
  static String encodeBatch(List<String> paragraphs) {
    final buf = StringBuffer();
    for (var i = 0; i < paragraphs.length; i++) {
      buf.writeln('$batchMarker${i + 1}>>>');
      buf.writeln(paragraphs[i]);
    }
    return buf.toString();
  }

  /// 解析模型返回的批量译文为逐段列表。
  ///
  /// 宽容策略：以 `<<<N>>>` 行切分；序号缺失/乱序时按出现顺序对位；
  /// 解析出的段数少于 [expected] 或有空槽时返回 null（调用方走分块回退）。
  static List<String>? parseBatched(String raw, int expected) {
    if (raw.trim().isEmpty || expected <= 0) return null;
    final pattern = RegExp(r'<<<\s*(\d+)\s*>>>');
    final matches = pattern.allMatches(raw).toList();
    if (matches.isEmpty) return null;
    // 按标记切出各段译文。
    final parts = <String>[];
    for (var i = 0; i < matches.length; i++) {
      final start = matches[i].end;
      final end = i + 1 < matches.length ? matches[i + 1].start : raw.length;
      parts.add(raw.substring(start, end).trim());
    }
    if (parts.length < expected) return null;
    // 按标记序号对位；序号越界/重复时落入第一个空槽顺延兜底。
    final result = List<String>.filled(expected, '');
    for (var i = 0; i < matches.length; i++) {
      var idx = (int.tryParse(matches[i].group(1)!) ?? (i + 1)) - 1;
      if (idx < 0 || idx >= expected || result[idx].isNotEmpty) {
        idx = result.indexWhere((s) => s.isEmpty);
        if (idx < 0) break;
      }
      result[idx] = parts[i];
    }
    return result.any((s) => s.isEmpty) ? null : result;
  }

  /// 翻译整个段落列表。返回与输入等长的译文列表（失败抛异常，由 UI 展示）。
  ///
  /// [onProgress] 回调 (已完成段数, 总数)，供长章节显示进度。
  Future<List<String>> translateParagraphs(
    List<String> paragraphs, {
    int batchSize = 12,
    void Function(int done, int total)? onProgress,
  }) async {
    if (paragraphs.isEmpty) return const <String>[];
    final cfg = await _settings.getConfig();
    if (cfg.baseUrl.trim().isEmpty) {
      throw Exception('未配置云端 AI 接口');
    }

    // 1) 整章一次批量（最省 token）；失败/解析不齐 → 分块回退。
    try {
      final oneShot = await _requestBatch(paragraphs, cfg);
      final parsed = parseBatched(oneShot, paragraphs.length);
      if (parsed != null) {
        onProgress?.call(paragraphs.length, paragraphs.length);
        return parsed;
      }
    } on Object {
      // 落入分块回退。
    }

    // 2) 分块翻译（每块 batchSize 段，块内仍走批量协议）。
    final result = List<String>.filled(paragraphs.length, '');
    var done = 0;
    for (var start = 0; start < paragraphs.length; start += batchSize) {
      final end = (start + batchSize).clamp(0, paragraphs.length);
      final chunk = paragraphs.sublist(start, end);
      final raw = await _requestBatch(chunk, cfg);
      final parsed =
          parseBatched(raw, chunk.length) ?? (throw Exception('翻译返回格式异常'));
      for (var i = 0; i < chunk.length; i++) {
        result[start + i] = parsed[i];
      }
      done += chunk.length;
      onProgress?.call(done, paragraphs.length);
    }
    return result;
  }

  Future<String> _requestBatch(
      List<String> paragraphs, NovelSummaryConfig cfg) async {
    final trimmedBase = cfg.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
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
        'model':
            cfg.model.trim().isNotEmpty ? cfg.model.trim() : 'gpt-3.5-turbo',
        'messages': <Map<String, dynamic>>[
          <String, dynamic>{
            'role': 'system',
            'content': '你是专业的小说译者。把用户给出的每个编号段落翻译成'
                '$targetLanguage，保持原文的语气与人名译名一致。'
                '输出必须严格保持编号格式：每段译文前单独一行 <<<序号>>>，'
                '不要添加任何解释或合并段落。',
          },
          <String, dynamic>{'role': 'user', 'content': encodeBatch(paragraphs)},
        ],
        'temperature': 0.2,
      },
    );
    final choices = resp.data?['choices'] as List?;
    if (choices == null || choices.isEmpty) {
      throw Exception('empty choices');
    }
    final content = (choices.first['message'] as Map?)?['content'] as String?;
    if (content == null || content.trim().isEmpty) {
      throw Exception('empty content');
    }
    return content;
  }
}

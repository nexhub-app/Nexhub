/// 小说段落翻译服务（O3：双语/段落翻译）。
///
/// 复用 AI 统一配置（[NovelSummarySettings]）：
/// - **翻译级独立接口**优先（AI 配置页），baseUrl 为空时回落通用配置；
/// - 目标语言 / 分块大小读取翻译配置页的设置；
/// - **批量优先**：全部段落以 `<<<N>>>` 序号分隔拼成一次请求，解析回逐段译文
///   （省 token、快）；协议编解码统一走 [BatchProtocol]（B9 收敛单份实现）；
/// - **预算保护**（B3）：段落数超过 [_kOneShotMaxParagraphs] 时直接跳过
///   整章 one-shot 进入分块——超大章的整章请求几乎必被输出上限截断，
///   先试再败只会白付一次大请求的 token/延迟；
/// - **分块回退**：批量解析段数不齐 / 请求失败时按 [batchSize] 分块重试；
/// - 译文由调用方经 [NovelTranslationManager] 持久化（F5 导出附带同源）。
library;

import 'package:dio/dio.dart';

import '../../../core/ai/batch_protocol.dart';
import '../../../core/ai/translation_exception.dart';
import '../../../core/utils/app_log.dart';
import '../../../../core/novel/novel_translation_manager.dart';
import 'novel_summary_settings.dart';
import 'novel_summary_service.dart' show NovelSummaryConfig;

/// 段落翻译服务。
class NovelTranslationService {
  NovelTranslationService({
    Dio? dio,
    NovelSummarySettings? settings,
    String? targetLanguage,
  })  : _dio = dio ?? Dio(),
        _settings = settings ?? NovelSummarySettings.instance,
        _targetLanguage = targetLanguage;

  final Dio _dio;
  final NovelSummarySettings _settings;

  /// 翻译目标语言（提示词用，默认中文）；null 时运行时读翻译配置页设置。
  final String? _targetLanguage;

  /// 单次请求的段落数上限（B3）：超过直接分块，避免必然截断的超大请求。
  static const int _kOneShotMaxParagraphs = 40;

  /// 批量协议编码（兼容旧入口；实现收敛于 [BatchProtocol]，B9）。
  static String encodeBatch(List<String> paragraphs) =>
      BatchProtocol.encode(paragraphs);

  /// 批量协议解析（兼容旧入口；实现收敛于 [BatchProtocol]，B9）。
  static List<String>? parseBatched(String raw, int expected) =>
      BatchProtocol.decode(raw, expected);

  /// 翻译整个段落列表。返回与输入等长的译文列表（失败抛异常，由 UI 展示）。
  ///
  /// [onProgress] 回调 (已完成段数, 总数)，供长章节显示进度。
  Future<List<String>> translateParagraphs(
    List<String> paragraphs, {
    int? batchSize,
    void Function(int done, int total)? onProgress,
  }) async {
    if (paragraphs.isEmpty) return const <String>[];
    final cfg = await _settings.getTranslationConfig();
    if (cfg.baseUrl.trim().isEmpty) {
      throw const TranslationException('未配置云端 AI 接口');
    }
    final lang =
        _targetLanguage ?? await _settings.getTranslationTargetLanguage();
    final chunkSize =
        batchSize ?? await _settings.getTranslationBatchSize();

    // 1) 整章一次批量（最省 token）；超大章（B3）直接跳过——必然截断的
    //    请求不值得先付一次 token/延迟；失败/解析不齐 → 分块回退。
    final bool tryOneShot =
        paragraphs.length <= _kOneShotMaxParagraphs && batchSize == null;
    if (tryOneShot) {
      try {
        final oneShot = await _requestBatch(paragraphs, cfg, lang);
        final parsed = parseBatched(oneShot, paragraphs.length);
        if (parsed != null) {
          onProgress?.call(paragraphs.length, paragraphs.length);
          return parsed;
        }
      } on Object catch (e) {
        // 落入分块回退。
        AppLog.instance.w('[小说翻译] 整章批量失败，转入分块回退: $e');
      }
    }

    // 2) 分块翻译（每块 chunkSize 段，块内仍走批量协议）。
    final result = List<String>.filled(paragraphs.length, '');
    var done = 0;
    for (var start = 0; start < paragraphs.length; start += chunkSize) {
      final end = (start + chunkSize).clamp(0, paragraphs.length);
      final chunk = paragraphs.sublist(start, end);
      final raw = await _requestBatch(chunk, cfg, lang);
      final parsed =
          parseBatched(raw, chunk.length) ?? (throw const TranslationException('翻译返回格式异常'));
      for (var i = 0; i < chunk.length; i++) {
        result[start + i] = parsed[i];
      }
      done += chunk.length;
      onProgress?.call(done, paragraphs.length);
    }
    return result;
  }

  Future<String> _requestBatch(
      List<String> paragraphs, NovelSummaryConfig cfg, String lang) async {
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
              'content': '你是专业的小说译者。把用户给出的每个编号段落翻译成'
                  '$lang，保持原文的语气与人名译名一致。'
                  '本次共 ${paragraphs.length} 段，请完整输出 ${paragraphs.length} 段，'
                  '不要省略或合并。'
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
        throw const TranslationException('AI 返回内容为空');
      }
      final content = (choices.first['message'] as Map?)?['content'] as String?;
      if (content == null || content.trim().isEmpty) {
        throw const TranslationException('AI 返回内容为空');
      }
      return content;
    } on Object catch (e) {
      // B7：网络/超时类底层异常归一化后上抛，原始细节入日志。
      AppLog.instance.w('[小说翻译] 请求失败: $e');
      throw TranslationException.from(e);
    }
  }
}

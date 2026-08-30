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
/// - **术语表与提示词**（F1/F8）：system prompt 由 [PromptBuilder] 组装
///   （术语表 + 风格预设 + CoT + 作品语境），术语冲突在响应侧检测入日志；
/// - **块间衔接**（F2）：每块请求携带上一块最后 2 段的原文+译文，
///   缓解代词指代与语气断裂；
/// - **断点续译**（F4）：[existing] 传入已完成的部分译文（空串 = 待译），
///   已完成块直接复用不发请求；[onChunkPersisted] 供调用方逐块落盘检查点；
/// - 译文由调用方经 [NovelTranslationManager] 持久化（F5 导出附带同源）。
library;

import 'package:dio/dio.dart';

import '../../../core/ai/batch_protocol.dart';
import '../../../core/ai/glossary_manager.dart';
import '../../../core/ai/prompt_builder.dart';
import '../../../core/ai/translation_exception.dart';
import '../../../core/ai/translation_options_store.dart';
import '../../../core/ai/vision_translation_client.dart' show TranslationContextPair;
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
    GlossaryManager? glossary,
    TranslationOptionsStore? options,
  })  : _dio = dio ?? Dio(),
        _settings = settings ?? NovelSummarySettings.instance,
        _targetLanguage = targetLanguage,
        _glossary = glossary ?? GlossaryManager(),
        _options = options ?? TranslationOptionsStore();

  final Dio _dio;
  final NovelSummarySettings _settings;
  final GlossaryManager _glossary;
  final TranslationOptionsStore _options;

  /// 翻译目标语言（提示词用，默认中文）；null 时运行时读翻译配置页设置。
  final String? _targetLanguage;

  /// 单次请求的段落数上限（B3）：超过直接分块，避免必然截断的超大请求。
  static const int _kOneShotMaxParagraphs = 40;

  /// 块间衔接段数（F2）：每块请求携带上一块最后 2 段的原文+译文。
  static const int _kChunkContextPairs = 2;

  /// 批量协议编码（兼容旧入口；实现收敛于 [BatchProtocol]，B9）。
  static String encodeBatch(List<String> paragraphs) =>
      BatchProtocol.encode(paragraphs);

  /// 批量协议解析（兼容旧入口；实现收敛于 [BatchProtocol]，B9）。
  static List<String>? parseBatched(String raw, int expected) =>
      BatchProtocol.decode(raw, expected);

  /// 翻译整个段落列表。返回与输入等长的译文列表（失败抛异常，由 UI 展示）。
  ///
  /// [onProgress] 回调 (已完成段数, 总数)，供长章节显示进度；
  /// [workId] 用于术语表 / 风格的作品级配置（null 时用全局）；
  /// [existing] 为断点续译（F4）的已完成译文（与 [paragraphs] 等长，
  /// 空串表示待译）；[onChunkPersisted] 在每个分块完成后回调当前完整
  /// 译文快照，供调用方落盘检查点；[bookContext] 为 F3 全书概述注入。
  Future<List<String>> translateParagraphs(
    List<String> paragraphs, {
    int? batchSize,
    void Function(int done, int total)? onProgress,
    String? workId,
    List<String> existing = const <String>[],
    void Function(List<String> translatedSoFar)? onChunkPersisted,
    String? bookContext,
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

    // F1/F8：术语表（作品级回落全局）、风格（作品级覆盖全局）、CoT 开关。
    // 任一读取失败都按「无术语 + 标准风格」降级，不影响翻译主流程。
    var glossary = const <GlossaryEntry>[];
    var style = TranslationStyle.standard;
    var cot = false;
    try {
      glossary = await _glossary.effectiveEntries(workId, lang);
      style = await _options.effectiveStyle(workId);
      cot = await _options.getCotEnabled();
    } on Object {
      AppLog.instance.w('[小说翻译] 术语表/风格读取失败，按默认注入');
    }

    // F4：已完成的段落（existing 非空段）直接复用。
    final result = List<String>.generate(
      paragraphs.length,
      (i) => (i < existing.length ? existing[i] : '') ?? '',
    );
    var done = result.where((t) => t.isNotEmpty).length;
    final hasPartial = done > 0;
    if (done >= paragraphs.length) {
      onProgress?.call(done, paragraphs.length);
      return result;
    }
    onProgress?.call(done, paragraphs.length);

    // 1) 整章一次批量（最省 token）；超大章（B3）或已有断点（F4）直接跳过
    //    ——必然截断的请求不值得先付一次 token/延迟；失败/解析不齐 → 分块回退。
    final bool tryOneShot =
        paragraphs.length <= _kOneShotMaxParagraphs &&
            batchSize == null &&
            !hasPartial;
    if (tryOneShot) {
      try {
        final oneShot = await _requestBatch(
          paragraphs,
          cfg,
          lang,
          glossary: glossary,
          style: style,
          cot: cot,
          bookContext: bookContext,
        );
        final parsed = parseBatched(oneShot, paragraphs.length);
        if (parsed != null) {
          _detectGlossaryConflicts(glossary, paragraphs, parsed);
          onProgress?.call(paragraphs.length, paragraphs.length);
          return parsed;
        }
      } on Object catch (e) {
        // 落入分块回退。
        AppLog.instance.w('[小说翻译] 整章批量失败，转入分块回退: $e');
      }
    }

    // 2) 分块翻译（每块 chunkSize 段，块内仍走批量协议）。
    //    F4：整块已完成（全部非空）直接跳过，不重复请求；
    //    F2：携带上一块最后 2 段原文+译文作为衔接。
    List<TranslationContextPair> chunkContext = const <TranslationContextPair>[];
    for (var start = 0; start < paragraphs.length; start += chunkSize) {
      final end = (start + chunkSize).clamp(0, paragraphs.length);
      final chunk = paragraphs.sublist(start, end);
      final chunkExisting = <String>[
        for (var i = start; i < end; i++) result[i],
      ];
      final fullyDone = chunkExisting.every((t) => t.isNotEmpty);
      if (!fullyDone) {
        final raw = await _requestBatch(
          chunk,
          cfg,
          lang,
          glossary: glossary,
          style: style,
          cot: cot,
          bookContext: bookContext,
          priorContext: chunkContext,
        );
        final parsed =
            parseBatched(raw, chunk.length) ?? (throw const TranslationException('翻译返回格式异常'));
        _detectGlossaryConflicts(glossary, chunk, parsed);
        for (var i = 0; i < chunk.length; i++) {
          result[start + i] = parsed[i];
        }
        // F2：记录本块最后 N 段，供下一块衔接。
        chunkContext = <TranslationContextPair>[
          for (var i = (chunk.length - _kChunkContextPairs)
              .clamp(0, chunk.length);
              i < chunk.length;
              i++)
            (source: chunk[i], translation: parsed[i]),
        ];
      }
      done = result.where((t) => t.isNotEmpty).length;
      onProgress?.call(done, paragraphs.length);
      // F4：逐块检查点回调（快照拷贝，调用方可安全落盘）。
      onChunkPersisted?.call(List<String>.of(result));
    }
    return result;
  }

  /// 术语冲突检测（F1）：命中告警仅写日志（修正通道后续迭代）。
  void _detectGlossaryConflicts(
    List<GlossaryEntry> glossary,
    List<String> sources,
    List<String> translations,
  ) {
    if (glossary.isEmpty) return;
    try {
      final warnings =
          GlossaryManager.detectConflicts(glossary, sources, translations);
      for (final w in warnings) {
        AppLog.instance.w('[小说翻译][术语冲突] $w');
      }
    } on Object {
      // 检测失败不影响翻译主流程。
    }
  }

  Future<String> _requestBatch(
    List<String> paragraphs,
    NovelSummaryConfig cfg,
    String lang, {
    List<GlossaryEntry> glossary = const <GlossaryEntry>[],
    TranslationStyle style = TranslationStyle.standard,
    bool cot = false,
    String? bookContext,
    List<TranslationContextPair> priorContext = const <TranslationContextPair>[],
  }) async {
    final trimmedBase = cfg.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final system = PromptBuilder.novelSystemPrompt(
      lang: lang,
      paragraphCount: paragraphs.length,
      glossary: glossary,
      style: style,
      cot: cot,
      bookContext: bookContext,
    );
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
            // F2：上一块末尾若干段的原文+译文，作为衔接语境。
            for (final h in priorContext) ...<Map<String, dynamic>>[
              <String, dynamic>{
                'role': 'user',
                'content': encodeBatch(<String>[h.source]),
              },
              <String, dynamic>{'role': 'assistant', 'content': h.translation},
            ],
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

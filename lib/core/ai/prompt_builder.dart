/// 翻译提示词统一构建器（F1 术语注入 / F8 提示词体系化）。
///
/// 三条翻译链路（小说批量 / 字幕逐句 / 漫画视觉）的 system prompt 由本类
/// 按「基础指令 + 风格预设 + 术语表 + 作品语境 + 输出格式」分段拼接，
/// 各段独立可测；原硬编码在 [VisionTranslationClient] 与
/// `NovelTranslationService` 的提示词收敛至此（旧入口保留委托）。
library;

import 'glossary_manager.dart';
import 'vision_translation_client.dart';

/// 翻译风格预设（F8）：全局存 SharedPreferences，作品级覆盖存 Hive。
enum TranslationStyle {
  /// 标准（默认）：忠实原文语气，不加修饰。
  standard,

  /// 口语化：对话自然流畅，短句优先。
  colloquial,

  /// 文雅：书面语，用词考究。
  elegant,

  /// 网络用语：贴近当下社区表达习惯。
  internet;

  String get storageValue => name;

  static TranslationStyle fromStorage(String? v) => TranslationStyle.values
      .firstWhere((s) => s.name == v, orElse: () => TranslationStyle.standard);
}

/// 提示词构建器。
abstract final class PromptBuilder {
  /// 风格指令段（F8）。标准风格不追加任何文字（保持原提示词行为）。
  static String styleDirective(TranslationStyle style) => switch (style) {
        TranslationStyle.standard => '',
        TranslationStyle.colloquial =>
          '整体译文风格：口语化，对话自然流畅，避免书面腔，短句优先。',
        TranslationStyle.elegant =>
          '整体译文风格：文雅书面，用词考究，但不牺牲可读性。',
        TranslationStyle.internet =>
          '整体译文风格：贴近当下网络社区的表达习惯，可使用常见梗与缩写，但不生造。',
      };

  /// 术语表注入段（F1）。无术语时返回空串。
  ///
  /// 条数与总长有上限（防提示词膨胀挤占正文预算）：最多取 40 条、
  /// 每条拼接待超长时截断后续。
  static String glossarySection(List<GlossaryEntry> entries) {
    if (entries.isEmpty) return '';
    final buf = StringBuffer('术语表（译名必须严格统一，遇以下术语按指定译名翻译）：\n');
    var count = 0;
    for (final e in entries) {
      if (count >= 40) break;
      if (e.term.trim().isEmpty || e.preferred.trim().isEmpty) continue;
      buf.write('- ${e.term}→${e.preferred}');
      if (e.aliases.isNotEmpty) {
        buf.write('（别名亦可：${e.aliases.take(3).join('、')}）');
      }
      buf.writeln();
      count++;
    }
    if (count == 0) return '';
    return buf.toString();
  }

  /// 小说批量翻译 system prompt。
  static String novelSystemPrompt({
    required String lang,
    required int paragraphCount,
    List<GlossaryEntry> glossary = const <GlossaryEntry>[],
    TranslationStyle style = TranslationStyle.standard,
    String? bookContext,
    bool cot = false,
  }) {
    final buf = StringBuffer()
      ..write('你是专业的小说译者。把用户给出的每个编号段落翻译成$lang，'
          '保持原文的语气与人名译名一致。'
          '本次共 $paragraphCount 段，请完整输出 $paragraphCount 段，'
          '不要省略或合并。'
          '输出必须严格保持编号格式：每段译文前单独一行 <<<序号>>>，'
          '不要添加任何解释或合并段落。');
    _appendCommon(buf, style: style, glossary: glossary, bookContext: bookContext, cot: cot);
    return buf.toString();
  }

  /// 字幕逐句/批量翻译 system prompt。
  ///
  /// [lightweight] 为 true（F8 轻量格式）时不要求编号，靠换行顺序对位，
  /// 省 token；解析走 [BatchProtocol.decodeLoose]，失败由调用方回退编号协议。
  static String subtitleSystemPrompt({
    required String lang,
    List<GlossaryEntry> glossary = const <GlossaryEntry>[],
    TranslationStyle style = TranslationStyle.standard,
    bool lightweight = false,
    bool cot = false,
  }) {
    final buf = StringBuffer()
      ..write('你是专业的字幕译者。把用户给出的每个编号段落翻译成$lang，'
          '保持原文的语气与人名译名一致，译文口语化。');
    if (lightweight) {
      buf.write('直接输出译文：每行一条，与输入顺序一一对应，'
          '不要输出编号或任何解释。');
    } else {
      buf.write('输出必须严格保持编号格式：每段译文前单独一行 <<<序号>>>，'
          '不要添加任何解释或合并段落。');
    }
    _appendCommon(buf, style: style, glossary: glossary, cot: cot);
    return buf.toString();
  }

  /// 漫画页视觉 OCR+翻译 system prompt。
  ///
  /// [prevPageSummary]（F2）：前一页已译短摘要（由上一页 segments 拼成
  /// 1–2 句），供保持指代与语气连贯；成本封顶，不整页回灌。
  static String mangaSystemPrompt({
    required String lang,
    List<GlossaryEntry> glossary = const <GlossaryEntry>[],
    TranslationStyle style = TranslationStyle.standard,
    String? prevPageSummary,
  }) {
    final buf = StringBuffer(VisionTranslationClient.mangaBasePrompt(lang));
    _appendCommon(buf, style: style, glossary: glossary);
    final ctx = prevPageSummary?.trim();
    if (ctx != null && ctx.isNotEmpty) {
      buf.write('\n前一页内容摘要（保持指代与语气连贯，无需翻译输出）：$ctx');
    }
    return buf.toString();
  }

  /// 视频帧 OCR+翻译 system prompt。
  static String videoOcrSystemPrompt({
    required String lang,
    List<GlossaryEntry> glossary = const <GlossaryEntry>[],
    TranslationStyle style = TranslationStyle.standard,
  }) {
    final buf = StringBuffer(VisionTranslationClient.videoOcrBasePrompt(lang));
    _appendCommon(buf, style: style, glossary: glossary);
    return buf.toString();
  }

  /// 公共段拼接：风格 + 术语表 + 作品语境 + CoT。
  static void _appendCommon(
    StringBuffer buf, {
    TranslationStyle style = TranslationStyle.standard,
    List<GlossaryEntry> glossary = const <GlossaryEntry>[],
    String? bookContext,
    bool cot = false,
  }) {
    final styleText = styleDirective(style);
    if (styleText.isNotEmpty) {
      buf.write('\n$styleText');
    }
    final glossaryText = glossarySection(glossary);
    if (glossaryText.isNotEmpty) {
      buf.write('\n$glossaryText');
    }
    final ctx = bookContext?.trim();
    if (ctx != null && ctx.isNotEmpty) {
      buf.write('\n作品背景（翻译时保持设定与译名一致）：$ctx');
    }
    if (cot) {
      // 显式思维链（F8）：引导先理解再落笔，但不把推理过程写进输出。
      buf.write('\n翻译每段前先在内部确认：语境与指代、术语表命中、语气；'
          '确认后再输出最终译文，不要输出思考过程。');
    }
  }

  /// 全书预扫描——章节摘要 system prompt（F3）。
  static String prescanChapterSystemPrompt({required String lang}) =>
      '你是专业的文学编辑。用户会给出若干编号的章节片段（每段为该章开头的'
      '文字）。请为每个片段生成 1-2 句$lang摘要，概括该章的关键事件与出场'
      '人物。输出必须严格保持编号格式：每条摘要前单独一行 <<<序号>>>，'
      '不要添加任何解释。';

  /// 全书预扫描——全书概述 system prompt（F3）。
  static String prescanOverviewSystemPrompt({required String lang}) =>
      '你是专业的文学编辑。用户会给出《书名》与各章的摘要列表。'
      '请把它们汇总为一段约 200 字以内的$lang全书概述：'
      '交代主要人物、核心设定与主线走向，不要逐章罗列，'
      '不要输出标题或任何解释，只输出概述正文。';
}

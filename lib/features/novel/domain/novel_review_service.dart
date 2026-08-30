/// 翻译审查服务（F5 多阶段质量：证据驱动审查）。
///
/// **本地零成本启发式检查**（不发额外 AI 请求，满足成本护栏）：
/// - 术语一致性（[ReviewFindingType.glossary]）：术语表命中段落的译文
///   既非首选译名也非任何别名；
/// - 疑似漏译（[ReviewFindingType.missing]）：原文非空而译文为空；
/// - 疑似直译腔（[ReviewFindingType.literal]）：译文与原文完全相同，
///   或译文长度不足原文的 25%（对中日韩文对保守阈值）。
///
/// 「指代断裂」类需要模型逐段复审（会产生额外请求），当前版本不实现，
/// 报告不含该类证据。旧缓存（无 sources 字段）只能做译文本体检查。
library;

import '../../../core/ai/glossary_manager.dart';
import '../../../core/novel/novel_translation_manager.dart';
import '../../../core/novel/novel_review_manager.dart';

/// 审查引擎（纯函数，无 IO）。
abstract final class NovelReviewService {
  /// 对整书已缓存译文做审查，返回发现列表（调用方组装报告落盘）。
  static List<TranslationReviewFinding> review({
    required List<NovelChapterTranslation> chapters,
    required String lang,
    List<GlossaryEntry> glossary = const <GlossaryEntry>[],
  }) {
    final findings = <TranslationReviewFinding>[];
    for (final ch in chapters) {
      final sources = ch.sources;
      final translations = ch.translations;
      // 译文本体检查（无需原文）：空译文疑似漏译/坏数据。
      for (var i = 0; i < translations.length; i++) {
        if (translations[i].trim().isEmpty) {
          findings.add(TranslationReviewFinding(
            type: ReviewFindingType.missing,
            chapterId: ch.chapterId,
            chapterTitle: ch.chapterTitle,
            paragraphIndex: i,
            source: sources != null && i < sources.length
                ? sources[i]
                : '',
            translation: '',
            detail: '译文为空段',
          ));
        }
      }
      if (sources == null || sources.length != translations.length) {
        continue; // 旧缓存无对齐原文，跳过需要证据对照的检查。
      }
      for (var i = 0; i < translations.length; i++) {
        final src = sources[i].trim();
        final tr = translations[i].trim();
        if (src.isEmpty) continue;
        if (tr.isEmpty) continue; // 上面已记 missing。
        // 疑似直译腔：完全相同或长度异常收缩。
        if (src == tr && src.length > 3) {
          findings.add(TranslationReviewFinding(
            type: ReviewFindingType.literal,
            chapterId: ch.chapterId,
            chapterTitle: ch.chapterTitle,
            paragraphIndex: i,
            source: src,
            translation: tr,
            detail: '译文与原文完全相同',
          ));
        } else if (src.length > 12 && tr.length * 4 < src.length) {
          findings.add(TranslationReviewFinding(
            type: ReviewFindingType.literal,
            chapterId: ch.chapterId,
            chapterTitle: ch.chapterTitle,
            paragraphIndex: i,
            source: src,
            translation: tr,
            detail: '译文长度不足原文的 25%，疑似过度省略',
          ));
        }
        // 术语一致性：命中术语但译文偏离首选/别名。
        for (final e in glossary) {
          if (e.term.trim().isEmpty || e.preferred.trim().isEmpty) continue;
          if (!src.contains(e.term)) continue;
          final ok = <String>{e.preferred, ...e.aliases};
          if (ok.any(tr.contains)) continue;
          findings.add(TranslationReviewFinding(
            type: ReviewFindingType.glossary,
            chapterId: ch.chapterId,
            chapterTitle: ch.chapterTitle,
            paragraphIndex: i,
            source: src,
            translation: tr,
            detail: '术语「${e.term}」应译为「${e.preferred}」，'
                '实际译文未命中',
          ));
        }
      }
    }
    return findings;
  }
}

/// 翻译审查页（F5 多阶段质量：证据驱动审查）。
///
/// 列出有已缓存章节译文的书籍 → 一键本地审查（零额外 AI 请求）：
/// 术语一致性 / 疑似漏译 / 疑似直译腔 三类启发式检查，每条结论附
/// 原文/译文/位置证据。报告存 Hive 并落 JSON 文件（nexhub/reviews/）。
library;

import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:nexhub/core/ai/glossary_manager.dart';
import 'package:nexhub/core/novel/novel_review_manager.dart';
import 'package:nexhub/core/novel/novel_translation_manager.dart';
import 'package:nexhub/core/theme/app_tokens.dart';
import 'package:nexhub/core/widgets/app_animations.dart';
import '../../novel/domain/novel_review_service.dart';
import '../../novel/domain/novel_summary_settings.dart';

class TranslationReviewScreen extends StatefulWidget {
  const TranslationReviewScreen({super.key});

  @override
  State<TranslationReviewScreen> createState() =>
      _TranslationReviewScreenState();
}

class _TranslationReviewScreenState extends State<TranslationReviewScreen> {
  final NovelTranslationManager _translations = NovelTranslationManager();
  final NovelReviewManager _reports = NovelReviewManager();
  final GlossaryManager _glossary = GlossaryManager();

  String _lang = 'zh';
  bool _loading = true;
  bool _reviewing = false;
  final Map<String, int> _chapterCounts = <String, int>{};
  final Map<String, int> _findingCounts = <String, int>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      _lang = await NovelSummarySettings.instance.getTranslationTargetLanguage();
      await _translations.init();
      await _reports.init();
      final books = await _translations.listNovelIds();
      final reviewed = await _reports.listReviewedNovelIds();
      final chapterCounts = <String, int>{};
      final findingCounts = <String, int>{};
      for (final id in books) {
        final chapters =
            await _translations.listForNovel(id, lang: _lang);
        chapterCounts[id] = chapters.length;
        if (reviewed.contains(id)) {
          final report = await _reports.load(id, lang: _lang);
          findingCounts[id] = report?.findings.length ?? 0;
        }
      }
      if (!mounted) return;
      setState(() {
        _chapterCounts
          ..clear()
          ..addAll(chapterCounts);
        _findingCounts
          ..clear()
          ..addAll(findingCounts);
        _loading = false;
      });
    } on Object {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _reviewBook(String novelId) async {
    if (_reviewing) return;
    final l10n = AppLocalizations.of(context);
    setState(() => _reviewing = true);
    try {
      final chapters = await _translations.listForNovel(novelId, lang: _lang);
      var glossary = const <GlossaryEntry>[];
      try {
        glossary = await _glossary.effectiveEntries(novelId, _lang);
      } on Object {
        // 术语表不可用时跳过术语检查。
      }
      final findings = NovelReviewService.review(
        chapters: chapters,
        lang: _lang,
        glossary: glossary,
      );
      final truncated = findings.length > NovelReviewManager.summaryMaxFindings;
      final report = TranslationReviewReport(
        novelId: novelId,
        lang: _lang,
        novelTitle: novelId,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        chaptersReviewed: chapters.length,
        findings: truncated
            ? findings.take(NovelReviewManager.summaryMaxFindings).toList()
            : findings,
        truncated: truncated,
      );
      await _reports.save(report);
      // 摘要版同时落 JSON 文件（完整版，best-effort）。
      await NovelReviewManager.writeReportFile(report);
      if (!mounted) return;
      setState(() => _findingCounts[novelId] = report.findings.length);
      await _showReport(report, l10n);
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.reviewRunFailed)),
      );
    } finally {
      if (mounted) setState(() => _reviewing = false);
    }
  }

  Future<void> _showReport(
    TranslationReviewReport report,
    AppLocalizations l10n,
  ) async {
    final scheme = Theme.of(context).colorScheme;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.75,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.all(AppTokens.spaceMd),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        l10n.reviewTitle,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    Text(
                      l10n.reviewFindingCount(report.findings.length),
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: Theme.of(context).colorScheme.outline),
                    ),
                  ],
                ),
              ),
              if (report.truncated)
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppTokens.spaceMd),
                  child: Text(
                    l10n.reviewTruncated,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: Theme.of(context).colorScheme.error),
                  ),
                ),
              const Divider(height: 1),
              Expanded(
                child: report.findings.isEmpty
                    ? Center(child: Text(l10n.reviewNoFindings))
                    : ListView.builder(
                        padding: const EdgeInsets.all(AppTokens.spaceMd),
                        itemCount: report.findings.length,
                        itemBuilder: (context, i) {
                          final f = report.findings[i];
                          return Card(
                            margin: const EdgeInsets.only(
                                bottom: AppTokens.spaceSm),
                            child: Padding(
                              padding: const EdgeInsets.all(AppTokens.spaceSm),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Row(
                                    children: <Widget>[
                                      _typeChip(f.type, l10n, scheme, Theme.of(context).textTheme),
                                      const SizedBox(width: AppTokens.spaceSm),
                                      Expanded(
                                        child: Text(
                                          '${f.chapterTitle} · #${f.paragraphIndex + 1}',
                                          style: Theme.of(context).textTheme.labelMedium,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: AppTokens.spaceXs),
                                  Text(f.detail,
                                      style: Theme.of(context).textTheme.bodySmall),
                                  if (f.source.isNotEmpty) ...<Widget>[
                                    const SizedBox(height: AppTokens.spaceXs),
                                    Text(f.source,
                                        maxLines: 3,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(height: 1.4)),
                                  ],
                                  if (f.translation.isNotEmpty) ...<Widget>[
                                    const SizedBox(height: 2),
                                    Text(
                                      f.translation,
                                      maxLines: 3,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                              height: 1.4,
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .primary),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _typeChip(
      String type, AppLocalizations l10n, ColorScheme scheme, TextTheme text) {
    final label = switch (type) {
      ReviewFindingType.glossary => l10n.reviewTypeGlossary,
      ReviewFindingType.missing => l10n.reviewTypeMissing,
      ReviewFindingType.literal => l10n.reviewTypeLiteral,
      _ => type,
    };
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppTokens.spaceSm, vertical: AppTokens.spaceXxs),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppTokens.radiusSm),
      ),
      child: Text(label, style: text.labelMedium),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final books = _chapterCounts.keys.toList();
    return AppShrinkTitleScaffold(
      title: Text(l10n.reviewTitle),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : books.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(AppTokens.spaceXl),
                    child: Text(
                      l10n.reviewBooksEmpty,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.outline),
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(AppTokens.spaceLg),
                  itemCount: books.length,
                  itemBuilder: (context, i) {
                    final id = books[i];
                    final findings = _findingCounts[id];
                    return Card(
                      margin:
                          const EdgeInsets.only(bottom: AppTokens.spaceSm),
                      child: ListTile(
                        title: Text(
                          id,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          findings == null
                              ? l10n.reviewBookChapters(_chapterCounts[id] ?? 0)
                              : l10n.reviewBookFindings(findings),
                          style: TextStyle(
                              fontSize: 12, color: scheme.outline),
                        ),
                        trailing: _reviewing
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2),
                              )
                            : const Icon(Icons.chevron_right),
                        onTap: _reviewing ? null : () => _reviewBook(id),
                      ),
                    );
                  },
                ),
    );
  }
}

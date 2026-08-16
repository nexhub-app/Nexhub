import 'package:flutter/material.dart';
import '../../../core/widgets/app_animations.dart';
import 'package:nexhub/generated/app_localizations.dart';

import '../../../core/models/episode.dart';
import '../../../core/models/novel_block.dart';
import '../../../core/scraper/media_api_service.dart';
import '../../../core/models/plugin_config.dart';
import '../../../core/novel/novel_chinese_converter.dart';
import '../../../core/theme/app_tokens.dart';

/// 书内搜索结果项。
class InBookSearchResult {
  final int chapterIndex;
  final String chapterTitle;
  final String snippet;

  /// 命中位置在章内的字符偏移：命中前所有文本块长度累计 + 块内命中下标。
  /// 与阅读器分页偏移同源（P0-2 `_charOffsetForPage` 口径），跳转时用它
  /// 反查命中所在页，而非只落到章节首页。
  final int charOffset;

  const InBookSearchResult({
    required this.chapterIndex,
    required this.chapterTitle,
    required this.snippet,
    required this.charOffset,
  });
}

/// 书内搜索模式。
enum InBookSearchScope {
  /// 仅当前章节。
  currentChapter,
  /// 全书。
  wholeBook,
}

/// 全书搜索并发拉取数：章节串行逐个 `await` 在千章书上极慢，按小并发
/// 并行拉取（过高并发易触发源限流）。
const int _kSearchConcurrency = 6;

/// 单次搜索结果条数上限：常见词全书命中可能上千条，全部入列会让列表
/// 构建卡顿，截断到该值即停止收集。
const int _kMaxResults = 300;

/// 搜索中止信号（sheet 已关闭 / 发起新搜索时终止进行中的拉取）。
class _SearchAborted implements Exception {
  const _SearchAborted();
}

/// 简易并行 for：按 [concurrency] 并发执行 [task]，任一 task 抛出即整体中止。
Future<void> _parallelFor(
  int concurrency,
  List<int> items,
  Future<void> Function(int) task,
) async {
  if (concurrency < 1) concurrency = 1;
  if (items.isEmpty) return;
  final queue = List<int>.from(items);
  Future<void> worker() async {
    while (queue.isNotEmpty) {
      await task(queue.removeLast());
    }
  }

  final count = concurrency < items.length ? concurrency : items.length;
  await Future.wait(<Future<void>>[for (var i = 0; i < count; i++) worker()]);
}

/// 书内搜索底部抽屉。
///
/// 支持「全书 / 单章」ChoiceChip 切换，输入关键字后拉取正文并匹配；
/// 全书搜索按小并发并行拉取 + 章节结果缓存（重复搜索不重抓），段内
/// 全量匹配（一词多现逐条列出）；结果点击跳转到章节内命中位置。
Future<InBookSearchResult?> showNovelInBookSearchSheet({
  required BuildContext context,
  required List<Episode> chapters,
  required int currentChapterIndex,
  required MediaApiService service,
  required PluginConfig? source,
  required String novelId,
  required ChineseConvertMode convertMode,
}) {
  return showModalBottomSheet<InBookSearchResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => _InBookSearchSheet(
      chapters: chapters,
      currentChapterIndex: currentChapterIndex,
      service: service,
      source: source,
      novelId: novelId,
      convertMode: convertMode,
    ),
  );
}

class _InBookSearchSheet extends StatefulWidget {
  const _InBookSearchSheet({
    required this.chapters,
    required this.currentChapterIndex,
    required this.service,
    required this.source,
    required this.novelId,
    required this.convertMode,
  });

  final List<Episode> chapters;
  final int currentChapterIndex;
  final MediaApiService service;
  final PluginConfig? source;
  final String novelId;

  /// 与阅读器一致的繁简转换模式：正文与关键字均按该模式转换后再匹配，
  /// 保证「屏显简体、原文繁体」时也能用简体关键字搜到。
  final ChineseConvertMode convertMode;

  @override
  State<_InBookSearchSheet> createState() => _InBookSearchSheetState();
}

class _InBookSearchSheetState extends State<_InBookSearchSheet> {
  final TextEditingController _controller = TextEditingController();
  InBookSearchScope _scope = InBookSearchScope.currentChapter;
  List<InBookSearchResult> _results = const <InBookSearchResult>[];
  bool _searching = false;

  /// 已搜索章数 / 总章数（搜索中显示进度）。
  int _searchedCount = 0;
  int _totalCount = 0;

  /// 章节正文缓存（章下标 → 块列表）：sheet 存活期内重复搜索不重抓。
  final Map<int, List<NovelBlock>> _chapterCache = <int, List<NovelBlock>>{};

  /// 搜索代号：发起新搜索时自增，旧搜索的异步回调据此中止。
  int _generation = 0;

  @override
  void dispose() {
    _generation++; // 让进行中的搜索在下一个 await 点退出。
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final keywordSrc = _controller.text.trim();
    if (keywordSrc.isEmpty || widget.source == null) return;
    final int gen = ++_generation;
    // 关键字按阅读器转换模式同步转换：正文转换后匹配，关键字不转则搜不到。
    final keyword = convertChinese(keywordSrc, widget.convertMode);
    setState(() {
      _searching = true;
      _results = const <InBookSearchResult>[];
      _searchedCount = 0;
    });
    final chapterIndices = _scope == InBookSearchScope.currentChapter
        ? <int>[widget.currentChapterIndex]
        : List<int>.generate(widget.chapters.length, (i) => i);
    _totalCount = chapterIndices.length;
    // 章下标 → 该章命中列表：并行拉取乱序完成，按章序归并保证结果有序。
    final byChapter = <int, List<InBookSearchResult>>{};
    var collected = 0; // 已收集命中总数（达上限即停止收集）
    try {
      await _parallelFor(_kSearchConcurrency, chapterIndices, (ci) async {
        if (gen != _generation || !mounted) throw const _SearchAborted();
        if (collected >= _kMaxResults) throw const _SearchAborted();
        final chapter = widget.chapters[ci];
        List<NovelBlock>? blocks = _chapterCache[ci];
        if (blocks == null) {
          try {
            blocks = await widget.service.fetchNovelContent(
              widget.source!,
              novelId: widget.novelId,
              chapterUrl: chapter.url,
            );
            _chapterCache[ci] = blocks;
          } on Object {
            // 跳过拉取失败的章节。
            return;
          }
        }
        if (gen != _generation || !mounted) throw const _SearchAborted();
        final hits =
            _matchChapter(ci, chapter.title, blocks, keyword, _kMaxResults - collected);
        if (hits.isNotEmpty) byChapter[ci] = hits;
        collected += hits.length;
        if (mounted && gen == _generation) {
          setState(() => _searchedCount++);
        }
      });
    } on _SearchAborted {
      // 发起新搜索 / 关闭面板 / 结果达上限：丢弃余量，正常归并已有结果。
    } finally {
      if (mounted && gen == _generation) {
        setState(() {
          _searching = false;
          _results = <InBookSearchResult>[
            for (final ci in chapterIndices)
              ...byChapter[ci] ?? const <InBookSearchResult>[],
          ];
        });
      } else {
        _searching = false;
      }
    }
  }

  /// 在一章块列表内做全量匹配（段内一词多现逐条命中），并计算章内字符
  /// 偏移（与阅读器分页偏移同口径：仅累计文本块，插图不计）。
  /// [limit] 为本次可收集的命中上限。
  List<InBookSearchResult> _matchChapter(
    int chapterIndex,
    String chapterTitle,
    List<NovelBlock> blocks,
    String keyword,
    int limit,
  ) {
    final hits = <InBookSearchResult>[];
    var offset = 0;
    for (final block in blocks) {
      if (block is! NovelTextBlock) continue;
      final para = convertChinese(block.text, widget.convertMode);
      var idx = para.indexOf(keyword);
      while (idx >= 0) {
        final start = (idx - 20).clamp(0, para.length);
        final end =
            (idx + keyword.length + 20).clamp(0, para.length);
        hits.add(InBookSearchResult(
          chapterIndex: chapterIndex,
          chapterTitle: chapterTitle,
          snippet:
              '${start > 0 ? '...' : ''}${para.substring(start, end)}${end < para.length ? '...' : ''}',
          charOffset: offset + idx,
        ));
        if (hits.length >= limit) return hits;
        idx = para.indexOf(keyword, idx + keyword.length);
      }
      offset += para.length;
    }
    return hits;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AppSheetBody(
      child: Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.9,
        expand: false,
        builder: (ctx, scrollController) => Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.all(AppTokens.spaceMd),
              child: Column(
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: TextField(
                          controller: _controller,
                          decoration: InputDecoration(
                            hintText: l10n.searchInBook,
                            prefixIcon: const Icon(Icons.search),
                            border: const OutlineInputBorder(),
                          ),
                          onSubmitted: (_) => _search(),
                        ),
                      ),
                      const SizedBox(width: AppTokens.spaceSm),
                      FilledButton(
                        onPressed: _searching ? null : _search,
                        child: Text(l10n.search),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppTokens.spaceSm),
                  Wrap(
                    spacing: AppTokens.spaceSm,
                    children: <Widget>[
                      ChoiceChip(
                        label: Text(l10n.currentChapter),
                        selected:
                            _scope == InBookSearchScope.currentChapter,
                        onSelected: (_) => setState(() => _scope =
                            InBookSearchScope.currentChapter),
                      ),
                      ChoiceChip(
                        label: Text(l10n.wholeBook),
                        selected: _scope == InBookSearchScope.wholeBook,
                        onSelected: (_) => setState(() =>
                            _scope = InBookSearchScope.wholeBook),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              child: _searching
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          const CircularProgressIndicator(),
                          if (_totalCount > 1)
                            Padding(
                              padding: const EdgeInsets.only(
                                  top: AppTokens.spaceSm),
                              child: Text(
                                l10n.searchProgress(_searchedCount,
                                    _totalCount),
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                        ],
                      ),
                    )
                  : _results.isEmpty
                      ? Center(child: Text(l10n.noSearchResults))
                      : ListView.separated(
                          controller: scrollController,
                          itemCount: _results.length,
                          separatorBuilder: (_, __) => const Divider(
                              height: 1, indent: AppTokens.spaceMd),
                          itemBuilder: (_, i) {
                            final r = _results[i];
                            return ListTile(
                              title: Text(
                                '${l10n.chapterN(r.chapterIndex + 1)} · ${r.chapterTitle}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                r.snippet,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onTap: () => Navigator.of(context).pop(r),
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
}

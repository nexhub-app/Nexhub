/// 跨作品待读队列 UI（X-2 跨类型对齐：小说 / 漫画）。
///
/// 提供两个入口辅助：
/// - [openReadingQueueSheet]：队列管理弹层（列出 / 点击开始阅读 / 长按移除 / 清空），
///   对应「恢复最近队列」——点击队首即从上次位置继续；
/// - [openReadingFromQueue]：打开队列某项——重新抓取章节目录后推入对应阅读器
///   （小说 / 漫画），打开后自动移出队列（读完即完成），并记录为最近队列。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../features/novel/presentation/novel_reader_screen.dart';
import '../../features/manga/presentation/comic_reader_screen.dart';
import '../../generated/app_localizations.dart';
import '../models/episode.dart' show Episode;
import '../models/plugin_config.dart' show PluginConfig, SourceType;
import '../navigation/app_page_route.dart';
import '../reader/reading_queue_store.dart';
import '../scraper/media_api_service.dart';
import '../services/source_repository.dart';
import '../theme/app_tokens.dart';
import 'app_empty_state.dart';
import 'source_image.dart';

/// 打开待读队列弹层（当前队列实时读取）。
Future<void> openReadingQueueSheet(BuildContext context) async {
  final ReadingQueueStore store = ReadingQueueStore();
  final List<QueuedReading> queue = await store.getQueue();
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(AppTokens.radiusLg),
      ),
    ),
    builder: (BuildContext ctx) =>
        _ReadingQueueSheet(store: store, initial: queue),
  );
}

/// 从队列项打开阅读器：抓取章节目录 → 推入阅读页；打开后自动移出队列并记为最近。
///
/// 仅支持在线作品（本地作品不出现在队列，见各入口的过滤）。
Future<void> openReadingFromQueue(
  BuildContext context,
  QueuedReading w,
  ReadingQueueStore store,
) async {
  final l10n = AppLocalizations.of(context);
  final AppLocalizations sheetL10n = AppLocalizations.of(context);
  // 加载指示：抓目录可能需要若干秒（长书目录多页串行）。
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext ctx) => AlertDialog(
      content: Row(
        children: <Widget>[
          const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          const SizedBox(width: AppTokens.spaceMd),
          Expanded(child: Text(sheetL10n.readingQueueLoading(w.title))),
        ],
      ),
    ),
  );
  try {
    final SourceRepository repo = context.read<SourceRepository>();
    final MediaApiService service = context.read<MediaApiService>();
    final PluginConfig? source = w.sourceId.isEmpty ? null : repo.getById(w.sourceId);
    if (source == null) {
      if (context.mounted) Navigator.of(context).pop(); // 关闭 loading
      throw StateError('source missing: ${w.sourceId}');
    }
    final List<Episode> episodes = w.sourceType == SourceType.mangaSource
        ? await service.fetchChapters(source, w.itemId)
        : await service.fetchNovelChapters(source, w.itemId);
    if (!context.mounted) return;
    Navigator.of(context).pop(); // 关闭 loading
    // 移出队列（读完即完成）并记录最近。
    await store.removeByItemId(w.itemId);
    await store.setCurrent(w);
    if (!context.mounted) return;
    await Navigator.of(context).push(
      AppPageRoute<void>(
        builder: (_) {
          // 目录为空时从 0 起（clamp(0, -1) 越界）。
          final int start =
              episodes.isEmpty ? 0 : w.initialChapterIndex.clamp(0, episodes.length - 1);
          if (w.sourceType == SourceType.mangaSource) {
            return ComicReaderScreen(
              comicId: w.itemId,
              title: w.title,
              sourceId: w.sourceId,
              chapters: episodes,
              initialChapterIndex: start,
              detailUrl: w.detailUrl,
              coverUrl: w.coverUrl,
            );
          }
          return NovelReaderScreen(
            novelId: w.itemId,
            title: w.title,
            sourceId: w.sourceId,
            chapters: episodes,
            initialChapterIndex: start,
            detailUrl: w.detailUrl,
            coverUrl: w.coverUrl,
          );
        },
      ),
    );
  } catch (e) {
    if (context.mounted) Navigator.of(context).pop(); // 关闭 loading
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${l10n.readingQueueLoadFailed}: $e'),
        ),
      );
    }
  }
}

/// 队列弹层主体：空态 + 列表（点击开始阅读 / 长按移除 / 清空）。
class _ReadingQueueSheet extends StatefulWidget {
  final ReadingQueueStore store;
  final List<QueuedReading> initial;

  const _ReadingQueueSheet({required this.store, required this.initial});

  @override
  State<_ReadingQueueSheet> createState() => _ReadingQueueSheetState();
}

class _ReadingQueueSheetState extends State<_ReadingQueueSheet> {
  late List<QueuedReading> _queue;

  @override
  void initState() {
    super.initState();
    _queue = widget.initial;
  }

  Future<void> _reload() async {
    final List<QueuedReading> q = await widget.store.getQueue();
    if (mounted) setState(() => _queue = q);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final double height = MediaQuery.sizeOf(context).height * 0.7;
    return SafeArea(
      child: SizedBox(
        height: height,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppTokens.spaceMd,
                vertical: AppTokens.spaceSm,
              ),
              child: Row(
                children: <Widget>[
                  Text(
                    l10n.readingQueueTitle,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const Spacer(),
                  if (_queue.isNotEmpty)
                    TextButton(
                      onPressed: () async {
                        await widget.store.clear();
                        await _reload();
                      },
                      child: Text(l10n.readingQueueClear),
                    ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _queue.isEmpty
                  ? AppEmptyState(
                      icon: Icons.playlist_add,
                      message: l10n.readingQueueEmpty,
                    )
                  : ListView.separated(
                      itemCount: _queue.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (BuildContext ctx, int index) {
                        final QueuedReading w = _queue[index];
                        return ListTile(
                          leading: ClipRRect(
                            borderRadius:
                                BorderRadius.circular(AppTokens.radiusSm),
                            child: SizedBox(
                              width: 40,
                              height: 56,
                              child: SourceImage(url: w.coverUrl),
                            ),
                          ),
                          title: Text(
                            w.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            w.sourceType == SourceType.mangaSource
                                ? l10n.readingQueueTypeComic
                                : l10n.readingQueueTypeNovel,
                          ),
                          onTap: () {
                            Navigator.of(ctx).pop();
                            openReadingFromQueue(context, w, widget.store);
                          },
                          onLongPress: () async {
                            await widget.store.removeAt(index);
                            await _reload();
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
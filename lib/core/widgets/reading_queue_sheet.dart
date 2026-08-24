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
import '../download/download_manager.dart';
import '../download/download_local_first.dart';
import '../download/download_task.dart' show DownloadTask;
import '../local/local_content_actions.dart' show openDownloadedWorkFolder;
import '../models/episode.dart' show Episode;
import '../models/plugin_config.dart' show PluginConfig, SourceType;
import '../navigation/app_page_route.dart';
import '../novel/novel_toc_cache.dart';
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
    builder: (BuildContext ctx) => _ReadingQueueSheet(
      store: store,
      initial: queue,
      pageContext: context,
    ),
  );
}

/// 从队列项打开阅读器：抓取章节目录 → 推入阅读页；打开后自动移出队列并记为最近。
///
/// 仅支持在线作品（本地作品不出现在队列，见各入口的过滤）。
///
/// 抓取健壮性：小说优先读 TOC 缓存（详情页/上次打开写入）秒开；在线抓取带
/// 超时熔断（12s），失败时回退 TOC 缓存，缓存也没有才报错——避免「一直加载」。
Future<void> openReadingFromQueue(
  BuildContext context,
  QueuedReading w,
  ReadingQueueStore store,
) async {
  // 本地优先：已下载（同源同 id / 标题匹配）的作品直接本地读——
  // 不弹加载指示、不抓目录（下载完成的内容离线可读）。
  DownloadManager? dm;
  try {
    dm = context.read<DownloadManager>();
  } on Object {
    dm = null;
  }
  if (dm != null) {
    final Object? matched = findLocalDownload(
      dm,
      sourceType: w.sourceType,
      contentId: w.itemId,
      title: w.title,
    );
    if (matched is DownloadTask && context.mounted) {
      await openDownloadedWorkFolder(
        context,
        id: w.itemId,
        title: w.title,
        sourceId: w.sourceId,
        workDir: matched.localPath!,
        kind: kindForFormat(matched.format),
        initialIndex: w.initialChapterIndex,
      );
      await store.removeByItemId(w.itemId);
      await store.setCurrent(w);
      return;
    }
  }
  final l10n = AppLocalizations.of(context);
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
          Expanded(child: Text(l10n.readingQueueLoading(w.title))),
        ],
      ),
    ),
  );
  try {
    final SourceRepository repo = context.read<SourceRepository>();
    final MediaApiService service = context.read<MediaApiService>();
    final PluginConfig? source =
        w.sourceId.isEmpty ? null : repo.getById(w.sourceId);
    if (source == null) {
      // 统一由 catch 关闭 loading（避免重复 pop 弹掉页面）。
      throw StateError('source missing: ${w.sourceId}');
    }
    // 小说：优先读 TOC 缓存，命中即秒开（不重新抓目录）。
    List<Episode>? episodes;
    final NovelTocCache tocCache = NovelTocCache();
    if (w.sourceType == SourceType.novelSource) {
      final List<Episode>? cached = await tocCache.read(w.sourceId, w.itemId);
      if (cached != null && cached.isNotEmpty) {
        episodes = cached;
      }
    }
    // TOC 缓存未命中：在线抓取（12s 熔断，防止慢源永久转圈）。
    if (episodes == null) {
      try {
        episodes = await (w.sourceType == SourceType.mangaSource
                ? service.fetchChapters(source, w.itemId)
                : service.fetchNovelChapters(source, w.itemId))
            .timeout(const Duration(seconds: 12));
      } on Object {
        // 抓取失败/超时：小说回退 TOC 缓存（有就用，无则继续抛）。
        if (w.sourceType == SourceType.novelSource) {
          final List<Episode>? cached =
              await tocCache.read(w.sourceId, w.itemId);
          if (cached != null && cached.isNotEmpty) {
            episodes = cached;
          }
        }
        if (episodes == null) rethrow;
      }
    }
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
          final int start = episodes!.isEmpty
              ? 0
              : w.initialChapterIndex.clamp(0, episodes!.length - 1);
          if (w.sourceType == SourceType.mangaSource) {
            return ComicReaderScreen(
              comicId: w.itemId,
              title: w.title,
              sourceId: w.sourceId,
              chapters: episodes!,
              initialChapterIndex: start,
              detailUrl: w.detailUrl,
              coverUrl: w.coverUrl,
            );
          }
          return NovelReaderScreen(
            novelId: w.itemId,
            title: w.title,
            sourceId: w.sourceId,
            chapters: episodes!,
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

  /// 打开弹层时的页面级 context：点击队列项后用它完成 dialog/导航，
  /// 避免用弹层自身 context（pop 后 mounted=false 导致加载永不关闭）。
  final BuildContext pageContext;

  const _ReadingQueueSheet({
    required this.store,
    required this.initial,
    required this.pageContext,
  });

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
                            // 用打开弹层时的页面 context 完成后续导航：
                            // 弹层自身 context 在 pop 后 mounted=false。
                            openReadingFromQueue(
                                widget.pageContext, w, widget.store);
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
/// RSS 收藏页（文档 §10.2 P1-3）。
///
/// 跨源汇总所有收藏（favorite=true）的文章，列表展示封面/标题/作者/时间，
/// 点击离线打开（使用缓存全文），星标可取消收藏。入口在「设置 → 内容与网络」。
library;

import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:nexhub/core/navigation/app_page_route.dart';

import '../../../core/rss/rss_article_store.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_animations.dart';
import '../../../core/widgets/app_empty_state.dart';
import '../../../core/widgets/app_loading_indicator.dart';
import '../../../core/widgets/app_cover_image.dart';
import '../../home/presentation/browse_article_detail_screen.dart';

class RssFavoritesScreen extends StatefulWidget {
  const RssFavoritesScreen({super.key});

  @override
  State<RssFavoritesScreen> createState() => _RssFavoritesScreenState();
}

class _RssFavoritesScreenState extends State<RssFavoritesScreen> {
  final RssArticleStore _store = RssArticleStore.instance;
  List<RssArticleRecord> _items = const <RssArticleRecord>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await _store.init();
    if (mounted) {
      setState(() {
        _items = _store.getAllFavorites();
        _loading = false;
      });
    }
  }

  Future<void> _toggle(RssArticleRecord rec) async {
    await _store.toggleFavoriteByRecord(rec);
    if (mounted) {
      setState(() => _items = _store.getAllFavorites());
    }
  }

  String _formatDate(int? ms) {
    if (ms == null) return '-';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.rssFavorites)),
      body: _loading
          ? const Center(child: AppLoadingIndicator())
          : _items.isEmpty
              ? AppEmptyState(icon: Icons.bookmark_outline, message: l10n.rssFavoritesEmpty)
              : ListView.separated(
                  padding: const EdgeInsets.all(AppTokens.spaceMd),
                  itemCount: _items.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final rec = _items[i];
                    // 首屏逐条交错入场（最多 8 条），滚动回来不重播。
                    return Entrance(
                      index: i < 8 ? i : 8,
                      offset: 12,
                      fromScale: 0.98,
                      onceKey:
                          'rssfav:${RssArticleRecord.key(rec.feedId, rec.itemUrl, rec.title)}',
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: AppTokens.spaceSm,
                          vertical: AppTokens.spaceXs,
                        ),
                        leading: rec.coverUrl != null
                            ? ClipRRect(
                                borderRadius:
                                    BorderRadius.circular(AppTokens.radiusSm),
                                child: AppCoverImage(
                                  coverUrl: rec.coverUrl,
                                  width: 48,
                                  height: 48,
                                  fit: BoxFit.cover,
                                ),
                              )
                            : const Icon(Icons.article_outlined),
                        title: Text(
                          rec.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (rec.author != null)
                              Text(
                                rec.author!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                            const SizedBox(height: AppTokens.spaceXxs),
                            Text(
                              _formatDate(rec.publishedAtMs),
                              style: Theme.of(context)
                                  .textTheme
                                  .labelSmall
                                  ?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                        trailing: AppTapScale(
                          scale: 0.85,
                          duration: AppTokens.durFast,
                          child: IconButton(
                            icon: const Icon(Icons.star_rounded,
                                color: Colors.amber),
                            tooltip: l10n.rssStarRemove,
                            onPressed: () => _toggle(rec),
                          ),
                        ),
                        onTap: () => Navigator.of(context).push(
                          AppPageRoute<void>(
                            builder: (_) => BrowseArticleDetailScreen(
                              item: rec.toItem(),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}

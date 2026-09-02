/// 全局 RSS 站内搜索 —— 一次搜索所有已订阅源的文章（P1-5）。
///
/// 数据来源：各订阅源的本地条目缓存（`rss_feed_cache_v1`，由 [RssArticleStore] 维护）。
/// 即「搜已加载过的内容」，离线也能用；未抓取过的源不会出现命中（引导用户先打开该源）。
///
/// 与 feed 详情页的「本源搜索」互补：本页是跨源汇总，详情页是单源内过滤。
library;

import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:nexhub/core/navigation/app_page_route.dart';
import 'package:nexhub/core/rss/rss_article_store.dart';
import 'package:nexhub/core/rss/rss_feed.dart';
import 'package:nexhub/core/rss/rss_manager.dart';
import 'package:nexhub/core/theme/app_tokens.dart';
import 'package:nexhub/core/widgets/app_animations.dart';
import 'package:nexhub/core/widgets/app_empty_state.dart';
import 'package:nexhub/core/widgets/app_search_field.dart';
import 'package:provider/provider.dart';

import '../../home/presentation/browse_article_detail_screen.dart';

/// 一条聚合搜索结果：来自哪个订阅源 + 哪篇文章。
class _SearchHit {
  final RssFeed feed;
  final RssItem item;
  const _SearchHit({required this.feed, required this.item});
}

class RssSearchScreen extends StatefulWidget {
  const RssSearchScreen({super.key});

  @override
  State<RssSearchScreen> createState() => _RssSearchScreenState();
}

class _RssSearchScreenState extends State<RssSearchScreen> {
  final TextEditingController _ctrl = TextEditingController();
  String _query = '';
  bool _loading = true;
  List<_SearchHit> _all = const <_SearchHit>[];

  @override
  void initState() {
    super.initState();
    _buildIndex();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// 聚合所有订阅源的本地缓存条目（一次性建内存索引）。
  Future<void> _buildIndex() async {
    setState(() => _loading = true);
    final manager = context.read<RssManager>();
    await RssArticleStore.instance.init();
    final hits = <_SearchHit>[];
    for (final feed in manager.feeds) {
      for (final item in RssArticleStore.instance.getFeedItems(feed.id)) {
        hits.add(_SearchHit(feed: feed, item: item));
      }
    }
    if (mounted) {
      setState(() {
        _all = hits;
        _loading = false;
      });
    }
  }

  List<_SearchHit> get _results {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _all;
    return _all.where((h) {
      final hay = '${h.item.title} ${_stripHtml(h.item.description ?? '')} '
          '${h.feed.title}'.toLowerCase();
      return hay.contains(q);
    }).toList();
  }

  String _stripHtml(String html) =>
      html.replaceAll(RegExp(r'<[^>]*>'), '').replaceAll(RegExp(r'\s+'), ' ').trim();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final results = _results;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.rssSearchTitle)),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTokens.spaceMd,
              AppTokens.spaceSm,
              AppTokens.spaceMd,
              AppTokens.spaceXs,
            ),
            child: AppSearchField(
              controller: _ctrl,
              hint: l10n.rssSearchHint,
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _query.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () {
                        _ctrl.clear();
                        setState(() => _query = '');
                      },
                    )
                  : null,
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppTokens.spaceMd,
              vertical: AppTokens.spaceXxs,
            ),
            child: Row(
              children: <Widget>[
                Text(
                  _loading
                      ? l10n.rssSearchBuilding
                      : l10n.rssSearchCount(results.length, _all.length),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
                const Spacer(),
                TextButton.icon(
                  icon: const Icon(Icons.refresh, size: 16),
                  label: Text(l10n.retry),
                  onPressed: _buildIndex,
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : results.isEmpty
                    ? AppEmptyState(
                        icon: Icons.search_off_outlined,
                        message: _query.trim().isNotEmpty
                            ? l10n.rssSearchNoResult
                            : l10n.rssSearchEmpty,
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.all(AppTokens.spaceMd),
                        itemCount: results.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final hit = results[i];
                          return Entrance(
                            index: i < 8 ? i : 8,
                            onceKey: 'rsssrch:${hit.feed.id}:${hit.item.url}',
                            child: ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: scheme.primaryContainer
                                      .withValues(alpha: 0.5),
                                  borderRadius:
                                      BorderRadius.circular(AppTokens.radiusSm),
                                ),
                                child: Icon(Icons.rss_feed,
                                    color: scheme.primary, size: 18),
                              ),
                              title: Text(hit.item.title,
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text(
                                '${hit.feed.title} · ${_stripHtml(hit.item.description ?? '')}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                    ),
                              ),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () => _open(hit),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Future<void> _open(_SearchHit hit) async {
    await RssArticleStore.instance.markRead(hit.feed.id, hit.item);
    final content =
        RssArticleStore.instance.getContent(hit.feed.id, hit.item) ?? hit.item.content;
    if (!mounted) return;
    Navigator.of(context).push(
      AppPageRoute<void>(
        builder: (_) =>
            BrowseArticleDetailScreen(item: hit.item.copyWith(content: content)),
      ),
    );
    RssArticleStore.instance.fetchFullText(hit.feed.id, hit.item);
  }
}

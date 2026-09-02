/// RSS 订阅源详情页——展示某订阅源的条目列表（文档 §10.2 + P1-3）。
///
/// 改造点（P1-3）：
/// - 抓取成功后写入本地条目缓存（断网也能看列表）；失败时回退离线缓存。
/// - 点开文章自动标记已读，并后台抓取全文缓存（之后可离线读）。
/// - 每篇可收藏（星标切换）；已读整条置灰。
/// - 顶部「全部标为已读」+ 筛选（全部 / 未读 / 收藏）。
library;

import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:provider/provider.dart';
import 'package:nexhub/core/navigation/app_page_route.dart';

import '../../../core/rss/rss_feed.dart';
import '../../../core/rss/rss_manager.dart';
import '../../../core/rss/rss_article_store.dart';
import '../../../core/comic/models/reader_preferences.dart'
    show PrefsBackend, SharedPrefsBackend;
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/source_image.dart';
import '../../../core/widgets/app_animations.dart';
import '../../../core/widgets/app_empty_state.dart';
import '../../../core/widgets/app_error_state.dart';
import '../../../core/widgets/app_loading_indicator.dart';
import '../../../core/widgets/app_refresh_indicator.dart';
import '../../../core/widgets/app_search_field.dart';
import '../../home/presentation/browse_article_detail_screen.dart';

enum _RssFilter { all, unread, favorites }

class RssFeedDetailScreen extends StatefulWidget {
  final RssFeed feed;

  const RssFeedDetailScreen({super.key, required this.feed});

  @override
  State<RssFeedDetailScreen> createState() => _RssFeedDetailScreenState();
}

class _RssFeedDetailScreenState extends State<RssFeedDetailScreen> {
  ParsedFeed? _parsed;
  bool _loading = true;
  bool _offline = false;
  String? _error;
  _RssFilter _filter = _RssFilter.all;
  String _query = '';
  final TextEditingController _searchCtrl = TextEditingController();

  /// 订阅列表排版样式：0=列表（默认）/ 1=卡片（带封面缩略）/ 2=紧凑。
  int _listLayout = 0;

  final RssArticleStore _store = RssArticleStore.instance;
  final PrefsBackend _prefsBackend = const SharedPrefsBackend();
  static const String _listLayoutKey = 'rss_list_layout_v1';

  @override
  void initState() {
    super.initState();
    _loadListLayout();
    _loadFeed();
  }

  Future<void> _loadListLayout() async {
    try {
      final v = await _prefsBackend.get(_listLayoutKey);
      if (v != null) {
        final parsed = int.tryParse(v);
        if (parsed != null && mounted) setState(() => _listLayout = parsed);
      }
    } on Object {
      // 读取失败忽略，回退默认列表
    }
  }

  Future<void> _setListLayout(int mode) async {
    if (_listLayout == mode) return;
    setState(() => _listLayout = mode);
    try {
      await _prefsBackend.set(_listLayoutKey, mode.toString());
    } on Object {
      // 持久化失败忽略，内存态已生效
    }
  }

  /// 按文章页地址把相对/协议相对封面地址绝对化（卡片缩略图用）。
  String _absUrl(String raw, String baseUrl) {
    final Uri? base = Uri.tryParse(baseUrl);
    if (base == null) return raw;
    return base.resolve(raw).toString();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadFeed() async {
    final manager = context.read<RssManager>();
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
        _offline = false;
      });
    }
    await _store.init();
    try {
      final result = await manager.fetchFeed(widget.feed);
      if (mounted) {
        await _store.cacheFeed(widget.feed.id, result.items);
        setState(() {
          _parsed = result;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        final cached = _store.getFeedItems(widget.feed.id);
        if (cached.isNotEmpty) {
          setState(() {
            _parsed = ParsedFeed(title: widget.feed.title, items: cached);
            _loading = false;
            _offline = true;
          });
        } else {
          setState(() {
            _error = e.toString();
            _loading = false;
          });
        }
      }
    }
  }

  List<RssItem> get _visibleItems {
    final items = _parsed?.items ?? const <RssItem>[];
    final filtered = switch (_filter) {
      _RssFilter.all => items,
      _RssFilter.unread => items.where((i) => !_store.isRead(widget.feed.id, i)).toList(),
      _RssFilter.favorites =>
        items.where((i) => _store.isFavorite(widget.feed.id, i)).toList(),
    };
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return filtered;
    // 站内搜索：标题或摘要含关键字（忽略大小写与 HTML 标签）。
    return filtered.where((i) {
      final hay = '${i.title} ${_stripHtml(i.description ?? '')}'.toLowerCase();
      return hay.contains(q);
    }).toList();
  }

  Future<void> _onOpen(RssItem item) async {
    await _store.markRead(widget.feed.id, item);
    final content = _store.getContent(widget.feed.id, item) ?? item.content;
    if (mounted) {
      setState(() {}); // 反映已读置灰（返回后可见）
      Navigator.of(context).push(
        AppPageRoute<void>(
          builder: (_) => BrowseArticleDetailScreen(
            item: item.copyWith(content: content),
            feedId: widget.feed.id,
          ),
        ),
      );
    }
    // 后台抓取全文并缓存，下次离线可读。
    _store.fetchFullText(widget.feed.id, item);
  }

  Future<void> _onToggleFavorite(RssItem item) async {
    final fav = await _store.toggleFavorite(widget.feed.id, item);
    if (mounted) {
      setState(() {});
      final l10n = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(fav ? l10n.rssArticleFavorited : l10n.rssArticleUnfavorited)),
      );
    }
  }

  Future<void> _onMarkAllRead() async {
    final items = _parsed?.items ?? const <RssItem>[];
    if (items.isEmpty) return;
    await _store.markAllRead(widget.feed.id, items);
    if (mounted) {
      setState(() {});
      final l10n = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.rssMarkedAllRead)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.feed.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.done_all_outlined),
            tooltip: l10n.rssMarkAllRead,
            onPressed: _onMarkAllRead,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: l10n.retry,
            onPressed: _loadFeed,
          ),
          // 订阅列表排版样式：列表 / 卡片 / 紧凑。
          PopupMenuButton<int>(
            icon: const Icon(Icons.view_agenda_outlined),
            tooltip: l10n.rssListLayout,
            onSelected: _setListLayout,
            itemBuilder: (BuildContext context) => <PopupMenuEntry<int>>[
              PopupMenuItem<int>(
                value: 0,
                child: Row(
                  children: <Widget>[
                    const Icon(Icons.list, size: 18),
                    const SizedBox(width: AppTokens.spaceSm),
                    Text(l10n.rssLayoutList),
                  ],
                ),
              ),
              PopupMenuItem<int>(
                value: 1,
                child: Row(
                  children: <Widget>[
                    const Icon(Icons.view_agenda_outlined, size: 18),
                    const SizedBox(width: AppTokens.spaceSm),
                    Text(l10n.rssLayoutCard),
                  ],
                ),
              ),
              PopupMenuItem<int>(
                value: 2,
                child: Row(
                  children: <Widget>[
                    const Icon(Icons.view_headline_outlined, size: 18),
                    const SizedBox(width: AppTokens.spaceSm),
                    Text(l10n.rssLayoutCompact),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          _buildFilterBar(context, l10n),
          // 站内搜索：标题/摘要关键字过滤（仅过滤已加载条目，断网也能搜）。
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTokens.spaceMd,
              0,
              AppTokens.spaceMd,
              AppTokens.spaceXs,
            ),
            child: AppSearchField(
              controller: _searchCtrl,
              hint: l10n.rssSearchHint,
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _query.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () {
                        _searchCtrl.clear();
                        setState(() => _query = '');
                      },
                    )
                  : null,
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          if (_offline)
            // 离线横幅淡入上滑弹出，避免突然跳出一条横条。
            Entrance(
              offset: 8,
              fromScale: 1.0,
              duration: AppTokens.durBase,
              child: Container(
                width: double.infinity,
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                padding: const EdgeInsets.symmetric(
                  horizontal: AppTokens.spaceMd,
                  vertical: AppTokens.spaceSm,
                ),
                child: Text(
                  l10n.rssOfflineCached,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
            ),
          Expanded(child: _buildBody(context, l10n)),
        ],
      ),
    );
  }

  Widget _buildFilterBar(BuildContext context, AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    final chips = <_RssFilter, String>{
      _RssFilter.all: l10n.rssShowAll,
      _RssFilter.unread: l10n.rssShowUnread,
      _RssFilter.favorites: l10n.rssFavorites,
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: AppTokens.spaceMd,
        vertical: AppTokens.spaceXs,
      ),
      child: Wrap(
        spacing: AppTokens.spaceSm,
        children: chips.entries.map((entry) {
          final selected = _filter == entry.key;
          return AppTapScale(
            // 芯片按下缩一下、松手弹回，切换筛选有手感。
            scale: 0.92,
            duration: AppTokens.durFast,
            child: FilterChip(
              label: Text(entry.value),
              selected: selected,
              onSelected: (_) => setState(() => _filter = entry.key),
              checkmarkColor: scheme.onPrimary,
              selectedColor: scheme.primary,
              labelStyle: TextStyle(
                color: selected ? scheme.onPrimary : scheme.onSurface,
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildBody(BuildContext context, AppLocalizations l10n) {
    if (_loading) {
      return const Center(child: AppLoadingIndicator());
    }
    if (_error != null) {
      return AppErrorState(
        message: l10n.loadFailed,
        onRetry: _loadFeed,
      );
    }
    final items = _visibleItems;
    if (items.isEmpty) {
      return AppEmptyState(
        icon: Icons.article_outlined,
        message: _query.trim().isNotEmpty
            ? l10n.rssSearchNoResult
            : l10n.emptyRssItems,
      );
    }
    return AppRefreshIndicator(
      onRefresh: _loadFeed,
      child: ListView.separated(
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        padding: const EdgeInsets.all(AppTokens.spaceMd),
        itemCount: items.length,
        separatorBuilder: (_, __) =>
            _listLayout == 0 ? const Divider(height: 1) : const SizedBox.shrink(),
        itemBuilder: (context, i) {
          final item = items[i];
          // 首屏逐条交错入场（最多 8 条，避免长列表延迟累积）；
          // onceKey 保证滚动回来不再重播。
          return Entrance(
            index: i < 8 ? i : 8,
            offset: 12,
            fromScale: 0.98,
            onceKey: 'rss:${widget.feed.id}:${item.url}',
            child: _buildItemTile(context, item),
          );
        },
      ),
    );
  }

  Widget _buildListTile(BuildContext context, RssItem item) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final read = _store.isRead(widget.feed.id, item);
    final fav = _store.isFavorite(widget.feed.id, item);
    final titleColor =
        read ? scheme.onSurfaceVariant.withValues(alpha: 0.55) : scheme.onSurface;
    final subColor =
        read ? scheme.onSurfaceVariant.withValues(alpha: 0.45) : scheme.onSurfaceVariant;

    return AnimatedOpacity(
      // 已读 → 渐隐变灰（渐变过渡，而非瞬间切换）
      opacity: read ? 0.6 : 1.0,
      duration: AppTokens.durBase,
      curve: Curves.easeOutCubic,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppTokens.spaceSm,
          vertical: AppTokens.spaceXs,
        ),
        title: Text(
          item.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context)
              .textTheme
              .titleSmall
              ?.copyWith(color: titleColor),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (item.description != null)
              Text(
                _stripHtml(item.description!),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: subColor),
              ),
            const SizedBox(height: AppTokens.spaceXs),
            Row(
              children: [
                if (item.author != null) ...[
                  Icon(Icons.person_outline, size: 12, color: subColor),
                  const SizedBox(width: AppTokens.spaceXxs),
                  Flexible(
                    child: Text(
                      item.author!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .labelSmall
                          ?.copyWith(color: subColor),
                    ),
                  ),
                  const SizedBox(width: AppTokens.spaceSm),
                ],
                if (item.publishedAt != null) ...[
                  Icon(Icons.schedule, size: 12, color: subColor),
                  const SizedBox(width: AppTokens.spaceXxs),
                  Text(
                    _formatDate(item.publishedAt!),
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(color: subColor),
                  ),
                ],
              ],
            ),
          ],
        ),
        trailing: AppTapScale(
          scale: 0.85,
          duration: AppTokens.durFast,
          child: IconButton(
            icon: AnimatedSwitcher(
              // 星标实心 / 空心切换时缩放淡入，确认感更明确。
              duration: AppTokens.durBase,
              switchInCurve: AppCurves.spring,
              switchOutCurve: Curves.easeOutCubic,
              transitionBuilder: (Widget child, Animation<double> anim) =>
                  ScaleTransition(scale: anim, child: child),
              child: Icon(
                fav ? Icons.star_rounded : Icons.star_outline_rounded,
                key: ValueKey<bool>(fav),
                color: fav ? Colors.amber : scheme.onSurfaceVariant,
              ),
            ),
            tooltip: fav ? l10n.rssStarRemove : l10n.rssStarAdd,
            onPressed: () => _onToggleFavorite(item),
          ),
        ),
        onTap: () => _onOpen(item),
      ),
    );
  }

  /// 按当前排版样式分发到具体渲染。
  Widget _buildItemTile(BuildContext context, RssItem item) {
    switch (_listLayout) {
      case 1:
        return _buildCardTile(context, item);
      case 2:
        return _buildCompactTile(context, item);
      case 0:
      default:
        return _buildListTile(context, item);
    }
  }

  /// 卡片样式：带封面缩略图 + 标题 + 摘要 + 元信息 + 星标。
  Widget _buildCardTile(BuildContext context, RssItem item) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final read = _store.isRead(widget.feed.id, item);
    final fav = _store.isFavorite(widget.feed.id, item);
    final titleColor =
        read ? scheme.onSurfaceVariant.withValues(alpha: 0.55) : scheme.onSurface;
    final subColor =
        read ? scheme.onSurfaceVariant.withValues(alpha: 0.45) : scheme.onSurfaceVariant;
    final cover =
        item.coverUrl != null ? _absUrl(item.coverUrl!, item.url) : null;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: AppTokens.spaceXs),
      child: InkWell(
        onTap: () => _onOpen(item),
        child: Padding(
          padding: const EdgeInsets.all(AppTokens.spaceSm),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (cover != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppTokens.radiusSm),
                  child: SizedBox(
                    width: 72,
                    height: 72,
                    child: SourceImage(
                      url: cover,
                      fit: BoxFit.cover,
                      refererOverride: item.url.isNotEmpty ? item.url : null,
                    ),
                  ),
                ),
              if (cover != null) const SizedBox(width: AppTokens.spaceSm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(color: titleColor),
                    ),
                    const SizedBox(height: AppTokens.spaceXs),
                    if (item.description != null)
                      Text(
                        _stripHtml(item.description!),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: subColor),
                      ),
                    const SizedBox(height: AppTokens.spaceXs),
                    Row(
                      children: <Widget>[
                        if (item.author != null) ...<Widget>[
                          Icon(Icons.person_outline, size: 12, color: subColor),
                          const SizedBox(width: AppTokens.spaceXxs),
                          Flexible(
                            child: Text(
                              item.author!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .labelSmall
                                  ?.copyWith(color: subColor),
                            ),
                          ),
                          const SizedBox(width: AppTokens.spaceSm),
                        ],
                        if (item.publishedAt != null) ...<Widget>[
                          Icon(Icons.schedule, size: 12, color: subColor),
                          const SizedBox(width: AppTokens.spaceXxs),
                          Text(
                            _formatDate(item.publishedAt!),
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(color: subColor),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              AppTapScale(
                scale: 0.85,
                duration: AppTokens.durFast,
                child: IconButton(
                  icon: Icon(
                    fav ? Icons.star_rounded : Icons.star_outline_rounded,
                    color: fav ? Colors.amber : scheme.onSurfaceVariant,
                  ),
                  tooltip: fav ? l10n.rssStarRemove : l10n.rssStarAdd,
                  onPressed: () => _onToggleFavorite(item),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 紧凑样式：单行标题 + 星标，信息密度最高。
  Widget _buildCompactTile(BuildContext context, RssItem item) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final read = _store.isRead(widget.feed.id, item);
    final fav = _store.isFavorite(widget.feed.id, item);
    final titleColor =
        read ? scheme.onSurfaceVariant.withValues(alpha: 0.55) : scheme.onSurface;
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: AppTokens.spaceSm),
      title: Text(
        item.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context)
            .textTheme
            .bodyMedium
            ?.copyWith(color: titleColor),
      ),
      trailing: AppTapScale(
        scale: 0.85,
        duration: AppTokens.durFast,
        child: IconButton(
          icon: Icon(
            fav ? Icons.star_rounded : Icons.star_outline_rounded,
            color: fav ? Colors.amber : scheme.onSurfaceVariant,
            size: 18,
          ),
          tooltip: fav ? l10n.rssStarRemove : l10n.rssStarAdd,
          onPressed: () => _onToggleFavorite(item),
        ),
      ),
      onTap: () => _onOpen(item),
    );
  }

  String _stripHtml(String html) {
    return html
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _formatDate(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }
}

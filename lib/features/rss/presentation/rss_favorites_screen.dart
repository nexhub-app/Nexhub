/// RSS 收藏页（文档 §10.2 P1-3）。
///
/// 跨源汇总所有收藏（favorite=true）的文章，列表展示封面/标题/作者/时间，
/// 点击离线打开（使用缓存全文），星标可取消收藏。入口在「设置 → 内容与网络」。
///
/// 列表排版与订阅源详情页共享同一套样式与偏好（rss_article_tiles）。
library;

import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:nexhub/core/navigation/app_page_route.dart';

import '../../../core/comic/models/reader_preferences.dart'
    show PrefsBackend, SharedPrefsBackend;
import '../../../core/rss/rss_article_store.dart';
import '../../../core/rss/rss_feed.dart' show RssItem;
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_animations.dart';
import '../../../core/widgets/app_empty_state.dart';
import '../../../core/widgets/app_loading_indicator.dart';
import '../../home/presentation/browse_article_detail_screen.dart';
import 'rss_article_tiles.dart';

class RssFavoritesScreen extends StatefulWidget {
  const RssFavoritesScreen({super.key});

  @override
  State<RssFavoritesScreen> createState() => _RssFavoritesScreenState();
}

class _RssFavoritesScreenState extends State<RssFavoritesScreen> {
  final RssArticleStore _store = RssArticleStore.instance;
  final PrefsBackend _prefsBackend = const SharedPrefsBackend();
  List<RssArticleRecord> _items = const <RssArticleRecord>[];
  bool _loading = true;
  int _listLayout = RssListLayoutMode.list;

  @override
  void initState() {
    super.initState();
    _loadLayout();
    _load();
  }

  Future<void> _loadLayout() async {
    final int mode = await RssListLayoutMode.load(_prefsBackend);
    if (mounted) setState(() => _listLayout = mode);
  }

  Future<void> _setLayout(int mode) async {
    if (_listLayout == mode) return;
    setState(() => _listLayout = mode);
    await RssListLayoutMode.save(_prefsBackend, mode);
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

  String _stripHtml(String html) => html
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.rssFavorites),
        actions: <Widget>[
          RssListLayoutAction(layout: _listLayout, onSelected: _setLayout),
        ],
      ),
      body: _loading
          ? const Center(child: AppLoadingIndicator())
          : _items.isEmpty
              ? AppEmptyState(
                  icon: Icons.bookmark_outline, message: l10n.rssFavoritesEmpty)
              : ListView.separated(
                  padding: const EdgeInsets.all(AppTokens.spaceMd),
                  itemCount: _items.length,
                  separatorBuilder: (_, __) =>
                      _listLayout == RssListLayoutMode.list
                          ? const Divider(height: 1)
                          : const SizedBox.shrink(),
                  itemBuilder: (context, i) {
                    final rec = _items[i];
                    final item = rec.toItem();
                    // 首屏逐条交错入场（最多 8 条），滚动回来不重播。
                    return Entrance(
                      index: i < 8 ? i : 8,
                      offset: 12,
                      fromScale: 0.98,
                      onceKey:
                          'rssfav:${RssArticleRecord.key(rec.feedId, rec.itemUrl, rec.title)}',
                      child: buildRssArticleTile(
                        context,
                        _listLayout,
                        RssArticleTileData(
                          item: item,
                          read: rec.read,
                          favorite: rec.favorite,
                          coverUrl: rec.coverUrl != null && item.url.isNotEmpty
                              ? _abs(rec.coverUrl!, item.url)
                              : rec.coverUrl,
                          excerpt: rec.description != null
                              ? _stripHtml(rec.description!)
                              : null,
                          author: rec.author,
                          dateText: _formatDate(rec.publishedAtMs),
                          onOpen: () => _open(context, i),
                          onToggleFavorite: () => _toggle(rec),
                        ),
                      ),
                    );
                  },
                ),
    );
  }

  /// 相对封面地址按文章页绝对化（与详情页一致，否则相对地址加载不出）。
  String _abs(String raw, String baseUrl) {
    final Uri? base = Uri.tryParse(baseUrl);
    if (base == null) return raw;
    return base.resolve(raw).toString();
  }

  /// 打开收藏文章并携带收藏列表作为上下篇导航上下文。
  void _open(BuildContext context, int index) {
    final rec = _items[index];
    final navItems = _items.map<RssItem>((r) => r.toItem()).toList();
    Navigator.of(context).push(
      AppPageRoute<void>(
        builder: (_) => BrowseArticleDetailScreen(
          item: navItems[index],
          feedId: rec.feedId,
          contextItems: navItems,
          contextIndex: index,
        ),
      ),
    );
  }
}

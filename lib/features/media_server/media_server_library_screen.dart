/// 媒体服务器库浏览页：海报墙网格 + 分页（startIndex/limit）+ 服务器内搜索。
///
/// 分页走无限滚动（滚动近底部自动加载下一页）；搜索 400ms 防抖后
/// 全库 searchTerm 查询（Recursive，不带 ParentId）。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:nexhub/generated/app_localizations.dart';

import '../../core/navigation/app_page_route.dart';
import '../../core/services/media_server/media_server_client.dart';
import '../../core/services/media_server/media_server_models.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/utils/app_haptics.dart';
import '../../core/widgets/app_shimmer.dart';
import 'media_server_detail_screen.dart';
import 'media_server_widgets.dart';

class MediaServerLibraryScreen extends StatefulWidget {
  final MediaServerClientBase client;
  final ServerLibrary library;

  const MediaServerLibraryScreen({
    super.key,
    required this.client,
    required this.library,
  });

  @override
  State<MediaServerLibraryScreen> createState() =>
      _MediaServerLibraryScreenState();
}

class _MediaServerLibraryScreenState extends State<MediaServerLibraryScreen> {
  static const int _pageSize = 30;

  final ScrollController _scroll = ScrollController();
  final TextEditingController _search = TextEditingController();
  Timer? _debounce;

  List<ServerMediaItem> _items = <ServerMediaItem>[];
  int _total = 0;
  bool _loading = false;
  bool _loadingMore = false;
  Object? _error;
  String _searchTerm = '';

  /// 库类型 → 列表过滤：剧集库只列 Series（集在详情页出）。
  List<String> get _includeTypes =>
      (widget.library.collectionType == 'tvshows')
          ? const <String>['Series']
          : const <String>['Movie'];

  bool get _hasMore => _items.length < _total;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _reload();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_hasMore || _loading || _loadingMore) return;
    if (_scroll.position.extentAfter < 400) {
      _loadMore();
    }
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
      _items = <ServerMediaItem>[];
      _total = 0;
    });
    try {
      final page = await widget.client.fetchItems(
        parentId: widget.library.id,
        searchTerm: _searchTerm.isEmpty ? null : _searchTerm,
        includeTypes: _includeTypes,
        startIndex: 0,
        limit: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _items = page.items;
        _total = page.total;
        _loading = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore) return;
    setState(() => _loadingMore = true);
    try {
      final page = await widget.client.fetchItems(
        parentId: widget.library.id,
        searchTerm: _searchTerm.isEmpty ? null : _searchTerm,
        includeTypes: _includeTypes,
        startIndex: _items.length,
        limit: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _items = [..._items, ...page.items];
        _total = page.total;
        _loadingMore = false;
      });
    } on Object {
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  void _onSearchChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      if (_searchTerm == v.trim()) return;
      _searchTerm = v.trim();
      _reload();
    });
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.library.name),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(64),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTokens.spaceMd,
              0,
              AppTokens.spaceMd,
              AppTokens.spaceSm,
            ),
            child: TextField(
              controller: _search,
              onChanged: _onSearchChanged,
              decoration: InputDecoration(
                hintText: l10n.mediaServerSearchHint,
                isDense: true,
                prefixIcon: const Icon(Icons.search_rounded),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
        ),
      ),
      body: _buildBody(context, l10n, scheme),
    );
  }

  Widget _buildBody(
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme scheme,
  ) {
    if (_loading) return const _LibrarySkeleton();
    if (_error != null) {
      return _LibraryError(
        message: l10n.mediaServerLoadFailed('$_error'),
        onRetry: _reload,
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: Text(
          l10n.mediaServerNoResults,
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
      );
    }
    return GridView.builder(
      controller: _scroll,
      padding: const EdgeInsets.all(AppTokens.spaceMd),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 130,
        mainAxisSpacing: AppTokens.spaceSm,
        crossAxisSpacing: AppTokens.spaceSm,
        childAspectRatio: 0.55,
      ),
      itemCount: _items.length + (_hasMore || _loadingMore ? 1 : 0),
      itemBuilder: (context, i) {
        if (i >= _items.length) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(AppTokens.spaceMd),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        final item = _items[i];
        return _LibraryPosterCard(
          client: widget.client,
          item: item,
          onTap: () {
            AppHaptics.selectionClick();
            Navigator.of(context).push(
              AppPageRoute<void>(
                builder: (_) => MediaServerDetailScreen(
                  client: widget.client,
                  itemId: item.id,
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// 海报卡：海报 + 标题 + 年份。
class _LibraryPosterCard extends StatelessWidget {
  final MediaServerClientBase client;
  final ServerMediaItem item;
  final VoidCallback onTap;

  const _LibraryPosterCard({
    required this.client,
    required this.item,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppTokens.radiusMd),
              child: MediaServerPoster(
                url: client.imageUrl(item.id, maxWidth: 300),
                headers: client.authHeaders(),
              ),
            ),
          ),
          const SizedBox(height: AppTokens.spaceXs),
          Text(
            item.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurface),
          ),
          if (item.productionYear != null)
            Text(
              '${item.productionYear}',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
        ],
      ),
    );
  }
}

/// 库加载骨架（MD3 微光占位）：海报墙同构。
class _LibrarySkeleton extends StatelessWidget {
  const _LibrarySkeleton();

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: 0.7,
      child: GridView.builder(
        padding: const EdgeInsets.all(AppTokens.spaceMd),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 130,
          mainAxisSpacing: AppTokens.spaceSm,
          crossAxisSpacing: AppTokens.spaceSm,
          childAspectRatio: 0.55,
        ),
        itemCount: 9,
        itemBuilder: (context, i) => AppShimmer(
          borderRadius: AppTokens.radiusMd,
          phase: (i % 5) * 0.18,
        ),
      ),
    );
  }
}

/// 库加载失败 + 重试。
class _LibraryError extends StatelessWidget {  final String message;
  final VoidCallback onRetry;

  const _LibraryError({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.spaceLg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.cloud_off_rounded, color: scheme.outline, size: 40),
            const SizedBox(height: AppTokens.spaceMd),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: AppTokens.spaceMd),
            OutlinedButton(
              onPressed: onRetry,
              child: Text(AppLocalizations.of(context).mediaServerRetry),
            ),
          ],
        ),
      ),
    );
  }
}

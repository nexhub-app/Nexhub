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
import '../../core/services/media_server/media_server_settings.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/utils/app_haptics.dart';
import '../../core/widgets/app_empty_state.dart';
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

  // C3 筛选 / 排序状态。
  String _watchedFilter = ''; // '' 全部 / IsPlayed 已看 / -IsPlayed 未看
  String _sortBy = 'SortName';
  String _sortOrder = 'Ascending';

  // G2 流派 / 年份筛选（空 = 不限）。选项来自库内实际条目（fetchFilterOptions）。
  String _genre = '';
  String _year = '';
  List<String> _genreOptions = <String>[];
  List<String> _yearOptions = <String>[];

  /// G3：重载序号（防过期搜索结果覆盖新结果）。
  int _reloadSeq = 0;

  /// 库类型 → 列表过滤：剧集库只列 Series（集在详情页出）；
  /// 合集库（G2）列 BoxSet 条目。
  List<String> get _includeTypes => switch (widget.library.collectionType) {
        'tvshows' => const <String>['Series'],
        'boxsets' => const <String>['BoxSet'],
        _ => const <String>['Movie'],
      };

  bool get _hasMore => _items.length < _total;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _reload();
    unawaited(_loadFilterOptions());
  }

  /// G2：加载流派 / 年份筛选项（best-effort，失败则不显示该维度）。
  Future<void> _loadFilterOptions() async {
    final opts = await widget.client.fetchFilterOptions(
      parentId: widget.library.id,
      includeTypes: _includeTypes,
    );
    if (!mounted) return;
    setState(() {
      _genreOptions = opts.genres;
      _yearOptions = opts.years;
    });
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
    final seq = ++_reloadSeq;
    if (_searchTerm.isNotEmpty) {
      // G3：记录搜索历史（去重置顶，最多 10 条）。
      unawaited(
        MediaServerPlaybackSettings.instance.addSearchHistory(_searchTerm),
      );
    }
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
        sortBy: _sortBy,
        sortOrder: _sortOrder,
        filters: _watchedFilter.isEmpty ? const <String>[] : <String>[
          _watchedFilter,
        ],
        genres: _genre.isEmpty ? const <String>[] : <String>[_genre],
        years: _year.isEmpty ? const <String>[] : <String>[_year],
      );
      // G3：过期结果守卫。
      if (!mounted || seq != _reloadSeq) return;
      setState(() {
        _items = page.items;
        _total = page.total;
        _loading = false;
      });
    } on Object catch (e) {
      if (!mounted || seq != _reloadSeq) return;
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
        sortBy: _sortBy,
        sortOrder: _sortOrder,
        filters: _watchedFilter.isEmpty ? const <String>[] : <String>[
          _watchedFilter,
        ],
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
    // C3：筛选 / 排序行 + 内容区。
    Widget content;
    if (_loading) {
      content = const _LibrarySkeleton();
    } else if (_error != null) {
      content = _LibraryError(
        message: l10n.mediaServerLoadFailed('$_error'),
        onRetry: _reload,
      );
    } else if (_items.isEmpty) {
      content = AppEmptyState(
        icon: Icons.search_off_rounded,
        message: l10n.mediaServerNoResults,
      );
    } else {
      content = GridView.builder(
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
    return Column(
      children: <Widget>[
        _filterRow(context, l10n, scheme),
        // G3：搜索历史 chips（仅搜索词为空时显示）。
        if (_searchTerm.isEmpty && !_loading)
          ListenableBuilder(
            listenable: MediaServerPlaybackSettings.instance,
            builder: (context, _) {
              final history =
                  MediaServerPlaybackSettings.instance.searchHistory;
              if (history.isEmpty) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppTokens.spaceMd,
                  0,
                  AppTokens.spaceMd,
                  AppTokens.spaceXs,
                ),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: <Widget>[
                            for (final q in history)
                              Padding(
                                padding: const EdgeInsets.only(
                                  right: AppTokens.spaceXs,
                                ),
                                child: ActionChip(
                                  label: Text(q),
                                  onPressed: () {
                                    AppHaptics.selectionClick();
                                    _search.text = q;
                                    _onSearchChanged(q);
                                  },
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: l10n.mediaServerSearchHistoryClear,
                      icon: const Icon(Icons.delete_sweep_rounded),
                      onPressed: () => MediaServerPlaybackSettings.instance
                          .clearSearchHistory(),
                    ),
                  ],
                ),
              );
            },
          ),
        Expanded(child: content),
      ],
    );
  }

  /// 筛选行（C3）：已看状态 chips + 排序方向 / 排序键；G2 追加流派 / 年份。
  Widget _filterRow(
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme scheme,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _watchedAndSortRow(context, l10n, scheme),
        // G2：流派 / 年份筛选（有可选项时才显示，避免空行占位）。
        if (_genreOptions.isNotEmpty || _yearOptions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTokens.spaceMd,
              0,
              AppTokens.spaceMd,
              AppTokens.spaceXs,
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: <Widget>[
                  if (_genreOptions.isNotEmpty)
                    _dimensionChip(
                      label: _genre.isEmpty
                          ? l10n.mediaServerFilterGenre
                          : _genre,
                      active: _genre.isNotEmpty,
                      onTap: () => _pickDimension(
                        title: l10n.mediaServerFilterGenre,
                        options: _genreOptions,
                        current: _genre,
                        onPicked: (v) => setState(() => _genre = v),
                      ),
                    ),
                  if (_genreOptions.isNotEmpty && _yearOptions.isNotEmpty)
                    const SizedBox(width: AppTokens.spaceXs),
                  if (_yearOptions.isNotEmpty)
                    _dimensionChip(
                      label: _year.isEmpty
                          ? l10n.mediaServerFilterYear
                          : _year,
                      active: _year.isNotEmpty,
                      onTap: () => _pickDimension(
                        title: l10n.mediaServerFilterYear,
                        options: _yearOptions,
                        current: _year,
                        onPicked: (v) => setState(() => _year = v),
                      ),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  /// 单个维度筛选 chip（点击弹选择表；已选时高亮并可清除）。
  Widget _dimensionChip({
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    return ActionChip(
      avatar: Icon(
        active ? Icons.filter_alt_rounded : Icons.filter_alt_outlined,
        size: 18,
      ),
      label: Text(label),
      onPressed: () {
        AppHaptics.selectionClick();
        onTap();
      },
    );
  }

  /// 维度取值选择（含「不限」项清除筛选）。
  Future<void> _pickDimension({
    required String title,
    required List<String> options,
    required String current,
    required ValueChanged<String> onPicked,
  }) async {
    final l10n = AppLocalizations.of(context);
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (sheetCtx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(sheetCtx).size.height * 0.85,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.all(AppTokens.spaceMd),
                child: Text(title, style: Theme.of(sheetCtx).textTheme.titleMedium),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: <Widget>[
                    ListTile(
                      leading: current.isEmpty
                          ? const Icon(Icons.check_rounded)
                          : null,
                      title: Text(l10n.mediaServerFilterAll),
                      onTap: () => Navigator.of(sheetCtx).pop(''),
                    ),
                    for (final o in options)
                      ListTile(
                        leading: current == o
                            ? const Icon(Icons.check_rounded)
                            : null,
                        title: Text(o),
                        onTap: () => Navigator.of(sheetCtx).pop(o),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked == null) return;
    if (picked == current) return;
    onPicked(picked);
    _reload();
  }

  /// 已看状态 chips + 排序操作行。
  Widget _watchedAndSortRow(
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme scheme,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTokens.spaceMd,
        AppTokens.spaceSm,
        AppTokens.spaceSm,
        AppTokens.spaceXs,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: <Widget>[
                  _filterChip(l10n.mediaServerFilterAll, '', scheme),
                  const SizedBox(width: AppTokens.spaceXs),
                  _filterChip(l10n.mediaServerFilterUnwatched, '-IsPlayed', scheme),
                  const SizedBox(width: AppTokens.spaceXs),
                  _filterChip(l10n.mediaServerFilterWatched, 'IsPlayed', scheme),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: l10n.mediaServerSort,
            icon: Icon(
              _sortOrder == 'Ascending'
                  ? Icons.arrow_upward_rounded
                  : Icons.arrow_downward_rounded,
            ),
            onPressed: () {
              AppHaptics.selectionClick();
              setState(() {
                _sortOrder =
                    _sortOrder == 'Ascending' ? 'Descending' : 'Ascending';
              });
              _reload();
            },
          ),
          IconButton(
            tooltip: l10n.mediaServerSort,
            icon: const Icon(Icons.tune_rounded),
            onPressed: () => _pickSort(l10n),
          ),
        ],
      ),
    );
  }

  Widget _filterChip(String label, String value, ColorScheme scheme) {
    return ChoiceChip(
      label: Text(label),
      selected: _watchedFilter == value,
      onSelected: (_) {
        AppHaptics.selectionClick();
        if (_watchedFilter == value) return;
        setState(() => _watchedFilter = value);
        _reload();
      },
    );
  }

  /// 排序键选择（名称 / 年份 / 入库时间）。
  Future<void> _pickSort(AppLocalizations l10n) async {
    final options = <(String, String)>[
      (l10n.mediaServerSortByName, 'SortName'),
      (l10n.mediaServerSortByYear, 'ProductionYear'),
      (l10n.mediaServerSortByAdded, 'DateCreated'),
    ];
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (sheetCtx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(sheetCtx).size.height * 0.85,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final (label, key) in options)
                ListTile(
                  leading: _sortBy == key
                      ? const Icon(Icons.check_rounded)
                      : null,
                  title: Text(label),
                  onTap: () => Navigator.of(sheetCtx).pop(key),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || picked == _sortBy || !mounted) return;
    setState(() => _sortBy = picked);
    _reload();
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
    final played = item.userData?.played ?? false;
    final ticks = item.userData?.playbackPositionTicks ?? 0;
    final runtime = item.runTimeTicks ?? 0;
    final progress = (runtime > 0 && ticks > 0 && !played)
        ? (ticks / runtime).clamp(0.0, 1.0)
        : null;
    // G1：按卡片逻辑宽 × 像素密度请求海报分辨率。
    final posterMaxWidth =
        (130 * MediaQuery.devicePixelRatioOf(context)).round().clamp(240, 600);
    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppTokens.radiusMd),
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  MediaServerPoster(
                    url: client.imageUrl(item.id, maxWidth: posterMaxWidth),
                    headers: client.authHeaders(),
                    // C4：库网格 → 详情页共享元素过渡（网格内 id 唯一）。
                    heroTag: 'ms:${item.id}',
                  ),
                  if (played)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.check_rounded,
                          size: 14,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  if (progress != null)
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: ClipRRect(
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(2),
                        ),
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 4,
                          backgroundColor: Colors.white.withValues(alpha: 0.25),
                        ),
                      ),
                    ),
                ],
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

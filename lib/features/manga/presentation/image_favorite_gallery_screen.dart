/// 图片收藏图库（REQ-C2 · X-3 统一图库 · 问题 3 全面增强）。
///
/// 功能矩阵：
/// - 来源分类：全部 / 漫画 / 媒体（播放器截图）/ 小说（无对勾 chips）；
/// - 时间轴筛选：全部 / 今天 / 本周 / 本月 / 今年 / 更早；
/// - 布局切换：网格 / 手写两列瀑布流（来源比例 + URL 哈希错落）；
/// - 显示开关：标题、时间（均默认显示）；
/// - 按作品分组：同类作品（同 comicId）堆叠卡片——横向滑动切换组内图片，
///   点击展开该组全屏相册（左右翻页 + 删除/分享）；
/// - 长按菜单：删除 / 分享（本地文件发文件、网络链接发文本）/ 重命名标题；
/// - 排序：最新 / 最早 / 按标题；搜索：标题 / 作品 / 链接；
/// - 灵动感：主体 AnimatedSwitcher 淡入、缩略图横向微缩放。
///
/// [sourceFilter] 非空时锁定分类（漫画阅读器入口仅显示漫画收藏）。
/// 组件实现（瀑布流 / 堆叠卡 / 相册 / 查看器）在 part 文件中。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:nexhub/core/comic/image_favorite_manager.dart';
import 'package:nexhub/core/navigation/app_page_route.dart';
import 'package:nexhub/core/theme/app_tokens.dart';
import 'package:nexhub/core/widgets/app_alert_dialog.dart';
import 'package:nexhub/core/widgets/app_empty_state.dart';
import 'package:nexhub/core/widgets/source_image.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:share_plus/share_plus.dart';

part 'image_favorite_gallery_parts.dart';

/// 排序方式。
enum _GallerySort { newest, oldest, title }

/// 时间轴筛选。
enum _TimeRange { all, today, week, month, year, older }

/// 布局方式。
enum _GalleryLayout { grid, masonry }

/// 图片收藏图库页。
class ImageFavoriteGalleryScreen extends StatefulWidget {
  const ImageFavoriteGalleryScreen({super.key, this.manager, this.sourceFilter});

  /// 可注入的管理器（便于测试 / 复用同一实例）；默认新建。
  final ImageFavoriteManager? manager;

  /// 锁定来源分类（null = 全部）；漫画阅读器入口传 [ImageFavoriteSource.comic]。
  final ImageFavoriteSource? sourceFilter;

  @override
  State<ImageFavoriteGalleryScreen> createState() =>
      _ImageFavoriteGalleryScreenState();
}

class _ImageFavoriteGalleryScreenState
    extends State<ImageFavoriteGalleryScreen> {
  late final ImageFavoriteManager _manager;
  List<ImageFavorite> _favorites = const <ImageFavorite>[];
  bool _loading = true;

  ImageFavoriteSource? _sourceFilter;
  _TimeRange _timeRange = _TimeRange.all;
  _GalleryLayout _layout = _GalleryLayout.grid;
  _GallerySort _sort = _GallerySort.newest;
  bool _groupByWork = false;
  bool _showTitle = true;
  bool _showTime = true;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _manager = widget.manager ?? ImageFavoriteManager();
    _sourceFilter = widget.sourceFilter;
    _load();
  }

  Future<void> _load() async {
    final List<ImageFavorite> list = await _manager.list();
    if (!mounted) return;
    setState(() {
      _favorites = list;
      _loading = false;
    });
  }

  int get _columns {
    final int cols = (MediaQuery.sizeOf(context).width / 180).floor();
    return cols < 2 ? 2 : (cols > 4 ? 4 : cols);
  }

  bool _inTimeRange(ImageFavorite f, DateTime now) {
    final DateTime t = DateTime.fromMillisecondsSinceEpoch(f.createdAt);
    final int days = now.difference(t).inDays;
    return switch (_timeRange) {
      _TimeRange.all => true,
      _TimeRange.today =>
        t.year == now.year && t.month == now.month && t.day == now.day,
      _TimeRange.week => days >= 0 && days < 7,
      _TimeRange.month => days >= 0 && days < 31,
      _TimeRange.year => days >= 0 && days < 366,
      _TimeRange.older => days >= 366,
    };
  }

  /// 当前筛选结果（分类 + 时间轴 + 关键词 + 排序）。
  List<ImageFavorite> get _visible {
    List<ImageFavorite> list = _favorites;
    final ImageFavoriteSource? filter = _sourceFilter;
    if (filter != null) {
      list = list.where((f) => f.source == filter).toList();
    }
    final DateTime now = DateTime.now();
    list = list.where((f) => _inTimeRange(f, now)).toList();
    final String q = _query.trim().toLowerCase();
    if (q.isNotEmpty) {
      list = list.where((f) {
        return f.chapterTitle.toLowerCase().contains(q) ||
            f.comicId.toLowerCase().contains(q) ||
            f.imageUrl.toLowerCase().contains(q);
      }).toList();
    }
    switch (_sort) {
      case _GallerySort.newest:
        list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      case _GallerySort.oldest:
        list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      case _GallerySort.title:
        list.sort((a, b) => a.chapterTitle.toLowerCase().compareTo(
            b.chapterTitle.toLowerCase()));
    }
    return list;
  }

  /// 按作品（comicId）分组，保持排序后的相对顺序。
  List<List<ImageFavorite>> get _groups {
    final List<List<ImageFavorite>> groups = <List<ImageFavorite>>[];
    for (final ImageFavorite f in _visible) {
      bool added = false;
      for (final List<ImageFavorite> g in groups) {
        if (g.first.comicId == f.comicId) {
          g.add(f);
          added = true;
          break;
        }
      }
      if (!added) groups.add(<ImageFavorite>[f]);
    }
    return groups;
  }

  // ─────────────── 操作：删除 / 分享 / 重命名 ───────────────

  Future<void> _confirmDelete(ImageFavorite favorite) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(l10n.deleteConfirmTitle),
        content: Text(l10n.imageFavoriteDeleteConfirm),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _manager.remove(favorite.key);
    if (!mounted) return;
    setState(() {
      _favorites = List<ImageFavorite>.from(_favorites)
        ..removeWhere((f) => f.key == favorite.key);
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.imageFavoriteDeleted)),
    );
  }

  /// 分享：本地文件发文件（截图），网络链接发文本链接。
  Future<void> _share(ImageFavorite favorite) async {
    final String url = favorite.imageUrl;
    try {
      if (!url.startsWith('http')) {
        final File file = File(url);
        if (await file.exists()) {
          await Share.shareXFiles(<XFile>[XFile(file.path)]);
          return;
        }
      }
      await Share.share(url);
    } on Object {
      // 分享取消 / 失败忽略。
    }
  }

  Future<void> _rename(ImageFavorite favorite) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final TextEditingController controller =
        TextEditingController(text: favorite.chapterTitle);
    final String? title = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(l10n.imageFavoriteRename),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: l10n.imageFavoriteTitleHint),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: Text(l10n.ok),
          ),
        ],
      ),
    );
    if (title == null || title.trim().isEmpty) return;
    final bool ok = await _manager.updateTitle(favorite.key, title);
    if (!mounted) return;
    if (ok) {
      setState(() {
        _favorites = _favorites
            .map((f) => f.key == favorite.key
                ? ImageFavorite(
                    source: f.source,
                    comicId: f.comicId,
                    chapterIndex: f.chapterIndex,
                    chapterTitle: title.trim(),
                    pageIndex: f.pageIndex,
                    imageUrl: f.imageUrl,
                    createdAt: f.createdAt,
                  )
                : f)
            .toList();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.imageFavoriteRenamed)),
      );
    }
  }

  /// 长按菜单：删除 / 分享 / 重命名标题。
  Future<void> _showActions(ImageFavorite favorite) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    await showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              dense: true,
              title: Text(
                favorite.chapterTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                _timeLabel(favorite),
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.share_outlined),
              title: Text(l10n.share),
              onTap: () {
                Navigator.of(ctx).pop();
                _share(favorite);
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: Text(l10n.imageFavoriteRename),
              onTap: () {
                Navigator.of(ctx).pop();
                _rename(favorite);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: Text(l10n.delete),
              onTap: () {
                Navigator.of(ctx).pop();
                _confirmDelete(favorite);
              },
            ),
            const SizedBox(height: AppTokens.spaceSm),
          ],
        ),
      ),
    );
  }

  String _timeLabel(ImageFavorite f) {
    final DateTime t = DateTime.fromMillisecondsSinceEpoch(f.createdAt);
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  /// 打开全屏大图（Hero 飞入 + InteractiveViewer 缩放）。
  void _openFullscreen(ImageFavorite favorite) {
    Navigator.of(context).push(
      AppHeroPageRoute<void>(
        builder: (_) => _ImageFavoriteViewer(favorite: favorite),
      ),
    );
  }

  /// 打开某作品组的相册（全屏左右翻页 + 删除/分享）。
  void _openWorkPager(List<ImageFavorite> items) {
    Navigator.of(context).push(
      AppPageRoute<void>(
        builder: (_) => _WorkPagerPage(items: items, onChanged: _load),
      ),
    );
  }

  // ─────────────────────── 工具区构建 ───────────────────────

  Widget _buildSourceFilter(AppLocalizations l10n) {
    final bool locked = widget.sourceFilter != null;
    final List<(ImageFavoriteSource?, String, IconData)> options =
        <(ImageFavoriteSource?, String, IconData)>[
      (null, l10n.imageFavoriteAll, Icons.photo_library_outlined),
      (
        ImageFavoriteSource.comic,
        l10n.imageFavoriteSourceComic,
        Icons.menu_book_outlined,
      ),
      (
        ImageFavoriteSource.player,
        l10n.imageFavoriteSourcePlayer,
        Icons.play_circle_outline,
      ),
      (
        ImageFavoriteSource.novel,
        l10n.imageFavoriteSourceNovel,
        Icons.auto_stories_outlined,
      ),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: AppTokens.spaceMd),
      child: Row(
        children: <Widget>[
          for (final (source, label, icon) in options) ...<Widget>[
            _PlainChip(
              icon: icon,
              label: label,
              selected: _sourceFilter == source,
              enabled: !(locked && source != null),
              onTap: () => setState(() => _sourceFilter = source),
            ),
            const SizedBox(width: AppTokens.spaceXs),
          ],
        ],
      ),
    );
  }

  Widget _buildTimeRange(AppLocalizations l10n) {
    final List<( _TimeRange, String)> options = <( _TimeRange, String)>[
      (_TimeRange.all, l10n.imageFavoriteTimeAll),
      (_TimeRange.today, l10n.imageFavoriteTimeToday),
      (_TimeRange.week, l10n.imageFavoriteTimeWeek),
      (_TimeRange.month, l10n.imageFavoriteTimeMonth),
      (_TimeRange.year, l10n.imageFavoriteTimeYear),
      (_TimeRange.older, l10n.imageFavoriteTimeOlder),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: AppTokens.spaceMd),
      child: Row(
        children: <Widget>[
          for (final (range, label) in options) ...<Widget>[
            _PlainChip(
              icon: null,
              label: label,
              selected: _timeRange == range,
              enabled: true,
              onTap: () => setState(() => _timeRange = range),
            ),
            const SizedBox(width: AppTokens.spaceXs),
          ],
        ],
      ),
    );
  }

  Widget _buildControlsRow(AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppTokens.spaceMd),
      child: Row(
        children: <Widget>[
          SegmentedButton<_GalleryLayout>(
            showSelectedIcon: false,
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            segments: <ButtonSegment<_GalleryLayout>>[
              ButtonSegment<_GalleryLayout>(
                value: _GalleryLayout.grid,
                icon: const Icon(Icons.grid_view, size: 16),
                label: Text(l10n.imageFavoriteLayoutGrid),
              ),
              ButtonSegment<_GalleryLayout>(
                value: _GalleryLayout.masonry,
                icon: const Icon(Icons.view_quilt_outlined, size: 16),
                label: Text(l10n.imageFavoriteLayoutMasonry),
              ),
            ],
            selected: <_GalleryLayout>{_layout},
            onSelectionChanged: (Set<_GalleryLayout> s) =>
                setState(() => _layout = s.first),
          ),
          const SizedBox(width: AppTokens.spaceXs),
          _PlainChip(
            icon: Icons.layers_outlined,
            label: l10n.imageFavoriteGroupByWork,
            selected: _groupByWork,
            enabled: true,
            onTap: () => setState(() => _groupByWork = !_groupByWork),
          ),
          const Spacer(),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_horiz),
            tooltip: l10n.imageFavoriteDisplayOptions,
            onSelected: (String v) {
              switch (v) {
                case 'title':
                  setState(() => _showTitle = !_showTitle);
                case 'time':
                  setState(() => _showTime = !_showTime);
                case 'newest':
                  setState(() => _sort = _GallerySort.newest);
                case 'oldest':
                  setState(() => _sort = _GallerySort.oldest);
                case 'byTitle':
                  setState(() => _sort = _GallerySort.title);
              }
            },
            itemBuilder: (BuildContext ctx) => <PopupMenuEntry<String>>[
              CheckedPopupMenuItem<String>(
                value: 'title',
                checked: _showTitle,
                child: Text(l10n.imageFavoriteShowTitle),
              ),
              CheckedPopupMenuItem<String>(
                value: 'time',
                checked: _showTime,
                child: Text(l10n.imageFavoriteShowTime),
              ),
              const PopupMenuDivider(),
              CheckedPopupMenuItem<String>(
                value: 'newest',
                checked: _sort == _GallerySort.newest,
                child: Text(l10n.imageFavoriteSortNewest),
              ),
              CheckedPopupMenuItem<String>(
                value: 'oldest',
                checked: _sort == _GallerySort.oldest,
                child: Text(l10n.imageFavoriteSortOldest),
              ),
              CheckedPopupMenuItem<String>(
                value: 'byTitle',
                checked: _sort == _GallerySort.title,
                child: Text(l10n.imageFavoriteSortTitle),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSearch(AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTokens.spaceMd,
        vertical: AppTokens.spaceXs,
      ),
      child: TextField(
        onChanged: (String v) => setState(() => _query = v),
        decoration: InputDecoration(
          hintText: l10n.imageFavoriteSearchHint,
          prefixIcon: const Icon(Icons.search),
          isDense: true,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.imageFavoriteGalleryTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _buildSearch(l10n),
                _buildSourceFilter(l10n),
                const SizedBox(height: AppTokens.spaceXs),
                _buildTimeRange(l10n),
                const SizedBox(height: AppTokens.spaceXs),
                _buildControlsRow(l10n),
                const SizedBox(height: AppTokens.spaceXs),
                Expanded(child: _buildBody(l10n)),
              ],
            ),
    );
  }

  Widget _buildBody(AppLocalizations l10n) {
    final List<ImageFavorite> visible = _visible;
    final Widget child;
    if (visible.isEmpty) {
      child = AppEmptyState(
        icon: Icons.photo_library_outlined,
        message: _favorites.isEmpty
            ? l10n.imageFavoriteEmpty
            : l10n.imageFavoriteNoMatch,
      );
    } else if (_groupByWork) {
      final List<List<ImageFavorite>> groups = _groups;
      child = ListView.separated(
        padding: const EdgeInsets.all(AppTokens.spaceMd),
        itemCount: groups.length,
        separatorBuilder: (_, __) => const SizedBox(height: AppTokens.spaceMd),
        itemBuilder: (BuildContext ctx, int index) {
          final List<ImageFavorite> items = groups[index];
          return _WorkStackCard(
            key: ValueKey<String>('work-${items.first.comicId}'),
            items: items,
            showTitle: _showTitle,
            showTime: _showTime,
            timeLabel: _timeLabel,
            onTapOpen: () => _openWorkPager(items),
            onLongPress: (ImageFavorite f) => _showActions(f),
          );
        },
      );
    } else if (_layout == _GalleryLayout.masonry) {
      child = _MasonryGrid(
        items: visible,
        columns: _columns.clamp(2, 3),
        showTitle: _showTitle,
        showTime: _showTime,
        timeLabel: _timeLabel,
        onOpen: _openFullscreen,
        onLongPress: _showActions,
      );
    } else {
      child = GridView.builder(
        padding: const EdgeInsets.all(AppTokens.spaceMd),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: _columns,
          mainAxisSpacing: AppTokens.spaceSm,
          crossAxisSpacing: AppTokens.spaceSm,
          childAspectRatio: _showTitle || _showTime ? 0.66 : 0.72,
        ),
        itemCount: visible.length,
        itemBuilder: (BuildContext ctx, int index) {
          return _buildThumb(ctx, visible[index]);
        },
      );
    }
    // 灵动感：筛选 / 布局 / 分组切换时主体淡入淡出。
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      child: KeyedSubtree(
        key: ValueKey<String>(
            '${_layout.name}-$_groupByWork-${_timeRange.name}-'
            '${_sourceFilter?.apiName ?? 'all'}-$_query-${_sort.name}'),
        child: child,
      ),
    );
  }

  /// 单个缩略图：点击看大图，长按操作菜单。
  Widget _buildThumb(BuildContext context, ImageFavorite favorite) {
    final bool showMeta = _showTitle || _showTime;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _openFullscreen(favorite),
        onLongPress: () => _showActions(favorite),
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            SourceImage(
              url: favorite.imageUrl,
              heroTag: favorite.key,
              fit: BoxFit.cover,
            ),
            Positioned(
              left: AppTokens.spaceXs,
              bottom: showMeta ? 30 : AppTokens.spaceXs,
              child: _SourceBadge(source: favorite.source),
            ),
            if (showMeta)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: <Color>[
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.55),
                      ],
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      if (_showTitle)
                        Text(
                          favorite.chapterTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      if (_showTime)
                        Text(
                          _timeLabel(favorite),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 9,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            Positioned(
              top: AppTokens.spaceXs,
              right: AppTokens.spaceXs,
              child: Material(
                color: Colors.black.withValues(alpha: 0.45),
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => _confirmDelete(favorite),
                  child: const Padding(
                    padding: EdgeInsets.all(2),
                    child: Icon(Icons.close, size: 16, color: Colors.white),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
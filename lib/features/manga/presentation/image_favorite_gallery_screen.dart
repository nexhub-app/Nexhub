/// 图片收藏图库（REQ-C2 · 问题 3 统一图库增强）——网格缩略图目录页。
///
/// 展示 [ImageFavoriteManager] 中的全部收藏图片：网格缩略图（2~4 列自适应），
/// 点击打开全屏大图（Hero 飞入 + InteractiveViewer 缩放），长按缩略图或点
/// 右上角按钮删除单条。
///
/// 统一图库（X-3 / 问题 3）：支持按来源分类（全部 / 漫画 / 媒体[播放器] /
/// 小说）、标题/链接搜索、时间排序（最新/最早）与按标题排序、条数统计；
/// [sourceFilter] 非空时锁定该分类（如漫画阅读器入口只显示漫画收藏）。
library;

import 'package:flutter/material.dart';
import 'package:nexhub/core/comic/image_favorite_manager.dart';
import 'package:nexhub/core/navigation/app_page_route.dart';
import 'package:nexhub/core/theme/app_tokens.dart';
import 'package:nexhub/core/widgets/app_empty_state.dart';
import 'package:nexhub/core/widgets/source_image.dart';
import 'package:nexhub/generated/app_localizations.dart';

/// 排序方式。
enum _GallerySort { newest, oldest, title }

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

class _ImageFavoriteGalleryScreenState extends State<ImageFavoriteGalleryScreen> {
  late final ImageFavoriteManager _manager;
  List<ImageFavorite> _favorites = const <ImageFavorite>[];
  bool _loading = true;

  /// 当前分类（全部显示 null）。
  ImageFavoriteSource? _sourceFilter;

  String _query = '';
  _GallerySort _sort = _GallerySort.newest;

  @override
  void initState() {
    super.initState();
    _manager = widget.manager ?? ImageFavoriteManager();
    _sourceFilter = widget.sourceFilter;
    _load();
  }

  /// 从 Hive 重新加载收藏列表。
  Future<void> _load() async {
    final List<ImageFavorite> list = await _manager.list();
    if (!mounted) return;
    setState(() {
      _favorites = list;
      _loading = false;
    });
  }

  /// 网格列数：按屏宽自适应（每列约 180px），限制在 2~4 列。
  int get _columns {
    final int cols = (MediaQuery.sizeOf(context).width / 180).floor();
    return cols < 2 ? 2 : (cols > 4 ? 4 : cols);
  }

  /// 当前筛选结果：来源分类 + 关键词（标题 / 作品名 / 图片地址）+ 排序。
  List<ImageFavorite> get _visible {
    List<ImageFavorite> list = _favorites;
    final ImageFavoriteSource? filter = _sourceFilter;
    if (filter != null) {
      list = list.where((f) => f.source == filter).toList();
    }
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
        list.sort((a, b) =>
            a.chapterTitle.toLowerCase().compareTo(b.chapterTitle.toLowerCase()));
    }
    return list;
  }

  /// 删除确认弹窗，确认后移除该条收藏并提示。
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

  /// 打开全屏大图（Hero 飞入 + InteractiveViewer 缩放）。
  void _openFullscreen(ImageFavorite favorite) {
    Navigator.of(context).push(
      AppHeroPageRoute<void>(
        builder: (_) => _ImageFavoriteViewer(favorite: favorite),
      ),
    );
  }

  /// 分类切换（全部 / 漫画 / 媒体 / 小说）。
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
    return Semantics(
      label: l10n.imageFavoriteFilter,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppTokens.spaceMd),
        child: Row(
          children: <Widget>[
            for (final (source, label, icon) in options) ...<Widget>[
              ChoiceChip(
                avatar: Icon(icon, size: 16),
                label: Text(label),
                selected: _sourceFilter == source,
                onSelected: locked && source != null
                    ? null
                    : (_) => setState(() {
                          _sourceFilter = source;
                        }),
              ),
              const SizedBox(width: AppTokens.spaceXs),
            ],
          ],
        ),
      ),
    );
  }

  /// 搜索框 + 排序行 + 计数。
  Widget _buildToolbar(AppLocalizations l10n) {
    final int count = _visible.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTokens.spaceMd,
            vertical: AppTokens.spaceXs,
          ),
          child: TextField(
            onChanged: (v) => setState(() => _query = v),
            decoration: InputDecoration(
              hintText: l10n.imageFavoriteSearchHint,
              prefixIcon: const Icon(Icons.search),
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 8,
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppTokens.spaceMd),
          child: Row(
            children: <Widget>[
              Text(
                l10n.imageFavoriteCount(count),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const Spacer(),
              ChoiceChip(
                label: Text(l10n.imageFavoriteSortNewest),
                selected: _sort == _GallerySort.newest,
                onSelected: (_) => setState(() => _sort = _GallerySort.newest),
              ),
              const SizedBox(width: AppTokens.spaceXs),
              ChoiceChip(
                label: Text(l10n.imageFavoriteSortOldest),
                selected: _sort == _GallerySort.oldest,
                onSelected: (_) => setState(() => _sort = _GallerySort.oldest),
              ),
              const SizedBox(width: AppTokens.spaceXs),
              ChoiceChip(
                label: Text(l10n.imageFavoriteSortTitle),
                selected: _sort == _GallerySort.title,
                onSelected: (_) => setState(() => _sort = _GallerySort.title),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppTokens.spaceXs),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.imageFavoriteGalleryTitle)),
      body: _buildBody(l10n),
    );
  }

  Widget _buildBody(AppLocalizations l10n) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final List<ImageFavorite> visible = _visible;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _buildSourceFilter(l10n),
        _buildToolbar(l10n),
        Expanded(
          child: visible.isEmpty
              ? AppEmptyState(
                  icon: Icons.photo_library_outlined,
                  message: _favorites.isEmpty
                      ? l10n.imageFavoriteEmpty
                      : l10n.imageFavoriteNoMatch,
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(AppTokens.spaceMd),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: _columns,
                    mainAxisSpacing: AppTokens.spaceSm,
                    crossAxisSpacing: AppTokens.spaceSm,
                  ),
                  itemCount: visible.length,
                  itemBuilder: (BuildContext ctx, int index) {
                    return _buildThumb(ctx, visible[index]);
                  },
                ),
        ),
      ],
    );
  }

  /// 单个缩略图：点击看大图，长按 / 右上角按钮删除。
  Widget _buildThumb(BuildContext context, ImageFavorite favorite) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppTokens.radiusSm),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          GestureDetector(
            onTap: () => _openFullscreen(favorite),
            onLongPress: () => _confirmDelete(favorite),
            child: SourceImage(
              url: favorite.imageUrl,
              heroTag: favorite.key,
              fit: BoxFit.cover,
            ),
          ),
          // 来源角标（X-3 统一图库：漫画 / 播放器截图 / 小说插图）。
          Positioned(
            left: AppTokens.spaceXs,
            bottom: AppTokens.spaceXs,
            child: _SourceBadge(source: favorite.source),
          ),
          // 右上角删除按钮（半透明圆形，叠在缩略图上，避免误触放大图）。
          Positioned(
            top: AppTokens.spaceXs,
            right: AppTokens.spaceXs,
            child: Material(
              color: Colors.black.withValues(alpha: 0.45),
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => _confirmDelete(favorite),
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: Icon(
                    Icons.close,
                    size: 16,
                    color: scheme.onInverseSurface,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 来源角标（X-3）：半透明黑底小图标 + 来源名，区分漫画/播放器截图/小说插图。
class _SourceBadge extends StatelessWidget {
  const _SourceBadge({required this.source});

  final ImageFavoriteSource source;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final (IconData icon, String label) = switch (source) {
      ImageFavoriteSource.comic => (
          Icons.menu_book_outlined,
          l10n.imageFavoriteSourceComic,
        ),
      ImageFavoriteSource.player => (
          Icons.play_circle_outline,
          l10n.imageFavoriteSourcePlayer,
        ),
      ImageFavoriteSource.novel => (
          Icons.auto_stories_outlined,
          l10n.imageFavoriteSourceNovel,
        ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(AppTokens.radiusSm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 11, color: Colors.white),
          const SizedBox(width: 3),
          Text(
            label,
            style: const TextStyle(fontSize: 10, color: Colors.white),
          ),
        ],
      ),
    );
  }
}

/// 全屏查看单张收藏图片（黑底 + InteractiveViewer 缩放 + Hero 飞入）。
class _ImageFavoriteViewer extends StatelessWidget {
  const _ImageFavoriteViewer({required this.favorite});

  final ImageFavorite favorite;

  @override
  Widget build(BuildContext context) {
    final Size size = MediaQuery.sizeOf(context);
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // 点击空白处返回。
        onTap: () => Navigator.of(context).maybePop(),
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 5,
          child: Center(
            child: Hero(
              tag: favorite.key,
              child: SourceImage(
                url: favorite.imageUrl,
                width: size.width,
                height: size.height,
                fit: BoxFit.contain,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
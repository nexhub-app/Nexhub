part of 'image_favorite_gallery_screen.dart';

// 图库页组件实现（与主文件同库，可访问私有类型）：
// - _PlainChip：无对勾的分类 / 时间轴 / 开关 chip；
// - _MasonryGrid / _MasonryItem：手写两列瀑布流；
// - _WorkStackCard：作品分组「堆叠卡片」（横滑切换 + 点击展开相册）；
// - _WorkPagerPage：组内全屏相册（左右翻页 + 删除 / 分享）；
// - _ImageFavoriteViewer：单图全屏查看（Hero + InteractiveViewer）；
// - _SourceBadge：来源角标。
// 注意：part 文件无独立 import，所需库由主文件统一导入。

/// 无对勾 chip：选中用底色 + 描边 + 加粗区分（问题 3：去掉选择对勾）。
class _PlainChip extends StatelessWidget {
  final IconData? icon;
  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback? onTap;

  const _PlainChip({
    this.icon,
    required this.label,
    required this.selected,
    required this.enabled,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color bg = selected
        ? scheme.primaryContainer.withValues(alpha: 0.7)
        : scheme.surfaceContainerHighest.withValues(alpha: 0.45);
    final Color fg =
        selected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant;
    return Opacity(
      opacity: enabled ? 1 : 0.55,
      child: Material(
        color: bg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(
            color: selected
                ? scheme.primary.withValues(alpha: 0.5)
                : Colors.transparent,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: enabled ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (icon != null) ...<Widget>[
                  Icon(icon, size: 15, color: fg),
                  const SizedBox(width: 4),
                ],
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: fg,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 来源角标（X-3）：半透明黑底小图标 + 来源名。
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

/// 手写两列瀑布流：列内纵向连续，项高按来源比例 + URL 哈希微调错落。
class _MasonryGrid extends StatelessWidget {
  final List<ImageFavorite> items;
  final int columns;
  final bool showTitle;
  final bool showTime;
  final String Function(ImageFavorite) timeLabel;
  final ValueChanged<ImageFavorite> onOpen;
  final ValueChanged<ImageFavorite> onLongPress;

  const _MasonryGrid({
    required this.items,
    required this.columns,
    required this.showTitle,
    required this.showTime,
    required this.timeLabel,
    required this.onOpen,
    required this.onLongPress,
  });

  double _aspectFor(ImageFavorite f) {
    final double base = switch (f.source) {
      ImageFavoriteSource.comic => 0.72,
      ImageFavoriteSource.player => 1.6,
      ImageFavoriteSource.novel => 0.78,
    };
    final int h = f.imageUrl.hashCode.abs() % 100;
    return base * (0.85 + h / 100.0 * 0.3);
  }

  @override
  Widget build(BuildContext context) {
    final List<List<ImageFavorite>> cols =
        List<List<ImageFavorite>>.generate(columns, (_) => <ImageFavorite>[]);
    for (int i = 0; i < items.length; i++) {
      cols[i % columns].add(items[i]);
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppTokens.spaceMd),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (int c = 0; c < columns; c++) ...<Widget>[
            Expanded(
              child: Column(
                children: <Widget>[
                  for (int i = 0; i < cols[c].length; i++) ...<Widget>[
                    _MasonryItem(
                      favorite: cols[c][i],
                      aspect: _aspectFor(cols[c][i]),
                      showTitle: showTitle,
                      showTime: showTime,
                      timeLabel: timeLabel,
                      onTap: () => onOpen(cols[c][i]),
                      onLongPress: () => onLongPress(cols[c][i]),
                    ),
                    if (i < cols[c].length - 1)
                      const SizedBox(height: AppTokens.spaceSm),
                  ],
                ],
              ),
            ),
            if (c < columns - 1) const SizedBox(width: AppTokens.spaceSm),
          ],
        ],
      ),
    );
  }
}

class _MasonryItem extends StatelessWidget {
  final ImageFavorite favorite;
  final double aspect;
  final bool showTitle;
  final bool showTime;
  final String Function(ImageFavorite) timeLabel;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _MasonryItem({
    required this.favorite,
    required this.aspect,
    required this.showTitle,
    required this.showTime,
    required this.timeLabel,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final bool showMeta = showTitle || showTime;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onLongPress: onLongPress,
        child: AspectRatio(
          aspectRatio: aspect,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppTokens.radiusSm),
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                SourceImage(url: favorite.imageUrl, fit: BoxFit.cover),
                Positioned(
                  left: AppTokens.spaceXs,
                  bottom: showMeta ? 28 : AppTokens.spaceXs,
                  child: _SourceBadge(source: favorite.source),
                ),
                if (showMeta)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 3),
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
                          if (showTitle)
                            Text(
                              favorite.chapterTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10.5,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          if (showTime)
                            Text(
                              timeLabel(favorite),
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 9,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 作品分组「堆叠卡片」：同作品多图叠影 + 顶层 PageView 横滑切换，
/// 点指示点显示当前位置，点击卡片展开该组相册（_WorkPagerPage）。
class _WorkStackCard extends StatefulWidget {
  final List<ImageFavorite> items;
  final bool showTitle;
  final bool showTime;
  final String Function(ImageFavorite) timeLabel;
  final VoidCallback onTapOpen;
  final ValueChanged<ImageFavorite> onLongPress;

  const _WorkStackCard({
    super.key,
    required this.items,
    required this.showTitle,
    required this.showTime,
    required this.timeLabel,
    required this.onTapOpen,
    required this.onLongPress,
  });

  @override
  State<_WorkStackCard> createState() => _WorkStackCardState();
}

class _WorkStackCardState extends State<_WorkStackCard> {
  int _page = 0;

  @override
  Widget build(BuildContext context) {
    final List<ImageFavorite> items = widget.items;
    final ImageFavorite first = items.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTapOpen,
          onLongPress: () => widget.onLongPress(first),
          child: SizedBox(
            height: 230,
            child: Stack(
              clipBehavior: Clip.none,
              children: <Widget>[
                // 叠影：第 2、3 张错位露出，营造堆叠感。
                if (items.length > 1 && items.length > 2)
                  Positioned.fill(
                    child: Transform.translate(
                      offset: const Offset(-10, -8),
                      child: Transform.rotate(
                        angle: -0.02,
                        child: _stackLayer(items[2], 0.45),
                      ),
                    ),
                  ),
                if (items.length > 1)
                  Positioned.fill(
                    child: Transform.translate(
                      offset: const Offset(10, 8),
                      child: Transform.rotate(
                        angle: 0.02,
                        child: _stackLayer(items[1], 0.65),
                      ),
                    ),
                  ),
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(AppTokens.radiusMd),
                    child: PageView.builder(
                      itemCount: items.length,
                      onPageChanged: (int i) => setState(() => _page = i),
                      itemBuilder: (BuildContext ctx, int index) {
                        return SourceImage(
                          url: items[index].imageUrl,
                          fit: BoxFit.cover,
                          radius: AppTokens.radiusMd,
                        );
                      },
                    ),
                  ),
                ),
                // 指示点。
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 8,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      for (int i = 0; i < items.length; i++)
                        Container(
                          width: i == _page ? 14 : 6,
                          height: 6,
                          margin: const EdgeInsets.symmetric(horizontal: 2),
                          decoration: BoxDecoration(
                            color: i == _page
                                ? Colors.white
                                : Colors.white54,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppTokens.spaceXs),
        Row(
          children: <Widget>[
            if (widget.showTitle)
              Expanded(
                child: Text(
                  first.chapterTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            if (widget.showTime)
              Text(
                widget.timeLabel(first),
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Theme.of(context).hintColor),
              ),
          ],
        ),
      ],
    );
  }

  Widget _stackLayer(ImageFavorite f, double opacity) {
    return Opacity(
      opacity: opacity,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        child: SourceImage(url: f.imageUrl, fit: BoxFit.cover),
      ),
    );
  }
}

/// 组内全屏相册：黑底 PageView 左右翻页，顶部标题 / 计数，支持删除 / 分享。
class _WorkPagerPage extends StatefulWidget {
  final List<ImageFavorite> items;
  final VoidCallback onChanged;

  const _WorkPagerPage({required this.items, required this.onChanged});

  @override
  State<_WorkPagerPage> createState() => _WorkPagerPageState();
}

class _WorkPagerPageState extends State<_WorkPagerPage> {
  late List<ImageFavorite> _items;
  int _index = 0;
  final ImageFavoriteManager _manager = ImageFavoriteManager();

  @override
  void initState() {
    super.initState();
    _items = List<ImageFavorite>.from(widget.items);
  }

  Future<void> _deleteCurrent() async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AppAlertDialog(
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
    if (ok != true || _items.isEmpty) return;
    final ImageFavorite f = _items[_index];
    await _manager.remove(f.key);
    if (!mounted) return;
    setState(() {
      _items.removeAt(_index);
      if (_index >= _items.length) _index = _items.length - 1;
    });
    widget.onChanged();
    // 必须在 pop() 之前捕获 ScaffoldMessenger，否则清空后 pop 再访问 context 会崩溃。
    final messenger = ScaffoldMessenger.of(context);
    final msg = l10n.imageFavoriteDeleted;
    if (_items.isEmpty && mounted) Navigator.of(context).pop();
    messenger.showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _shareCurrent() async {
    if (_items.isEmpty) return;
    final ImageFavorite f = _items[_index];
    final String url = f.imageUrl;
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
      // 忽略。
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
        title: _items.isEmpty
            ? null
            : Text(
                '${_items[_index].chapterTitle}'
                ' · ${_index + 1}/${_items.length}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
        actions: <Widget>[
          IconButton(
            tooltip: l10n.imageFavoriteShowTime,
            icon: Icon(
              Icons.share_outlined,
              color: Colors.white,
            ),
            onPressed: _shareCurrent,
          ),
          IconButton(
            tooltip: l10n.delete,
            icon: const Icon(Icons.delete_outline, color: Colors.white),
            onPressed: _deleteCurrent,
          ),
        ],
      ),
      body: _items.isEmpty
          ? const SizedBox.shrink()
          : GestureDetector(
              onTap: () => Navigator.of(context).maybePop(),
              child: PageView.builder(
                itemCount: _items.length,
                onPageChanged: (int i) => setState(() => _index = i),
                itemBuilder: (BuildContext ctx, int index) {
                  return InteractiveViewer(
                    minScale: 0.5,
                    maxScale: 5,
                    child: Center(
                      child: SourceImage(
                        url: _items[index].imageUrl,
                        width: MediaQuery.sizeOf(ctx).width,
                        height: MediaQuery.sizeOf(ctx).height,
                        fit: BoxFit.contain,
                      ),
                    ),
                  );
                },
              ),
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
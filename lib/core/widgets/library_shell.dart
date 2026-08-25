import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:provider/provider.dart';

import '../history/history_manager.dart';
import '../favorites/favorites_manager.dart';
import '../models/bookshelf_filter.dart';
import '../models/plugin_config.dart';
import '../theme/app_tokens.dart';
import 'app_animations.dart';
import 'app_empty_state.dart';
import 'app_icon_button.dart';
import 'app_segmented_tabs.dart';
import 'bookshelf_filter_sheet.dart';
import 'favorite_group_bar.dart';
import 'layout_picker_button.dart';
import 'package:nexhub/core/widgets/app_alert_dialog.dart';

/// Unified library shell shared by the media / manga / novel modules.
///
/// Provides:
/// 1. Top icon tabs (library / online / subscribe / sources)
/// 2. AppBar search + filter
/// 3. Sub-tab segments (local / history / favorite) on the library tab
/// 4. Empty state with primary action
///
/// Implemented once here and reused by the three modules. No copy-pasting.
class LibraryShell extends StatefulWidget {
  final String title;

  /// 可覆盖顶栏「书架」Tab 文案（默认 [AppLocalizations.tabLibrary]）。
  /// 仅影视模块传「媒体库」，漫画 / 小说仍用「书架」。
  final String? libraryTabLabel;

  final IconData emptyIcon;
  final String emptyMessage;
  final String? emptyActionLabel;
  final VoidCallback? onEmptyAction;

  /// Per-tab body injection (replaces the former [body] / [bodyBuilder]).
  ///
  /// [libraryBodyBuilder] receives the currently selected sub-tab and the
  /// active [BookshelfFilter] so it can render sub-tab-aware, filter-aware
  /// content (e.g. [BookshelfContent]). The other three bodies are static
  /// widgets that do not depend on the sub-tab.
  final Widget Function(LibrarySubTab subTab, BookshelfFilter filter)?
      libraryBodyBuilder;
  final Widget? onlineBody;
  final Widget? subscribeBody;

  /// Sources tab is rendered inline (no longer pushes a separate route).
  final Widget? sourcesBody;

  /// Floating action button, shown only while the sources tab is active.
  final Widget? floatingActionButton;

  /// Optional [ValueNotifier] to dynamically suppress [floatingActionButton].
  /// When provided, the FAB is hidden while [ValueNotifier.value] is true.
  /// Used by embedded [SourceManagerScreen] to hide the outer FAB during
  /// import preview (where the bottom confirm bar would be occluded).
  final ValueNotifier<bool>? fabSuppressedNotifier;

  /// Search tap handler. Required — every module wires its own search page.
  final VoidCallback onSearch;

  /// Optional category provider for the filter sheet. Given the current
  /// sub-tab, returns the list of distinct categories present in that
  /// sub-tab's data. When null, the filter sheet's category section only
  /// shows "All".
  final List<String> Function(LibrarySubTab subTab)? categoryProvider;

  /// Whether to show the local / history / favorite sub-tabs on the library
  /// top tab.
  final bool showSubTabs;

  /// Source type used to wire the "clear history" AppBar action. When set,
  /// a clear-history icon appears on the library top tab while the history
  /// sub-tab is active; tapping it confirms then clears this module's history
  /// via [HistoryManager.clearHistory]. When null, no clear action is shown.
  final SourceType? historySourceType;

  /// 收藏分类夹所属模块类型。动漫 / 漫画 / 小说三端分类夹互相隔离，
  /// 分组栏与筛选面板都只展示本类型的分组。
  ///
  /// 未显式提供时回落到 [historySourceType]（各模块内两者同值），
  /// 再回落到 [SourceType.animeSource]。
  final SourceType? favoriteSourceType;

  const LibraryShell({
    super.key,
    required this.title,
    this.libraryTabLabel,
    required this.emptyIcon,
    required this.emptyMessage,
    required this.onSearch,
    this.emptyActionLabel,
    this.onEmptyAction,
    this.libraryBodyBuilder,
    this.onlineBody,
    this.subscribeBody,
    this.sourcesBody,
    this.floatingActionButton,
    this.fabSuppressedNotifier,
    this.categoryProvider,
    this.showSubTabs = true,
    this.historySourceType,
    this.favoriteSourceType,
  });

  @override
  State<LibraryShell> createState() => _LibraryShellState();
}

enum LibraryTopTab { library, online, subscribe, sources }

enum LibrarySubTab { local, history, favorite }

class _LibraryShellState extends State<LibraryShell> {
  LibraryTopTab _currentTopTab = LibraryTopTab.library;
  final Set<LibrarySubTab> _sub = <LibrarySubTab>{LibrarySubTab.local};
  BookshelfFilter _filter = const BookshelfFilter();

  /// 当前模块的收藏分类夹类型（三端隔离的判别依据）。
  SourceType get _favType =>
      widget.favoriteSourceType ??
      widget.historySourceType ??
      SourceType.animeSource;

  /// 顶栏标题滚动渐隐进度（0=顶部完整显示，1=已下滚收缩）。
  /// 用 ValueNotifier 仅重建标题本身，避免每帧滚动 setState 整页。
  final ValueNotifier<double> _titleShrink = ValueNotifier<double>(0);

  @override
  void dispose() {
    _titleShrink.dispose();
    super.dispose();
  }

  /// 监听 body 内滚动：0→64px 映射为标题 0→1 的渐隐收缩进度。
  bool _onScroll(ScrollNotification n) {
    if (n.depth == 0 && n.metrics.axis == Axis.vertical) {
      _titleShrink.value = (n.metrics.pixels / 64).clamp(0.0, 1.0);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;

    // 监听 fabSuppressedNotifier，预览模式变化时即时隐藏/恢复 FAB。
    return ListenableBuilder(
      listenable: widget.fabSuppressedNotifier ?? const _NoopListenable(),
      builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: ValueListenableBuilder<double>(
          valueListenable: _titleShrink,
          builder: (context, t, child) => Opacity(
            // 下滚时标题淡至 60% 并轻微缩小，形成层次感；回到顶部还原。
            opacity: 1.0 - 0.4 * t,
            child: Transform.scale(scale: 1.0 - 0.08 * t, child: child),
          ),
          child: Text(_topTabLabel(l10n)),
        ),
        centerTitle: true,
        leading: _currentTopTab == LibraryTopTab.library
            ? IconButton(
                icon: const Icon(Icons.search_outlined),
                tooltip: l10n.search,
                onPressed: widget.onSearch,
              )
            : null,
        actions: <Widget>[
          if (_currentTopTab == LibraryTopTab.library) ...[
            // 本地子段始终保留导入入口（顶栏图标，避免嵌套 Scaffold 时 FAB 被底栏遮挡看不到）。
            if (widget.onEmptyAction != null &&
                _sub.first == LibrarySubTab.local)
              IconButton(
                icon: const Icon(Icons.add),
                tooltip: widget.emptyActionLabel ?? l10n.import,
                onPressed: widget.onEmptyAction,
              ),
            if (widget.historySourceType != null &&
                _sub.first == LibrarySubTab.history)
              IconButton(
                icon: const Icon(Icons.delete_sweep_outlined),
                tooltip: l10n.clearHistory,
                onPressed: _confirmClearHistory,
              ),
            AppIconButton(
              icon: Icons.filter_list_outlined,
              tooltip: l10n.filter,
              onPressed: _openFilterSheet,
              color: _filter.isDefault ? null : scheme.primary,
            ),
            const LayoutPickerButton(),
          ],
        ],
      ),
      body: NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: Column(
          children: <Widget>[
            _buildTopTabs(l10n, scheme),
            if (_currentTopTab == LibraryTopTab.library && widget.showSubTabs)
              _buildSubTabs(l10n),
            // 分组栏（仅收藏子段）：显隐用 AnimatedSize 平滑过渡。
            AnimatedSize(
              duration: AppTokens.durBase,
              curve: AppCurves.smooth,
              alignment: Alignment.topCenter,
              child: (_currentTopTab == LibraryTopTab.library &&
                      widget.showSubTabs &&
                      _sub.first == LibrarySubTab.favorite)
                  ? FavoriteGroupBar(
                      sourceType: _favType,
                      selectedGroupIds: _filter.groupIds,
                      onChanged: (Set<String> ids) => setState(
                          () => _filter = _filter.copyWith(groupIds: ids)),
                    )
                  : const SizedBox.shrink(),
            ),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
      floatingActionButton: _buildFab(l10n),
    ),
    );
  }

  Widget? _buildFab(AppLocalizations l10n) {
    // 仅源管理 top tab 显示 FAB（collect API 导入）；本地导入入口改由顶栏图标提供。
    if (_currentTopTab == LibraryTopTab.sources &&
        widget.floatingActionButton != null &&
        !(widget.fabSuppressedNotifier?.value ?? false)) {
      return widget.floatingActionButton;
    }
    return null;
  }

  Future<void> _confirmClearHistory() async {
    final SourceType? type = widget.historySourceType;
    if (type == null) return;
    final AppLocalizations l10n = AppLocalizations.of(context);
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AppAlertDialog(
        title: Text(l10n.clearHistory),
        content: Text(l10n.clearHistoryConfirm),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.confirm),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await context.read<HistoryManager>().clearHistory(type);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.historyCleared)),
    );
  }

  Future<void> _openFilterSheet() async {
    final List<String> categories =
        widget.categoryProvider?.call(_sub.first) ?? <String>[];
    final BookshelfFilter? result = await showBookshelfFilterSheet(
      context,
      initialFilter: _filter,
      categories: categories,
      sourceType: _sourceTypeForSubTab(_sub.first),
      // 分组段仅收藏子段有意义，其余子段不展示。
      groups: _sub.first == LibrarySubTab.favorite
          ? context.read<FavoritesManager>().groupsFor(_favType)
          : const [],
    );
    if (result != null && mounted) {
      setState(() => _filter = result);
    }
  }

  /// 当前子段所属模块类型：收藏段取 [_favType]，历史/已下载段取
  /// [historySourceType]（未提供时回落 [_favType]）。用于筛选面板按类型渲染排序项。
  SourceType _sourceTypeForSubTab(LibrarySubTab sub) {
    switch (sub) {
      case LibrarySubTab.favorite:
        return _favType;
      case LibrarySubTab.history:
      case LibrarySubTab.local:
        return widget.historySourceType ?? _favType;
    }
  }

  String _topTabLabel(AppLocalizations l10n) {
    switch (_currentTopTab) {
      case LibraryTopTab.library:
        return widget.libraryTabLabel ?? l10n.tabLibrary;
      case LibraryTopTab.online:
        return l10n.tabOnline;
      case LibraryTopTab.subscribe:
        return l10n.tabSubscribe;
      case LibraryTopTab.sources:
        return l10n.tabSources;
    }
  }

  Widget _buildBody() {
    switch (_currentTopTab) {
      case LibraryTopTab.library:
        // 筛选结果切换动效：fade + 轻微上滑（key 随筛选状态变化）。
        return AnimatedSwitcher(
          duration: AppTokens.durBase,
          switchInCurve: AppCurves.smooth,
          switchOutCurve: AppCurves.smooth,
          transitionBuilder: (Widget child, Animation<double> anim) =>
              FadeTransition(
            opacity: anim,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.02),
                end: Offset.zero,
              ).animate(anim),
              child: child,
            ),
          ),
          child: KeyedSubtree(
            key: ValueKey<Object>((_sub.first, _filter)),
            child: widget.libraryBodyBuilder?.call(_sub.first, _filter) ??
                _buildEmptyState(),
          ),
        );
      case LibraryTopTab.online:
        return widget.onlineBody ?? _buildEmptyState();
      case LibraryTopTab.subscribe:
        return widget.subscribeBody ?? _buildEmptyState();
      case LibraryTopTab.sources:
        return widget.sourcesBody ?? _buildEmptyState();
    }
  }

  Widget _buildTopTabs(AppLocalizations l10n, ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTokens.spaceMd,
        vertical: AppTokens.spaceXs,
      ),
      // 每个页签用 Expanded 均分宽度：窄屏下 4 个页签（含长文案如英文
      // "Subscribe"/"Sources"）也不会横向溢出（修复 130：页面不适配部分手机）。
      child: Row(
        children: <Widget>[
          Expanded(
            child: _TopTabItem(
              icon: Icons.menu_book_outlined,
              label: widget.libraryTabLabel ?? l10n.tabLibrary,
              selected: _currentTopTab == LibraryTopTab.library,
              onTap: () => _selectTop(LibraryTopTab.library),
              scheme: scheme,
            ),
          ),
          Expanded(
            child: _TopTabItem(
              icon: Icons.language_outlined,
              label: l10n.tabOnline,
              selected: _currentTopTab == LibraryTopTab.online,
              onTap: () => _selectTop(LibraryTopTab.online),
              scheme: scheme,
            ),
          ),
          Expanded(
            child: _TopTabItem(
              icon: Icons.rss_feed_outlined,
              label: l10n.tabSubscribe,
              selected: _currentTopTab == LibraryTopTab.subscribe,
              onTap: () => _selectTop(LibraryTopTab.subscribe),
              scheme: scheme,
            ),
          ),
          Expanded(
            child: _TopTabItem(
              icon: Icons.extension_outlined,
              label: l10n.tabSources,
              selected: _currentTopTab == LibraryTopTab.sources,
              onTap: () => _selectTop(LibraryTopTab.sources),
              scheme: scheme,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSubTabs(AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTokens.spaceLg,
        vertical: AppTokens.spaceSm,
      ),
      child: AppSegmentedTabs<LibrarySubTab>(
        selected: _sub,
        onSelectionChanged: (Set<LibrarySubTab> s) =>
            setState(() => _sub..clear()..addAll(s)),
        segments: <ButtonSegment<LibrarySubTab>>[
          ButtonSegment<LibrarySubTab>(
              value: LibrarySubTab.local, label: Text(l10n.subTabLocal)),
          ButtonSegment<LibrarySubTab>(
              value: LibrarySubTab.history, label: Text(l10n.subTabHistory)),
          ButtonSegment<LibrarySubTab>(
              value: LibrarySubTab.favorite, label: Text(l10n.subTabFavorite)),
        ],
      ),
    );
  }

  Widget _buildEmptyState() => AppEmptyState(
        icon: widget.emptyIcon,
        message: widget.emptyMessage,
        actionLabel: widget.emptyActionLabel,
        onAction: widget.onEmptyAction,
      );

  void _selectTop(LibraryTopTab tab) {
    // 切换顶部页签后新页从顶部开始 → 标题还原为完整状态。
    _titleShrink.value = 0;
    setState(() => _currentTopTab = tab);
  }
}

class _TopTabItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final ColorScheme scheme;

  const _TopTabItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    required this.scheme,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTokens.radiusSm),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppTokens.spaceSm,
          vertical: AppTokens.spaceXs,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              icon,
              size: 22,
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppTokens.spaceXxs),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: selected ? scheme.primary : scheme.onSurfaceVariant,
                    fontWeight:
                        selected ? FontWeight.w600 : FontWeight.normal,
                  ),
            ),
            const SizedBox(height: AppTokens.spaceXs),
            // 选中态下划线指示器（对齐 AppTabBar UnderlineTabIndicator 写法）
            Container(
              height: 2,
              width: 32,
              decoration: BoxDecoration(
                color: selected ? scheme.primary : Colors.transparent,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 空操作 [Listenable]，当 [fabSuppressedNotifier] 为 null 时使用，
/// 避免 [ListenableBuilder] 因 listenable 为 null 崩溃。
class _NoopListenable implements Listenable {
  const _NoopListenable();
  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
}
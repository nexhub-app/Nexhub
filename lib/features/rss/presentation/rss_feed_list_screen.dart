/// RSS 订阅源列表页 —— 新版设计。
///
/// 空状态居中显示图标+提示文字，右下角 FAB 添加订阅。
/// 有数据时显示列表。
///
/// 三模块共用，通过 [moduleType] 过滤订阅源。
/// 也用于浏览页全局 RSS（moduleType = null）。
library;

import 'dart:developer' as dev;

import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:provider/provider.dart';

import '../../../core/models/plugin_config.dart';
import '../../../core/rss/rss_feed.dart';
import '../../../core/rss/rss_manager.dart';
import '../../../core/rss/rss_update_checker.dart';
import '../../../core/settings/general_settings.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_empty_state.dart';
import '../../../core/widgets/app_animations.dart';
import '../../../core/widgets/source_image.dart';
import 'rss_feed_detail_screen.dart';
import 'rss_add_subscription_screen.dart';
import 'rss_opml_screen.dart';
import 'rss_discovery_screen.dart';
import 'rss_search_screen.dart';
import 'package:nexhub/core/navigation/app_page_route.dart';
import 'package:nexhub/core/widgets/app_alert_dialog.dart';

class RssFeedListScreen extends StatefulWidget {
  /// 绑定的模块类型（null = 浏览页全局 RSS）。
  final SourceType? moduleType;

  const RssFeedListScreen({super.key, this.moduleType});

  @override
  State<RssFeedListScreen> createState() => _RssFeedListScreenState();
}

class _RssFeedListScreenState extends State<RssFeedListScreen> {
  /// 测速结果：feedId → 延迟毫秒（-1 = 失败，null = 测试中）。
  final Map<String, int?> _speeds = {};
  bool _testingAll = false;

  /// 本地兜底隐藏集合：unbind 后立即从本屏（分类视图）过滤，确保「移回全局」
  /// 后一定从分类列表消失，不依赖 notifyListeners/watch 时序（bug 兜底）。
  final Set<String> _hiddenIds = {};

  /// 当前选中的分组筛选（null = 全部；'' = 未分组；其他 = 分组名）。
  /// 仅全局视图（moduleType == null）下生效，因分组是跨模块标签语义。
  String? _activeGroup;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final manager = context.watch<RssManager>();
    final checker = context.watch<RssUpdateChecker>();
    // 全局视图（moduleType == null）显示全部订阅：绑定到分类的订阅不消失，
    // 同时出现在对应模块分类页（feedsFor 按 moduleType 过滤）。分类视图仅显示本分类订阅。
    final feeds = widget.moduleType == null
        ? manager.feeds
        : manager.feedsFor(widget.moduleType);
    // 分类视图（moduleType != null）应用本地隐藏兜底：unbind 的 feed 立即从本屏移除；
    // 全局视图（moduleType == null）显示全部订阅，不做隐藏。
    final visibleFeeds = widget.moduleType == null
        ? feeds
        : feeds.where((f) => !_hiddenIds.contains(f.id)).toList();

    // 全局视图下按分组筛选（分组是跨模块标签，分类视图不启用以免语义混乱）。
    final bool groupFilterOn = widget.moduleType == null &&
        _activeGroup != null &&
        manager.allGroups.isNotEmpty;
    final feedsToShow = groupFilterOn
        ? (_activeGroup!.isEmpty
            ? visibleFeeds.where((f) => f.groups.isEmpty).toList()
            : visibleFeeds
                .where((f) => f.groups.contains(_activeGroup))
                .toList())
        : visibleFeeds;

    // 全局视图分组条：全部 / 各分组 / 未分组（水平可滚动）。无分组时不显示。
    final bool canShowGroupBar =
        widget.moduleType == null && manager.allGroups.isNotEmpty;

    // 根据类型选择不同的空状态图标
    final IconData emptyIcon = switch (widget.moduleType) {
      SourceType.novelSource => Icons.menu_book_outlined,
      SourceType.animeSource => Icons.movie_outlined,
      SourceType.mangaSource => Icons.auto_stories_outlined,
      _ => Icons.rss_feed_outlined,
    };

    return Scaffold(
      appBar: widget.moduleType == null
          ? AppBar(
              // 全局视图保留顶栏（返回导航）；标题与测速/更多按要求删去。
            )
          : null,
      body: visibleFeeds.isEmpty
          ? AppEmptyState(
              icon: emptyIcon,
              message: l10n.emptyRssSubscribe,
            )
          : ListView.separated(
              padding: const EdgeInsets.all(AppTokens.spaceMd),
              itemCount: feedsToShow.length + (canShowGroupBar ? 1 : 0),
              separatorBuilder: (_, __) =>
                  const SizedBox(height: AppTokens.spaceSm),
              itemBuilder: (context, i) {
                // 第一项：分组筛选条（水平可滚动芯片）。
                if (canShowGroupBar && i == 0) {
                  return _buildGroupBar(context, manager, l10n, scheme);
                }
                final int feedIndex = i - (canShowGroupBar ? 1 : 0);
                final feed = feedsToShow[feedIndex];
                final newCount = checker.newCountFor(feed.id);
                return Entrance(
                  // 首屏逐条交错入场（最多 8 条），滚动回来不重播。
                  index: feedIndex < 8 ? feedIndex : 8,
                  offset: 12,
                  fromScale: 0.98,
                  onceKey: 'rssfeed:${feed.id}',
                  child: AppCard(
                    onTap: () {
                      // 进入详情时清零未读数
                      if (newCount > 0) {
                        checker.markRead(feed.id);
                      }
                      Navigator.of(context).push(
                        AppPageRoute<void>(
                          builder: (_) => RssFeedDetailScreen(feed: feed),
                        ),
                      );
                    },
                    padding: EdgeInsets.zero,
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: AppTokens.spaceLg,
                        vertical: AppTokens.spaceXs,
                      ),
                      leading: _feedLeadingIcon(feed, scheme),
                      title: Text(
                        feed.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        _speedSubtitle(feed, l10n),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          if (newCount > 0)
                            // 隐私设置「隐藏通知内容」：只显示中性圆点，
                            // 不暴露未读具体数量，防旁人窥屏。
                            GeneralSettingsStore
                                    .instance.settings.hideNotificationContent
                                ? Container(
                                    width: 16,
                                    height: 16,
                                    decoration: BoxDecoration(
                                      color: scheme.primary,
                                      shape: BoxShape.circle,
                                    ),
                                  )
                                : AnimatedSwitcher(
                                    // 未读数变化时缩放淡入，灵动反馈。
                                    duration: AppTokens.durBase,
                                    switchInCurve: AppCurves.spring,
                                    switchOutCurve: Curves.easeOutCubic,
                                    transitionBuilder: (Widget child,
                                            Animation<double> anim) =>
                                        ScaleTransition(
                                            scale: anim, child: child),
                                    child: Container(
                                      key: ValueKey<int>(newCount),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: scheme.primary,
                                        borderRadius: BorderRadius.circular(
                                            AppTokens.radiusFull),
                                      ),
                                      child: Text(
                                        '$newCount',
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelSmall
                                            ?.copyWith(color: scheme.onPrimary),
                                      ),
                                    ),
                                  )
                          else
                            const SizedBox.shrink(),
                          // 溢出菜单：聚合 绑定/移回/测速/编辑/删除，避免行内按钮过多（手机端杂乱）。
                          PopupMenuButton<String>(
                            icon: Icon(Icons.more_vert,
                                color: scheme.onSurfaceVariant),
                            tooltip: l10n.moreActions,
                            onSelected: (action) =>
                                _onFeedMenuItem(action, context, manager, feed),
                            itemBuilder: (ctx) => <PopupMenuEntry<String>>[
                              if (widget.moduleType == null &&
                                  feed.moduleType == null)
                                PopupMenuItem<String>(
                                  value: 'bind',
                                  child: ListTile(
                                    leading:
                                        const Icon(Icons.playlist_add_outlined),
                                    title: Text(l10n.rssBindModuleTitle),
                                    contentPadding: EdgeInsets.zero,
                                  ),
                                ),
                              if (widget.moduleType != null)
                                PopupMenuItem<String>(
                                  value: 'unbind',
                                  child: ListTile(
                                    leading: const Icon(
                                        Icons.playlist_remove_outlined),
                                    title: Text(l10n.rssUnbindGlobal),
                                    contentPadding: EdgeInsets.zero,
                                  ),
                                ),
                              PopupMenuItem<String>(
                                value: 'speed',
                                child: ListTile(
                                  leading: const Icon(Icons.speed),
                                  title: Text(l10n.rssTestSpeed),
                                  contentPadding: EdgeInsets.zero,
                                ),
                              ),
                              PopupMenuItem<String>(
                                value: 'edit',
                                child: ListTile(
                                  leading: const Icon(Icons.edit_outlined),
                                  title: Text(l10n.editRoute),
                                  contentPadding: EdgeInsets.zero,
                                ),
                              ),
                              PopupMenuItem<String>(
                                value: 'groups',
                                child: ListTile(
                                  leading: const Icon(Icons.folder_outlined),
                                  title: Text(l10n.rssSetGroups),
                                  contentPadding: EdgeInsets.zero,
                                ),
                              ),
                              PopupMenuItem<String>(
                                value: 'delete',
                                child: ListTile(
                                  leading: Icon(Icons.delete_outline,
                                      color: scheme.error),
                                  title: Text(l10n.delete,
                                      style: TextStyle(color: scheme.error)),
                                  contentPadding: EdgeInsets.zero,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
      // 右下角 FAB 添加按钮（匹配截图 7）
      floatingActionButton: FloatingActionButton(
        onPressed: () => _navigateToAdd(context),
        backgroundColor: scheme.secondaryContainer,
        foregroundColor: scheme.onSecondaryContainer,
        child: const Icon(Icons.add),
      ),
    );
  }

  /// 测速结果的副标题显示。
  String _speedSubtitle(RssFeed feed, AppLocalizations l10n) {
    final speed = _speeds[feed.id];
    if (speed == null) return feed.description ?? feed.url;
    if (speed < 0)
      return '${feed.description ?? feed.url} · ${l10n.rssSpeedFailed}';
    return '${feed.description ?? feed.url} · ${l10n.rssSpeedMs(speed)}';
  }

  /// 订阅列表项左侧图标：优先显示站点 favicon（B8 修复），加载失败/无图时
  /// 回退到通用 RSS 图标。favicon 经 [RssFeed.effectiveIconUrl] 解析
  /// （自带 iconUrl 优先，否则站点根 /favicon.ico）。
  ///
  /// 走 [SourceImage] 而非裸 `Image.network`：后者不带 UA/Referer 也不走
  /// 应用代理（Dio 统一下载），防盗链站点与代理环境下大量 favicon 加载
  /// 失败回退默认图。失败静默回退芯片图标（不显示重试 UI）。
  Widget _feedLeadingIcon(RssFeed feed, ColorScheme scheme) {
    final icon = feed.effectiveIconUrl;
    if (icon == null) return _rssIconChip(scheme);
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppTokens.radiusSm),
      child: SourceImage(
        url: icon,
        width: 40,
        height: 40,
        fit: BoxFit.cover,
        enableRetry: false,
        placeholder: _rssIconChip(scheme),
        errorWidget: _rssIconChip(scheme),
      ),
    );
  }

  Widget _rssIconChip(ColorScheme scheme) => Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: scheme.primaryContainer.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(AppTokens.radiusSm),
        ),
        child: Icon(Icons.rss_feed, color: scheme.primary, size: 22),
      );

  /// 一键测速全部订阅源（P8.2.3 §廿二）。
  Future<void> _testAllSpeed(RssManager manager) async {
    setState(() {
      _testingAll = true;
      _speeds.clear();
    });
    await manager.testAllFeeds(
      onProgress: (feedId, ms) {
        if (mounted) {
          setState(() => _speeds[feedId] = ms);
        }
      },
    );
    if (mounted) setState(() => _testingAll = false);
  }

  void _navigateToAdd(BuildContext context) {
    Navigator.of(context).push(
      AppPageRoute<void>(
        builder: (_) => RssAddSubscriptionScreen(
          moduleType: widget.moduleType,
        ),
      ),
    );
  }

  void _confirmDelete(
    BuildContext context,
    RssManager manager,
    String feedId,
    String feedTitle,
  ) {
    final l10n = AppLocalizations.of(context);

    showDialog<void>(
      context: context,
      builder: (dialogContext) => AppAlertDialog(
        title: Text(l10n.deleteConfirmTitle),
        content: Text(l10n.deleteConfirmContent(feedTitle)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () {
              manager.removeFeed(feedId);
              Navigator.of(dialogContext).pop();
            },
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
  }

  /// 编辑订阅的 RSS 路由（URL）与标题，保存即调用 [RssManager.updateFeed]。
  void _showEditDialog(
    BuildContext context,
    RssManager manager,
    RssFeed feed,
  ) {
    final l10n = AppLocalizations.of(context);
    final titleCtrl = TextEditingController(text: feed.title);
    final urlCtrl = TextEditingController(text: feed.url);
    final formKey = GlobalKey<FormState>();

    showDialog<void>(
      context: context,
      builder: (dialogContext) => AppAlertDialog(
        title: Text(l10n.editRoute),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextFormField(
                controller: titleCtrl,
                decoration: InputDecoration(labelText: l10n.routeTitle),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? l10n.requiredHint : null,
              ),
              const SizedBox(height: AppTokens.spaceSm),
              TextFormField(
                controller: urlCtrl,
                decoration: InputDecoration(labelText: l10n.routeUrl),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? l10n.requiredHint : null,
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() != true) return;
              manager.updateFeed(
                feed.copyWith(
                  title: titleCtrl.text.trim(),
                  url: urlCtrl.text.trim(),
                ),
              );
              Navigator.of(dialogContext).pop();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(l10n.routeSaved)),
                );
              }
            },
            child: Text(l10n.save),
          ),
        ],
      ),
    );
  }

  /// 订阅项溢出菜单分发：bind / unbind / speed / edit / delete。
  Future<void> _onFeedMenuItem(
    String action,
    BuildContext context,
    RssManager manager,
    RssFeed feed,
  ) async {
    final l10n = AppLocalizations.of(context);
    switch (action) {
      case 'bind':
        _showBindDialog(context, manager, feed);
      case 'unbind':
        // 三重保险：unbindFeed（按 id/url 兜底改内存+notify）→ notifyChanged
        // （强制 watch 重建）→ setState（本屏强制重绘），确保一定从分类列表移除。
        try {
          await manager.unbindFeed(feed.id, feed.url);
        } on Object {
          // 忽略异常，依赖下方兜底刷新。
        }
        manager.notifyChanged();
        dev.log('[RSS] unbind feed=${feed.id} 处理后分类剩 '
            '${manager.feedsFor(widget.moduleType).length} 条');
        // 本地兜底：立即从本屏（分类视图）隐藏该订阅，确保一定消失。
        if (mounted) {
          setState(() {
            _hiddenIds.add(feed.id);
          });
        }
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.rssUnbindGlobal)),
          );
        }
      case 'speed':
        final ms = await manager.testFeedSpeed(feed);
        setState(() => _speeds[feed.id] = ms);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(ms < 0 ? l10n.rssSpeedFailed : l10n.rssSpeedMs(ms)),
            ),
          );
        }
      case 'edit':
        _showEditDialog(context, manager, feed);
      case 'groups':
        _showGroupAssign(context, manager, feed);
      case 'delete':
        _confirmDelete(context, manager, feed.id, feed.title);
    }
  }

  /// 将全局订阅绑定到某个模块（小说/漫画/视频）。
  ///
  /// 绑定后该订阅从全局视图消失、出现在对应模块分类页（feedsFor 按 moduleType 过滤）。
  void _showBindDialog(
    BuildContext context,
    RssManager manager,
    RssFeed feed,
  ) {
    final l10n = AppLocalizations.of(context);
    final options = <SourceType, String>{
      SourceType.novelSource: l10n.rssBindToNovel,
      SourceType.animeSource: l10n.rssBindToAnime,
      SourceType.mangaSource: l10n.rssBindToManga,
    };
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AppAlertDialog(
        title: Text(l10n.rssBindModuleTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: options.entries
              .map((e) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.playlist_add_outlined),
                    title: Text(e.value),
                    onTap: () async {
                      await manager
                          .updateFeed(feed.copyWith(moduleType: e.key));
                      // 若该 feed 此前被本地隐藏（unbind 兜底），绑定后解除隐藏。
                      if (mounted) {
                        setState(() {
                          _hiddenIds.remove(feed.id);
                        });
                      }
                      if (dialogContext.mounted) {
                        ScaffoldMessenger.of(dialogContext).showSnackBar(
                          SnackBar(content: Text(e.value)),
                        );
                        Navigator.of(dialogContext).pop();
                      }
                    },
                  ))
              .toList(),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.cancel),
          ),
        ],
      ),
    );
  }

  /// 顶部「更多」菜单分发：OPML 导入导出 / 网站发现 / 管理分组。
  void _onTopMenu(String action, BuildContext context, RssManager manager) {
    switch (action) {
      case 'opml':
        Navigator.of(context).push(
          AppPageRoute<void>(builder: (_) => const RssOpmlScreen()),
        );
      case 'discover':
        Navigator.of(context).push(
          AppPageRoute<void>(builder: (_) => const RssDiscoveryScreen()),
        );
      case 'global_search':
        Navigator.of(context).push(
          AppPageRoute<void>(builder: (_) => const RssSearchScreen()),
        );
      case 'manage_groups':
        _showManageGroups(context, manager);
    }
  }

  /// 分组筛选条（水平可滚动芯片）：全部 / 各分组 / 未分组。
  Widget _buildGroupBar(
    BuildContext context,
    RssManager manager,
    AppLocalizations l10n,
    ColorScheme scheme,
  ) {
    final groups = manager.allGroups;
    return Container(
      height: 40,
      margin: const EdgeInsets.only(bottom: AppTokens.spaceXs),
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: <Widget>[
          _groupChip(l10n.rssGroupAll, _activeGroup == null, scheme, () {
            setState(() => _activeGroup = null);
          }),
          for (final g in groups)
            _groupChip(g, _activeGroup == g, scheme, () {
              setState(() => _activeGroup = g);
            }),
          _groupChip(l10n.rssGroupUngrouped, _activeGroup == '', scheme, () {
            setState(() => _activeGroup = '');
          }),
        ],
      ),
    );
  }

  Widget _groupChip(
    String label,
    bool selected,
    ColorScheme scheme,
    VoidCallback onTap,
  ) {
    return Padding(
      padding: const EdgeInsets.only(right: AppTokens.spaceSm),
      child: AppTapScale(
        scale: 0.94,
        duration: AppTokens.durFast,
        child: FilterChip(
          label: Text(label),
          selected: selected,
          onSelected: (_) => onTap(),
        ),
      ),
    );
  }

  /// 为单个订阅指定分组（多选覆盖式）+ 快捷新建分组。
  void _showGroupAssign(
      BuildContext context, RssManager manager, RssFeed feed) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final selected = <String>{...feed.groups};
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(AppTokens.radiusLg)),
      ),
      builder: (sheetCtx) {
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            final groups = manager.allGroups;
            return AppSheetBody(
              child: SafeArea(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.85,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          AppTokens.spaceMd,
                          AppTokens.spaceSm,
                          AppTokens.spaceMd,
                          0,
                        ),
                        child: Text(
                          '${l10n.rssSetGroups} · ${feed.title}',
                          style: Theme.of(context).textTheme.titleMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(height: AppTokens.spaceMd),
                      if (groups.isEmpty)
                        Padding(
                          padding:
                              const EdgeInsets.only(bottom: AppTokens.spaceSm),
                          child: Text(
                            l10n.rssGroupEmpty,
                            textAlign: TextAlign.center,
                            style:
                                Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                    ),
                          ),
                        ),
                      Flexible(
                        child: SingleChildScrollView(
                          child: Wrap(
                            spacing: AppTokens.spaceSm,
                            runSpacing: AppTokens.spaceXs,
                            children: <Widget>[
                              for (final g in groups)
                                FilterChip(
                                  label: Text(g),
                                  selected: selected.contains(g),
                                  onSelected: (on) => setSheet(() {
                                    on ? selected.add(g) : selected.remove(g);
                                  }),
                                ),
                              ActionChip(
                                avatar: const Icon(Icons.add, size: 16),
                                label: Text(l10n.rssGroupAdd),
                                onPressed: () async {
                                  final name =
                                      await _promptGroupName(context, l10n);
                                  if (name != null) {
                                    await manager.renameGroup(name, name);
                                    setSheet(() => selected.add(name));
                                  }
                                },
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: AppTokens.spaceMd),
                      Padding(
                        padding: const EdgeInsets.all(AppTokens.spaceMd),
                        child: FilledButton(
                          onPressed: () async {
                            await manager.setFeedGroups(
                                feed.id, selected.toList());
                            if (ctx.mounted) Navigator.of(ctx).pop();
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text(l10n.rssGroupSetDone)),
                              );
                            }
                          },
                          child: Text(l10n.confirm),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// 管理分组：列出全部分组，支持重命名 / 删除 / 新建。
  void _showManageGroups(BuildContext context, RssManager manager) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(AppTokens.radiusLg)),
      ),
      builder: (sheetCtx) {
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            final groups = manager.allGroups;
            return AppSheetBody(
              child: SafeArea(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.85,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Padding(
                        padding: const EdgeInsets.all(AppTokens.spaceMd),
                        child: Row(
                          children: <Widget>[
                            Text(l10n.rssGroupManage,
                                style: Theme.of(context).textTheme.titleMedium),
                            const Spacer(),
                            TextButton.icon(
                              icon: const Icon(Icons.add, size: 18),
                              label: Text(l10n.rssGroupAdd),
                              onPressed: () async {
                                // 就地新建：分组已有一等公民注册表（RssManager
                                // 独立持久化），空分组也能存在，无需先挂到某个
                                // 订阅上——此前这里只弹提示把用户踢去订阅项，
                                // 点了「新建」却看不到任何反馈。
                                final name =
                                    await _promptGroupName(context, l10n);
                                if (name == null || name.isEmpty) return;
                                final bool created =
                                    await manager.createGroup(name);
                                if (!ctx.mounted) return;
                                // 刷新面板列表（新分组立即出现在下方）。
                                setSheet(() {});
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(created
                                          ? l10n.rssGroupSetDone
                                          : l10n.rssGroupAddExists(name)),
                                    ),
                                  );
                                }
                              },
                            ),
                          ],
                        ),
                      ),
                      Flexible(
                        child: groups.isEmpty
                            ? Padding(
                                padding:
                                    const EdgeInsets.all(AppTokens.spaceMd),
                                child: Text(
                                  l10n.rssGroupEmpty,
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
                                          color: scheme.onSurfaceVariant),
                                ),
                              )
                            : ListView.builder(
                                shrinkWrap: true,
                                itemCount: groups.length,
                                itemBuilder: (lctx, i) {
                                  final g = groups[i];
                                  final count = manager.feedsInGroup(g).length;
                                  return Entrance(
                                    index: i < 8 ? i : 8,
                                    onceKey: 'mgrp:$g',
                                    child: ListTile(
                                      leading:
                                          const Icon(Icons.folder_outlined),
                                      title: Text(g),
                                      subtitle:
                                          Text(l10n.rssGroupFeedCount(count)),
                                      trailing: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: <Widget>[
                                          IconButton(
                                            icon:
                                                const Icon(Icons.edit_outlined),
                                            tooltip: l10n.rssGroupRename,
                                            onPressed: () async {
                                              final newName =
                                                  await _promptGroupName(
                                                      context, l10n,
                                                      initial: g);
                                              if (newName != null &&
                                                  newName != g) {
                                                await manager.renameGroup(
                                                    g, newName);
                                                setSheet(() {});
                                              }
                                            },
                                          ),
                                          IconButton(
                                            icon: Icon(Icons.delete_outline,
                                                color: scheme.error),
                                            tooltip: l10n.rssGroupDelete,
                                            onPressed: () async {
                                              final ok =
                                                  await _confirmDeleteGroup(
                                                      context,
                                                      manager,
                                                      g,
                                                      l10n);
                                              if (ok) setSheet(() {});
                                            },
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// 输入分组名（新建 / 重命名共用）。返回 null 表示取消。
  Future<String?> _promptGroupName(
    BuildContext context,
    AppLocalizations l10n, {
    String? initial,
  }) async {
    final ctrl = TextEditingController(text: initial ?? '');
    return showDialog<String>(
      context: context,
      builder: (dialogCtx) {
        final l10n = AppLocalizations.of(dialogCtx);
        return AlertDialog(
          title: Text(initial == null ? l10n.rssGroupAdd : l10n.rssGroupRename),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: InputDecoration(
              labelText: l10n.rssGroupName,
              border: const OutlineInputBorder(),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: () {
                final v = ctrl.text.trim();
                if (v.isEmpty) return;
                Navigator.of(dialogCtx).pop(v);
              },
              child: Text(l10n.ok),
            ),
          ],
        );
      },
    );
  }

  /// 删除分组确认：仅移除分组标记，不删订阅。
  Future<bool> _confirmDeleteGroup(
    BuildContext context,
    RssManager manager,
    String name,
    AppLocalizations l10n,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AppAlertDialog(
        title: Text(l10n.rssGroupDelete),
        content: Text(l10n.rssGroupDeleteConfirm(name)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    if (ok == true) {
      await manager.deleteGroup(name);
      if (mounted && _activeGroup == name) {
        setState(() => _activeGroup = null);
      }
      return true;
    }
    return false;
  }
}

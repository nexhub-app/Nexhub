/// 收藏分组栏（收藏子段专用）。
///
/// 水平滚动的栏：最前面为「管理」入口，其后 [全部] [未分组] [分组…]。
/// 由 [LibraryShell] 渲染在子段 Tab 与 body 之间，仅
/// library 顶部 Tab + favorite 子段时显示。
/// 多选并集语义：命中任一分组即显示（与 [BookshelfFilter.groupIds] 一致）。
/// 点击任一 chip 会自动滚动使其居中。
library;

import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:provider/provider.dart';

import '../favorites/favorite_group.dart';
import '../favorites/favorites_manager.dart';
import '../models/plugin_config.dart';
import '../theme/app_tokens.dart';
import 'app_animations.dart';
import 'favorite_group_manage_sheet.dart';

class FavoriteGroupBar extends StatefulWidget {
  /// 当前选中的分组 id 集合（空集 = 全部；可含 [kUngroupedId]）。
  final Set<String> selectedGroupIds;

  /// 选中变化回调（回传新的完整集合）。
  final ValueChanged<Set<String>> onChanged;

  /// 当前模块类型（决定展示哪些分组）。
  final SourceType sourceType;

  const FavoriteGroupBar({
    super.key,
    required this.selectedGroupIds,
    required this.onChanged,
    required this.sourceType,
  });

  @override
  State<FavoriteGroupBar> createState() => _FavoriteGroupBarState();
}

class _FavoriteGroupBarState extends State<FavoriteGroupBar> {
  final ScrollController _scrollController = ScrollController();

  // 固定 chip 的 GlobalKey 必须是 State 级字段：若每次 build 新建，
  // 子树会被销毁重建，选中脉冲动画会丢失。
  final GlobalKey _manageKey = GlobalKey();
  final GlobalKey _allKey = GlobalKey();
  final GlobalKey _ungroupedKey = GlobalKey();

  // 分组 chip 的 key 按 id 记忆化复用：既能跨 build 保持稳定（居中滚动可靠），
  // 又避免 GlobalObjectKey<String> 违反 GlobalKey<T extends State<...>> 约束。
  final Map<String, GlobalKey> _groupKeys = <String, GlobalKey>{};
  GlobalKey _keyFor(String id) =>
      _groupKeys.putIfAbsent(id, () => GlobalKey());

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// 切换单个分组 id 的选中态，返回新集合。
  Set<String> _toggled(String id) {
    final Set<String> next = Set<String>.of(widget.selectedGroupIds);
    if (!next.remove(id)) next.add(id);
    return next;
  }

  /// 点击 chip 后滚动使其居中（alignment 0.5）。
  void _scrollToCenter(GlobalKey key) {
    final BuildContext? ctx = key.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.5,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final List<FavoriteGroup> groups =
        context.watch<FavoritesManager>().groupsFor(widget.sourceType);

    return SizedBox(
      height: 44,
      child: ListView(
        controller: _scrollController,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppTokens.spaceMd),
        children: <Widget>[
          // 「管理」入口放到最前面，便于随时隐藏 / 显示、排序分类。
          Padding(
            padding: const EdgeInsets.only(right: AppTokens.spaceSm),
            child: ActionChip(
              key: _manageKey,
              avatar: const Icon(Icons.tune_outlined, size: 16),
              label: Text(l10n.manageGroups),
              onPressed: () {
                _scrollToCenter(_manageKey);
                showFavoriteGroupManageSheet(
                  context,
                  sourceType: widget.sourceType,
                );
              },
            ),
          ),
          _GroupChip(
            key: _allKey,
            label: l10n.groupAll,
            selected: widget.selectedGroupIds.isEmpty,
            onTap: () {
              _scrollToCenter(_allKey);
              widget.onChanged(const <String>{});
            },
          ),
          _GroupChip(
            key: _ungroupedKey,
            label: l10n.groupUngrouped,
            selected: widget.selectedGroupIds.contains(kUngroupedId),
            onTap: () {
              _scrollToCenter(_ungroupedKey);
              widget.onChanged(_toggled(kUngroupedId));
            },
          ),
          for (final FavoriteGroup g in groups)
            _GroupChip(
              key: _keyFor(g.id),
              label: g.name,
              selected: widget.selectedGroupIds.contains(g.id),
              onTap: () {
                _scrollToCenter(_keyFor(g.id));
                widget.onChanged(_toggled(g.id));
              },
            ),
        ],
      ),
    );
  }
}

class _GroupChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _GroupChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: AppTokens.spaceSm),
      // 选中态变化时播放一次脉冲（分组 chip 选中动效，文档 §动画规范）。
      child: AppValuePulse(
        trigger: selected,
        from: 0.9,
        child: FilterChip(
          label: Text(label),
          selected: selected,
          onSelected: (_) => onTap(),
        ),
      ),
    );
  }
}

/// 条目分组指定面板。
///
/// 为单个收藏条目指定所属分组（多选覆盖式）。入口：
/// 1. 书架收藏卡片长按；
/// 2. 详情页收藏成功 SnackBar 的「设分组」action。
/// FilterChip Wrap 多选 + 快捷新建，确认调 [FavoritesManager.setEntryGroups]。
library;

import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:provider/provider.dart';

import '../favorites/favorite_group.dart';
import '../favorites/favorites_manager.dart';
import '../models/plugin_config.dart';
import '../theme/app_tokens.dart';
import 'app_animations.dart';
import 'favorite_group_manage_sheet.dart' show promptGroupName;

/// 唤起条目分组指定底部面板。条目未收藏时静默不弹。
Future<void> showFavoriteGroupAssignSheet(
  BuildContext context, {
  required String contentId,
  required SourceType sourceType,
}) {
  final FavoritesManager manager = context.read<FavoritesManager>();
  final bool favorited =
      manager.favoritesFor(sourceType).any((e) => e.id == contentId);
  if (!favorited) return Future<void>.value();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(AppTokens.radiusLg),
      ),
    ),
    builder: (BuildContext ctx) => _GroupAssignSheet(
      contentId: contentId,
      sourceType: sourceType,
    ),
  );
}

class _GroupAssignSheet extends StatefulWidget {
  final String contentId;
  final SourceType sourceType;

  const _GroupAssignSheet({
    required this.contentId,
    required this.sourceType,
  });

  @override
  State<_GroupAssignSheet> createState() => _GroupAssignSheetState();
}

class _GroupAssignSheetState extends State<_GroupAssignSheet> {
  late final Set<String> _selected;

  @override
  void initState() {
    super.initState();
    final FavoritesManager manager = context.read<FavoritesManager>();
    final entry = manager
        .favoritesFor(widget.sourceType)
        .where((e) => e.id == widget.contentId)
        .firstOrNull;
    _selected = Set<String>.of(entry?.groupIds ?? const <String>[]);
  }

  Future<void> _quickCreate() async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final FavoritesManager manager = context.read<FavoritesManager>();
    final String? name = await promptGroupName(
      context,
      title: l10n.newGroup,
      sourceType: widget.sourceType,
    );
    if (name == null) return;
    final FavoriteGroup? group =
        await manager.createGroup(name, type: widget.sourceType);
    if (group != null && mounted) {
      setState(() => _selected.add(group.id)); // 新建后自动选中
    }
  }

  Future<void> _confirm() async {
    final FavoritesManager manager = context.read<FavoritesManager>();
    await manager.setEntryGroups(
      widget.contentId,
      widget.sourceType,
      _selected.toList(),
    );
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ThemeData theme = Theme.of(context);
    // 仅展示当前模块（动漫 / 漫画 / 小说）自己的分类夹，三端不互通。
    final List<FavoriteGroup> groups =
        context.watch<FavoritesManager>().groupsFor(widget.sourceType);

    return AppSheetBody(
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppTokens.spaceMd,
            AppTokens.spaceSm,
            AppTokens.spaceMd,
            AppTokens.spaceMd,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: AppTokens.spaceXs),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onSurfaceVariant
                        .withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: AppTokens.spaceSm),
              Text(l10n.setGroups, style: theme.textTheme.titleMedium),
              const SizedBox(height: AppTokens.spaceMd),
              // 该模块还没有任何分类夹时给出引导，避免面板看起来是空的。
              if (groups.isEmpty)
                Padding(
                  padding:
                      const EdgeInsets.only(bottom: AppTokens.spaceSm),
                  child: Text(
                    l10n.noGroupsHint,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              Flexible(
                child: SingleChildScrollView(
                  child: Wrap(
                    spacing: AppTokens.spaceSm,
                    runSpacing: AppTokens.spaceXs,
                    children: <Widget>[
                      for (final FavoriteGroup g in groups)
                        FilterChip(
                          label: Text(g.name),
                          selected: _selected.contains(g.id),
                          onSelected: (bool on) => setState(() {
                            on ? _selected.add(g.id) : _selected.remove(g.id);
                          }),
                        ),
                      // 快捷新建分组入口。
                      ActionChip(
                        avatar: const Icon(Icons.add, size: 16),
                        label: Text(l10n.newGroup),
                        onPressed: _quickCreate,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppTokens.spaceMd),
              FilledButton(
                onPressed: _confirm,
                child: Text(l10n.confirm),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

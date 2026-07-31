/// Bangumi 同步设置面板（绑定 / 评分 / 短评 / 一键同步）。
///
/// 为单个收藏条目配置并推送 Bangumi 同步：
/// 1. 搜索框（预填条目标题）→ 候选列表 → 点选绑定写 [SubjectLinkStore]；
/// 2. 已绑定时显示条目编号，可解绑，或手动「从 Bangumi 拉取」远端评分与短评；
/// 3. 评分（0-10 滑条）与短评保存到 [FavoritesManager]，「同步到 Bangumi」
///    静默保存后调 [BangumiSyncService.syncOne] 推送当前条目；收藏状态由
///    同步逻辑按阅读进度自动判定。
/// 入口：详情页 Bangumi 卡片同步按钮、书架收藏卡片长按菜单。
library;

import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:provider/provider.dart';

import '../favorites/favorites_manager.dart';
import '../models/plugin_config.dart';
import '../services/bangumi/bangumi_models.dart';
import '../services/bangumi/bangumi_sync_service.dart';
import '../services/bangumi/subject_link_store.dart';
import '../theme/app_tokens.dart';

/// 唤起 Bangumi 绑定与评分底部面板。
///
/// 不再要求本地收藏：未收藏条目也可手动搜索绑定（详情页卡片解耦收藏流程后，
/// 用户可能在未收藏时就需要绑定 / 同步 Bangumi 条目）。
Future<void> showBangumiBindSheet(
  BuildContext context, {
  required String contentId,
  required SourceType sourceType,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(AppTokens.radiusLg),
      ),
    ),
    builder: (BuildContext ctx) => _BangumiBindSheet(
      contentId: contentId,
      sourceType: sourceType,
    ),
  );
}

class _BangumiBindSheet extends StatefulWidget {
  final String contentId;
  final SourceType sourceType;

  const _BangumiBindSheet({
    required this.contentId,
    required this.sourceType,
  });

  @override
  State<_BangumiBindSheet> createState() => _BangumiBindSheetState();
}

class _BangumiBindSheetState extends State<_BangumiBindSheet> {
  late final TextEditingController _searchController;
  late final TextEditingController _commentController;

  FavoriteEntry? _entry;
  SubjectLink? _link;
  List<BangumiSubject> _candidates = const <BangumiSubject>[];
  bool _searching = false;
  bool _pulling = false;
  bool _syncing = false;
  int _rating = 0;

  BangumiSyncService get _service => context.read<BangumiSyncService>();

  @override
  void initState() {
    super.initState();
    final FavoritesManager manager = context.read<FavoritesManager>();
    _entry = manager
        .favoritesFor(widget.sourceType)
        .where((e) => e.id == widget.contentId)
        .firstOrNull;
    _searchController = TextEditingController(text: _entry?.title ?? '');
    _commentController = TextEditingController(text: _entry?.myComment ?? '');
    _rating = _entry?.myRating ?? 0;
    _loadLink();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _commentController.dispose();
    super.dispose();
  }

  Future<void> _loadLink() async {
    final link = await _service.linkStore.get(widget.contentId);
    if (mounted) setState(() => _link = link);
  }

  Future<void> _search() async {
    final keyword = _searchController.text.trim();
    if (keyword.isEmpty) return;
    setState(() => _searching = true);
    try {
      final results = await _service.client.searchSubjects(
        keyword,
        types: SubjectLinkStore.searchTypesFor(widget.sourceType),
      );
      if (mounted) setState(() => _candidates = results);
    } catch (_) {
      if (mounted) setState(() => _candidates = const <BangumiSubject>[]);
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _bind(BangumiSubject subject) async {
    final link = SubjectLink(
      subjectId: subject.id,
      forcedType: _link?.forcedType,
    );
    await _service.linkStore.put(widget.contentId, link);
    if (mounted) setState(() => _link = link);
  }

  Future<void> _unbind() async {
    await _service.linkStore.remove(widget.contentId);
    if (mounted) setState(() => _link = null);
  }

  /// 从 Bangumi 拉取远端评分与短评，覆盖面板当前输入（保存后生效）。
  Future<void> _pullFromRemote() async {
    final l10n = AppLocalizations.of(context);
    final link = _link;
    if (link == null) return;
    setState(() => _pulling = true);
    try {
      final remote = await _service.client.fetchUserCollection(link.subjectId);
      if (!mounted) return;
      if (remote == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.bangumiPullEmpty)),
        );
        return;
      }
      setState(() {
        if (remote.rate > 0) _rating = remote.rate;
        if (remote.comment.isNotEmpty) {
          _commentController.text = remote.comment;
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.bangumiPullDone)),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.bangumiSyncFailed)),
      );
    } finally {
      if (mounted) setState(() => _pulling = false);
    }
  }

  /// 写入本地评分 / 短评到收藏条目（供保存与同步共用，不弹出面板）。
  Future<void> _persist() async {
    final manager = context.read<FavoritesManager>();
    await manager.updateBangumiMeta(
      widget.contentId,
      widget.sourceType,
      myRating: _rating,
      myComment: _commentController.text.trim(),
    );
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context);
    await _persist();
    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.bangumiSaved)),
    );
  }

  /// 一键同步：静默保存本地评分 / 短评 → syncOne → 结果 SnackBar。
  Future<void> _sync() async {
    final l10n = AppLocalizations.of(context);
    setState(() => _syncing = true);
    try {
      await _persist();
      final SyncLogItem? item =
          await _service.syncOne(widget.contentId, widget.sourceType);
      if (!mounted || item == null) return;
      final String message = switch (item.status) {
        SyncLogStatus.success => l10n.bangumiSyncDone,
        SyncLogStatus.skipped => l10n.bangumiLogSkipped,
        SyncLogStatus.failed => l10n.bangumiSyncFailed,
        SyncLogStatus.pendingBind => l10n.bangumiBindFirst,
      };
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    } on StateError {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.bangumiNotLoggedIn)),
      );
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: AppTokens.spaceLg,
          right: AppTokens.spaceLg,
          top: AppTokens.spaceLg,
          bottom: AppTokens.spaceLg + bottomInset,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(l10n.bangumiBindAndRate, style: theme.textTheme.titleMedium),
            const SizedBox(height: AppTokens.spaceMd),
            // ───── 绑定状态 / 搜索 ─────
            if (_link != null) ...<Widget>[
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.link),
                title: Text(l10n.bangumiBoundTo(_link!.subjectId)),
                trailing: TextButton(
                  onPressed: _unbind,
                  child: Text(l10n.bangumiUnbind),
                ),
              ),
              // 手动拉取远端评分/短评覆盖本地（空缺回拉之外的主动覆盖入口）。
              OutlinedButton.icon(
                onPressed: _pulling ? null : _pullFromRemote,
                icon: _pulling
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.cloud_download, size: 16),
                label: Text(l10n.bangumiPullFromRemote),
              ),
            ] else ...<Widget>[
              TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  labelText: l10n.bangumiSearchHint,
                  border: const OutlineInputBorder(),
                  suffixIcon: _searching
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : IconButton(
                          icon: const Icon(Icons.search),
                          onPressed: _search,
                        ),
                ),
                onSubmitted: (_) => _search(),
              ),
              const SizedBox(height: AppTokens.spaceSm),
              if (_candidates.isEmpty && !_searching)
                Padding(
                  padding: const EdgeInsets.all(AppTokens.spaceSm),
                  child: Text(
                    l10n.bangumiNoResults,
                    style: theme.textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                )
              else
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: _candidates.length,
                    itemBuilder: (context, index) {
                      final subject = _candidates[index];
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: subject.image != null
                            ? ClipRRect(
                                borderRadius:
                                    BorderRadius.circular(AppTokens.radiusSm),
                                child: Image.network(
                                  subject.image!,
                                  width: 32,
                                  height: 44,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) =>
                                      const Icon(Icons.image_not_supported),
                                ),
                              )
                            : const Icon(Icons.tv),
                        title: Text(
                          subject.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          [
                            if (subject.name != subject.displayName)
                              subject.name,
                            if (subject.date != null) subject.date!,
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => _bind(subject),
                      );
                    },
                  ),
                ),
            ],
            const SizedBox(height: AppTokens.spaceMd),
            // ───── 评分与短评 ─────
            Row(
              children: <Widget>[
                Text(l10n.bangumiMyRating, style: theme.textTheme.bodyMedium),
                Expanded(
                  child: Slider(
                    value: _rating.toDouble(),
                    min: 0,
                    max: 10,
                    divisions: 10,
                    label: _rating > 0 ? '$_rating' : l10n.bangumiRatingNone,
                    onChanged: (v) => setState(() => _rating = v.round()),
                  ),
                ),
                SizedBox(
                  width: 24,
                  child: Text(
                    _rating > 0 ? '$_rating' : '-',
                    style: theme.textTheme.titleMedium,
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
            TextField(
              controller: _commentController,
              decoration: InputDecoration(
                labelText: l10n.bangumiMyComment,
                hintText: l10n.bangumiCommentHint,
                border: const OutlineInputBorder(),
              ),
              maxLines: 2,
              maxLength: 380,
            ),
            const SizedBox(height: AppTokens.spaceMd),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _syncing ? null : _save,
                    icon: const Icon(Icons.save_outlined, size: 16),
                    label: Text(l10n.save),
                  ),
                ),
                const SizedBox(width: AppTokens.spaceSm),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _syncing ? null : _sync,
                    icon: _syncing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.sync, size: 16),
                    label: Text(l10n.bangumiSyncThis),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

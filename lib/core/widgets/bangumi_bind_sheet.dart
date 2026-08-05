/// Bangumi 绑定面板（仅绑定条目，不含评分 / 短评编辑）。
///
/// 为单个内容条目搜索并绑定 Bangumi 条目：
/// 1. 搜索框（预填条目标题）→ 候选列表 → 点选绑定写 [SubjectLinkStore]；
/// 2. 已绑定时显示条目编号，可解绑重新绑定。
/// 评分 / 短评等同步编辑不在此面板（由同步对话框处理）。
/// 入口：详情页 Bangumi 卡片「手动绑定」、书架收藏卡片长按菜单。
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

/// 唤起 Bangumi 绑定底部面板。
///
/// 只负责「绑定条目」：搜索 Bangumi 条目并写入 [SubjectLinkStore]。
/// 评分 / 短评的编辑与同步不在此面板内。
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

  FavoriteEntry? _entry;
  SubjectLink? _link;
  List<BangumiSubject> _candidates = const <BangumiSubject>[];
  bool _searching = false;

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
    _loadLink();
  }

  @override
  void dispose() {
    _searchController.dispose();
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
            Text(l10n.bangumiManualBind, style: theme.textTheme.titleMedium),
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
            ] else ...<Widget>[
              TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  labelText: l10n.bangumiSearchHint,
                  border: const OutlineInputBorder(),
                  suffixIcon: _searching
                      ? const Padding(
                          padding: EdgeInsets.all(AppTokens.spaceMd),
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
            Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(l10n.close),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Bangumi 收藏同步弹窗（详情页底栏「同步」按钮唤起）。
///
/// 自上而下：条目标题 → 打星（1-10）→ 吐槽（短评）→ 五状态
/// （想看 / 看过 / 在看 / 搁置 / 抛弃）→ 底部「公开/私密」切换 + 「同步」按钮。
/// 提交即 PATCH /v0/users/-/collections/{subject_id}（未收藏时 client 自动回退 POST）。
library;

import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:provider/provider.dart';

import '../models/plugin_config.dart';
import '../services/bangumi/bangumi_client.dart';
import '../services/bangumi/bangumi_models.dart';
import '../services/bangumi/bangumi_sync_service.dart';
import '../theme/app_tokens.dart';

/// 唤起 Bangumi 同步弹窗。
Future<void> showBangumiSyncDialog(
  BuildContext context, {
  required int subjectId,
  String? title,
  required String contentId,
  required SourceType sourceType,
}) {
  final BangumiClient client = context.read<BangumiSyncService>().client;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: const BoxConstraints(maxWidth: 720),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (BuildContext ctx) => _BangumiSyncDialog(
      client: client,
      subjectId: subjectId,
      title: title,
      contentId: contentId,
      sourceType: sourceType,
    ),
  );
}

class _BangumiSyncDialog extends StatefulWidget {
  final BangumiClient client;
  final int subjectId;
  final String? title;
  final String contentId;
  final SourceType sourceType;

  const _BangumiSyncDialog({
    required this.client,
    required this.subjectId,
    this.title,
    required this.contentId,
    required this.sourceType,
  });

  @override State<_BangumiSyncDialog> createState() => _BangumiSyncDialogState();
}

class _BangumiSyncDialogState extends State<_BangumiSyncDialog> {
  BangumiSubjectDetail? _detail;
  bool _loading = true;

  int _rate = 0;
  String _comment = '';
  int _type = BangumiCollectionType.wish;
  bool _private = false;
  bool _saving = false;

  final TextEditingController _commentCtrl = TextEditingController();
  final TextEditingController _progressCtrl = TextEditingController();

  /// 当前条目是否为动漫（走 episode 级标记）。
  bool get _isAnime => widget.sourceType == SourceType.animeSource;

  /// 当前条目是否为书籍（漫画/小说，走 ep_status）。
  bool get _isBook => widget.sourceType == SourceType.mangaSource ||
      widget.sourceType == SourceType.novelSource;

  BangumiSyncService get _service => context.read<BangumiSyncService>();

  @override
  void initState() {
    super.initState();
    _commentCtrl.text = _comment;
    _load();
  }

  @override
  void dispose() {
    _commentCtrl.dispose();
    _progressCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait<Object?>([
        widget.client.fetchSubject(widget.subjectId),
        widget.client.fetchUserCollection(widget.subjectId),
      ]);
      if (!mounted) return;
      final detail = results[0] as BangumiSubjectDetail?;
      final remote = results[1] as BangumiUserCollection?;
      setState(() {
        _detail = detail;
        if (remote != null) {
          _rate = remote.rate;
          _comment = remote.comment;
          _type = remote.type;
          _private = remote.isPrivate;
          // 书籍预填远端 ep_status（1 起计数，0 表示未开始）。
          if (_isBook && remote.epStatus > 0) {
            _progressCtrl.text = '${remote.epStatus}';
          }
        }
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      // 拉取失败仍允许手动设置（可能未收藏）。
      setState(() {
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    if (!_service.auth.isLoggedIn) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).bangumiSyncLoginHint)));
      }
      return;
    }
    if (_saving) return;
    setState(() => _saving = true);
    try {
      // 解析手动输入的进度（空 = 不修改进度）。
      final progressText = _progressCtrl.text.trim();
      final int? progress = progressText.isEmpty ? null : int.tryParse(progressText);

      // 书籍：ep_status 直接随 PATCH 一起提交。
      final int? bookEpStatus = (_isBook && progress != null && progress >= 0)
          ? progress
          : null;

      // 1. PATCH 收藏（评分 / 吐槽 / 状态 / 公开私密 / 书籍进度）。
      await widget.client.patchCollection(
        widget.subjectId,
        CollectionPayload(
          type: _type,
          rate: _rate,
          comment: _comment.trim().isNotEmpty ? _comment.trim() : null,
          private: _private,
          epStatus: bookEpStatus,
        ),
      );

      // 2. 动漫：手动指定已看集数时，拉取 episode 列表并标记差集。
      if (_isAnime && progress != null && progress > 0) {
        final episodes = await widget.client.fetchEpisodes(widget.subjectId);
        final episodeIds = <int>[
          for (int i = 0; i < progress && i < episodes.length; i++)
            episodes[i].id,
        ];
        if (episodeIds.isNotEmpty) {
          // 增量标集：只标记远端尚未「看过」的差集。
          final remoteEps =
              await widget.client.fetchCollectedEpisodes(widget.subjectId);
          final diff = <int>[
            for (final id in episodeIds)
              if (remoteEps[id] != 2) id,
          ];
          if (diff.isNotEmpty) {
            await widget.client.markEpisodesWatched(widget.subjectId, diff);
          }
        }
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).bangumiSyncSaved)));
        Navigator.of(context).pop();
      }
    } on BangumiApiException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).bangumiSyncFailed)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).bangumiSyncFailed)));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 打星行（1-10）+ 当前分提示，点击星位设置/取消评分。
  Widget _buildStarRating(ThemeData theme, ColorScheme scheme, AppLocalizations l10n) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
      Row(children: <Widget>[
        for (int i = 1; i <= 10; i++)
          Expanded(
            child: InkWell(
              onTap: () => setState(() => _rate = (_rate == i ? 0 : i)),
              borderRadius: BorderRadius.circular(AppTokens.radiusSm),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Icon(
                  i <= _rate ? Icons.star : Icons.star_border,
                  size: 22,
                  color: i <= _rate ? scheme.primary : scheme.outline,
                ),
              ),
            ),
          ),
      ]),
      if (_rate > 0)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(l10n.bangumiRatingValue(_rate),
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final titleText = _detail?.displayName ?? widget.title ?? 'Bangumi';

    final states = <(int, String)>[
      (BangumiCollectionType.wish, l10n.bangumiStateWish),
      (BangumiCollectionType.doing, l10n.bangumiStateDoing),
      (BangumiCollectionType.collect, l10n.bangumiStateCollect),
      (BangumiCollectionType.onHold, l10n.bangumiStateOnHold),
      (BangumiCollectionType.dropped, l10n.bangumiStateDropped),
    ];

    return Padding(
      padding: EdgeInsets.only(
        left: AppTokens.spaceMd, right: AppTokens.spaceMd, top: AppTokens.spaceMd,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppTokens.spaceLg,
      ),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
        // 顶部标题
        Row(children: <Widget>[
          Expanded(child: Text(titleText, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            maxLines: 2, overflow: TextOverflow.ellipsis)),
          if (!_loading)
            IconButton(icon: const Icon(Icons.close), visualDensity: VisualDensity.compact,
              onPressed: () => Navigator.of(context).pop()),
        ]),
        const Divider(),
        if (_loading)
          const Center(child: Padding(padding: EdgeInsets.all(AppTokens.spaceLg),
            child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5))))
        else ...<Widget>[
          // 打星
          Row(children: <Widget>[
            Icon(Icons.star_outline, size: 18, color: scheme.primary),
            const SizedBox(width: AppTokens.spaceXs),
            Text(l10n.bangumiSyncRating, style: theme.textTheme.titleSmall),
            const Spacer(),
            if (_rate > 0) TextButton.icon(onPressed: () => setState(() => _rate = 0),
              icon: const Icon(Icons.clear, size: 16), label: Text(l10n.clear)),
          ]),
          const SizedBox(height: AppTokens.spaceXs),
          _buildStarRating(theme, scheme, l10n),
          const SizedBox(height: AppTokens.spaceMd),

          // 吐槽
          TextField(
            controller: _commentCtrl,
            onChanged: (v) => _comment = v,
            maxLines: 4,
            minLines: 2,
            decoration: InputDecoration(
              labelText: l10n.bangumiSyncComment,
              alignLabelWithHint: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppTokens.radiusMd)),
            ),
          ),
          const SizedBox(height: AppTokens.spaceMd),

          // 五状态
          Text(l10n.bangumiCollectionStatus, style: theme.textTheme.titleSmall),
          const SizedBox(height: AppTokens.spaceXs),
          Wrap(spacing: AppTokens.spaceXs, runSpacing: AppTokens.spaceXs, children: <Widget>[
            for (final e in states)
              ChoiceChip(label: Text(e.$2), selected: _type == e.$1,
                onSelected: (_) => setState(() => _type = e.$1)),
          ]),
          const SizedBox(height: AppTokens.spaceMd),

          // 已看集数 / 已读章节（动漫走 episode 标记，书籍走 ep_status）
          if (_isAnime || _isBook) ...<Widget>[
            TextField(
              controller: _progressCtrl,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: _isAnime
                    ? l10n.bangumiSyncWatchedEpisodes
                    : l10n.bangumiSyncWatchedChapters,
                helperText: l10n.bangumiSyncProgressHint,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppTokens.radiusMd)),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: AppTokens.spaceSm, vertical: AppTokens.spaceSm),
              ),
            ),
            const SizedBox(height: AppTokens.spaceLg),
          ],

          // 底部：公开/私密 + 同步
          Row(children: <Widget>[
            OutlinedButton.icon(
              onPressed: () => setState(() => _private = !_private),
              icon: Icon(_private ? Icons.lock : Icons.public, size: 18),
              label: Text(_private ? l10n.bangumiPrivate : l10n.bangumiPublic),
            ),
            const SizedBox(width: AppTokens.spaceSm),
            Expanded(child: FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving ? const SizedBox(width: 16, height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.sync, size: 18),
              label: Text(l10n.bangumiSync),
            )),
          ]),
        ],
      ]),
    );
  }
}

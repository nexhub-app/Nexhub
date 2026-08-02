/// Bangumi 收藏同步弹窗（详情页底栏「同步」按钮唤起）。
///
/// 按源站（com.czy0729.bangumi）原版 UI 重设计，分两套布局：
/// - 书籍（漫画 / 小说）：`Chap.` + `Vol.` 数字步进 + `+` 按钮 + 更新（对应网站
///   书籍收藏编辑页的章节 / 卷进度）；保存时同时 PATCH `ep_status` 与 `vol_status`。
/// - 动漫（影视）：可点击的数字网格（逐集标记已看 / 取消）+ 分页（如 166-197，
///   `第 4 / 46 页`）+ 周 / 时 / 分 放送信息条 + 更新。
///
/// 评分 / 吐槽 / 五状态 / 公开私密 收纳到「高级选项」ExpansionTile（默认收起），
/// 点击「更新」或底部「同步到 Bangumi」统一提交（含进度 + 高级项）。
///
/// 提交逻辑：底部「同步到 Bangumi」整体 PATCH /v0/users/-/collections/{subject_id}
/// （未收藏时 client 自动回退 POST）；动漫逐集用 markEpisodesWatched 标记差集。
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
  /// 用户是否手动改过收藏状态（手动优先于自动判定）。
  bool _typeTouched = false;
  bool _private = false;
  bool _saving = false;

  final TextEditingController _commentCtrl = TextEditingController();
  // 书籍：章节数（Chap.）/ 卷数（Vol.）。
  final TextEditingController _chapCtrl = TextEditingController();
  final TextEditingController _volCtrl = TextEditingController();
  // 动漫：快速「标记前 N 集已看」。
  final TextEditingController _quickCtrl = TextEditingController();

  /// 动漫：已选（看过）的 Bangumi 剧集 id 集合（直接存 id，避免 sort 取整映射误差）。
  Set<int> _selectedEpisodeIds = <int>{};

  /// 动漫剧集列表（_load 中拉取）。
  List<BangumiEpisode>? _episodes;
  bool _loadingEpisodes = false;
  String? _episodesLoadError;

  /// 动漫剧集网格分页。
  static const int _epPageSize = 30;
  int _epPage = 0;

  /// 当前条目是否为动漫（走 episode 级标记）。
  bool get _isAnime => widget.sourceType == SourceType.animeSource;

  /// 当前条目是否为书籍（漫画 / 小说，走 ep_status + vol_status）。
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
    _chapCtrl.dispose();
    _volCtrl.dispose();
    _quickCtrl.dispose();
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
        }
        if (_isBook) {
          if (remote != null && remote.epStatus > 0) {
            _chapCtrl.text = '${remote.epStatus}';
          }
          if (remote != null && remote.volStatus > 0) {
            _volCtrl.text = '${remote.volStatus}';
          }
        }
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      // 拉取失败仍允许手动设置（可能未收藏）。
      setState(() => _loading = false);
      return;
    }
    if (_isAnime) _loadEpisodes();
  }

  /// 动漫：拉取剧集列表并预填已看集（远端 collected 中 type==2 的）。
  Future<void> _loadEpisodes() async {
    if (!mounted) return;
    setState(() {
      _loadingEpisodes = true;
      _episodesLoadError = null;
    });
    try {
      final eps = await widget.client.fetchEpisodes(widget.subjectId);
      if (!mounted) return;
      setState(() => _episodes = eps);
      try {
        final remoteEps =
            await widget.client.fetchCollectedEpisodes(widget.subjectId);
        if (!mounted) return;
        final sel = <int>{
          for (final ep in eps)
            if ((remoteEps[ep.id] ?? 0) == 2) ep.id,
        };
        setState(() => _selectedEpisodeIds = sel);
      } catch (_) {
        /* 预填失败不阻断 */
      }
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _episodesLoadError = e.toString());
    } finally {
      if (mounted) setState(() => _loadingEpisodes = false);
    }
  }

  int _int(TextEditingController c) => int.tryParse(c.text.trim()) ?? 0;

  void _increment(TextEditingController c) {
    final n = _int(c);
    c.text = '${n + 1}';
    setState(() {});
  }

  /// 进度 (已读, 总数)，用于进度条与标题计数。
  (int, int) _progress() {
    if (_isBook) {
      final total = (_detail?.eps ?? 0) > 0 ? _detail!.eps : 0;
      return (_int(_chapCtrl), total);
    }
    final total = _episodes?.length ?? 0;
    return (_selectedEpisodeIds.length, total);
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
      if (_isBook) {
        final chap = _int(_chapCtrl);
        final vol = _int(_volCtrl);
        final total = (_detail?.eps ?? 0) > 0 ? _detail!.eps : 0;
        final desired = _typeTouched
            ? _type
            : (total > 0 && chap >= total
                ? BangumiCollectionType.collect
                : (chap > 0
                    ? BangumiCollectionType.doing
                    : BangumiCollectionType.wish));
        await widget.client.patchCollection(
          widget.subjectId,
          CollectionPayload(
            type: desired,
            rate: _rate,
            comment: _comment.trim().isNotEmpty ? _comment.trim() : null,
            private: _private,
            epStatus: chap,
            volStatus: vol,
          ),
        );
      } else {
        final eps = _episodes ?? <BangumiEpisode>[];
        final selected = <int>{..._selectedEpisodeIds};
        final quick = _int(_quickCtrl);
        if (quick > 0 && eps.isNotEmpty) {
          final sorted = [...eps]
            ..sort((a, b) => a.sort.compareTo(b.sort));
          for (int i = 0; i < quick && i < sorted.length; i++) {
            selected.add(sorted[i].id);
          }
        }
        final desired = _typeTouched
            ? _type
            : (eps.isNotEmpty && selected.length >= eps.length
                ? BangumiCollectionType.collect
                : (selected.isNotEmpty
                    ? BangumiCollectionType.doing
                    : BangumiCollectionType.wish));
        // 1) 先确保收藏存在并写入评分 / 吐槽 / 状态 / 隐私。
        await widget.client.patchCollection(
          widget.subjectId,
          CollectionPayload(
            type: desired,
            rate: _rate,
            comment: _comment.trim().isNotEmpty ? _comment.trim() : null,
            private: _private,
          ),
        );
        // 2) 增量标记已看集（仅差集）。
        if (selected.isNotEmpty) {
          final remoteEps =
              await widget.client.fetchCollectedEpisodes(widget.subjectId);
          final diff = <int>[
            for (final id in selected)
              if ((remoteEps[id] ?? 0) != 2) id,
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

  /// 打星行（1-10）+ 当前分提示。
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

    return SingleChildScrollView(
      padding: EdgeInsets.only(
        left: AppTokens.spaceMd,
        right: AppTokens.spaceMd,
        top: AppTokens.spaceMd,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppTokens.spaceLg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // 顶部标题 + 关闭
          Row(children: <Widget>[
            Expanded(
              child: Text(
                titleText,
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (!_loading)
              IconButton(
                icon: const Icon(Icons.close),
                visualDensity: VisualDensity.compact,
                onPressed: () => Navigator.of(context).pop(),
              ),
          ]),
          const Divider(height: 1),

          if (_loading)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(AppTokens.spaceLg),
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
              ),
            )
          else ...<Widget>[
            const SizedBox(height: AppTokens.spaceMd),
            if (_isAnime) _buildAnimeSection(theme, scheme, l10n)
            else _buildBookSection(theme, scheme, l10n),
            const Divider(height: AppTokens.spaceLg),

            // 高级选项（评分 / 吐槽 / 状态 / 公开私密）
            Theme(
              data: theme.copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding:
                    const EdgeInsets.only(bottom: AppTokens.spaceMd),
                leading: Icon(Icons.tune, size: 20, color: scheme.primary),
                title: Text(
                  l10n.bangumiSyncAdvancedOptions,
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  l10n.bangumiSyncAdvancedHint,
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
                children: <Widget>[
                  Row(children: <Widget>[
                    Icon(Icons.star_outline, size: 18, color: scheme.primary),
                    const SizedBox(width: AppTokens.spaceXs),
                    Text(l10n.bangumiSyncRating, style: theme.textTheme.titleSmall),
                    const Spacer(),
                    if (_rate > 0)
                      TextButton.icon(
                        onPressed: () => setState(() => _rate = 0),
                        icon: const Icon(Icons.clear, size: 16),
                        label: Text(l10n.clear),
                      ),
                  ]),
                  const SizedBox(height: AppTokens.spaceXs),
                  _buildStarRating(theme, scheme, l10n),
                  const SizedBox(height: AppTokens.spaceMd),
                  TextField(
                    controller: _commentCtrl,
                    onChanged: (v) => _comment = v,
                    maxLines: 4,
                    minLines: 2,
                    decoration: InputDecoration(
                      labelText: l10n.bangumiSyncComment,
                      alignLabelWithHint: true,
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppTokens.radiusMd)),
                    ),
                  ),
                  const SizedBox(height: AppTokens.spaceMd),
                  Text(l10n.bangumiCollectionStatus, style: theme.textTheme.titleSmall),
                  const SizedBox(height: AppTokens.spaceXs),
                  Wrap(
                    spacing: AppTokens.spaceXs,
                    runSpacing: AppTokens.spaceXs,
                    children: <Widget>[
                      for (final e in states)
                        ChoiceChip(
                          label: Text(e.$2),
                          selected: _type == e.$1,
                          onSelected: (_) => setState(() {
                            _type = e.$1;
                            _typeTouched = true;
                          }),
                        ),
                    ],
                  ),
                  const SizedBox(height: AppTokens.spaceMd),
                  Row(children: <Widget>[
                    Icon(_private ? Icons.lock : Icons.public,
                        size: 18, color: scheme.primary),
                    const SizedBox(width: AppTokens.spaceXs),
                    Text(
                      _private ? l10n.bangumiPrivate : l10n.bangumiPublic,
                      style: theme.textTheme.titleSmall,
                    ),
                    const Spacer(),
                    Switch(
                      value: _private,
                      onChanged: (v) => setState(() => _private = v),
                    ),
                  ]),
                ],
              ),
            ),
            const SizedBox(height: AppTokens.spaceMd),

            // 底部主操作：同步到 Bangumi（含进度 + 高级项）
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _saving ? null : _save,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: AppTokens.spaceMd),
                ),
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.sync, size: 18),
                label: Text(
                  l10n.bangumiSync,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 书籍（漫画 / 小说）：Chap. + Vol. 步进 + 更新。
  Widget _buildBookSection(ThemeData theme, ColorScheme scheme, AppLocalizations l10n) {
    final (done, total) = _progress();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
      Row(children: <Widget>[
        Icon(Icons.bookmark_outline, size: 18, color: scheme.primary),
        const SizedBox(width: AppTokens.spaceXs),
        Text(l10n.bangumiSyncMyCompletion,
          style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
        const Spacer(),
        Text(
          total > 0 ? '$done / $total' : '$done / ${l10n.bangumiSyncUnknown}',
          style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ]),
      const SizedBox(height: AppTokens.spaceSm),
      _buildProgressBar(theme, scheme, done, total),
      const SizedBox(height: AppTokens.spaceMd),
      Row(crossAxisAlignment: CrossAxisAlignment.end, children: <Widget>[
        _buildStepper(theme, scheme, l10n.bangumiSyncChapLabel, _chapCtrl),
        const SizedBox(width: AppTokens.spaceMd),
        _buildStepper(theme, scheme, l10n.bangumiSyncVolLabel, _volCtrl),
        const SizedBox(width: AppTokens.spaceMd),
        FilledButton.icon(
          onPressed: _saving ? null : _save,
          style: FilledButton.styleFrom(
            backgroundColor: scheme.primaryContainer,
            foregroundColor: scheme.onPrimaryContainer,
          ),
          icon: _saving
              ? const SizedBox(
                  width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh, size: 18),
          label: Text(l10n.bangumiSyncUpdate),
        ),
      ]),
    ]);
  }

  /// 单个 Chap./Vol. 步进控件：标签 + 数字输入 + `+` 按钮。
  Widget _buildStepper(
    ThemeData theme,
    ColorScheme scheme,
    String label,
    TextEditingController ctrl,
  ) {
    return Expanded(
      child: Row(children: <Widget>[
        SizedBox(
          width: 46,
          child: Text(label,
            style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
        ),
        Expanded(
          child: TextField(
            controller: ctrl,
            keyboardType: TextInputType.number,
            onChanged: (_) => setState(() {}),
            textAlign: TextAlign.center,
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: AppTokens.spaceSm, vertical: AppTokens.spaceSm),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppTokens.radiusMd),
                borderSide: BorderSide(color: scheme.outline),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppTokens.radiusMd),
                borderSide: BorderSide(color: scheme.primary, width: 2),
              ),
            ),
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
        IconButton(
          onPressed: () => _increment(ctrl),
          icon: const Icon(Icons.add),
          tooltip: AppLocalizations.of(context).bangumiSyncIncrement,
          visualDensity: VisualDensity.compact,
        ),
      ]),
    );
  }

  /// 动漫：数字网格 + 分页 + 周/时/分 + 更新。
  Widget _buildAnimeSection(ThemeData theme, ColorScheme scheme, AppLocalizations l10n) {
    final (done, total) = _progress();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
      Row(children: <Widget>[
        Icon(Icons.playlist_play, size: 18, color: scheme.primary),
        const SizedBox(width: AppTokens.spaceXs),
        Text(l10n.bangumiSyncAnimeGridTitle,
          style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
        const Spacer(),
        Text(
          total > 0 ? '$done / $total' : '$done / ${l10n.bangumiSyncUnknown}',
          style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ]),
      const SizedBox(height: AppTokens.spaceXs),
      Text(l10n.bangumiSyncAnimeGridHint,
        style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
      const SizedBox(height: AppTokens.spaceSm),
      _buildEpisodeGrid(theme, scheme, l10n),
      const SizedBox(height: AppTokens.spaceSm),
      _buildPageNav(theme, scheme, l10n),
      const SizedBox(height: AppTokens.spaceMd),
      // 快速「标记前 N 集已看」+ 更新
      Row(crossAxisAlignment: CrossAxisAlignment.end, children: <Widget>[
        Expanded(
          child: TextField(
            controller: _quickCtrl,
            keyboardType: TextInputType.number,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              isDense: true,
              labelText: l10n.bangumiSyncWatchedEpisodes,
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: AppTokens.spaceSm, vertical: AppTokens.spaceSm),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppTokens.radiusMd),
                borderSide: BorderSide(color: scheme.outline),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppTokens.radiusMd),
                borderSide: BorderSide(color: scheme.primary, width: 2),
              ),
            ),
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(width: AppTokens.spaceMd),
        FilledButton.icon(
          onPressed: _saving ? null : _save,
          style: FilledButton.styleFrom(
            backgroundColor: scheme.primaryContainer,
            foregroundColor: scheme.onPrimaryContainer,
          ),
          icon: _saving
              ? const SizedBox(
                  width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh, size: 18),
          label: Text(l10n.bangumiSyncUpdate),
        ),
      ]),
      const SizedBox(height: AppTokens.spaceMd),
      _buildScheduleBar(theme, scheme, l10n),
    ]);
  }

  Widget _buildEpisodeGrid(ThemeData theme, ColorScheme scheme, AppLocalizations l10n) {
    final eps = _episodes;
    if (eps == null) {
      if (_loadingEpisodes) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: AppTokens.spaceSm),
          child: Row(children: <Widget>[
            const SizedBox(width: 16, height: 16,
              child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: AppTokens.spaceSm),
            Text(l10n.loading, style: TextStyle(color: scheme.onSurfaceVariant)),
          ]),
        );
      }
      if (_episodesLoadError != null) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: AppTokens.spaceXs),
          child: Text(l10n.bangumiSyncLoadEpisodesFailed(_episodesLoadError!),
            style: TextStyle(color: scheme.error, fontSize: 12)),
        );
      }
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppTokens.spaceXs),
        child: Text(l10n.bangumiSyncNoEpisodeList(_detail?.eps ?? 0),
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
      );
    }
    if (eps.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppTokens.spaceXs),
        child: Text(l10n.bangumiSyncNoEpisodeList(_detail?.eps ?? 0),
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
      );
    }
    final totalPages = (eps.length / _epPageSize).ceil();
    if (_epPage >= totalPages) _epPage = totalPages - 1;
    final start = _epPage * _epPageSize;
    final end = (start + _epPageSize).clamp(0, eps.length);
    final pageEps = eps.sublist(start, end);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 300),
      child: SingleChildScrollView(
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            for (final ep in pageEps) _buildEpCell(theme, scheme, ep),
          ],
        ),
      ),
    );
  }

  Widget _buildEpCell(ThemeData theme, ColorScheme scheme, BangumiEpisode ep) {
    final selected = _selectedEpisodeIds.contains(ep.id);
    return InkWell(
      onTap: () => setState(() {
        if (selected) {
          _selectedEpisodeIds.remove(ep.id);
        } else {
          _selectedEpisodeIds.add(ep.id);
        }
      }),
      borderRadius: BorderRadius.circular(AppTokens.radiusSm),
      child: Container(
        width: 40,
        height: 38,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? scheme.primary : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(AppTokens.radiusSm),
          border: Border.all(
            color: selected ? scheme.primary : scheme.outline,
          ),
        ),
        child: Text('${ep.sort.round()}',
          style: theme.textTheme.bodySmall?.copyWith(
            color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          )),
      ),
    );
  }

  Widget _buildPageNav(ThemeData theme, ColorScheme scheme, AppLocalizations l10n) {
    final eps = _episodes;
    if (eps == null || eps.isEmpty) return const SizedBox.shrink();
    final totalPages = (eps.length / _epPageSize).ceil();
    final start = _epPage * _epPageSize + 1;
    final end = (_epPage * _epPageSize + _epPageSize).clamp(0, eps.length);
    return Row(mainAxisAlignment: MainAxisAlignment.center, children: <Widget>[
      IconButton(
        onPressed: _epPage > 0 ? () => setState(() => _epPage--) : null,
        icon: const Icon(Icons.navigate_before),
        visualDensity: VisualDensity.compact,
      ),
      Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
        Text('$start–$end',
          style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
        Text(l10n.bangumiSyncPageOf(_epPage + 1, totalPages),
          style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
      ]),
      IconButton(
        onPressed: _epPage < totalPages - 1 ? () => setState(() => _epPage++) : null,
        icon: const Icon(Icons.navigate_next),
        visualDensity: VisualDensity.compact,
      ),
    ]);
  }

  /// 周 / 时 / 分 放送信息条（周从 air_date 推算，时/分无数据时为 —）。
  Widget _buildScheduleBar(ThemeData theme, ColorScheme scheme, AppLocalizations l10n) {
    const weekdays = <String>['一', '二', '三', '四', '五', '六', '日'];
    String weekday = '—';
    final air = _detail?.airDate;
    if (air != null && air.isNotEmpty) {
      final dt = DateTime.tryParse(air);
      if (dt != null) weekday = '周${weekdays[dt.weekday - 1]}';
    }
    final items = <(String, String)>[
      (l10n.bangumiSyncScheduleWeek, weekday),
      (l10n.bangumiSyncScheduleHour, '—'),
      (l10n.bangumiSyncScheduleMinute, '—'),
    ];
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppTokens.spaceSm, vertical: AppTokens.spaceXs),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
      ),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: <Widget>[
        for (final e in items)
          Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
            Text(e.$1, style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 2),
            Text(e.$2, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
          ]),
      ]),
    );
  }

  /// 进度条 + 文本百分比。
  Widget _buildProgressBar(ThemeData theme, ColorScheme scheme, int done, int total) {
    final ratio = total > 0 ? (done / total).clamp(0.0, 1.0) : 0.0;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
      ClipRRect(
        borderRadius: BorderRadius.circular(AppTokens.radiusSm),
        child: LinearProgressIndicator(
          value: ratio,
          minHeight: 8,
          backgroundColor: scheme.surfaceContainerHighest,
          valueColor: AlwaysStoppedAnimation<Color>(scheme.primary),
        ),
      ),
    ]);
  }
}

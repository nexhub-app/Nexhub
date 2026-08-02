/// Bangumi 收藏同步弹窗（详情页底栏「同步」按钮唤起）。
///
/// 按源网站原版 UI 风格重设计：顶部「我的完成度」进度条 + 数字输入 +
/// 更新按钮作为主操作区（参考 manga/novel 源站常见的「节奏稍快 / 我的完成度」面板）；
/// 评分 / 吐槽 / 五状态 / 公开私密 等扩展项收纳到「高级选项」ExpansionTile 默认收起。
/// 外层 [SingleChildScrollView] 兜底，避免内容过长溢出（窄屏 + 长吐槽 + 千集列表）。
///
/// 提交逻辑：底部「同步到 Bangumi」整体 PATCH /v0/users/-/collections/{subject_id}
/// （未收藏时 client 自动回退 POST）；点击「更新」仅把进度推送到 Bangumi。
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

  /// 用户手动选中的集/章节序号（1 起）。与数字框强镜像：
  /// - 数字框 N 变化 → 勾选 1..N 全选；
  /// - 勾选区变化 → 数字框 = max(已选序号)，空集时清空数字框。
  /// 保存时：动漫用勾选对应的 Bangumi episode id 调 markEpisodesWatched；
  /// 书籍（ep_status 字段）= max(已选序号)。
  Set<int> _selectedIndexes = <int>{};

  /// 是否展开逐集/章节勾选区（默认收起，避免上千集时弹窗过长）。
  bool _showEpCheckboxes = false;

  /// 展开时拉取的 Bangumi episode 列表（用于勾选 → id 的映射）。
  List<BangumiEpisode>? _episodes;
  bool _loadingEpisodes = false;
  String? _episodesLoadError;

  /// 当前条目是否为动漫（走 episode 级标记）。
  bool get _isAnime => widget.sourceType == SourceType.animeSource;

  /// 当前条目是否为书籍（漫画/小说，走 ep_status）。
  bool get _isBook => widget.sourceType == SourceType.mangaSource ||
      widget.sourceType == SourceType.novelSource;

  /// 多选列表的"集/话/章"单位：动漫=集、漫画=话、小说=章。用于总数标题。
  String _unitWord(AppLocalizations l10n) {
    if (_isAnime) return l10n.bangumiSyncUnitEp;
    if (widget.sourceType == SourceType.mangaSource) {
      return l10n.bangumiSyncUnitVolume;
    }
    return l10n.bangumiSyncUnitChapter;
  }

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
            _selectedIndexes = <int>{
              for (int i = 1; i <= remote.epStatus; i++) i,
            };
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

  /// 数字框变化 → 同步勾选 1..N（Bangumi API 的"标记前 N 集已看"语义）。
  /// 取消所有勾选：数字框清空。
  void _onProgressChanged(String v) {
    final n = int.tryParse(v.trim());
    if (n == null || n <= 0) {
      setState(() => _selectedIndexes = <int>{});
      return;
    }
    setState(() {
      _selectedIndexes = <int>{for (int i = 1; i <= n; i++) i};
    });
  }

  /// 勾选某项（idx 1 起）→ 数字框 = max(已选)；取消 → 数字框 = max(剩余已选)。
  void _toggleIndex(int idx, bool? v) {
    setState(() {
      final next = <int>{..._selectedIndexes};
      if (v == true) {
        next.add(idx);
      } else {
        next.remove(idx);
      }
      _selectedIndexes = next;
      final maxN = next.isEmpty ? 0 : next.reduce((a, b) => a > b ? a : b);
      _progressCtrl.text = maxN == 0 ? '' : '$maxN';
    });
  }

  /// 切换"选择具体集/章节"展开状态：首次展开时拉取 Bangumi episode 列表。
  Future<void> _toggleShowList() async {
    setState(() => _showEpCheckboxes = !_showEpCheckboxes);
    if (_showEpCheckboxes && _episodes == null && !_loadingEpisodes) {
      setState(() {
        _loadingEpisodes = true;
        _episodesLoadError = null;
      });
      try {
        final eps = await widget.client.fetchEpisodes(widget.subjectId);
        if (!mounted) return;
        setState(() {
          _episodes = eps;
          _loadingEpisodes = false;
        });
      } on Object catch (e) {
        if (!mounted) return;
        setState(() {
          _episodesLoadError = e.toString();
          _loadingEpisodes = false;
        });
      }
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
      // 数字框是"快捷主操作"；勾选区强镜像（max(已选) = 数字框值）。
      // 这里直接读数字框作为最终进度输入——勾选区只是可视化与细调。
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

      // 2. 动漫：用勾选区构造 episode id 集合并标记差集。
      // 数字框 = max(已选) 时，勾选区 = {1..max}；若用户取消中间某项，
      // 勾选区是"非连续子集"，Bangumi 仍能逐集标记。
      if (_isAnime && _selectedIndexes.isNotEmpty) {
        if (_episodes == null || _episodes!.isEmpty) {
          // 列表未加载（用户未展开多选）时回退到"前 N 集"语义，
          // 拉一次 episode 列表。
          final episodes = await widget.client.fetchEpisodes(widget.subjectId);
          if (!mounted) return;
          _episodes = episodes;
        }
        final episodes = _episodes!;
        final episodeIds = <int>[
          for (final idx in _selectedIndexes)
            for (final ep in episodes)
              if (ep.sort.round() == idx) ep.id,
        ];
        if (episodeIds.isNotEmpty) {
          // 增量标集：只标记远端尚未「看过」的差集（避免重复 PATCH）。
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

  /// 逐集/章节勾选区（可滚动）。已选集合 [_selectedIndexes] 与数字框强镜像。
  /// 动漫：episode 列表来自 Bangumi（按 sort 升序），每行按 sort 序号对应。
  /// 书籍：Bangumi 没有 episode 概念，使用 _detail.eps（已知时）回退到本地序号。
  Widget _buildEpCheckboxList(AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    final unit = _unitWord(l10n);
    if (_loadingEpisodes) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppTokens.spaceSm),
        child: Row(children: <Widget>[
          const SizedBox(
            width: 16, height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: AppTokens.spaceSm),
          Text(l10n.loading, style: TextStyle(color: scheme.onSurfaceVariant)),
        ]),
      );
    }
    if (_episodesLoadError != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppTokens.spaceXs),
        child: Text(
          l10n.bangumiSyncLoadEpisodesFailed(_episodesLoadError!),
          style: TextStyle(color: scheme.error, fontSize: 12),
        ),
      );
    }
    final eps = _episodes;
    if (_isAnime) {
      if (eps == null || eps.isEmpty) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: AppTokens.spaceXs),
          child: Text(
            l10n.bangumiSyncNoEpisodeList(_detail?.eps ?? 0),
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
          ),
        );
      }
      return _buildAnimeCheckboxList(l10n, eps, unit);
    }
    // 书籍：直接用序号 1.._detail.eps（或 1..24 兜底）。
    final total = (_detail?.eps ?? 0) > 0 ? _detail!.eps : 24;
    return _buildBookCheckboxList(l10n, total, unit);
  }

  Widget _buildAnimeCheckboxList(
    AppLocalizations l10n,
    List<BangumiEpisode> eps,
    String unit,
  ) {
    final selected = <int>{..._selectedIndexes};
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
      // 顶部：全选/全不选 + 总数提示
      Row(children: <Widget>[
        TextButton.icon(
          onPressed: () => setState(() {
            _selectedIndexes = <int>{
              for (int i = 1; i <= eps.length; i++) i,
            };
            _progressCtrl.text = '${eps.length}';
          }),
          icon: const Icon(Icons.check_box_outlined, size: 16),
          label: Text(l10n.selectAll),
        ),
        TextButton.icon(
          onPressed: () => setState(() {
            _selectedIndexes = <int>{};
            _progressCtrl.text = '';
          }),
          icon: const Icon(Icons.check_box_outline_blank, size: 16),
          label: Text(l10n.deselectAll),
        ),
        const Spacer(),
        Text(
          l10n.bangumiSyncChaptersLoadedHint(eps.length, unit),
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      ]),
      const SizedBox(height: AppTokens.spaceXs),
      ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 240),
        child: Scrollbar(
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: eps.length,
            itemBuilder: (BuildContext ctx, int i) {
              final ep = eps[i];
              final idx = ep.sort.round();
              if (idx < 1) return const SizedBox.shrink();
              return CheckboxListTile(
                value: selected.contains(idx),
                onChanged: (v) {
                  _toggleIndex(idx, v);
                  // 强制 setState 触发 ListView 刷新（_toggleIndex 已 setState）。
                },
                title: Text(l10n.episodeN(idx)),
                controlAffinity: ListTileControlAffinity.leading,
                dense: true,
                contentPadding: EdgeInsets.zero,
              );
            },
          ),
        ),
      ),
    ]);
  }

  Widget _buildBookCheckboxList(
    AppLocalizations l10n,
    int total,
    String unit,
  ) {
    final selected = <int>{..._selectedIndexes};
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
      Row(children: <Widget>[
        TextButton.icon(
          onPressed: () => setState(() {
            _selectedIndexes = <int>{for (int i = 1; i <= total; i++) i};
            _progressCtrl.text = '$total';
          }),
          icon: const Icon(Icons.check_box_outlined, size: 16),
          label: Text(l10n.selectAll),
        ),
        TextButton.icon(
          onPressed: () => setState(() {
            _selectedIndexes = <int>{};
            _progressCtrl.text = '';
          }),
          icon: const Icon(Icons.check_box_outline_blank, size: 16),
          label: Text(l10n.deselectAll),
        ),
        const Spacer(),
        Text(
          l10n.bangumiSyncChaptersTotal(total, unit),
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      ]),
      const SizedBox(height: AppTokens.spaceXs),
      ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 240),
        child: Scrollbar(
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: total,
            itemBuilder: (BuildContext ctx, int i) {
              final idx = i + 1;
              return CheckboxListTile(
                value: selected.contains(idx),
                onChanged: (v) => _toggleIndex(idx, v),
                title: Text(_isBook && widget.sourceType == SourceType.mangaSource
                    ? l10n.chapterN(idx)
                    : l10n.novelChapterN(idx)),
                controlAffinity: ListTileControlAffinity.leading,
                dense: true,
                contentPadding: EdgeInsets.zero,
              );
            },
          ),
        ),
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
          // 顶部标题 + 关闭按钮
          Row(children: <Widget>[
            Expanded(
              child: Text(
                titleText,
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
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
            // ───────── 主区：「我的完成度」按网站样式 ─────────
            // 标题行：左侧 label，右侧当前进度
            Row(children: <Widget>[
              Icon(Icons.bookmark_outline, size: 18, color: scheme.primary),
              const SizedBox(width: AppTokens.spaceXs),
              Text(
                l10n.bangumiSyncMyCompletion,
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              if (_isAnime || _isBook)
                Text(
                  _progressLabelText(l10n),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
            ]),
            const SizedBox(height: AppTokens.spaceSm),

            // 进度条（网站原版样式：高亮当前比例 + 剩余灰色）
            _buildProgressBar(theme, scheme, l10n),
            const SizedBox(height: AppTokens.spaceMd),

            // 数字输入 + / total + 更新按钮（参考网站 UI）
            if (_isAnime || _isBook)
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: _progressCtrl,
                      keyboardType: TextInputType.number,
                      onChanged: _onProgressChanged,
                      decoration: InputDecoration(
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: AppTokens.spaceSm,
                            vertical: AppTokens.spaceSm),
                        border: OutlineInputBorder(
                          borderRadius:
                              BorderRadius.circular(AppTokens.radiusMd),
                          borderSide: BorderSide(color: scheme.outline),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius:
                              BorderRadius.circular(AppTokens.radiusMd),
                          borderSide:
                              BorderSide(color: scheme.primary, width: 2),
                        ),
                      ),
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppTokens.spaceSm),
                    child: Text(
                      '/ ${_totalLabel(l10n)}',
                      style: theme.textTheme.titleMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    style: FilledButton.styleFrom(
                      backgroundColor: scheme.primaryContainer,
                      foregroundColor: scheme.onPrimaryContainer,
                    ),
                    icon: _saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh, size: 18),
                    label: Text(l10n.bangumiSyncUpdate),
                  ),
                ],
              ),
            const SizedBox(height: AppTokens.spaceXs),

            // 展开「选择具体集/章节」
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _toggleShowList,
                icon: Icon(
                  _showEpCheckboxes
                      ? Icons.expand_less
                      : Icons.expand_more,
                  size: 18,
                ),
                label: Text(_showEpCheckboxes
                    ? l10n.bangumiSyncCollapseList
                    : l10n.bangumiSyncExpandList),
              ),
            ),
            if (_showEpCheckboxes)
              Padding(
                padding: const EdgeInsets.only(bottom: AppTokens.spaceMd),
                child: _buildEpCheckboxList(l10n),
              ),

            const Divider(height: AppTokens.spaceLg),

            // ───────── 高级选项（评分 / 吐槽 / 状态 / 公开私密） ─────────
            Theme(
              data: theme.copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(
                    bottom: AppTokens.spaceMd),
                leading: Icon(Icons.tune, size: 20, color: scheme.primary),
                title: Text(
                  l10n.bangumiSyncAdvancedOptions,
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  l10n.bangumiSyncAdvancedHint,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                children: <Widget>[
                  // 打星
                  Row(children: <Widget>[
                    Icon(Icons.star_outline, size: 18, color: scheme.primary),
                    const SizedBox(width: AppTokens.spaceXs),
                    Text(l10n.bangumiSyncRating,
                        style: theme.textTheme.titleSmall),
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

                  // 吐槽
                  TextField(
                    controller: _commentCtrl,
                    onChanged: (v) => _comment = v,
                    maxLines: 4,
                    minLines: 2,
                    decoration: InputDecoration(
                      labelText: l10n.bangumiSyncComment,
                      alignLabelWithHint: true,
                      border: OutlineInputBorder(
                          borderRadius:
                              BorderRadius.circular(AppTokens.radiusMd)),
                    ),
                  ),
                  const SizedBox(height: AppTokens.spaceMd),

                  // 五状态
                  Text(l10n.bangumiCollectionStatus,
                      style: theme.textTheme.titleSmall),
                  const SizedBox(height: AppTokens.spaceXs),
                  Wrap(
                    spacing: AppTokens.spaceXs,
                    runSpacing: AppTokens.spaceXs,
                    children: <Widget>[
                      for (final e in states)
                        ChoiceChip(
                          label: Text(e.$2),
                          selected: _type == e.$1,
                          onSelected: (_) =>
                              setState(() => _type = e.$1),
                        ),
                    ],
                  ),
                  const SizedBox(height: AppTokens.spaceMd),

                  // 公开/私密
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

            // ───────── 底部：同步到 Bangumi（主操作） ─────────
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _saving ? null : _save,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                      vertical: AppTokens.spaceMd),
                ),
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
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

  /// 进度条 + 文本百分比（按 _progressCtrl 数字 vs 总数比例）。
  Widget _buildProgressBar(
      ThemeData theme, ColorScheme scheme, AppLocalizations l10n) {
    final n = int.tryParse(_progressCtrl.text.trim()) ?? 0;
    final total = _totalCount();
    final ratio = total > 0 ? (n / total).clamp(0.0, 1.0) : 0.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ClipRRect(
          borderRadius: BorderRadius.circular(AppTokens.radiusSm),
          child: LinearProgressIndicator(
            value: ratio,
            minHeight: 8,
            backgroundColor: scheme.surfaceContainerHighest,
            valueColor: AlwaysStoppedAnimation<Color>(scheme.primary),
          ),
        ),
        const SizedBox(height: AppTokens.spaceXs),
        Text(
          total > 0
              ? '$n / $total'
              : (n > 0 ? '$n' : '0'),
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  /// 进度数字旁的提示文本（动漫/漫画/小说单位不同）。
  String _progressLabelText(AppLocalizations l10n) {
    final total = _totalCount();
    if (total > 0) return '${_unitWord(l10n)}: $total';
    return '';
  }

  /// 总数：动漫= Bangumi 返回的 eps（按 _episodes.length 优先），书籍 = _detail.eps 兜底 24。
  int _totalCount() {
    if (_isAnime) {
      if (_episodes != null && _episodes!.isNotEmpty) return _episodes!.length;
      if ((_detail?.eps ?? 0) > 0) return _detail!.eps;
    } else if (_isBook) {
      if ((_detail?.eps ?? 0) > 0) return _detail!.eps;
      return 24;
    }
    return 0;
  }

  /// 显示在 input 旁的 "X / Y" 中的 Y 部分。
  String _totalLabel(AppLocalizations l10n) {
    final total = _totalCount();
    return total > 0 ? '$total' : '?';
  }
}

/// Bangumi 全页标签内容（详情页「Bangumi」标签页）。
///
/// 结构（本轮改版）：
/// - 顶部常驻**头部卡**（封面 + 标题 + 评分/排名），不可折叠；
/// - 下方分区（均可折叠子区）：
///   · 详情内容：评分卡 / 简介（可展开）/ 元信息 / 收藏统计；
///   · 标签（搞笑等用户标签，可折叠）；
///   · 角色（可折叠子区，横向滚动）；
///   · 制作人员（可折叠子区，横向滚动）；
///   · 关联作品（点击条目弹出 Bangumi 条目面板）；
/// - 已移除标签页内吐槽与同步面板（同步改由详情页底栏「同步」按钮唤起弹窗）。
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:provider/provider.dart';

import '../models/plugin_config.dart';
import '../services/bangumi/bangumi_models.dart';
import '../services/bangumi/bangumi_proxy_config.dart';
import '../services/bangumi/bangumi_sync_service.dart';
import '../services/bangumi/subject_link_store.dart';
import '../theme/app_tokens.dart';
import 'bangumi_bind_sheet.dart';
import 'bangumi_subject_sheet.dart';

enum _FullState { loading, resolved, candidates, noMatch, error }

class BangumiFullTab extends StatefulWidget {
  final String contentId;
  final String title;
  final SourceType sourceType;

  /// 解析成功后上抛 subjectId，供详情页底栏渲染「同步」按钮。
  final ValueNotifier<int?>? subjectIdNotifier;

  const BangumiFullTab({
    super.key,
    required this.contentId,
    required this.title,
    required this.sourceType,
    this.subjectIdNotifier,
  });

  @override State<BangumiFullTab> createState() => _BangumiFullTabState();
}

class _BangumiFullTabState extends State<BangumiFullTab>
    with SingleTickerProviderStateMixin {
  _FullState _state = _FullState.loading;
  SubjectLink? _link;
  BangumiSubjectDetail? _detail;
  List<BangumiCharacter> _characters = const <BangumiCharacter>[];
  List<BangumiStaff> _staff = const <BangumiStaff>[];
  List<BangumiRelatedSubject> _related = const <BangumiRelatedSubject>[];
  List<BangumiSubject> _candidates = const <BangumiSubject>[];
  bool _loadingDetail = false;
  bool _detailFailed = false;
  bool _detailExpanded = true;   // 详情子区
  bool _tagsExpanded = true;     // 标签子区（搞笑等用户标签）
  bool _charsExpanded = true;    // 角色子区（默认展开，便于直接看到内容）
  bool _staffExpanded = true;    // 制作人员子区（默认展开，便于直接看到内容）
  bool _relatedExpanded = true;  // 关联作品子区（默认展开，可折叠）

  late final AnimationController _enter =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 600));

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _enter.dispose();
    super.dispose();
  }

  /// 入场动画：按序淡入 + 轻微上移（灵动感）。
  Widget _animate(Widget child, int index) {
    final begin = (index * 0.07).clamp(0.0, 0.55);
    final end = (begin + 0.4).clamp(0.0, 1.0);
    final curve = CurvedAnimation(
      parent: _enter,
      curve: Interval(begin, end, curve: Curves.easeOutCubic),
    );
    return FadeTransition(
      opacity: curve,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.06),
          end: Offset.zero,
        ).animate(curve),
        child: child,
      ),
    );
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _state = _FullState.loading;
      _detailFailed = false;
      _characters = const <BangumiCharacter>[];
      _staff = const <BangumiStaff>[];
      _related = const <BangumiRelatedSubject>[];
    });
    final service = context.read<BangumiSyncService>();
    try {
      final result = await service.linkStore.resolve(
        widget.contentId,
        widget.title,
        widget.sourceType,
      );
      if (!mounted) return;
      if (result.link != null) {
        _link = result.link;
        widget.subjectIdNotifier?.value = result.link!.subjectId;
        _state = _FullState.resolved;
        await Future.wait(<Future<void>>[
          _fetchDetail(result.link!.subjectId),
          _fetchCharsAndStaff(result.link!.subjectId),
          _fetchRelated(result.link!.subjectId),
        ]);
        if (mounted) _enter.forward(from: 0);
      } else if (result.candidates.isNotEmpty) {
        _candidates = result.candidates;
        _state = _FullState.candidates;
      } else {
        _state = _FullState.noMatch;
      }
    } catch (_) {
      if (!mounted) return;
      _state = _FullState.error;
    }
    if (mounted) setState(() {});
  }

  Future<void> _fetchDetail(int sid) async {
    setState(() => _loadingDetail = true);
    try {
      final d = await context.read<BangumiSyncService>().client.fetchSubject(sid);
      if (mounted) setState(() => _detail = d);
    } catch (_) {
      if (mounted) setState(() => _detailFailed = true);
    } finally {
      if (mounted) setState(() => _loadingDetail = false);
    }
  }

  Future<void> _fetchCharsAndStaff(int sid) async {
    try {
      final res = await context
          .read<BangumiSyncService>()
          .client
          .fetchCharactersAndStaff(sid);
      if (mounted) {
        if (res.characters.isNotEmpty) setState(() => _characters = res.characters);
        if (res.staff.isNotEmpty) setState(() => _staff = res.staff);
      }
    } catch (_) { /* 角色/制作人员非核心，失败不阻断 */ }
  }

  Future<void> _fetchRelated(int sid) async {
    try {
      final rels = await context
          .read<BangumiSyncService>()
          .client
          .fetchRelatedSubjects(sid);
      if (mounted && rels.isNotEmpty) setState(() => _related = rels);
    } catch (_) { /* 关联非核心，失败不阻断 */ }
  }

  Future<void> _rebind() async {
    await showBangumiBindSheet(
      context,
      contentId: widget.contentId,
      sourceType: widget.sourceType,
    );
    if (mounted) await _load();
  }

  Future<void> _bindCandidate(BangumiSubject s) async {
    await context
        .read<BangumiSyncService>()
        .linkStore
        .put(widget.contentId, SubjectLink(subjectId: s.id));
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    switch (_state) {
      case _FullState.loading:
        return const Center(
          child: SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
        );
      case _FullState.error:
        return _retryRow(l10n, l10n.bangumiLoadFailed, _load);
      case _FullState.candidates:
        return _buildCandidates(l10n);
      case _FullState.noMatch:
        return _actionRow(l10n, l10n.bangumiNoMatch,
            l10n.bangumiManualBind, _rebind);
      case _FullState.resolved:
        return _buildResolved(context, l10n);
    }
  }

  Widget _retryRow(AppLocalizations l10n, String msg, VoidCallback cb) =>
      Padding(
        padding: const EdgeInsets.all(AppTokens.spaceLg),
        child: Row(
          children: [
            Expanded(child: Text(msg, style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant))),
            TextButton(onPressed: cb, child: Text(l10n.retry)),
          ],
        ),
      );

  Widget _actionRow(AppLocalizations l10n, String msg,
      String action, VoidCallback cb) => Padding(
        padding: const EdgeInsets.all(AppTokens.spaceLg),
        child: Row(children: [
          Expanded(child: Text(msg, style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant))),
          TextButton.icon(onPressed: cb, icon: const Icon(Icons.link,size:16), label: Text(action)),
        ]),
      );

  Widget _buildCandidates(AppLocalizations l10n) => Padding(
        padding: const EdgeInsets.all(AppTokens.spaceLg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(l10n.bangumiConfirmBind, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: AppTokens.spaceSm),
          for (final c in _candidates.take(8))
            ListTile(dense: true, contentPadding: EdgeInsets.zero,
              leading: c.image != null ? ClipRRect(
                borderRadius: BorderRadius.circular(AppTokens.radiusSm),
                child: Image.network(c.image!, width:36,height:50,fit:BoxFit.cover,
                  errorBuilder:(_,__,___)=>const Icon(Icons.tv)),
              ) : const Icon(Icons.tv, size:36),
              title: Text(c.displayName, maxLines:1, overflow:TextOverflow.ellipsis),
              subtitle: Text([
                if(c.name!=c.displayName) c.name,
                if(c.date!=null) c.date!,
              ].join(' · '), maxLines:1, overflow:TextOverflow.ellipsis),
              trailing: TextButton(onPressed:()=>_bindCandidate(c), child:Text(l10n.bangumiBindSubject)),
            ),
          const SizedBox(height: AppTokens.spaceSm),
          OutlinedButton.icon(onPressed:_rebind, icon:const Icon(Icons.search,size:16), label:Text(l10n.bangumiManualBind)),
        ]),
      );

  /// ──── 已解析：可折叠头部 + 分区内容 ────
  Widget _buildResolved(BuildContext ctx, AppLocalizations l10n) {
    if (_loadingDetail && _detail == null) {
      return const Center(child: SizedBox(width:28,height:28,
        child: CircularProgressIndicator(strokeWidth:2.5)));
    }
    if (_detailFailed || _detail == null) {
      return _retryRow(l10n, l10n.bangumiLoadFailed, ()=>_fetchDetail(_link!.subjectId));
    }

    final d = _detail!;
    final rating = d.rating;
    final col = d.collection;
    final theme = Theme.of(context);

    return ListView(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        AppTokens.spaceMd, AppTokens.spaceSm,
        AppTokens.spaceMd, AppTokens.spaceXl,
      ),
      children: <Widget>[
        // ══════════ 头部卡（常驻，不折叠）══════════
        _BangumiHeaderCard(
          detail: d, rating: rating,
          onOpenWeb: () => showBangumiSubjectSheet(context, subjectId: d.id),
          onRebind: _rebind,
        ),
        const SizedBox(height: AppTokens.spaceMd),

                    // ── 详情内容（可折叠子区）──
                    _animate(
                      _CollapseTile(
                        icon: Icons.info_outline,
                        title: l10n.bangumiDetail,
                        expanded: _detailExpanded,
                        onChanged: (v) => setState(() => _detailExpanded = v),
                        child: _DetailBody(detail: d, rating: rating, col: col),
                      ), 0,
                    ),

                    // ── 标签（可折叠子区：搞笑等用户标签）──
                    if (d.tags.isNotEmpty) ...<Widget>[
                      const SizedBox(height: AppTokens.spaceSm),
                      _animate(
                        _CollapseTile(
                          icon: Icons.sell_outlined,
                          title: l10n.bangumiTags,
                          expanded: _tagsExpanded,
                          onChanged: (v) => setState(() => _tagsExpanded = v),
                          child: Wrap(
                            spacing: AppTokens.spaceXs, runSpacing: AppTokens.spaceXs,
                            children: d.tags
                              .map((t) => Chip(
                                label: Text(t, style: theme.textTheme.labelSmall),
                                visualDensity: VisualDensity.compact,
                                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ))
                              .toList(),
                          ),
                        ), 1,
                      ),
                    ],

                    // ── 角色（可折叠子区，横向滚动）──
                    if (_characters.isNotEmpty) ...<Widget>[
                      const SizedBox(height: AppTokens.spaceSm),
                      _animate(
                        _CollapseTile(
                          icon: Icons.people_outline,
                          title: l10n.bangumiCharacters,
                          expanded: _charsExpanded,
                          onChanged: (v) => setState(() => _charsExpanded = v),
                          child: SizedBox(
                            height: 142,
                            child: ListView.separated(
                              scrollDirection: Axis.horizontal,
                              itemCount: _characters.length,
                              separatorBuilder: (_,__) => const SizedBox(width: AppTokens.spaceSm),
                              itemBuilder: (_, i) => _CharacterTile(char: _characters[i]),
                            ),
                          ),
                        ), 1,
                      ),
                    ],

                    // ── 制作人员（可折叠子区，横向滚动）──
                    if (_staff.isNotEmpty) ...<Widget>[
                      const SizedBox(height: AppTokens.spaceSm),
                      _animate(
                        _CollapseTile(
                          icon: Icons.movie_creation_outlined,
                          title: l10n.bangumiStaff,
                          expanded: _staffExpanded,
                          onChanged: (v) => setState(() => _staffExpanded = v),
                          child: SizedBox(
                            height: 142,
                            child: ListView.separated(
                              scrollDirection: Axis.horizontal,
                              itemCount: _staff.length,
                              separatorBuilder: (_,__) => const SizedBox(width: AppTokens.spaceSm),
                              itemBuilder: (_, i) => _StaffTile(staff: _staff[i]),
                            ),
                          ),
                        ), 2,
                      ),
                    ],

                    // ── 关联作品（可折叠，点击条目弹出）──
                    if (_related.isNotEmpty) ...<Widget>[
                      const SizedBox(height: AppTokens.spaceSm),
                      _animate(
                        _CollapseTile(
                          icon: Icons.link,
                          title: l10n.bangumiRelated,
                          expanded: _relatedExpanded,
                          onChanged: (v) => setState(() => _relatedExpanded = v),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
                            ..._related.map((r) => _RelatedTile(
                              related: r,
                              onTap: () => showBangumiSubjectSheet(ctx, subjectId: r.id),
                            )),
                          ]),
                        ), 3,
                      ),
                    ],

        const SizedBox(height: AppTokens.spaceLg),
      ],
    );
  }
}

// ═══════════════════════════ 辅助控件 ═══════════════════════════

/// 可折叠头部卡：封面 + 标题 + 评分/排名；整卡可点收起/展开。
class _BangumiHeaderCard extends StatelessWidget {
  final BangumiSubjectDetail detail;
  final BangumiSubjectRating rating;
  final VoidCallback onOpenWeb;
  final VoidCallback onRebind;

  const _BangumiHeaderCard({
    required this.detail,
    required this.rating,
    required this.onOpenWeb,
    required this.onRebind,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final cover = detail.image != null
        ? ClipRRect(
            borderRadius: BorderRadius.circular(AppTokens.radiusMd),
            child: CachedNetworkImage(
              imageUrl: BangumiProxyConfig.instance.resolveImageUrl(detail.image!),
              width: 72, height: 96, fit: BoxFit.cover,
              placeholder: (_, __) => Container(
                width: 72, height: 96, color: scheme.surfaceContainerHighest,
                child: const Center(child: SizedBox(width: 20, height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2))),
              ),
              errorWidget: (_, __, ___) => Container(
                width: 72, height: 96, color: scheme.surfaceContainerHighest,
                child: const Center(child: Icon(Icons.tv, size: 28)),
              ),
            ),
          )
        : Container(width: 72, height: 96, color: scheme.surfaceContainerHighest,
            child: const Center(child: Icon(Icons.tv, size: 28)));

    final coverAnimated = TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0.92, end: 1),
      duration: const Duration(milliseconds: 360),
      curve: Curves.easeOutBack,
      builder: (_, s, child) => Transform.scale(scale: s, child: child),
      child: cover,
    );

    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTokens.radiusLg),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Padding(
          padding: const EdgeInsets.all(AppTokens.spaceMd),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            coverAnimated,
            const SizedBox(width: AppTokens.spaceMd),
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(children: [
                  Expanded(child: Text(detail.displayName,
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                    maxLines: 2, overflow: TextOverflow.ellipsis)),
                  IconButton(icon: const Icon(Icons.open_in_new, size: 18),
                    tooltip: l10n.bangumiViewOnWeb, visualDensity: VisualDensity.compact,
                    onPressed: onOpenWeb),
                  IconButton(icon: const Icon(Icons.link, size: 18),
                    tooltip: l10n.bangumiManualBind, visualDensity: VisualDensity.compact,
                    onPressed: onRebind),
                ]),
                const SizedBox(height: AppTokens.spaceXs),
                if (rating.hasScore)
                  Row(children: [
                    Icon(Icons.star, color: scheme.primary, size: 18),
                    const SizedBox(width: 4),
                    Text(rating.score.toStringAsFixed(1),
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: scheme.primary, fontWeight: FontWeight.bold)),
                    if (rating.rank > 0) ...<Widget>[
                      const SizedBox(width: AppTokens.spaceSm),
                      Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(color: scheme.primaryContainer,
                          borderRadius: BorderRadius.circular(AppTokens.radiusFull)),
                        child: Text('#${rating.rank}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onPrimaryContainer, fontWeight: FontWeight.w600))),
                    ],
                    const Spacer(),
                    Text(l10n.bangumiRatingUsers(rating.total),
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                  ])
                else
                  Text(l10n.bangumiNoRating,
                    style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
                const SizedBox(height: 2),
                Text('数据来自 Bangumi',
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              ],
            )),
          ]),
        ),
      );
  }
}

/// 通用可折叠子区（标题行 + 旋转箭头 + 高度过渡）。
class _CollapseTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final bool expanded;
  final ValueChanged<bool> onChanged;
  final Widget child;

  const _CollapseTile({
    required this.icon,
    required this.title,
    required this.expanded,
    required this.onChanged,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
      InkWell(
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        onTap: () => onChanged(!expanded),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppTokens.spaceSm),
          child: Row(children: [
            Icon(icon, size: 18, color: scheme.primary),
            const SizedBox(width: AppTokens.spaceXs),
            Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
            const Spacer(),
            AnimatedRotation(
              turns: expanded ? 0.5 : 0,
              duration: const Duration(milliseconds: 240),
              child: Icon(Icons.expand_more, color: scheme.onSurfaceVariant, size: 20),
            ),
          ]),
        ),
      ),
      AnimatedSize(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOutCubic,
        child: expanded
            ? Padding(
                padding: const EdgeInsets.only(bottom: AppTokens.spaceSm),
                child: child,
              )
            : const SizedBox.shrink(),
      ),
    ]);
  }
}

/// 详情子区正文：简介（可展开）+ 元信息 + 标签云 + 收藏统计。
class _DetailBody extends StatefulWidget {
  final BangumiSubjectDetail detail;
  final BangumiSubjectRating rating;
  final BangumiCollectionStat col;
  const _DetailBody({required this.detail, required this.rating, required this.col});

  @override State<_DetailBody> createState() => _DetailBodyState();
}
class _DetailBodyState extends State<_DetailBody> {
  bool _summaryExpanded = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final d = widget.detail;
    final col = widget.col;

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
      // 评分卡（来自 Bangumi rating API：平均分 / 排名 / 评分人数）
      if (widget.rating.hasScore) ...<Widget>[
        Row(children: <Widget>[
          Icon(Icons.star_rounded, color: scheme.primary, size: 26),
          const SizedBox(width: 6),
          Text(widget.rating.score.toStringAsFixed(1),
            style: theme.textTheme.headlineSmall?.copyWith(
              color: scheme.primary, fontWeight: FontWeight.bold)),
          const SizedBox(width: AppTokens.spaceMd),
          if (widget.rating.rank > 0) ...<Widget>[
            Icon(Icons.emoji_events_outlined, size: 16, color: scheme.tertiary),
            const SizedBox(width: 4),
            Text(l10n.bangumiRank(widget.rating.rank),
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            const SizedBox(width: AppTokens.spaceMd),
          ],
          Text(l10n.bangumiRatingUsers(widget.rating.total),
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        ]),
        const SizedBox(height: AppTokens.spaceSm),
      ],
      // 简介
      if (d.summary.trim().isNotEmpty) ...<Widget>[
        AnimatedCrossFade(
          firstChild: Text(d.summary.trim(), maxLines: 3, overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium),
          secondChild: Text(d.summary.trim(), style: theme.textTheme.bodyMedium),
          crossFadeState: _summaryExpanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 250),
        ),
        if (d.summary.length > 120)
          Align(alignment: Alignment.centerLeft, child: TextButton(
            onPressed: () => setState(() => _summaryExpanded = !_summaryExpanded),
            child: Text(_summaryExpanded ? l10n.collapse : l10n.expand),
          )),
      ],
      // 元信息
      if (d.eps > 0 || d.airDate != null) ...<Widget>[
        const SizedBox(height: AppTokens.spaceSm),
        Wrap(spacing: AppTokens.spaceMd, runSpacing: AppTokens.spaceSm, children: <Widget>[
          if (d.eps > 0) _MetaChip(icon: Icons.movie_outlined, label: l10n.bangumiEps(d.eps)),
          if (d.airDate != null) _MetaChip(icon: Icons.event_outlined, label: l10n.bangumiAirDate(d.airDate!)),
          _MetaChip(icon: Icons.category_outlined, label: _typeLabel(d.type, l10n)),
        ]),
      ],
      // 收藏统计
      if (col.total > 0) ...<Widget>[
        const SizedBox(height: AppTokens.spaceSm),
        Wrap(spacing: AppTokens.spaceLg, runSpacing: AppTokens.spaceSm, children: <Widget>[
          if (col.wish > 0) _CollectionChip(icon: Icons.favorite_border, label: l10n.bangumiCollectionWish(col.wish), count: col.wish, color: scheme.tertiary),
          if (col.doing > 0) _CollectionChip(icon: Icons.play_circle_outline, label: l10n.bangumiCollectionDoing(col.doing), count: col.doing, color: scheme.primary),
          if (col.collect > 0) _CollectionChip(icon: Icons.check_circle_outline, label: l10n.bangumiCollectionCollect(col.collect), count: col.collect, color: scheme.secondary),
          if (col.onHold > 0) _CollectionChip(icon: Icons.pause_circle_outline, label: '${col.onHold} ${l10n.bangumiStateOnHold}', count: col.onHold, color: scheme.outline),
          if (col.dropped > 0) _CollectionChip(icon: Icons.cancel_outlined, label: '${col.dropped} ${l10n.bangumiStateDropped}', count: col.dropped, color: scheme.error),
        ]),
      ],
    ]);
  }

  static String _typeLabel(int type, AppLocalizations l10n) {
    switch (type) {
      case 1: return l10n.bangumiSubjectTypeBook;
      case 2: return l10n.bangumiSubjectTypeAnime;
      case 3: return '音乐';
      case 4: return l10n.bangumiSubjectTypeReal;
      case 6: return l10n.bangumiSubjectTypeReal;
      default: return '#$type';
    }
  }
}

class _MetaChip extends StatelessWidget {
  final IconData icon; final String label;
  const _MetaChip({required this.icon, required this.label});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size:14, color:t.colorScheme.onSurfaceVariant),
      const SizedBox(width:4),
      Text(label, style:t.textTheme.bodySmall?.copyWith(color:t.colorScheme.onSurfaceVariant)),
    ]);
  }
}

class _CollectionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final int count;
  final Color color;
  const _CollectionChip({
    required this.icon,
    required this.label,
    required this.count,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 4),
        Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: <Widget>[
          Text(label, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color)),
          Text('$count', style: Theme.of(context).textTheme.titleSmall?.copyWith(
            color: color, fontWeight: FontWeight.bold)),
        ]),
      ]),
    );
  }
}

/// 角色横向卡片。
class _CharacterTile extends StatelessWidget {
  final BangumiCharacter char;
  const _CharacterTile({required this.char});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(width: 100, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(AppTokens.radiusSm),
        child: char.image != null ? CachedNetworkImage(imageUrl: BangumiProxyConfig.instance.resolveImageUrl(char.image!), width: 100, fit: BoxFit.cover,
          placeholder: (_, __) => Container(color: theme.colorScheme.surfaceContainerHighest,
            child: const Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 1.5)))),
          errorWidget: (_, __, ___) => Container(color: theme.colorScheme.surfaceContainerHighest,
            child: const Center(child: Icon(Icons.person_outline))),
        ) : Container(color: theme.colorScheme.surfaceContainerHighest,
          child: const Center(child: Icon(Icons.person_outline))),
      )),
      const SizedBox(height: 4),
      Text(char.displayName, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.labelSmall),
      if (char.actor != null) Text(char.actor!.displayName, maxLines: 1, overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
    ]));
  }
}

/// 制作人员横向卡片。
class _StaffTile extends StatelessWidget {
  final BangumiStaff staff;
  const _StaffTile({required this.staff});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SizedBox(width: 100, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(AppTokens.radiusSm),
        child: staff.image != null ? CachedNetworkImage(imageUrl: BangumiProxyConfig.instance.resolveImageUrl(staff.image!), width: 100, fit: BoxFit.cover,
          placeholder: (_, __) => Container(color: scheme.surfaceContainerHighest,
            child: const Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 1.5)))),
          errorWidget: (_, __, ___) => Container(color: scheme.surfaceContainerHighest,
            child: const Center(child: Icon(Icons.person_outline))),
        ) : Container(color: scheme.surfaceContainerHighest,
          child: const Center(child: Icon(Icons.person_outline))),
      )),
      const SizedBox(height: 4),
      Text(staff.displayName, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.labelSmall),
      if (staff.relation != null) Text(staff.relation!, maxLines: 1, overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(color: scheme.primary)),
    ]));
  }
}

/// 关联作品条目（点击弹出 Bangumi 条目面板）。
class _RelatedTile extends StatelessWidget {
  final BangumiRelatedSubject related;
  final VoidCallback onTap;
  const _RelatedTile({required this.related, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListTile(
      dense: true, contentPadding: EdgeInsets.zero,
      leading: related.image != null ? ClipRRect(
        borderRadius: BorderRadius.circular(AppTokens.radiusSm),
        child: CachedNetworkImage(imageUrl: BangumiProxyConfig.instance.resolveImageUrl(related.image!), width: 40, height: 54, fit: BoxFit.cover,
          placeholder: (_, __) => const SizedBox(width: 40, height: 54, child: Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 1.5)))),
          errorWidget: (_, __, ___) => const Icon(Icons.tv, size: 40),
        ),
      ) : const Icon(Icons.tv, size: 40),
      title: Text(related.displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Row(children: [
        if (related.relation != null) ...<Widget>[
          Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            margin: const EdgeInsets.only(right: 6),
            decoration: BoxDecoration(color: scheme.primaryContainer,
              borderRadius: BorderRadius.circular(AppTokens.radiusFull)),
            child: Text(related.relation!, style: theme.textTheme.labelSmall?.copyWith(color: scheme.onPrimaryContainer))),
        ],
        if (related.score != null) Text('★ ${related.score!.toStringAsFixed(1)}', style: theme.textTheme.bodySmall),
        if (related.score == null && related.relation == null)
          Text(_typeLabel(related.type, l10n), style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
      ]),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }

  static String _typeLabel(int type, AppLocalizations l10n) {
    switch (type) {
      case 1: return l10n.bangumiSubjectTypeBook;
      case 2: return l10n.bangumiSubjectTypeAnime;
      case 3: return '音乐';
      case 4: return l10n.bangumiSubjectTypeReal;
      case 6: return l10n.bangumiSubjectTypeReal;
      default: return '#$type';
    }
  }
}

/// Bangumi 全页标签内容（详情页「Bangumi」标签页）。
///
/// 替代原来仅展示 `BangumiDetailCard` 小卡片的方式，
/// 以全屏滚动布局呈现条目的完整信息：
/// 头部（封面+评分+收藏统计）→ 简介 → 元信息 → 全部标签 → 角色 → 关联作品 → 吐槽。
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:provider/provider.dart';

import '../models/plugin_config.dart';
import '../services/bangumi/bangumi_client.dart';
import '../services/bangumi/bangumi_models.dart';
import '../services/bangumi/bangumi_proxy_config.dart';
import '../services/bangumi/bangumi_sync_service.dart';
import '../services/bangumi/subject_link_store.dart';
import '../theme/app_tokens.dart';
import 'bangumi_bind_sheet.dart';
import 'bangumi_comment_section.dart';
import 'bangumi_subject_sheet.dart';

enum _FullState { loading, resolved, candidates, noMatch, error }

class BangumiFullTab extends StatefulWidget {
  final String contentId;
  final String title;
  final SourceType sourceType;

  const BangumiFullTab({
    super.key,
    required this.contentId,
    required this.title,
    required this.sourceType,
  });

  @override State<BangumiFullTab> createState() => _BangumiFullTabState();
}

class _BangumiFullTabState extends State<BangumiFullTab> {
  _FullState _state = _FullState.loading;
  SubjectLink? _link;
  BangumiSubjectDetail? _detail;
  BangumiUserCollection? _remote;
  List<BangumiCharacter> _characters = const <BangumiCharacter>[];
  List<BangumiRelatedSubject> _related = const <BangumiRelatedSubject>[];
  List<BangumiSubject> _candidates = const <BangumiSubject>[];
  bool _loadingDetail = false;
  bool _detailFailed = false;
  bool _summaryExpanded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _state = _FullState.loading;
      _detailFailed = false;
      _remote = null;
      _characters = const <BangumiCharacter>[];
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
        _state = _FullState.resolved;
        // 并行拉取：详情 + 收藏 + 角色 + 关联作品 + 评论(由子widget自行加载)
        await Future.wait(<Future<void>>[
          _fetchDetail(result.link!.subjectId),
          _fetchRemote(result.link!.subjectId),
          _fetchCharacters(result.link!.subjectId),
          _fetchRelated(result.link!.subjectId),
        ]);
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

  Future<void> _fetchRemote(int sid) async {
    try {
      final r = await context
          .read<BangumiSyncService>()
          .client
          .fetchUserCollection(sid);
      if (mounted) setState(() => _remote = r);
    } catch (_) {
      if (mounted) setState(() => _remote = null);
    }
  }

  Future<void> _fetchCharacters(int sid) async {
    try {
      final chars = await context
          .read<BangumiSyncService>()
          .client
          .fetchCharacters(sid);
      if (mounted && chars.isNotEmpty) setState(() => _characters = chars);
    } catch (_) { /* 角色非核心，失败不阻断 */ }
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
    final theme = Theme.of(context);

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
        return _retryRow(l10n, theme, l10n.bangumiLoadFailed, _load);
      case _FullState.candidates:
        return _buildCandidates(l10n, theme);
      case _FullState.noMatch:
        return _actionRow(l10n, theme, l10n.bangumiNoMatch,
            l10n.bangumiManualBind, _rebind);
      case _FullState.resolved:
        return _buildResolved(context, l10n, theme);
    }
  }

  Widget _retryRow(AppLocalizations l10n, ThemeData theme, String msg, VoidCallback cb) =>
      Padding(
        padding: const EdgeInsets.all(AppTokens.spaceLg),
        child: Row(
          children: [
            Expanded(child: Text(msg, style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant))),
            TextButton(onPressed: cb, child: Text(l10n.retry)),
          ],
        ),
      );

  Widget _actionRow(AppLocalizations l10n, ThemeData theme, String msg,
      String action, VoidCallback cb) => Padding(
        padding: const EdgeInsets.all(AppTokens.spaceLg),
        child: Row(children: [
          Expanded(child: Text(msg, style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant))),
          TextButton.icon(onPressed: cb, icon: const Icon(Icons.link,size:16), label: Text(action)),
        ]),
      );

  Widget _buildCandidates(AppLocalizations l10n, ThemeData theme) => Padding(
        padding: const EdgeInsets.all(AppTokens.spaceLg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(l10n.bangumiConfirmBind, style: theme.textTheme.bodyMedium),
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

  /// ──── 已解析：全屏滚动布局 ────
  Widget _buildResolved(BuildContext ctx, AppLocalizations l10n, ThemeData theme) {
    if (_loadingDetail && _detail == null) {
      return const Center(child: SizedBox(width:28,height:28,
        child: CircularProgressIndicator(strokeWidth:2.5)));
    }
    if (_detailFailed || _detail == null) {
      return _retryRow(l10n, theme, l10n.bangumiLoadFailed, ()=>_fetchDetail(_link!.subjectId));
    }

    final d = _detail!;
    final rating = d.rating;
    final col = d.collection;
    final scheme = theme.colorScheme;

    return ListView(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        AppTokens.spaceLg, AppTokens.spaceMd,
        AppTokens.spaceLg, AppTokens.spaceXl,
      ),
      children: <Widget>[
        // ══════════ 1. 头部：封面 + 标题行 + 评分 + 操作 ══════════
        _HeaderSection(detail:d, rating:rating, col:col, link:_link!,
          onRebind: _rebind, remote: _remote),

        const SizedBox(height: AppTokens.spaceLg),

        // ══════════ 2. 简介（可展开）══════════
        if (d.summary.trim().isNotEmpty) ...<Widget>[
          _SectionTitle(l10n, Icons.article_outlined, l10n.bangumiSummary),
          const SizedBox(height: AppTokens.spaceXs),
          AnimatedCrossFade(
            firstChild: Text(
              d.summary.trim(),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
            secondChild: Text(
              d.summary.trim(),
              style: theme.textTheme.bodyMedium,
            ),
            crossFadeState: _summaryExpanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 250),
          ),
          if (d.summary.length > 120)
            TextButton(
              onPressed: () => setState(() => _summaryExpanded = !_summaryExpanded),
              child: Text(_summaryExpanded ? l10n.collapse : l10n.expand),
            ),
          const Divider(height: AppTokens.spaceLg),
        ],

        // ══════════ 3. 元信息：话数 / 放送日期 / 类型 ══════════
        if (d.eps > 0 || d.airDate != null) ...<Widget>[
          Wrap(spacing:AppTokens.spaceMd, runSpacing:AppTokens.spaceSm, children:[
            if(d.eps>0)_MetaChip(icon:Icons.movie_outlined, label:l10n.bangumiEps(d.eps)),
            if(d.airDate!=null)_MetaChip(icon:Icons.event_outlined, label:l10n.bangumiAirDate(d.airDate!)),
            _MetaChip(icon:Icons.category_outlined, label:_typeLabel(d.type, l10n)),
          ]),
          const Divider(height: AppTokens.spaceLg),
        ],

        // ══════════ 4. 收藏统计横排 ══════════
        if (col.total > 0) ...<Widget>[
          _SectionTitle(l10n, Icons.bar_chart, l10n.bangumiCollectionStat),
          const SizedBox(height: AppTokens.spaceXs),
          Wrap(spacing: AppTokens.spaceLg, runSpacing: AppTokens.spaceSm, children: [
            if(col.wish>0)_CollectionChip(icon:Icons.favorite_border, label:l10n.bangumiCollectionWish(col.wish), count:col.wish, color:scheme.tertiary),
            if(col.doing>0)_CollectionChip(icon:Icons.play_circle_outline, label:l10n.bangumiCollectionDoing(col.doing), count:col.doing, color:scheme.primary),
            if(col.collect>0)_CollectionChip(icon:Icons.check_circle_outline, label:l10n.bangumiCollectionCollect(col.collect), count:col.collect, color:scheme.secondary),
            if(col.onHold>0)_CollectionChip(icon:Icons.pause_circle_outline, label:'${col.onHold} ${l10n.bangumiStateOnHold}', count:col.onHold, color:scheme.outline),
            if(col.dropped>0)_CollectionChip(icon:Icons.cancel_outlined, label:'${col.dropped} ${l10n.bangumiStateDropped}', count:col.dropped, color:scheme.error),
          ]),
          const Divider(height: AppTokens.spaceLg),
        ],

        // ══════════ 5. 全部标签云 ══════════
        if (d.tags.isNotEmpty) ...<Widget>[
          _SectionTitle(l10n, Icons.label_outline, l10n.bangumiTags),
          const SizedBox(height: AppTokens.spaceXs),
          Wrap(
            spacing: AppTokens.spaceSm, runSpacing: AppTokens.spaceXs,
            children: d.tags.map((t) => Chip(
              label: Text(t, style: theme.textTheme.labelSmall),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            )).toList(),
          ),
          const Divider(height: AppTokens.spaceLg),
        ],

        // ══════════ 6. 角色列表 ══════════
        if (_characters.isNotEmpty) ...<Widget>[
          _SectionTitle(l10n, Icons.people_outline, l10n.bangumiCharacters),
          const SizedBox(height: AppTokens.spaceXs),
          SizedBox(
            height: 140,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _characters.length,
              separatorBuilder: (_,__) => const SizedBox(width: AppTokens.spaceSm),
              itemBuilder: (_, i) => _CharacterTile(char: _characters[i]),
            ),
          ),
          const Divider(height: AppTokens.spaceLg),
        ],

        // ══════════ 7. 关联作品 ��═════════
        if (_related.isNotEmpty) ...<Widget>[
          _SectionTitle(l10n, Icons.link, l10n.bangumiRelated),
          const SizedBox(height: AppTokens.spaceXs),
          ..._related.map((r) => ListTile(
            dense: true, contentPadding: EdgeInsets.zero,
            leading: r.image != null ? ClipRRect(
              borderRadius: BorderRadius.circular(AppTokens.radiusSm),
              child: CachedNetworkImage(imageUrl:BangumiProxyConfig.instance.resolveImageUrl(r.image!), width:40,height:54,fit:BoxFit.cover,
                placeholder:(_,__)=>const SizedBox(width:40,height:54,child:Center(child:SizedBox(width:16,height:16,child:CircularProgressIndicator(strokeWidth:1.5)))),
                errorWidget:(_,__,___)=>const Icon(Icons.tv, size:40),
              ),
            ) : const Icon(Icons.tv, size:40),
            title: Text(r.displayName, maxLines:1, overflow:TextOverflow.ellipsis),
            subtitle: Row(children: [
              if(r.relation!=null)...[Container(
                padding:const EdgeInsets.symmetric(horizontal:6,vertical:1),
                margin: const EdgeInsets.only(right:6),
                decoration: BoxDecoration(color:scheme.primaryContainer,
                  borderRadius:BorderRadius.circular(AppTokens.radiusFull)),
                child: Text(r.relation!, style:theme.textTheme.labelSmall?.copyWith(color:scheme.onPrimaryContainer)),
              )],
              if(r.score!=null) Text('★ ${r.score!.toStringAsFixed(1)}', style:theme.textTheme.bodySmall),
              if(r.score==null&&r.relation==null) Text(_typeLabel(r.type,l10n), style:theme.textTheme.bodySmall?.copyWith(color:scheme.onSurfaceVariant)),
            ]),
            onTap: () => showBangumiSubjectSheet(ctx, subjectId: r.id),
          )),
          const Divider(height: AppTokens.spaceLg),
        ],

        // ══════════ 8. 同步面板（紧凑版）══════════
        if (_link != null) ...<Widget>[
          _CompactSyncPanel(subjectId:_link!.subjectId, contentId:widget.contentId,
            sourceType:widget.sourceType, initialRemote:_remote),
          const Divider(height: AppTokens.spaceLg),
        ],

        // ══════════ 9. 吐槽评论区 ═══��══════
        BangumiCommentSection(
          contentId: widget.contentId,
          title: widget.title,
          sourceType: widget.sourceType,
        ),

        const SizedBox(height: AppTokens.spaceLg),
      ],
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

// ═════════════════════════════ 辅助控件 ═══════════════════════════

class _SectionTitle extends StatelessWidget {
  final AppLocalizations l10n;
  final IconData icon;
  final String text;
  const _SectionTitle(this.l10n, this.icon, this.text);
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(children: [
      Icon(icon, size:18, color:theme.colorScheme.primary),
      const SizedBox(width:AppTokens.spaceXs),
      Text(text, style:theme.textTheme.titleSmall?.copyWith(fontWeight:FontWeight.w600)),
    ]);
  }
}

class _MetaChip extends StatelessWidget {
  final IconData icon; final String label;
  const _MetaChip({required this.icon, required this.label});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Row(mainAxisSize:MainAxisSize.min, children:[
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
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 4),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                label,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
              ),
              Text(
                '$count',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 头部区域：大封面 + 标题 + 评分 + 排名 + 操作按钮。
class _HeaderSection extends StatelessWidget {
  final BangumiSubjectDetail detail;
  final BangumiSubjectRating rating;
  final BangumiCollectionStat col;
  final SubjectLink link;
  final VoidCallback onRebind;
  final BangumiUserCollection? remote;
  const _HeaderSection({required this.detail, required this.rating, required this.col,
    required this.link, required this.onRebind, this.remote});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // 大封面
      ClipRRect(borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        child: detail.image != null ? CachedNetworkImage(
          imageUrl: BangumiProxyConfig.instance.resolveImageUrl(detail.image!), width:100, height:134, fit:BoxFit.cover,
          placeholder:(_,__)=>Container(width:100,height:134,color:scheme.surfaceContainerHighest,
            child:const Center(child:SizedBox(width:24,height:24,child:CircularProgressIndicator(strokeWidth:2)))),
          errorWidget:(_,__,___)=>Container(width:100,height:134,color:scheme.surfaceContainerHighest,
            child:const Center(child:Icon(Icons.tv, size:32))),
        ) : Container(width:100,height:134,color:scheme.surfaceContainerHighest,
          child:const Center(child:Icon(Icons.tv, size:32))),
      ),
      const SizedBox(width: AppTokens.spaceMd),
      // 右侧信息
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(detail.displayName, style:theme.textTheme.titleMedium?.copyWith(fontWeight:FontWeight.w700),
            maxLines:2, overflow:TextOverflow.ellipsis)),
          IconButton(icon:const Icon(Icons.open_in_new,size:18), tooltip:l10n.bangumiViewOnWeb,
            visualDensity:VisualDensity.compact,
            onPressed:()=>showBangumiSubjectSheet(context, subjectId:detail.id)),
          IconButton(icon:const Icon(Icons.link,size:18), tooltip:l10n.bangumiManualBind,
            visualDensity:VisualDensity.compact, onPressed:onRebind),
        ]),
        const SizedBox(height: AppTokens.spaceXs),
        // 评分行
        if (rating.hasScore) Row(children: [
          Icon(Icons.star, color:scheme.primary, size:20),
          const SizedBox(width:4),
          Text(rating.score.toStringAsFixed(1), style:theme.textTheme.titleMedium?.copyWith(
            color:scheme.primary, fontWeight:FontWeight.bold)),
          const SizedBox(width: AppTokens.spaceSm),
          if(rating.rank>0) Container(padding:const EdgeInsets.symmetric(horizontal:7,vertical:2),
            decoration:BoxDecoration(color:scheme.primaryContainer,
              borderRadius:BorderRadius.circular(AppTokens.radiusFull)),
            child:Text('#${rating.rank}', style:theme.textTheme.labelSmall?.copyWith(
              color:scheme.onPrimaryContainer, fontWeight:FontWeight.w600))),
          const Spacer(),
          Text(l10n.bangumiRatingUsers(rating.total), style:theme.textTheme.bodySmall?.copyWith(color:scheme.onSurfaceVariant)),
        ]) else Text(l10n.bangumiNoRating, style:theme.textTheme.bodyMedium?.copyWith(color:scheme.onSurfaceVariant)),

        // 数据来源标注
        const SizedBox(height: 2),
        Text('数据来自 Bangumi', style:theme.textTheme.bodySmall?.copyWith(color:scheme.onSurfaceVariant)),
      ])),
    ]);
  }
}

/// 角色横向卡片。
class _CharacterTile extends StatelessWidget {
  final BangumiCharacter char;
  const _CharacterTile({required this.char});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(width:100, child:Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(child: ClipRRect(borderRadius:BorderRadius.circular(AppTokens.radiusSm),
        child: char.image != null ? CachedNetworkImage(imageUrl:BangumiProxyConfig.instance.resolveImageUrl(char.image!), width:100, fit:BoxFit.cover,
          placeholder:(_,__)=>Container(color:theme.colorScheme.surfaceContainerHighest,
            child:const Center(child:SizedBox(width:16,height:16,child:CircularProgressIndicator(strokeWidth:1.5)))),
          errorWidget:(_,__,___)=>Container(color:theme.colorScheme.surfaceContainerHighest,
            child:const Center(child:Icon(Icons.person_outline))),
        ) : Container(color:theme.colorScheme.surfaceContainerHighest,
          child:const Center(child:Icon(Icons.person_outline))),
      )),
      const SizedBox(height:4),
      Text(char.displayName, maxLines:1, overflow:TextOverflow.ellipsis, style:theme.textTheme.labelSmall),
      if(char.actor!=null) Text(char.actor!.displayName, maxLines:1, overflow:TextOverflow.ellipsis,
        style:theme.textTheme.bodySmall?.copyWith(color:theme.colorScheme.onSurfaceVariant)),
    ]));
  }
}

/// 紧凑同步面板（仅显示关键操作按钮，不含完整表单）。
class _CompactSyncPanel extends StatefulWidget {
  final int subjectId; final String contentId; final SourceType sourceType;
  final BangumiUserCollection? initialRemote;
  const _CompactSyncPanel({required this.subjectId, required this.contentId,
    required this.sourceType, this.initialRemote});

  @override State<_CompactSyncPanel> createState() => _CompactSyncPanelState();
}
class _CompactSyncPanelState extends State<_CompactSyncPanel> {
  late int _type;
  bool _pulling = false, _saving = false;

  @override void initState() {
    super.initState();
    _type = widget.initialRemote?.type ?? BangumiCollectionType.wish;
  }

  BangumiSyncService get _service => context.read<BangumiSyncService>();

  Future<void>_pull()async{
    setState(()=>_pulling=true);
    try{final r=await _service.client.fetchUserCollection(widget.subjectId);
      if(mounted){if(r!=null){setState(()=>_type=r.type); ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(AppLocalizations.of(context).bangumiPullDone)));}
        else {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context).bangumiPullEmpty)));
        }
      }
    }
    on BangumiApiException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context).bangumiSyncFailed)));
      }
    }
    catch(_){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(AppLocalizations.of(context).bangumiSyncFailed)));}
    finally{if(mounted)setState(()=>_pulling=false);}
  }

  Future<void>_save()async{
    setState(()=>_saving=true);
    try{final p=CollectionPayload(type:_type, rate:0, private:false);
      if(_service.auth.isLoggedIn) await _service.client.patchCollection(widget.subjectId,p);
      if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(_service.auth.isLoggedIn?AppLocalizations.of(context).bangumiSyncDone:AppLocalizations.of(context).bangumiSavedLocal)));}
    on BangumiApiException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context).bangumiSyncFailed)));
      }
    }
    catch(_){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(AppLocalizations.of(context).bangumiSyncFailed)));}
    finally{if(mounted)setState(()=>_saving=false);}
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(l10n.bangumiSyncOptions, style:theme.textTheme.titleSmall),
      const SizedBox(height: AppTokens.spaceSm),
      Wrap(spacing:AppTokens.spaceXs, runSpacing:AppTokens.spaceXs, children:[
        for(final e in <(int,String)>[
          (BangumiCollectionType.wish, l10n.bangumiStateWish),
          (BangumiCollectionType.doing, l10n.bangumiStateDoing),
          (BangumiCollectionType.collect, l10n.bangumiStateCollect),
          (BangumiCollectionType.onHold, l10n.bangumiStateOnHold),
          (BangumiCollectionType.dropped, l10n.bangumiStateDropped),
        ]) ChoiceChip(label:Text(e.$2), selected:_type==e.$1,
          onSelected:(_){if(mounted)setState(()=>_type=e.$1);}),
      ]),
      const SizedBox(height: AppTokens.spaceSm),
      Row(children: [
        Expanded(child: OutlinedButton.icon(
          onPressed:_pulling?null:_pull, icon:_pulling?const SizedBox(width:14,height:14,
            child:CircularProgressIndicator(strokeWidth:1.5)):const Icon(Icons.cloud_download,size:16),
          label:Text(l10n.bangumiPullFromRemote))),
        const SizedBox(width:AppTokens.spaceSm),
        Expanded(child: FilledButton.icon(
          onPressed:_saving?null:_save, icon:_saving?const SizedBox(width:14,height:14,
            child:CircularProgressIndicator(strokeWidth:1.5)):const Icon(Icons.sync,size:16),
          label:Text(l10n.bangumiSaveSync))),
      ]),
    ]);
  }
}

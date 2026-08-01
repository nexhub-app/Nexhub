/// Bangumi 吐槽标签页（详情页评论区子页之一）。
///
/// 通过 [SubjectLinkStore.resolve] 解析条目 → 调 [BangumiClient.fetchSubjectComments]
/// 拉取吐槽（公开接口，无需登录，只读展示）。未绑定条目时提示，不阻塞其它子页。
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:provider/provider.dart';

import 'dart:math' as math;

import '../models/plugin_config.dart';
import '../services/bangumi/bangumi_models.dart';
import '../services/bangumi/bangumi_proxy_config.dart';
import '../services/bangumi/bangumi_sync_service.dart';
import '../services/bangumi/subject_link_store.dart';
import '../theme/app_tokens.dart';

/// Bangumi 吐槽区（根据官方 v0 评论接口增加，只读）。
class BangumiCommentSection extends StatefulWidget {
  final String contentId;
  final String title;
  final SourceType sourceType;

  const BangumiCommentSection({
    super.key,
    required this.contentId,
    required this.title,
    required this.sourceType,
  });

  @override
  State<BangumiCommentSection> createState() => _BangumiCommentSectionState();
}

class _BangumiCommentSectionState extends State<BangumiCommentSection> {
  List<BangumiComment> _comments = const <BangumiComment>[];
  bool _loading = true;
  bool _failed = false;
  bool _noSubject = false;
  String? _errorMessage;
  String? _guessedName;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _failed = false;
      _errorMessage = null;
      _guessedName = null;
    });
    final service = context.read<BangumiSyncService>();
    try {
      final result = await service.linkStore.resolve(
        widget.contentId,
        widget.title,
        widget.sourceType,
      );
      if (!mounted) return;

      int? subjectId;
      if (result.link != null) {
        subjectId = result.link!.subjectId;
      } else if (result.candidates.isNotEmpty) {
        BangumiSubject? best;
        double bestScore = -1;
        for (final BangumiSubject c in result.candidates) {
          final double s = math.max(
            bangumiTitleSimilarity(widget.title, c.name),
            bangumiTitleSimilarity(widget.title, c.nameCn),
          );
          if (s > bestScore) {
            bestScore = s;
            best = c;
          }
        }
        if (best != null) {
          subjectId = best.id;
          _guessedName = best.nameCn.isNotEmpty ? best.nameCn : best.name;
        }
      }

      if (subjectId == null) {
        setState(() { _loading = false; _noSubject = true; });
        return;
      }

      final comments = await service.client.fetchSubjectComments(subjectId);
      if (!mounted) return;
      setState(() { _comments = comments; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _failed = true; _errorMessage = e.toString(); });
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(AppTokens.spaceLg),
        child: Center(child: SizedBox(width:20,height:20,child:CircularProgressIndicator(strokeWidth:2))),
      );
    }
    if (_noSubject) {
      return Padding(
        padding: const EdgeInsets.all(AppTokens.spaceLg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l10n.bangumiNoMatch, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: AppTokens.spaceSm),
          OutlinedButton(onPressed: _load, child: Text(l10n.retry)),
        ]),
      );
    }
    if (_failed) {
      return Padding(
        padding: const EdgeInsets.all(AppTokens.spaceLg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l10n.bangumiCommentsLoadFailed, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
          if (_errorMessage != null)
            Padding(padding: const EdgeInsets.only(top: AppTokens.spaceXs), child:
              Text(_errorMessage!, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant), maxLines:3, overflow:TextOverflow.ellipsis)),
          const SizedBox(height: AppTokens.spaceSm),
          OutlinedButton(onPressed: _load, child: Text(l10n.retry)),
        ]),
      );
    }
    if (_comments.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(AppTokens.spaceLg),
        child: Text(l10n.bangumiCommentsEmpty, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
      );
    }
    // 紧凑布局：减小外边距让评论更紧凑
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppTokens.spaceMd, vertical: AppTokens.spaceXs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (_guessedName != null)
            Padding(
              padding: const EdgeInsets.only(bottom: AppTokens.spaceXs),
              child: Text(l10n.bangumiGuessMatch(_guessedName!),
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            ),
          for (final c in _comments)
            Padding(
              padding: const EdgeInsets.only(bottom: AppTokens.spaceXs),
              child: _BangumiCommentTile(comment: c),
            ),
        ],
      ),
    );
  }
}

// ═══════════════════════════ 单条吐槽卡片（紧凑版） ═══════════════════════════

class _BangumiCommentTile extends StatelessWidget {
  final BangumiComment comment;
  const _BangumiCommentTile({required this.comment});

  /// ISO 时间 → 相对时间。
  static String _formatTime(String isoStr) {
    if (isoStr.isEmpty) return '';
    try {
      final dt = DateTime.parse(isoStr);
      final diff = DateTime.now().difference(dt);
      if (diff.inDays > 365) return '${dt.year}-${dt.month.toString().padLeft(2,'0')}-${dt.day.toString().padLeft(2,'0')}';
      if (diff.inDays > 30) return '${diff.inDays ~/ 30}个月前';
      if (diff.inDays > 0) return '${diff.inDays}天前';
      if (diff.inHours > 0) return '${diff.inHours}小时前';
      if (diff.inMinutes > 0) return '${diff.inMinutes}分钟前';
      return '刚刚';
    } catch (_) {
      final idx = isoStr.indexOf('T');
      return idx > 0 ? isoStr.substring(0, idx) : isoStr;
    }
  }

  @override
  Widget build(BuildContext context) {
    return _BangumiCommentTileBody(
      comment: comment,
      avatar: comment.avatar,
      timeStr: _formatTime(comment.createdAt),
    );
  }
}

/// 吐槽卡片体 — 紧凑布局，长评可折叠。
class _BangumiCommentTileBody extends StatefulWidget {
  final BangumiComment comment;
  final String? avatar;
  final String timeStr;
  const _BangumiCommentTileBody({required this.comment, this.avatar, required this.timeStr});
  @override State<_BangumiCommentTileBody> createState() => _BangumiCommentTileBodyState();
}

class _BangumiCommentTileBodyState extends State<_BangumiCommentTileBody> {
  bool _expanded = false;
  static const int _kFoldThreshold = 80;
  bool get _needsFold => widget.comment.comment.length > _kFoldThreshold;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    final text = widget.comment.comment;
    final needsFold = _needsFold;
    final hasRating = widget.comment.rating > 0;
    final hasTime = widget.timeStr.isNotEmpty;

    // 用 Container 做紧凑卡片背景（替代 AppCard 减少内边距）
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
      ),
      // 紧凑内边距：上下左右都缩小
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // ── 第一行：小头像 + 用户名 + 评分 ──
          Row(
            children: <Widget>[
              // 更小的头像
              if (widget.avatar != null && widget.avatar!.startsWith('http'))
                CircleAvatar(
                  radius: 11,
                  backgroundImage: CachedNetworkImageProvider(
                    BangumiProxyConfig.instance.resolveImageUrl(widget.avatar!),
                  ),
                )
              else
                CircleAvatar(
                  radius: 11,
                  backgroundColor: scheme.primaryContainer,
                  child: Icon(Icons.person, size: 13, color: scheme.onPrimaryContainer),
                ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(widget.comment.displayName,
                  style: theme.textTheme.labelSmall,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              // 评分星标
              if (hasRating)
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.star, size: 12, color: scheme.primary),
                  const SizedBox(width: 2),
                  Text('${widget.comment.rating}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.primary, fontWeight: FontWeight.bold)),
                ]),
            ],
          ),

          // ── 第二行：正文（可折叠）──
          const SizedBox(height: 4),
          if (needsFold)
            AnimatedCrossFade(
              firstChild: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
              secondChild: Text(text, style: theme.textTheme.bodySmall),
              crossFadeState: _expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
              duration: const Duration(milliseconds: 200),
            )
          else
            Text(text, style: theme.textTheme.bodySmall),

          // 展开/收起
          if (needsFold)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => setState(() => _expanded = !_expanded),
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding: const EdgeInsets.symmetric(horizontal: 4)),
                child: Text(_expanded ? l10n.collapse : l10n.expand,
                  style: theme.textTheme.labelSmall?.copyWith(color: scheme.primary)),
              ),
            ),

          // ── 第三行：时间戳 ──
          if (hasTime)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(widget.timeStr,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant, fontSize: 11)),
            ),
        ],
      ),
    );
  }
}

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
import 'app_card.dart';

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
        // 无高置信匹配时，取与标题最相似者作为兜底，避免「无匹配」死路。
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
        setState(() {
          _loading = false;
          _noSubject = true;
        });
        return;
      }

      final comments = await service.client.fetchSubjectComments(subjectId);
      if (!mounted) return;
      setState(() {
        _comments = comments;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
        _errorMessage = e.toString();
      });
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
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (_noSubject) {
      return Padding(
        padding: const EdgeInsets.all(AppTokens.spaceLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              l10n.bangumiNoMatch,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppTokens.spaceSm),
            OutlinedButton(onPressed: _load, child: Text(l10n.retry)),
          ],
        ),
      );
    }
    if (_failed) {
      return Padding(
        padding: const EdgeInsets.all(AppTokens.spaceLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              l10n.bangumiCommentsLoadFailed,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            if (_errorMessage != null)
              Padding(
                padding: const EdgeInsets.only(top: AppTokens.spaceXs),
                child: Text(
                  _errorMessage!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            const SizedBox(height: AppTokens.spaceSm),
            OutlinedButton(onPressed: _load, child: Text(l10n.retry)),
          ],
        ),
      );
    }
    if (_comments.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(AppTokens.spaceLg),
        child: Text(
          l10n.bangumiCommentsEmpty,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTokens.spaceLg,
        vertical: AppTokens.spaceSm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (_guessedName != null)
            Padding(
              padding: const EdgeInsets.only(bottom: AppTokens.spaceSm),
              child: Text(
                l10n.bangumiGuessMatch(_guessedName!),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          for (final c in _comments)
            Padding(
              padding: const EdgeInsets.only(bottom: AppTokens.spaceSm),
              child: _BangumiCommentTile(comment: c),
            ),
        ],
      ),
    );
  }
}

class _BangumiCommentTile extends StatelessWidget {
  final BangumiComment comment;

  const _BangumiCommentTile({required this.comment});

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final String? avatar = comment.avatar;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              if (avatar != null && avatar.startsWith('http'))
                CircleAvatar(
                  radius: 16,
                  backgroundImage: CachedNetworkImageProvider(
                    BangumiProxyConfig.instance.resolveImageUrl(avatar),
                  ),
                )
              else
                CircleAvatar(
                  radius: 16,
                  backgroundColor: scheme.primaryContainer,
                  child: Icon(
                    Icons.person,
                    size: 18,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
              const SizedBox(width: AppTokens.spaceSm),
              Expanded(
                child: Text(
                  comment.displayName,
                  style: theme.textTheme.labelLarge,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (comment.rating > 0)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(Icons.star, size: 14, color: scheme.primary),
                    const SizedBox(width: 2),
                    Text(
                      '${comment.rating}',
                      style: theme.textTheme.labelSmall,
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: AppTokens.spaceSm),
          Text(comment.comment, style: theme.textTheme.bodyMedium),
          if (comment.createdAt.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: AppTokens.spaceXs),
              child: Text(
                comment.createdAt,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

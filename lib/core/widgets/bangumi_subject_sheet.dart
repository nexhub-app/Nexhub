/// Bangumi 条目信息底部面板。
///
/// 拉取并展示「来自网站」的条目数据：封面、名称、站点评分（平均分 / 评分人数 /
/// 排名 / 分布）、简介与用户标签，并提供在 Bangumi 网页打开入口。
/// 入口：详情页 Bangumi 卡片评分区、设置页「浏览 Bangumi 收藏」列表项。
library;

import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/bangumi/bangumi_client.dart';
import '../services/bangumi/bangumi_models.dart';
import '../services/bangumi/bangumi_sync_service.dart';
import '../theme/app_tokens.dart';

/// 唤起 Bangumi 条目信息底部面板。
Future<void> showBangumiSubjectSheet(
  BuildContext context, {
  required int subjectId,
}) {
  final BangumiClient client = context.read<BangumiSyncService>().client;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(AppTokens.radiusLg),
      ),
    ),
    builder: (BuildContext ctx) =>
        _BangumiSubjectSheet(client: client, subjectId: subjectId),
  );
}

class _BangumiSubjectSheet extends StatefulWidget {
  final BangumiClient client;
  final int subjectId;

  const _BangumiSubjectSheet({required this.client, required this.subjectId});

  @override
  State<_BangumiSubjectSheet> createState() => _BangumiSubjectSheetState();
}

class _BangumiSubjectSheetState extends State<_BangumiSubjectSheet> {
  BangumiSubjectDetail? _detail;
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final detail = await widget.client.fetchSubject(widget.subjectId);
      if (mounted) setState(() => _detail = detail);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.spaceLg),
        child: _loading
            ? const Padding(
                padding: EdgeInsets.all(AppTokens.spaceXl),
                child: Center(child: CircularProgressIndicator()),
              )
            : _failed || _detail == null
                ? Padding(
                    padding: const EdgeInsets.all(AppTokens.spaceLg),
                    child: Text(
                      l10n.bangumiLoadFailed,
                      style: theme.textTheme.bodyMedium,
                      textAlign: TextAlign.center,
                    ),
                  )
                : _buildContent(context, l10n, theme, _detail!),
      ),
    );
  }

  Widget _buildContent(
    BuildContext context,
    AppLocalizations l10n,
    ThemeData theme,
    BangumiSubjectDetail detail,
  ) {
    final rating = detail.rating;
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // ───── 封面 + 标题 ─────
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (detail.image != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppTokens.radiusSm),
                  child: Image.network(
                    detail.image!,
                    width: 64,
                    height: 90,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) =>
                        const Icon(Icons.image_not_supported),
                  ),
                ),
              const SizedBox(width: AppTokens.spaceMd),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      detail.displayName,
                      style: theme.textTheme.titleMedium,
                    ),
                    if (detail.name.isNotEmpty &&
                        detail.name != detail.displayName)
                      Padding(
                        padding: const EdgeInsets.only(top: AppTokens.spaceXs),
                        child: Text(
                          detail.name,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppTokens.spaceMd),
          // ───── 站点评分 ─────
          _RatingRow(rating: rating, l10n: l10n, theme: theme),
          // ───── 简介 ─────
          if (detail.summary.trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: AppTokens.spaceMd),
            Text(l10n.bangumiSummary, style: theme.textTheme.titleSmall),
            const SizedBox(height: AppTokens.spaceXs),
            Text(
              detail.summary.trim(),
              style: theme.textTheme.bodyMedium,
            ),
          ],
          // ───── 标签 ─────
          if (detail.tags.isNotEmpty) ...<Widget>[
            const SizedBox(height: AppTokens.spaceMd),
            Text(l10n.bangumiTags, style: theme.textTheme.titleSmall),
            const SizedBox(height: AppTokens.spaceXs),
            Wrap(
              spacing: AppTokens.spaceSm,
              runSpacing: AppTokens.spaceXs,
              children: detail.tags
                  .take(12)
                  .map((t) => Chip(
                        label: Text(t),
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize:
                            MaterialTapTargetSize.shrinkWrap,
                      ))
                  .toList(),
            ),
          ],
          const SizedBox(height: AppTokens.spaceMd),
          OutlinedButton.icon(
            onPressed: () => launchUrl(
              Uri.parse('https://bgm.tv/subject/${detail.id}'),
              mode: LaunchMode.externalApplication,
            ),
            icon: const Icon(Icons.open_in_new, size: 16),
            label: Text(l10n.bangumiViewOnWeb),
          ),
        ],
      ),
    );
  }
}

/// 站点评分行：平均分 + 评分人数 + 排名。
class _RatingRow extends StatelessWidget {
  final BangumiSubjectRating rating;
  final AppLocalizations l10n;
  final ThemeData theme;

  const _RatingRow({
    required this.rating,
    required this.l10n,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    if (!rating.hasScore) {
      return Text(
        l10n.bangumiNoRating,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Icon(Icons.star, color: theme.colorScheme.primary, size: 28),
        const SizedBox(width: AppTokens.spaceXs),
        Text(
          rating.score.toStringAsFixed(1),
          style: theme.textTheme.headlineSmall?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(width: AppTokens.spaceMd),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                l10n.bangumiRatingUsers(rating.total),
                style: theme.textTheme.bodySmall,
              ),
              if (rating.rank > 0)
                Text(
                  l10n.bangumiRank(rating.rank),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

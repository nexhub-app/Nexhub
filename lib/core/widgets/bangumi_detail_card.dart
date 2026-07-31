/// Bangumi 详情页卡片。
///
/// 渲染在详情页进度卡之后（[ContentDetailShell.bangumiSection] 插槽）：
/// 1. 未收藏时仅提示「收藏后即可评分与同步」；
/// 2. 已收藏且已绑定条目时，展示「来自网站」的 Bangumi 评分（平均分 / 评分人数 /
///    排名）与评价（简介 + 用户标签），点击可查看条目信息；
/// 3. 已收藏未绑定时，提示并提供绑定入口；
/// 4. 标题行提供小尺寸同步按钮，点击弹出同步设置面板（[showBangumiBindSheet]），
///    在面板内完成绑定 / 评分 / 短评 / 一键同步。
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
import 'app_card.dart';
import 'bangumi_bind_sheet.dart';
import 'bangumi_subject_sheet.dart';

class BangumiDetailCard extends StatefulWidget {
  final String contentId;
  final SourceType sourceType;

  const BangumiDetailCard({
    super.key,
    required this.contentId,
    required this.sourceType,
  });

  @override
  State<BangumiDetailCard> createState() => _BangumiDetailCardState();
}

class _BangumiDetailCardState extends State<BangumiDetailCard> {
  SubjectLink? _link;
  bool _linkLoaded = false;
  BangumiSubjectDetail? _detail;
  bool _loadingDetail = false;
  bool _detailFailed = false;

  @override
  void initState() {
    super.initState();
    _loadLinkAndDetail();
  }

  /// 读取条目绑定并拉取站点评分 / 评价（绑定存在时）。
  Future<void> _loadLinkAndDetail() async {
    final service = context.read<BangumiSyncService>();
    final link = await service.linkStore.get(widget.contentId);
    if (!mounted) return;
    setState(() {
      _link = link;
      _linkLoaded = true;
    });
    if (link == null) return;
    setState(() {
      _loadingDetail = true;
      _detailFailed = false;
    });
    try {
      final detail = await service.client.fetchSubject(link.subjectId);
      if (mounted) setState(() => _detail = detail);
    } catch (_) {
      if (mounted) setState(() => _detailFailed = true);
    } finally {
      if (mounted) setState(() => _loadingDetail = false);
    }
  }

  /// 打开同步设置面板，关闭后刷新绑定与站点数据（绑定可能变化）。
  Future<void> _openSyncPanel() async {
    await showBangumiBindSheet(
      context,
      contentId: widget.contentId,
      sourceType: widget.sourceType,
    );
    if (mounted) await _loadLinkAndDetail();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final manager = context.watch<FavoritesManager>();
    final bool favorited = manager
        .favoritesFor(widget.sourceType)
        .any((e) => e.id == widget.contentId);

    // 未收藏：仅提示，收藏后卡片自动切换（watch 驱动）。
    if (!favorited) {
      return AppCard(
        child: Row(
          children: <Widget>[
            Icon(Icons.star_border, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: AppTokens.spaceSm),
            Expanded(
              child: Text(
                l10n.bangumiFavoriteFirst,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // ───── 标题行 + 小同步按钮 ─────
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  l10n.bangumiSiteRating,
                  style: theme.textTheme.titleMedium,
                ),
              ),
              IconButton(
                onPressed: _openSyncPanel,
                icon: const Icon(Icons.sync, size: 20),
                tooltip: l10n.bangumiSyncSettings,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          const SizedBox(height: AppTokens.spaceXs),
          _buildBody(context, l10n, theme),
        ],
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    AppLocalizations l10n,
    ThemeData theme,
  ) {
    // 未绑定：提示 + 绑定入口。
    if (_linkLoaded && _link == null) {
      return Row(
        children: <Widget>[
          Expanded(
            child: Text(
              l10n.bangumiBindToViewRating,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          TextButton.icon(
            onPressed: _openSyncPanel,
            icon: const Icon(Icons.link, size: 16),
            label: Text(l10n.bangumiBindSubject),
          ),
        ],
      );
    }

    // 加载中 / 未就绪。
    if (!_linkLoaded || _loadingDetail) {
      return const Padding(
        padding: EdgeInsets.all(AppTokens.spaceMd),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    // 加载失败。
    if (_detailFailed || _detail == null) {
      return Row(
        children: <Widget>[
          Expanded(
            child: Text(
              l10n.bangumiLoadFailed,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          TextButton(
            onPressed: _loadLinkAndDetail,
            child: Text(l10n.retry),
          ),
        ],
      );
    }

    final detail = _detail!;
    final rating = detail.rating;
    return InkWell(
      borderRadius: BorderRadius.circular(AppTokens.radiusSm),
      onTap: () => showBangumiSubjectSheet(context, subjectId: detail.id),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppTokens.spaceXs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // ───── 站点评分 ─────
            Row(
              children: <Widget>[
                if (rating.hasScore) ...<Widget>[
                  Icon(Icons.star,
                      color: theme.colorScheme.primary, size: 24),
                  const SizedBox(width: AppTokens.spaceXs),
                  Text(
                    rating.score.toStringAsFixed(1),
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: AppTokens.spaceSm),
                  Expanded(
                    child: Text(
                      rating.rank > 0
                          ? '${l10n.bangumiRatingUsers(rating.total)} · '
                              '${l10n.bangumiRank(rating.rank)}'
                          : l10n.bangumiRatingUsers(rating.total),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ] else
                  Expanded(
                    child: Text(
                      l10n.bangumiNoRating,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                Icon(Icons.chevron_right,
                    color: theme.colorScheme.onSurfaceVariant, size: 20),
              ],
            ),
            // ───── 评价：简介 ─────
            if (detail.summary.trim().isNotEmpty) ...<Widget>[
              const SizedBox(height: AppTokens.spaceSm),
              Text(
                detail.summary.trim(),
                style: theme.textTheme.bodyMedium,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            // ───── 评价：用户标签 ─────
            if (detail.tags.isNotEmpty) ...<Widget>[
              const SizedBox(height: AppTokens.spaceSm),
              Wrap(
                spacing: AppTokens.spaceSm,
                runSpacing: AppTokens.spaceXs,
                children: detail.tags
                    .take(6)
                    .map((t) => Chip(
                          label: Text(t),
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ))
                    .toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

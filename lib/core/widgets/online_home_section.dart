/// 在线列表首页 Section（Phase 1.3 #7 A4-#7）。
///
/// 横向滚动卡片列表，含标题 + "查看全部"按钮。
/// 点击卡片进详情页；点击"查看全部"跳到对应分类 Tab。
library;

import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:provider/provider.dart';

import '../models/media_item.dart';
import '../services/source_repository.dart';
import '../theme/app_tokens.dart';
import 'content_card.dart';

/// 首页横向 Section。
///
/// [title] 由调用方传入（已 l10n 翻译）；[items] 为该 Section 的卡片数据；
/// [onItemTap] 点击卡片回调；[onViewAll] 点击"查看全部"回调（跳到对应分类 Tab）。
///
/// 懒加载支持：当 [loading] 为 true 且 [items] 为空时显示骨架占位；
/// 当 [errorMessage] 非空且 [items] 为空时显示错误 + 重试（[onRetry]）。
class OnlineHomeSection extends StatelessWidget {
  const OnlineHomeSection({
    super.key,
    required this.title,
    required this.items,
    required this.onItemTap,
    this.onViewAll,
    this.heroPrefix = 'online-home',
    this.loading = false,
    this.errorMessage,
    this.onRetry,
  });

  /// Section 标题（已 l10n 翻译）。
  final String title;

  /// 该 Section 的卡片数据（最多展示 12 条）。
  final List<MediaItem> items;

  /// 点击卡片回调。
  final void Function(MediaItem item, String? heroTag) onItemTap;

  /// 点击"查看全部"回调（跳到对应分类 Tab）。
  final VoidCallback? onViewAll;

  /// Hero 动画前缀（避免多 Section 重复 tag）。
  final String heroPrefix;

  /// 是否正在加载（[items] 为空时显示骨架占位）。
  final bool loading;

  /// 加载失败文案（[items] 为空时显示错误 + 重试）。
  final String? errorMessage;

  /// 重试回调（[errorMessage] 非空时显示）。
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    // 既无数据、也无加载/错误态：保持收缩（理论上懒加载总会先进入 loading）。
    if (items.isEmpty && !loading && errorMessage == null) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // 标题栏 + 查看全部
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTokens.spaceLg,
            vertical: AppTokens.spaceXs,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Text(
                title,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (onViewAll != null)
                TextButton(
                  onPressed: onViewAll,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(l10n.viewAll),
                      const Icon(Icons.chevron_right, size: 16),
                    ],
                  ),
                ),
            ],
          ),
        ),
        if (loading && items.isEmpty)
          _buildLoadingRow(context)
        else if (errorMessage != null && items.isEmpty)
          _buildErrorRow(context, l10n)
        else
          _buildCardRow(context),
      ],
    );
  }

  /// 加载中骨架：横向 4 个灰色占位块。
  Widget _buildLoadingRow(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 200,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppTokens.spaceLg),
        itemCount: 4,
        separatorBuilder: (_, __) =>
            const SizedBox(width: AppTokens.spaceSm),
        itemBuilder: (BuildContext ctx, int i) => Container(
          width: 120,
          decoration: BoxDecoration(
            color: scheme.onSurface.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(AppTokens.radiusMd),
          ),
        ),
      ),
    );
  }

  /// 加载失败：文案 + 重试按钮。
  Widget _buildErrorRow(BuildContext context, AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTokens.spaceLg,
        vertical: AppTokens.spaceSm,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              errorMessage!,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          if (onRetry != null)
            TextButton(
              onPressed: onRetry,
              child: Text(l10n.retry),
            ),
        ],
      ),
    );
  }

  /// 横向卡片列表（正常态）。
  Widget _buildCardRow(BuildContext context) {
    return SizedBox(
      height: 200,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          horizontal: AppTokens.spaceLg,
        ),
        itemCount: items.length,
        separatorBuilder: (_, __) =>
            const SizedBox(width: AppTokens.spaceSm),
        itemBuilder: (BuildContext ctx, int i) {
          final item = items[i];
          return SizedBox(
            width: 120,
            child: ContentCard(
              title: item.title,
              coverUrl: item.coverUrl,
              source: ctx.read<SourceRepository>().getById(item.sourceId ?? ''),
              subtitle: item.status,
              meta: item.year,
              heroTag: '$heroPrefix-${item.id}',
              onTap: () => onItemTap(item, '$heroPrefix-${item.id}'),
            ),
          );
        },
      ),
    );
  }
}

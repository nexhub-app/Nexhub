/// RSS 文章列表条目的统一排版样式库（订阅源详情 / 收藏 / 搜索共用）。
///
/// 样式档位（SharedPreferences 键 `rss_list_layout_v1`，各列表页共享同一份）：
/// 0=列表（默认） / 1=卡片（封面缩略） / 2=紧凑（单行） / 3=大图卡片（杂志式）。
///
/// 统一走本库而非各页内联 ListTile 的原因：封面图必须经 [SourceImage] 携带
/// 文章页 Referer（防盗链站点裸请求一律 403）；排版样式改动一处全列表生效。
library;

import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';

import '../../../core/comic/models/reader_preferences.dart'
    show PrefsBackend;
import '../../../core/rss/rss_feed.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_animations.dart';
import '../../../core/widgets/source_image.dart';

/// 列表排版档位常量（与 `rss_list_layout_v1` 的取值一一对应）。
abstract final class RssListLayoutMode {
  static const int list = 0;
  static const int card = 1;
  static const int compact = 2;
  static const int magazine = 3;

  static const String prefsKey = 'rss_list_layout_v1';

  static Future<int> load(PrefsBackend backend) async {
    try {
      final String? v = await backend.get(prefsKey);
      final int? parsed = v == null ? null : int.tryParse(v);
      return (parsed == null || parsed < 0 || parsed > 3) ? list : parsed;
    } on Object {
      return list;
    }
  }

  static Future<void> save(PrefsBackend backend, int mode) async {
    try {
      await backend.set(prefsKey, mode.toString());
    } on Object {
      // 持久化失败忽略，内存态已生效。
    }
  }
}

/// 顶栏「列表样式」切换按钮（各列表页共用）。
class RssListLayoutAction extends StatelessWidget {
  final int layout;
  final ValueChanged<int> onSelected;

  const RssListLayoutAction({
    super.key,
    required this.layout,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    return PopupMenuButton<int>(
      icon: const Icon(Icons.view_agenda_outlined),
      tooltip: l10n.rssListLayout,
      onSelected: onSelected,
      itemBuilder: (BuildContext context) => <PopupMenuEntry<int>>[
        _item(0, Icons.list, l10n.rssLayoutList),
        _item(1, Icons.view_agenda_outlined, l10n.rssLayoutCard),
        _item(2, Icons.view_headline_outlined, l10n.rssLayoutCompact),
        _item(3, Icons.image_outlined, l10n.rssLayoutMagazine),
      ],
    );
  }

  PopupMenuItem<int> _item(int value, IconData icon, String label) {
    return PopupMenuItem<int>(
      value: value,
      child: Row(
        children: <Widget>[
          Icon(icon, size: 18),
          const SizedBox(width: AppTokens.spaceSm),
          Text(label),
        ],
      ),
    );
  }
}

/// 渲染一条列表条目所需的全部数据（由各列表页组装）。
class RssArticleTileData {
  final RssItem item;

  /// 已读置灰。
  final bool read;

  /// 是否已收藏（星标实心）。
  final bool favorite;

  /// 已按文章页地址绝对化的封面（可为 null）。
  final String? coverUrl;

  /// 已剥 HTML 的摘要（可为 null）。
  final String? excerpt;

  /// 作者/来源署名（可为 null）。
  final String? author;

  /// 已格式化的日期文本（可为 null）。
  final String? dateText;

  /// 来源标签（如聚合搜索里的订阅源名）；非空时优先于 [author] 展示。
  final String? sourceLabel;

  final VoidCallback onOpen;
  final VoidCallback onToggleFavorite;

  const RssArticleTileData({
    required this.item,
    required this.read,
    required this.favorite,
    required this.onOpen,
    required this.onToggleFavorite,
    this.coverUrl,
    this.excerpt,
    this.author,
    this.dateText,
    this.sourceLabel,
  });
}

/// 按排版档位分发到具体条目样式。
Widget buildRssArticleTile(
  BuildContext context,
  int layout,
  RssArticleTileData d,
) {
  switch (layout) {
    case RssListLayoutMode.card:
      return _CardTile(d: d);
    case RssListLayoutMode.compact:
      return _CompactTile(d: d);
    case RssListLayoutMode.magazine:
      return _MagazineTile(d: d);
    case RssListLayoutMode.list:
    default:
      return _ListTile(d: d);
  }
}

Color _titleColor(ThemeData theme, bool read) => read
    ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.55)
    : theme.colorScheme.onSurface;

Color _subColor(ThemeData theme, bool read) => read
    ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.45)
    : theme.colorScheme.onSurfaceVariant;

/// 元信息行：署名（或来源）+ 日期。
Widget _metaRow(RssArticleTileData d, ThemeData theme) {
  final Color color = _subColor(theme, d.read);
  final String? who = d.sourceLabel ?? d.author;
  return Row(
    children: <Widget>[
      if (who != null && who.isNotEmpty) ...<Widget>[
        Icon(Icons.person_outline, size: 12, color: color),
        const SizedBox(width: AppTokens.spaceXxs),
        Flexible(
          child: Text(
            who,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(color: color),
          ),
        ),
        const SizedBox(width: AppTokens.spaceSm),
      ],
      if (d.dateText != null) ...<Widget>[
        Icon(Icons.schedule, size: 12, color: color),
        const SizedBox(width: AppTokens.spaceXxs),
        Text(
          d.dateText!,
          style: theme.textTheme.labelSmall?.copyWith(color: color),
        ),
      ],
    ],
  );
}

/// 列表样式（默认）：标题 + 摘要 + 元信息 + 星标。
class _ListTile extends StatelessWidget {
  final RssArticleTileData d;

  const _ListTile({required this.d});

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppLocalizations l10n = AppLocalizations.of(context);
    return AnimatedOpacity(
      // 已读 → 渐隐变灰（渐变过渡，而非瞬间切换）
      opacity: d.read ? 0.6 : 1.0,
      duration: AppTokens.durBase,
      curve: Curves.easeOutCubic,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppTokens.spaceSm,
          vertical: AppTokens.spaceXs,
        ),
        title: Text(
          d.item.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleSmall?.copyWith(
            color: _titleColor(theme, d.read),
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (d.excerpt != null && d.excerpt!.isNotEmpty)
              Text(
                d.excerpt!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: _subColor(theme, d.read)),
              ),
            const SizedBox(height: AppTokens.spaceXs),
            _metaRow(d, theme),
          ],
        ),
        trailing: AppTapScale(
          scale: 0.85,
          duration: AppTokens.durFast,
          child: IconButton(
            icon: AnimatedSwitcher(
              duration: AppTokens.durBase,
              switchInCurve: AppCurves.spring,
              switchOutCurve: Curves.easeOutCubic,
              transitionBuilder: (Widget child, Animation<double> anim) =>
                  ScaleTransition(scale: anim, child: child),
              child: Icon(
                d.favorite ? Icons.star_rounded : Icons.star_outline_rounded,
                key: ValueKey<bool>(d.favorite),
                color: d.favorite
                    ? Colors.amber
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
            tooltip: d.favorite ? l10n.rssStarRemove : l10n.rssStarAdd,
            onPressed: d.onToggleFavorite,
          ),
        ),
        onTap: d.onOpen,
      ),
    );
  }
}

/// 卡片样式：封面缩略 + 标题 + 摘要 + 元信息 + 星标。
class _CardTile extends StatelessWidget {
  final RssArticleTileData d;

  const _CardTile({required this.d});

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppLocalizations l10n = AppLocalizations.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: AppTokens.spaceXs),
      child: InkWell(
        onTap: d.onOpen,
        child: Padding(
          padding: const EdgeInsets.all(AppTokens.spaceSm),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (d.coverUrl != null) ...<Widget>[
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppTokens.radiusSm),
                  child: SizedBox(
                    width: 72,
                    height: 72,
                    child: SourceImage(
                      url: d.coverUrl,
                      fit: BoxFit.cover,
                      refererOverride:
                          d.item.url.isNotEmpty ? d.item.url : null,
                    ),
                  ),
                ),
                const SizedBox(width: AppTokens.spaceSm),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      d.item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: _titleColor(theme, d.read),
                      ),
                    ),
                    const SizedBox(height: AppTokens.spaceXs),
                    if (d.excerpt != null && d.excerpt!.isNotEmpty)
                      Text(
                        d.excerpt!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: _subColor(theme, d.read)),
                      ),
                    const SizedBox(height: AppTokens.spaceXs),
                    _metaRow(d, theme),
                  ],
                ),
              ),
              AppTapScale(
                scale: 0.85,
                duration: AppTokens.durFast,
                child: IconButton(
                  icon: Icon(
                    d.favorite ? Icons.star_rounded : Icons.star_outline_rounded,
                    color: d.favorite
                        ? Colors.amber
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  tooltip: d.favorite ? l10n.rssStarRemove : l10n.rssStarAdd,
                  onPressed: d.onToggleFavorite,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 紧凑样式：单行标题 + 星标，信息密度最高。
class _CompactTile extends StatelessWidget {
  final RssArticleTileData d;

  const _CompactTile({required this.d});

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppLocalizations l10n = AppLocalizations.of(context);
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: AppTokens.spaceSm),
      title: Text(
        d.item.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium
            ?.copyWith(color: _titleColor(theme, d.read)),
      ),
      trailing: AppTapScale(
        scale: 0.85,
        duration: AppTokens.durFast,
        child: IconButton(
          icon: Icon(
            d.favorite ? Icons.star_rounded : Icons.star_outline_rounded,
            color: d.favorite
                ? Colors.amber
                : theme.colorScheme.onSurfaceVariant,
            size: 18,
          ),
          tooltip: d.favorite ? l10n.rssStarRemove : l10n.rssStarAdd,
          onPressed: d.onToggleFavorite,
        ),
      ),
      onTap: d.onOpen,
    );
  }
}

/// 大图卡片（杂志式）：通栏封面 + 标题/摘要/元信息，视觉冲击最强。
class _MagazineTile extends StatelessWidget {
  final RssArticleTileData d;

  const _MagazineTile({required this.d});

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppLocalizations l10n = AppLocalizations.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: AppTokens.spaceXs),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: d.onOpen,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (d.coverUrl != null)
              AspectRatio(
                aspectRatio: 16 / 9,
                child: SourceImage(
                  url: d.coverUrl,
                  fit: BoxFit.cover,
                  refererOverride: d.item.url.isNotEmpty ? d.item.url : null,
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(AppTokens.spaceSm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    d.item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: _titleColor(theme, d.read),
                    ),
                  ),
                  if (d.excerpt != null && d.excerpt!.isNotEmpty) ...<Widget>[
                    const SizedBox(height: AppTokens.spaceXs),
                    Text(
                      d.excerpt!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: _subColor(theme, d.read)),
                    ),
                  ],
                  const SizedBox(height: AppTokens.spaceXs),
                  Row(
                    children: <Widget>[
                      Expanded(child: _metaRow(d, theme)),
                      AppTapScale(
                        scale: 0.85,
                        duration: AppTokens.durFast,
                        child: IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: Icon(
                            d.favorite
                                ? Icons.star_rounded
                                : Icons.star_outline_rounded,
                            color: d.favorite
                                ? Colors.amber
                                : theme.colorScheme.onSurfaceVariant,
                          ),
                          tooltip:
                              d.favorite ? l10n.rssStarRemove : l10n.rssStarAdd,
                          onPressed: d.onToggleFavorite,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

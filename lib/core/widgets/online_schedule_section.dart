/// 在线列表周期表 Section（Phase 1.4 #7 A4-#7）。
///
/// 按 7 天（周一~周日）分组展示本周更新内容。横向 7 列 Chip，
/// 点击切换当天列表。源无法提供更新时间时回退为按 `latest` 顺序平铺。
///
/// 布局跟随全局 [LayoutSettings]（网格列数 / 列表模式 / 封面圆角 /
/// 标题 / 作者显示），并在布局变化时实时刷新（[ListenableBuilder]）。
library;

import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';

import '../models/media_item.dart';
import '../models/plugin_config.dart';
import '../settings/layout_settings.dart';
import '../theme/app_tokens.dart';
import 'app_cover_image.dart';
import 'content_card.dart';

/// 周更时间表 Section。
///
/// [items] 为近期内容列表（来自 `latest` route）；[onItemTap] 点击卡片回调。
/// 按 [MediaItem.updatedAt] 归类到对应星期；无 updatedAt 时回退为平铺列表。
class OnlineScheduleSection extends StatefulWidget {
  const OnlineScheduleSection({
    super.key,
    required this.items,
    required this.onItemTap,
    this.source,
    this.heroPrefix = 'online-schedule',
  });

  /// 近期内容列表（来自 `latest` route）。
  final List<MediaItem> items;

  /// 点击卡片回调。
  final void Function(MediaItem item, String? heroTag) onItemTap;

  /// 源配置：非空时封面注入防盗链 headers，修复远程封面灰屏。
  final PluginConfig? source;

  /// Hero 动画前缀。
  final String heroPrefix;

  @override
  State<OnlineScheduleSection> createState() => _OnlineScheduleSectionState();
}

class _OnlineScheduleSectionState extends State<OnlineScheduleSection> {
  /// 当前选中的星期（1=周一 ... 7=周日）。
  ///
  /// 默认值为"今天"的星期几（DateTime.weekday：1=Monday ... 7=Sunday）。
  late int _selectedWeekday = DateTime.now().weekday;

  /// 是否所有 items 都没有 updatedAt（用于回退为平铺列表）。
  bool get _hasNoUpdatedAt =>
      widget.items.every((it) => it.updatedAt == null);

  /// 返回某星期对应的中/英文标签。
  String _weekdayLabel(AppLocalizations l10n, int weekday) {
    return switch (weekday) {
      1 => l10n.weekdayMon,
      2 => l10n.weekdayTue,
      3 => l10n.weekdayWed,
      4 => l10n.weekdayThu,
      5 => l10n.weekdayFri,
      6 => l10n.weekdaySat,
      7 => l10n.weekdaySun,
      _ => '',
    };
  }

  /// 按 updatedAt 归类到各星期。
  Map<int, List<MediaItem>> _groupByWeekday() {
    final map = <int, List<MediaItem>>{
      1: <MediaItem>[],
      2: <MediaItem>[],
      3: <MediaItem>[],
      4: <MediaItem>[],
      5: <MediaItem>[],
      6: <MediaItem>[],
      7: <MediaItem>[],
    };
    for (final item in widget.items) {
      if (item.updatedAt == null) continue;
      map[item.updatedAt!.weekday]!.add(item);
    }
    return map;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    // 回退：无 updatedAt 时按 latest 顺序平铺。
    if (_hasNoUpdatedAt) {
      return _buildListBody(widget.items, theme, l10n);
    }

    final grouped = _groupByWeekday();
    final todayItems = grouped[_selectedWeekday] ?? <MediaItem>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // 星期 Chip 行
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTokens.spaceLg,
            vertical: AppTokens.spaceXs,
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: List<int>.generate(7, (i) => i + 1).map((wd) {
                final isSel = wd == _selectedWeekday;
                // 所有星期恒可点击：此前无内容的日子 onSelected 传 null 会把
                // Chip 禁用，导致「除周一外都点不了」。空日点进去展示既有的
                // emptyCategory 空态即可，交互不应被数据有无绑架。
                return Padding(
                  padding: const EdgeInsets.only(right: AppTokens.spaceXs),
                  child: ChoiceChip(
                    label: Text(_weekdayLabel(l10n, wd)),
                    selected: isSel,
                    onSelected: (_) =>
                        setState(() => _selectedWeekday = wd),
                  ),
                );
              }).toList(),
            ),
          ),
        ),
        const SizedBox(height: AppTokens.spaceXs),
        // 当天列表（随全局布局设置实时变化）
        if (todayItems.isEmpty)
          Padding(
            padding: const EdgeInsets.all(AppTokens.spaceLg),
            child: Text(
              l10n.emptyCategory,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else
          _buildListBody(todayItems, theme, l10n),
      ],
    );
  }

  /// 当天/平铺列表的内容区：跟随全局布局（网格列数 ↔ 列表模式）。
  /// 用 [ListenableBuilder] 订阅 [LayoutSettingsStore]，布局变化时即时重建。
  Widget _buildListBody(
    List<MediaItem> items,
    ThemeData theme,
    AppLocalizations l10n,
  ) {
    if (items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(AppTokens.spaceLg),
        child: Text(
          l10n.emptyCategory,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return ListenableBuilder(
      listenable: LayoutSettingsStore.instance,
      builder: (BuildContext context, _) {
        final LayoutSettings layout = LayoutSettingsStore.instance.settings;
        if (layout.layoutMode == LayoutMode.list) {
          // 列表模式：横向卡片行（封面 + 标题）。
          return ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.all(AppTokens.spaceLg),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: AppTokens.spaceSm),
            itemBuilder: (BuildContext c, int i) =>
                _buildListRow(items[i], layout),
          );
        }
        // 网格模式：按设置列数/间距渲染，复用统一 ContentCard（封面圆角/标题/
        // 作者跟随布局）。
        return LayoutBuilder(
          builder: (BuildContext context, BoxConstraints c) {
            final int cross = layout.gridColumns.clamp(1, 8);
            final double width = c.maxWidth;
            final double itemW = (width -
                    AppTokens.spaceLg * 2 -
                    AppTokens.spaceSm * (cross - 1)) /
                cross;
            return GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.all(AppTokens.spaceLg),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: cross,
                mainAxisSpacing: AppTokens.spaceLg,
                crossAxisSpacing: AppTokens.spaceSm,
                childAspectRatio: _gridAspectRatio(layout),
              ),
              itemCount: items.length,
              itemBuilder: (BuildContext ctx, int i) {
                final MediaItem item = items[i];
                final String heroTag = '${widget.heroPrefix}-${item.id}';
                return ContentCard(
                  coverUrl: item.coverUrl,
                  title: item.title,
                  source: widget.source,
                  subtitle: item.author,
                  onTap: () => widget.onItemTap(item, heroTag),
                  heroTag: heroTag,
                  width: itemW,
                );
              },
            );
          },
        );
      },
    );
  }

  /// 列表模式单行：封面（左）+ 标题/作者（右），跟随布局的圆角/标题/作者开关。
  Widget _buildListRow(MediaItem item, LayoutSettings layout) {
    final String heroTag = '${widget.heroPrefix}-${item.id}';
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => widget.onItemTap(item, heroTag),
      borderRadius: BorderRadius.circular(AppTokens.radiusMd),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AppCoverImage(
            coverUrl: item.coverUrl,
            source: widget.source,
            title: item.title,
            heroTag: heroTag,
            width: 64,
            height: 90,
            radius: layout.coverRadius,
          ),
          const SizedBox(width: AppTokens.spaceSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (layout.showTitle)
                  Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                if (item.author != null &&
                    item.author!.isNotEmpty &&
                    layout.showAuthor)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      item.author!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 网格卡片高宽比：随标题/作者开关微调（覆盖越多文字越长）。
  double _gridAspectRatio(LayoutSettings layout) {
    if (layout.showTitle) return 0.7;
    if (layout.showAuthor) return 0.78;
    return 0.62;
  }
}

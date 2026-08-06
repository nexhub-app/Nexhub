/// 统计页 —— 分模块展示阅读/观看时长（阶段 B++，仿 Animetail 风格）。
///
/// - 顶部三段 Tab（媒体 / 漫画 / 小说），切换各模块统计。
/// - AppBar 两个动作：搜索（过滤当前 Tab 的作品）、热力图（弹窗展示日级时长）。
/// - 主体三段卡（**Animetail 风格**：段标题加粗左对齐 + 卡片加大圆角 +
///   每项 大数字 + 下方图标 + 小标签）：
///   - **总览**：总时长 / 作品数 / 会话次数。
///   - **活跃**：近 7 天活跃 / 近 30 天活跃 / 活跃天数。
///   - **节奏**：平均会话时长 / 最长单日 / 当前连续。
/// - 作品列表：每行 名称 + 最后阅读时间 + 总时长；长按可清除该作品统计。
///
/// 数据全部来自 [StatsRepository.instance]（ChangeNotifier 单例），
/// 通过 [ListenableBuilder] 自动刷新 —— 阅读器 commit 后本页即时更新。
library;

import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';

import '../../../core/stats/stats_models.dart';
import '../../../core/stats/stats_repository.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_animations.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_cover_image.dart';
import '../../../core/widgets/app_list_tile.dart';
import '../../../core/widgets/app_segmented_tabs.dart';
import '../../../core/widgets/progress_card.dart' show formatRelativeTime;
import 'heatmap_sheet.dart';

/// 统计页（从设置主页「统计」入口进入）。
class StatsOverviewScreen extends StatefulWidget {
  const StatsOverviewScreen({super.key});

  @override
  State<StatsOverviewScreen> createState() => _StatsOverviewScreenState();
}

class _StatsOverviewScreenState extends State<StatsOverviewScreen> {
  StatsMediaType _type = StatsMediaType.novel;
  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  bool _searching = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// 当前 Tab 的作品列表（按最后阅读时间倒序）。
  List<WorkReadingStats> get _list {
    final all = StatsRepository.instance.statsBy(_type);
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return all;
    return all
        .where((s) =>
            (s.title?.toLowerCase().contains(q) ?? false) ||
            s.workId.toLowerCase().contains(q))
        .toList();
  }

  void _toggleSearch() {
    setState(() {
      _searching = !_searching;
      if (!_searching) {
        _searchController.clear();
        _query = '';
      }
    });
  }

  Future<void> _openHeatmap() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (ctx) => HeatmapSheet(initialType: _type),
    );
  }

  /// 把秒数格式化为「h 时 m 分 / m 分 s 秒 / s 秒」（l10n 键承载单位）。
  String _formatDuration(AppLocalizations l10n, int seconds) {
    if (seconds < 0) seconds = 0;
    if (seconds < 60) return l10n.statsDurSec(seconds);
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    if (h > 0) {
      if (m == 0) return l10n.statsDurHours(h);
      return l10n.statsDurHm(h, m);
    }
    return l10n.statsDurMs(m, s);
  }

  Future<void> _confirmClear(WorkReadingStats stat) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.statsClearTitle),
        content: Text(
          l10n.statsClearBody(stat.title ?? stat.workId),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.statsClearConfirm),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await StatsRepository.instance.removeWork(
        workId: stat.workId,
        sourceId: stat.sourceId,
        type: stat.type,
      );
    }
  }

  /// 通用分段卡：标题 + 3 个指标项（Animetail 风格）。
  Widget _buildSection({
    required String title,
    required List<({String value, String label, Color color, IconData icon})>
        items,
    required String entranceKey,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTokens.spaceLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTokens.spaceXs,
              0,
              AppTokens.spaceXs,
              AppTokens.spaceMd,
            ),
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ),
          Entrance(
            onceKey: entranceKey,
            child: AppCard(
              padding: const EdgeInsets.symmetric(
                vertical: AppTokens.spaceXl,
                horizontal: AppTokens.spaceLg,
              ),
              child: Row(
                children: <Widget>[
                  for (final it in items)
                    _StatMetric(
                      value: it.value,
                      label: it.label,
                      color: it.color,
                      icon: it.icon,
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 总览段：总时长 / 作品数 / 会话次数。
  Widget _buildOverviewSection(AppLocalizations l10n, List<WorkReadingStats> list) {
    final scheme = Theme.of(context).colorScheme;
    var totalSec = 0;
    var sessions = 0;
    for (final s in list) {
      totalSec += s.totalDurationSec;
      sessions += s.sessionCount;
    }
    return _buildSection(
      title: l10n.statsSectionOverview,
      entranceKey: 'stats_section_overview',
      items: <({String value, String label, Color color, IconData icon})>[
        (
          value: _formatDuration(l10n, totalSec),
          label: l10n.statsTotalDuration,
          color: scheme.primary,
          icon: Icons.timer_outlined,
        ),
        (
          value: '${list.length}',
          label: l10n.statsWorkCount,
          color: scheme.tertiary,
          icon: Icons.menu_book_outlined,
        ),
        (
          value: '$sessions',
          label: l10n.statsSessionCount,
          color: scheme.secondary,
          icon: Icons.repeat,
        ),
      ],
    );
  }

  /// 活跃段：近 7 天 / 近 30 天 / 活跃天数（当前模块下整个历史）。
  Widget _buildActivitySection(AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    final repo = StatsRepository.instance;
    final days7 = repo.recentActiveWorks(_type, const Duration(days: 7));
    final days30 = repo.recentActiveWorks(_type, const Duration(days: 30));
    // 活跃天数：扫描当前模块下所有有数据的「日」（从首条 lastReadAtMs 到今）。
    final all = repo.statsBy(_type);
    var activeDays = 0;
    if (all.isNotEmpty) {
      var minMs = all.first.lastReadAtMs;
      for (final s in all) {
        if (s.lastReadAtMs > 0 && s.lastReadAtMs < minMs) minMs = s.lastReadAtMs;
      }
      if (minMs > 0) {
        final start = DateTime.fromMillisecondsSinceEpoch(minMs);
        final now = DateTime.now();
        final dailys = repo.dailyForRange(start, now);
        for (final d in dailys) {
          final s = switch (_type) {
            StatsMediaType.media => d.mediaDurationSec,
            StatsMediaType.comic => d.comicDurationSec,
            StatsMediaType.novel => d.novelDurationSec,
          };
          if (s > 0) activeDays += 1;
        }
      }
    }
    return _buildSection(
      title: l10n.statsSectionActivity,
      entranceKey: 'stats_section_activity',
      items: <({String value, String label, Color color, IconData icon})>[
        (
          value: '$days7',
          label: l10n.stats7dActive,
          color: scheme.primary,
          icon: Icons.calendar_view_week,
        ),
        (
          value: '$days30',
          label: l10n.stats30dActive,
          color: scheme.tertiary,
          icon: Icons.calendar_month_outlined,
        ),
        (
          value: '$activeDays',
          label: l10n.statsActiveDays,
          color: scheme.secondary,
          icon: Icons.local_fire_department_outlined,
        ),
      ],
    );
  }

  /// 节奏段：平均会话 / 最长单日 / 当前连续。
  Widget _buildPaceSection(AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    final repo = StatsRepository.instance;
    final avg = repo.avgSessionDurationSec(_type);
    // 最长单日：扫描当前模块整年每日。
    final now = DateTime.now();
    var maxSec = 0;
    for (var m = 1; m <= 12; m++) {
      final monthStart = DateTime(now.year, m, 1);
      maxSec = [maxSec, repo.monthlyMaxDaily(monthStart, _type)].reduce(
        (a, b) => a > b ? a : b,
      );
    }
    final streak = repo.currentStreak(_type);
    return _buildSection(
      title: l10n.statsSectionPace,
      entranceKey: 'stats_section_pace',
      items: <({String value, String label, Color color, IconData icon})>[
        (
          value: _formatDuration(l10n, avg),
          label: l10n.statsAvgSession,
          color: scheme.primary,
          icon: Icons.av_timer_outlined,
        ),
        (
          value: _formatDuration(l10n, maxSec),
          label: l10n.statsMaxDaily,
          color: scheme.tertiary,
          icon: Icons.emoji_events_outlined,
        ),
        (
          value: '$streak',
          label: l10n.statsStreak,
          color: scheme.secondary,
          icon: Icons.whatshot_outlined,
        ),
      ],
    );
  }

  Widget _buildSearchField(AppLocalizations l10n) {
    return AnimatedSize(
      duration: AppTokens.durBase,
      curve: AppCurves.smooth,
      alignment: Alignment.topCenter,
      child: _searching
          ? Padding(
              padding: const EdgeInsets.fromLTRB(
                AppTokens.spaceLg,
                AppTokens.spaceXs,
                AppTokens.spaceLg,
                AppTokens.spaceXs,
              ),
              child: TextField(
                controller: _searchController,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: l10n.statsSearchHint,
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      _searchController.clear();
                      setState(() => _query = '');
                    },
                  ),
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius:
                        BorderRadius.circular(AppTokens.radiusFull),
                    borderSide: BorderSide(
                      color: Theme.of(context)
                          .colorScheme
                          .outlineVariant,
                    ),
                  ),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            )
          : const SizedBox(width: double.infinity),
    );
  }

  /// 单个作品行（封面 + 名称 + 最后阅读 + 总时长）。
  Widget _buildWorkTile(WorkReadingStats stat, AppLocalizations l10n, int index) {
    final name = stat.title?.isNotEmpty == true
        ? stat.title!
        : stat.workId;
    final readAt = stat.lastReadAtMs > 0
        ? DateTime.fromMillisecondsSinceEpoch(stat.lastReadAtMs)
        : null;
    return Entrance(
      onceKey: 'stats_item_${stat.boxKey}',
      index: index,
      child: AppListTile(
        leading: AppCoverImage(
          coverUrl: stat.coverUrl,
          title: name,
          width: 48,
          height: 64,
          radius: AppTokens.radiusSm,
        ),
        title: Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: readAt == null
            ? null
            : Text(
                '${l10n.statsLastRead} · '
                '${formatRelativeTime(l10n, readAt)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
        trailing: Text(
          _formatDuration(l10n, stat.totalDurationSec),
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
        ),
        onLongPress: () => _confirmClear(stat),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final list = _list;
    return AppShrinkTitleScaffold(
      title: Text(l10n.statsOverviewTitle),
      actions: <Widget>[
        IconButton(
          tooltip: l10n.statsSearchHint,
          icon: Icon(_searching ? Icons.close : Icons.search),
          onPressed: _toggleSearch,
        ),
        IconButton(
          tooltip: l10n.statsHeatmap,
          icon: const Icon(Icons.grid_view),
          onPressed: _openHeatmap,
        ),
      ],
      body: ListenableBuilder(
        listenable: StatsRepository.instance,
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppTokens.spaceLg,
                AppTokens.spaceSm,
                AppTokens.spaceLg,
                0,
              ),
              child: AppSegmentedTabs<StatsMediaType>(
                selected: <StatsMediaType>{_type},
                onSelectionChanged: (Set<StatsMediaType> s) {
                  if (s.isEmpty) return;
                  setState(() => _type = s.first);
                },
                segments: <ButtonSegment<StatsMediaType>>[
                  ButtonSegment(
                    value: StatsMediaType.novel,
                    label: Text(l10n.navNovel),
                    icon: const Icon(Icons.menu_book),
                  ),
                  ButtonSegment(
                    value: StatsMediaType.media,
                    label: Text(l10n.navMedia),
                    icon: const Icon(Icons.movie),
                  ),
                  ButtonSegment(
                    value: StatsMediaType.comic,
                    label: Text(l10n.navComic),
                    icon: const Icon(Icons.auto_stories),
                  ),
                ],
              ),
            ),
            _buildSearchField(l10n),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  AppTokens.spaceLg,
                  AppTokens.spaceXs,
                  AppTokens.spaceLg,
                  AppTokens.spaceXl,
                ),
                children: <Widget>[
                  _buildOverviewSection(l10n, list),
                  _buildActivitySection(l10n),
                  _buildPaceSection(l10n),
                  if (list.isEmpty)
                    _EmptyState(l10n: l10n)
                  else
                    for (var i = 0; i < list.length; i++) ...<Widget>[
                      _buildWorkTile(list[i], l10n, i),
                      if (i < list.length - 1)
                        const SizedBox(height: AppTokens.spaceXs),
                    ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 三段式分段里的单个指标项：大数字 + 图标 + 标签 + 强调色（Animetail 风格）。
class _StatMetric extends StatelessWidget {
  final String value;
  final String label;
  final Color color;
  final IconData icon;

  const _StatMetric({
    required this.value,
    required this.label,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          AppValuePulse(
            trigger: value,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                value,
                maxLines: 1,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w800,
                    ),
              ),
            ),
          ),
          const SizedBox(height: AppTokens.spaceXs),
          Icon(icon, size: 20, color: color.withOpacity(0.85)),
          const SizedBox(height: AppTokens.spaceXs),
          Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

/// 空态：当前 Tab 无任何统计记录。
class _EmptyState extends StatelessWidget {
  final AppLocalizations l10n;

  const _EmptyState({required this.l10n});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = AppStatusColors.ok(scheme);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppTokens.spaceXl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.insights,
            size: 56,
            color: AppStatusColors.containerOf(accent),
          ),
          const SizedBox(height: AppTokens.spaceMd),
          Text(
            l10n.statsNoRecords,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }
}

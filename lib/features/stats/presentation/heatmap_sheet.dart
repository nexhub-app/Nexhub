/// 热力图弹窗（阶段 B+++）—— 仿 GitHub contribution 单月网格展示阅读/观看时长。
///
/// - 顶部：标题 + 月份切换（← →）+ 关闭。
/// - 4 卡汇总（当月）：活跃天数 / 本月合计 / 最长单日 / 当前连续。
/// - 类型小切换（全部 / 媒体 / 漫画 / 小说）。
/// - **单月大网格**：6 周 × 7 天，cell 自适应到 22-28px，横向居中，
///   每格足够大，便于一眼看清日期+颜色深浅。
/// - 底部图例（少 → 多）+ 本月合计。
///
/// 数据：`StatsRepository.instance.dailyForRange(月首, 月末)`，
/// 按 [scope] 取分桶（null = 全部）时长。调用方已传 `isScrollControlled: true`。
library;

import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';

import '../../../core/stats/stats_models.dart';
import '../../../core/stats/stats_repository.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_segmented_tabs.dart';

/// 热力图弹窗（作为 showModalBottomSheet 的 builder 使用）。
class HeatmapSheet extends StatefulWidget {
  /// 初始选中类型（来自统计页当前 Tab）。
  final StatsMediaType? initialType;

  const HeatmapSheet({super.key, this.initialType});

  @override
  State<HeatmapSheet> createState() => _HeatmapSheetState();
}

class _HeatmapSheetState extends State<HeatmapSheet> {
  /// null = 全部类型。
  StatsMediaType? _scope;
  late DateTime _month;

  @override
  void initState() {
    super.initState();
    _scope = widget.initialType;
    final now = DateTime.now();
    _month = DateTime(now.year, now.month, 1);
  }

  int get _daysInMonth => DateTime(_month.year, _month.month + 1, 0).day;

  /// 当月每天时长（秒），index = 日期-1。
  List<int> _dailySec() {
    final end = DateTime(_month.year, _month.month, _daysInMonth);
    final stats = StatsRepository.instance.dailyForRange(_month, end);
    return stats
        .map((d) => switch (_scope) {
              null => d.totalDurationSec,
              StatsMediaType.media => d.mediaDurationSec,
              StatsMediaType.comic => d.comicDurationSec,
              StatsMediaType.novel => d.novelDurationSec,
            })
        .toList();
  }

  int _monthTotal(List<int> secs) =>
      secs.fold(0, (sum, s) => sum + s);

  void _prevMonth() => setState(() {
        _month = DateTime(_month.year, _month.month - 1, 1);
      });

  void _nextMonth() {
    final now = DateTime.now();
    final next = DateTime(_month.year, _month.month + 1, 1);
    if (next.isAfter(DateTime(now.year, now.month, 1))) return;
    setState(() => _month = next);
  }

  Color _cellColor(ColorScheme scheme, int sec, int maxSec) {
    if (sec <= 0) {
      return scheme.surfaceContainerHighest.withValues(alpha: 0.55);
    }
    final t = maxSec > 0
        ? ((sec / maxSec).clamp(0.25, 1.0)).toDouble()
        : 0.35;
    return Color.alphaBlend(
      scheme.primary.withValues(alpha: 0.22 + 0.78 * t),
      scheme.surface,
    );
  }

  String _fmtDuration(AppLocalizations l10n, int seconds) {
    if (seconds < 60) return l10n.statsDurSec(seconds);
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    if (h > 0) return l10n.statsDurHm(h, m);
    return l10n.statsDurMs(m, s);
  }

  /// 顶部 4 卡汇总（当月）。
  Widget _buildSummary(AppLocalizations l10n, int total) {
    final repo = StatsRepository.instance;
    final activeDays = repo.monthlyActiveDays(_month, _scope);
    final maxSec = repo.monthlyMaxDaily(_month, _scope);
    final streak = repo.currentStreak(_scope);
    Widget item(String label, String value, Color color) {
      return Expanded(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                value,
                maxLines: 1,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w800,
                    ),
              ),
            ),
            const SizedBox(height: AppTokens.spaceXxs),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    final scheme = Theme.of(context).colorScheme;
    return AppCard(
      padding: const EdgeInsets.symmetric(
        vertical: AppTokens.spaceMd,
        horizontal: AppTokens.spaceSm,
      ),
      child: Row(
        children: <Widget>[
          item(l10n.heatmapActiveDays, '$activeDays', scheme.primary),
          item(l10n.statsHeatmapTotal, _fmtDuration(l10n, total), scheme.tertiary),
          item(l10n.heatmapMaxDaily, _fmtDuration(l10n, maxSec), scheme.secondary),
          item(l10n.heatmapStreak, '$streak', scheme.error),
        ],
      ),
    );
  }

  /// 日历格式网格：7 列（周一~周日）+ 格内日期数字，背景色深浅 = 时长。
  /// cell 用 LayoutBuilder 自适应到 38-52 宽 × 36-48 高，月外格子留空。
  Widget _buildGrid(AppLocalizations l10n, ColorScheme scheme) {
    final secs = _dailySec();
    final maxSec = _monthTotal(secs);
    final firstWeekday = DateTime(_month.year, _month.month, 1).weekday;
    final offset = firstWeekday - 1; // 1=Mon..7=Sun → 月首前面空 offset 格
    final days = _daysInMonth;
    final rows = ((offset + days) / 7).ceil();

    const double gap = 6;
    const double minW = 38;
    const double maxW = 52;
    const double minH = 36;
    const double maxH = 48;

    Widget dayCell(int day, double w, double h) {
      // 月外格子直接留空（不渲染数字，避免出现 -4/0/32-37 等伪日期）。
      if (day < 1 || day > days) {
        return SizedBox(width: w, height: h);
      }
      final sec = day >= 1 && day <= secs.length ? secs[day - 1] : 0;
      final date = DateTime(_month.year, _month.month, day);
      final tooltip = sec <= 0
          ? '${date.month}/${date.day}'
          : '${date.month}/${date.day} · '
              '${_fmtDuration(l10n, sec)}';
      final hasRecord = sec > 0;
      final bg = hasRecord
          ? _cellColor(scheme, sec, maxSec)
          : scheme.surfaceContainerHighest.withValues(alpha: 0.45);
      final fg = hasRecord
          ? Colors.white
          : scheme.onSurfaceVariant.withValues(alpha: 0.75);
      return Tooltip(
        message: tooltip,
        child: AnimatedContainer(
          duration: AppTokens.durBase,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(AppTokens.radiusSm),
          ),
          alignment: Alignment.center,
          child: Text(
            '$day',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: fg,
                  fontWeight: hasRecord ? FontWeight.w700 : FontWeight.w500,
                ),
          ),
        ),
      );
    }

    // 表头与格子共享同一组 wCell/hCell：用 LayoutBuilder 一次性算出，
    // 再用 SizedBox(width: totalW) 包住 Column 让 Center 能真正居中。
    return LayoutBuilder(
      builder: (context, constraints) {
        final rawW = (constraints.maxWidth - gap * 6) / 7;
        final wCell = rawW.clamp(minW, maxW).toDouble();
        final hCell = (wCell * 0.92).clamp(minH, maxH).toDouble();
        final totalW = wCell * 7 + gap * 6;
        return Center(
          child: SizedBox(
            width: totalW,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                // 表头：周一 ~ 周日。
                Row(
                  children: <Widget>[
                    for (var d = 0; d < 7; d++) ...<Widget>[
                      if (d > 0) const SizedBox(width: gap),
                      SizedBox(
                        width: wCell,
                        child: Text(
                          switch (d) {
                            0 => l10n.weekdayMon,
                            1 => l10n.weekdayTue,
                            2 => l10n.weekdayWed,
                            3 => l10n.weekdayThu,
                            4 => l10n.weekdayFri,
                            5 => l10n.weekdaySat,
                            _ => l10n.weekdaySun,
                          },
                          textAlign: TextAlign.center,
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                    fontWeight: FontWeight.w600,
                                  ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: AppTokens.spaceSm),
                for (var row = 0; row < rows; row++) ...<Widget>[
                  Row(
                    children: <Widget>[
                      for (var col = 0; col < 7; col++) ...<Widget>[
                        if (col > 0) const SizedBox(width: gap),
                        SizedBox(
                          width: wCell,
                          height: hCell,
                          child: dayCell(
                            row * 7 + col - offset + 1,
                            wCell,
                            hCell,
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (row < rows - 1) const SizedBox(height: gap),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final secs = _dailySec();
    final total = _monthTotal(secs);
    final now = DateTime.now();
    final isCurrentMonth =
        _month.year == now.year && _month.month == now.month;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.95,
        ),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTokens.spaceMd,
              AppTokens.spaceMd,
              AppTokens.spaceMd,
              AppTokens.spaceMd,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        l10n.statsHeatmap,
                        style: Theme.of(context).textTheme.titleLarge
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    IconButton(
                      tooltip: l10n.statsPrevMonth,
                      icon: const Icon(Icons.chevron_left),
                      onPressed: _prevMonth,
                    ),
                    Text(
                      l10n.statsHeatmapMonthYear(
                        '${_month.year}',
                        '${_month.month}',
                      ),
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    IconButton(
                      tooltip: l10n.statsNextMonth,
                      icon: const Icon(Icons.chevron_right),
                      onPressed: isCurrentMonth ? null : _nextMonth,
                    ),
                    const SizedBox(width: AppTokens.spaceXs),
                    IconButton(
                      tooltip: l10n.cancel,
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
                const SizedBox(height: AppTokens.spaceMd),
                _buildSummary(l10n, total),
                const SizedBox(height: AppTokens.spaceMd),
                AppSegmentedTabs<StatsMediaType?>(
                  selected: <StatsMediaType?>{_scope},
                  onSelectionChanged: (Set<StatsMediaType?> s) {
                    if (s.isEmpty) return;
                    setState(() => _scope = s.first);
                  },
                  segments: <ButtonSegment<StatsMediaType?>>[
                    ButtonSegment<StatsMediaType?>(
                      value: null,
                      label: Text(l10n.statsAll),
                    ),
                    ButtonSegment<StatsMediaType?>(
                      value: StatsMediaType.novel,
                      label: Text(l10n.navNovel),
                    ),
                    ButtonSegment<StatsMediaType?>(
                      value: StatsMediaType.media,
                      label: Text(l10n.navMedia),
                    ),
                    ButtonSegment<StatsMediaType?>(
                      value: StatsMediaType.comic,
                      label: Text(l10n.navComic),
                    ),
                  ],
                ),
                const SizedBox(height: AppTokens.spaceLg),
                _buildGrid(l10n, scheme),
                const SizedBox(height: AppTokens.spaceLg),
                // 图例：少 → 多
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Text(l10n.statsHeatmapLess,
                        style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(width: AppTokens.spaceXs),
                    for (final t in <double>[0.0, 0.3, 0.6, 1.0]) ...<Widget>[
                      Container(
                        width: 10,
                        height: 10,
                        margin: const EdgeInsets.symmetric(
                          horizontal: AppTokens.spaceXxs,
                        ),
                        decoration: BoxDecoration(
                          color: t <= 0
                              ? scheme.surfaceContainerHighest
                                  .withValues(alpha: 0.55)
                              : Color.alphaBlend(
                                  scheme.primary.withValues(alpha: 
                                      0.22 + 0.78 * t),
                                  scheme.surface,
                                ),
                          borderRadius:
                              BorderRadius.circular(AppTokens.radiusXs),
                        ),
                      ),
                    ],
                    const SizedBox(width: AppTokens.spaceXs),
                    Text(l10n.statsHeatmapMore,
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
                const SizedBox(height: AppTokens.spaceMd),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
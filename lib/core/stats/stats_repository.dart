/// 阅读/观看统计仓库。
///
/// 数据落点：
/// - 作品聚合：Hive `reading_stats_v1`
/// - 按天聚合：Hive `reading_daily_v1`
///
/// 写入路径只用 [recordSession] —— 上层（[ReadingSessionRecorder]）只暴露
/// 「开始 / 暂停 / 结束」语义，所有聚合写都在 commit 时一次性落两个 box。
///
/// 读取路径：
/// - [statsFor] 查询单作品（统计页列表 / 详情页）。
/// - [statsBy] 列表（按模块分组）。
/// - [dailyForRange] 给热力图消费，给定 [start]..[end] 区间返回有序列表。
library;

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import 'stats_box.dart';
import 'stats_models.dart';

/// 时长提交来源（用于调试/未来过滤非法数据）。
enum SessionSource { mediaPlayer, comicReader, novelReader, manual }

/// 单次提交所需的最少字段。`durationSec` 必须 > 0，否则仓库直接丢弃。
class SessionDelta {
  final String workId;
  final String? sourceId;
  final StatsMediaType type;

  /// 本次新增的时长（秒）。
  final int durationSec;

  /// commit 时刻的时间戳（毫秒）。
  final int committedAtMs;

  /// 最后阅读章节（可选，用于 UI 展示）。
  final String? lastChapterTitle;

  /// 作品标题（可选，快照；UI 缺失时回退 workId）。
  final String? title;

  /// 封面 URL（可选，快照）。
  final String? coverUrl;

  /// 来源。
  final SessionSource source;

  const SessionDelta({
    required this.workId,
    required this.sourceId,
    required this.type,
    required this.durationSec,
    required this.committedAtMs,
    this.lastChapterTitle,
    this.title,
    this.coverUrl,
    this.source = SessionSource.manual,
  });
}

class StatsRepository extends ChangeNotifier {
  StatsRepository._();
  static final StatsRepository instance = StatsRepository._();

  static const String _dailyBoxDateFormat = 'yyyy-MM-dd';

  Box<dynamic> _workBox() {
    if (!Hive.isBoxOpen(kReadingStatsBoxName)) {
      throw StateError(
        'reading_stats_v1 box 未打开：请确认 splash 已注册 kStorageBoxNames',
      );
    }
    return Hive.box<dynamic>(kReadingStatsBoxName);
  }

  Box<dynamic> _dailyBox() {
    if (!Hive.isBoxOpen(kReadingDailyBoxName)) {
      throw StateError(
        'reading_daily_v1 box 未打开：请确认 splash 已注册 kStorageBoxNames',
      );
    }
    return Hive.box<dynamic>(kReadingDailyBoxName);
  }

  WorkReadingStats? _readWork(String boxKey) {
    final raw = _workBox().get(boxKey);
    if (raw == null) return null;
    if (raw is WorkReadingStats) return raw;
    if (raw is Map) {
      try {
        return WorkReadingStats.fromJson(Map<String, dynamic>.from(raw));
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  Future<void> _writeWork(WorkReadingStats stats) async {
    await _workBox().put(stats.boxKey, stats.toJson());
  }

  DailyReadingStats _readDaily(String day) {
    final raw = _dailyBox().get(day);
    if (raw == null) return DailyReadingStats.empty(day);
    if (raw is DailyReadingStats) return raw;
    if (raw is Map) {
      try {
        return DailyReadingStats.fromJson(Map<String, dynamic>.from(raw));
      } catch (_) {}
    }
    return DailyReadingStats.empty(day);
  }

  Future<void> _writeDaily(DailyReadingStats stats) async {
    await _dailyBox().put(stats.day, stats.toJson());
  }

  /// 提交一次会话增量。`durationSec <= 0` 直接忽略（不算作会话）。
  Future<void> recordSession(SessionDelta delta) async {
    if (delta.durationSec <= 0) return;
    try {
      final boxKey =
          '${delta.type.storageKey}|${delta.sourceId ?? ''}|${delta.workId}';
      final existing = _readWork(boxKey);
      final base = existing ??
          WorkReadingStats.zero(
            workId: delta.workId,
            sourceId: delta.sourceId,
            type: delta.type,
          );
      final updated = base.copyWith(
        totalDurationSec: base.totalDurationSec + delta.durationSec,
        sessionCount: base.sessionCount + 1,
        lastReadAtMs: delta.committedAtMs,
        title: delta.title,
        coverUrl: delta.coverUrl,
        lastChapterTitle:
            delta.lastChapterTitle ?? base.lastChapterTitle,
      );
      await _writeWork(updated);

      final dayKey = DailyReadingStats.dayKeyFromTimestamp(
        delta.committedAtMs,
      );
      final today = _readDaily(dayKey);
      final byType = switch (delta.type) {
        StatsMediaType.media =>
          today.copyWith(mediaDurationSec: today.mediaDurationSec + delta.durationSec),
        StatsMediaType.comic =>
          today.copyWith(comicDurationSec: today.comicDurationSec + delta.durationSec),
        StatsMediaType.novel =>
          today.copyWith(novelDurationSec: today.novelDurationSec + delta.durationSec),
      };
      final nextDay = byType.copyWith(
        totalDurationSec: today.totalDurationSec + delta.durationSec,
        sessionCount: today.sessionCount + 1,
      );
      await _writeDaily(nextDay);
      notifyListeners();
    } on Object catch (_) {
      // 任意 box 未就绪或写入失败：best-effort，不抛。
    }
  }

  /// 单作品聚合（不存在时返回 null）。
  WorkReadingStats? statsFor({
    required String workId,
    required String? sourceId,
    required StatsMediaType type,
  }) {
    final boxKey = '${type.storageKey}|${sourceId ?? ''}|$workId';
    return _readWork(boxKey);
  }

  /// 按模块列出所有聚合。返回排序后的快照（按 lastReadAtMs 倒序）。
  List<WorkReadingStats> statsBy(StatsMediaType type) {
    final result = <WorkReadingStats>[];
    try {
      for (final raw in _workBox().values) {
        WorkReadingStats? stat;
        if (raw is Map) {
          try {
            stat = WorkReadingStats.fromJson(Map<String, dynamic>.from(raw));
          } catch (_) {
            continue;
          }
        }
        if (stat == null) continue;
        if (stat.type != type) continue;
        result.add(stat);
      }
    } on Object {
      return const <WorkReadingStats>[];
    }
    result.sort((a, b) => b.lastReadAtMs.compareTo(a.lastReadAtMs));
    return result;
  }

  /// 全模块总时长（秒）。
  int totalDurationSec() {
    var sum = 0;
    for (final t in StatsMediaType.values) {
      sum += totalDurationSecByType(t);
    }
    return sum;
  }

  int totalDurationSecByType(StatsMediaType type) {
    var sum = 0;
    for (final s in statsBy(type)) {
      sum += s.totalDurationSec;
    }
    return sum;
  }

  /// 给定 [start] 到 [end]（含当天）的有序日聚合，长度 = end-start+1。
  ///
  /// 缺失日补 0。热力图直接消费，长度稳定方便做网格渲染。
  List<DailyReadingStats> dailyForRange(DateTime start, DateTime end) {
    final result = <DailyReadingStats>[];
    final s = DateTime(start.year, start.month, start.day);
    final e = DateTime(end.year, end.month, end.day);
    if (e.isBefore(s)) return const <DailyReadingStats>[];
    var cursor = s;
    while (!cursor.isAfter(e)) {
      final key = DailyReadingStats.dayKeyFromTimestamp(
        cursor.millisecondsSinceEpoch,
      );
      result.add(_readDaily(key));
      cursor = cursor.add(const Duration(days: 1));
    }
    return result;
  }

  /// 当前连续活跃天数（从今天/昨天往回数，直到出现 0 天为止）。
  /// [type] 为 null 表示全模块合计。
  int currentStreak(StatsMediaType? type) {
    final now = DateTime.now();
    var streak = 0;
    // 起点 = 今天；若今天尚未活动则从昨天开始（避免一打开就掉连击）。
    var cursor = DateTime(now.year, now.month, now.day);
    while (true) {
      final day = _readDaily(DailyReadingStats.dayKeyFromTimestamp(
        cursor.millisecondsSinceEpoch,
      ));
      final secs = _durationOf(day, type);
      if (secs > 0) {
        streak += 1;
        cursor = cursor.subtract(const Duration(days: 1));
      } else {
        // 仅在「cursor == 今天」且今天为 0 时允许回退一天，再判 0 才停。
        if (streak == 0 && _isSameDay(cursor, now)) {
          cursor = cursor.subtract(const Duration(days: 1));
          continue;
        }
        break;
      }
      // 防御：最多回溯 365 天。
      if (streak > 365) break;
    }
    return streak;
  }

  /// 当月活跃天数（>0 秒的天数）。[type] 为 null 表示全模块合计。
  int monthlyActiveDays(DateTime month, StatsMediaType? type) {
    final start = DateTime(month.year, month.month, 1);
    final end = DateTime(month.year, month.month + 1, 0);
    final dailys = dailyForRange(start, end);
    var n = 0;
    for (final d in dailys) {
      if (_durationOf(d, type) > 0) n += 1;
    }
    return n;
  }

  /// 当月最长单日（秒）。[type] 为 null 表示全模块合计。
  int monthlyMaxDaily(DateTime month, StatsMediaType? type) {
    final start = DateTime(month.year, month.month, 1);
    final end = DateTime(month.year, month.month + 1, 0);
    var maxSec = 0;
    for (final d in dailyForRange(start, end)) {
      final s = _durationOf(d, type);
      if (s > maxSec) maxSec = s;
    }
    return maxSec;
  }

  /// 全年活跃天数（>0 秒的天数）。[type] 为 null 表示全模块合计。
  int yearlyActiveDays(int year, StatsMediaType? type) {
    final start = DateTime(year, 1, 1);
    final end = DateTime(year, 12, 31);
    var n = 0;
    for (final d in dailyForRange(start, end)) {
      if (_durationOf(d, type) > 0) n += 1;
    }
    return n;
  }

  /// 全年最长单日（秒）。
  int yearlyMaxDaily(int year, StatsMediaType? type) {
    final start = DateTime(year, 1, 1);
    final end = DateTime(year, 12, 31);
    var maxSec = 0;
    for (final d in dailyForRange(start, end)) {
      final s = _durationOf(d, type);
      if (s > maxSec) maxSec = s;
    }
    return maxSec;
  }

  /// 全年总时长（秒）。
  int yearlyTotal(int year, StatsMediaType? type) {
    final start = DateTime(year, 1, 1);
    final end = DateTime(year, 12, 31);
    var sum = 0;
    for (final d in dailyForRange(start, end)) {
      sum += _durationOf(d, type);
    }
    return sum;
  }

  /// 给定模块下「最近 [within] 时长内有过阅读」的作品数（按 lastReadAtMs）。
  int recentActiveWorks(StatsMediaType type, Duration within) {
    final cutoff =
        DateTime.now().subtract(within).millisecondsSinceEpoch;
    var n = 0;
    for (final s in statsBy(type)) {
      if (s.lastReadAtMs >= cutoff) n += 1;
    }
    return n;
  }

  /// 当前模块下「总时长 ÷ 会话次数」（秒/会话）。无会话时返回 0。
  int avgSessionDurationSec(StatsMediaType type) {
    var totalSec = 0;
    var totalSessions = 0;
    for (final s in statsBy(type)) {
      totalSec += s.totalDurationSec;
      totalSessions += s.sessionCount;
    }
    if (totalSessions == 0) return 0;
    return totalSec ~/ totalSessions;
  }

  static int _durationOf(DailyReadingStats d, StatsMediaType? type) {
    if (type == null) return d.totalDurationSec;
    switch (type) {
      case StatsMediaType.media:
        return d.mediaDurationSec;
      case StatsMediaType.comic:
        return d.comicDurationSec;
      case StatsMediaType.novel:
        return d.novelDurationSec;
    }
  }

  static bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// 清除单作品的统计。删除从 box 移除条目（不属于"天"聚合的整体清理，
  /// 因为历史天数据可能在多部作品之间重复累加，难以反算回退某一作品的
  /// 历史贡献）。要彻底清空某天的数据请用 [clearDaily]。
  Future<void> removeWork({
    required String workId,
    required String? sourceId,
    required StatsMediaType type,
  }) async {
    final boxKey = '${type.storageKey}|${sourceId ?? ''}|$workId';
    try {
      await _workBox().delete(boxKey);
      notifyListeners();
    } on Object {}
  }

  /// 清空某日所有时长的聚合（用户/调试使用）。
  Future<void> clearDaily(DateTime day) async {
    final key = DailyReadingStats.dayKeyFromTimestamp(
      day.millisecondsSinceEpoch,
    );
    try {
      await _dailyBox().delete(key);
      notifyListeners();
    } on Object {}
  }

  /// 测试/重置：清空两个 box 的全部数据。
  Future<void> clearAll() async {
    try {
      await _workBox().clear();
      await _dailyBox().clear();
      notifyListeners();
    } on Object {}
  }
}

/// 阅读/观看统计的数据模型。
///
/// - [WorkReadingStats] 单作品聚合（累计时长、最后阅读时间、最后章节、标题）。
/// - [DailyReadingStats] 单日聚合（热力图直接消费）。
/// - [ReadingSessionSnapshot] 进行中会话（短生命，存 SharedPreferences）。
///
/// 所有时间戳都是「毫秒自 epoch」，与全应用统一。
library;

/// 三模块分类。复用 [SourceType] 的语义，但保留独立枚举方便统计页直接
/// 按 Tab 切换（不需要全量 SourceType 转换）。
enum StatsMediaType {
  /// 影视 / 动漫
  media,

  /// 漫画
  comic,

  /// 小说
  novel;

  String get storageKey => name;

  static StatsMediaType? tryParse(String? s) {
    switch (s) {
      case 'media':
        return StatsMediaType.media;
      case 'comic':
        return StatsMediaType.comic;
      case 'novel':
        return StatsMediaType.novel;
      default:
        return null;
    }
  }
}

/// 单作品聚合。
class WorkReadingStats {
  final String workId;
  final String? sourceId;
  final StatsMediaType type;

  /// 作品标题（快照，来自进入阅读器时的 [widget.title]）。UI 缺失时回退 workId。
  final String? title;

  /// 累计阅读/观看时长（秒）。
  final int totalDurationSec;

  /// 已结束的会话次数（commit 计数）。
  final int sessionCount;

  /// 最后阅读时间戳（毫秒）。
  final int lastReadAtMs;

  /// 最后阅读的章节标题（快照，UI 展示）。
  final String? lastChapterTitle;

  /// 封面 URL（快照，来自进入阅读器时的 widget.coverUrl）。
  final String? coverUrl;

  const WorkReadingStats({
    required this.workId,
    required this.sourceId,
    required this.type,
    this.title,
    this.totalDurationSec = 0,
    this.sessionCount = 0,
    required this.lastReadAtMs,
    this.lastChapterTitle,
    this.coverUrl,
  });

  String get boxKey => '${type.storageKey}|${sourceId ?? ''}|$workId';

  /// 复制并选择性覆盖字段。
  WorkReadingStats copyWith({
    int? totalDurationSec,
    int? sessionCount,
    int? lastReadAtMs,
    String? lastChapterTitle,
    String? title,
    String? coverUrl,
  }) {
    return WorkReadingStats(
      workId: workId,
      sourceId: sourceId,
      type: type,
      title: title ?? this.title,
      totalDurationSec: totalDurationSec ?? this.totalDurationSec,
      sessionCount: sessionCount ?? this.sessionCount,
      lastReadAtMs: lastReadAtMs ?? this.lastReadAtMs,
      lastChapterTitle: lastChapterTitle ?? this.lastChapterTitle,
      coverUrl: coverUrl ?? this.coverUrl,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'workId': workId,
        'sourceId': sourceId,
        'type': type.storageKey,
        'title': title,
        'totalDurationSec': totalDurationSec,
        'sessionCount': sessionCount,
        'lastReadAtMs': lastReadAtMs,
        'lastChapterTitle': lastChapterTitle,
        'coverUrl': coverUrl,
      };

  factory WorkReadingStats.fromJson(Map<String, dynamic> json) {
    return WorkReadingStats(
      workId: (json['workId'] as String?) ?? '',
      sourceId: json['sourceId'] as String?,
      type: StatsMediaType.tryParse(json['type'] as String?) ??
          StatsMediaType.media,
      title: json['title'] as String?,
      totalDurationSec: (json['totalDurationSec'] as int?) ?? 0,
      sessionCount: (json['sessionCount'] as int?) ?? 0,
      lastReadAtMs: (json['lastReadAtMs'] as int?) ?? 0,
      lastChapterTitle: json['lastChapterTitle'] as String?,
      coverUrl: json['coverUrl'] as String?,
    );
  }

  static WorkReadingStats zero({
    required String workId,
    required String? sourceId,
    required StatsMediaType type,
    String? title,
    String? coverUrl,
    int? initialTimestamp,
  }) {
    return WorkReadingStats(
      workId: workId,
      sourceId: sourceId,
      type: type,
      title: title,
      coverUrl: coverUrl,
      lastReadAtMs: initialTimestamp ?? 0,
    );
  }
}

/// 单日聚合（热力图最小数据源）。
class DailyReadingStats {
  /// 形如 `YYYY-MM-DD`。
  final String day;

  /// 当日总时长（秒）。
  final int totalDurationSec;

  /// 按模块分桶（秒）。
  final int mediaDurationSec;
  final int comicDurationSec;
  final int novelDurationSec;

  /// 当日 commit 的会话次数。
  final int sessionCount;

  const DailyReadingStats({
    required this.day,
    this.totalDurationSec = 0,
    this.mediaDurationSec = 0,
    this.comicDurationSec = 0,
    this.novelDurationSec = 0,
    this.sessionCount = 0,
  });

  DateTime? get date {
    final parts = day.split('-');
    if (parts.length != 3) return null;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final d = int.tryParse(parts[2]);
    if (y == null || m == null || d == null) return null;
    return DateTime(y, m, d);
  }

  DailyReadingStats copyWith({
    int? totalDurationSec,
    int? mediaDurationSec,
    int? comicDurationSec,
    int? novelDurationSec,
    int? sessionCount,
  }) {
    return DailyReadingStats(
      day: day,
      totalDurationSec: totalDurationSec ?? this.totalDurationSec,
      mediaDurationSec: mediaDurationSec ?? this.mediaDurationSec,
      comicDurationSec: comicDurationSec ?? this.comicDurationSec,
      novelDurationSec: novelDurationSec ?? this.novelDurationSec,
      sessionCount: sessionCount ?? this.sessionCount,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'day': day,
        'totalDurationSec': totalDurationSec,
        'mediaDurationSec': mediaDurationSec,
        'comicDurationSec': comicDurationSec,
        'novelDurationSec': novelDurationSec,
        'sessionCount': sessionCount,
      };

  factory DailyReadingStats.fromJson(Map<String, dynamic> json) {
    return DailyReadingStats(
      day: (json['day'] as String?) ?? '',
      totalDurationSec: (json['totalDurationSec'] as int?) ?? 0,
      mediaDurationSec: (json['mediaDurationSec'] as int?) ?? 0,
      comicDurationSec: (json['comicDurationSec'] as int?) ?? 0,
      novelDurationSec: (json['novelDurationSec'] as int?) ?? 0,
      sessionCount: (json['sessionCount'] as int?) ?? 0,
    );
  }

  static DailyReadingStats empty(String day) => DailyReadingStats(day: day);

  static String dayKeyFromTimestamp(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return '$y-$m-$dd';
  }
}

/// 进行中会话快照（不持久化进 box，仅在内存 + SharedPreferences 落盘避免
/// 杀进程丢失；commit 后立即丢弃）。
class ReadingSessionSnapshot {
  final String workId;
  final String? sourceId;
  final StatsMediaType type;

  /// 作品标题（快照）。
  final String? title;

  /// 当前会话起始时间戳（毫秒）。
  final int startedAtMs;

  /// 已经累计的时长（秒），包含之前未提交的部分。
  final int accumulatedSec;

  /// 最近一次 tick 的时间戳（毫秒），用于断点续算。
  final int lastTickAtMs;

  /// 最后阅读的章节（快照）。
  final String? lastChapterTitle;

  /// 封面 URL（快照）。
  final String? coverUrl;

  const ReadingSessionSnapshot({
    required this.workId,
    required this.sourceId,
    required this.type,
    this.title,
    required this.startedAtMs,
    required this.accumulatedSec,
    required this.lastTickAtMs,
    this.lastChapterTitle,
    this.coverUrl,
  });

  String get prefsKey => '${type.storageKey}|${sourceId ?? ''}|$workId';

  /// 复制并选择性覆盖字段（[ReadingSessionRecorder.tick] 高频调用）。
  ReadingSessionSnapshot copyWith({
    int? accumulatedSec,
    int? lastTickAtMs,
    String? lastChapterTitle,
    String? title,
    String? coverUrl,
  }) {
    return ReadingSessionSnapshot(
      workId: workId,
      sourceId: sourceId,
      type: type,
      title: title ?? this.title,
      startedAtMs: startedAtMs,
      accumulatedSec: accumulatedSec ?? this.accumulatedSec,
      lastTickAtMs: lastTickAtMs ?? this.lastTickAtMs,
      lastChapterTitle: lastChapterTitle ?? this.lastChapterTitle,
      coverUrl: coverUrl ?? this.coverUrl,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'workId': workId,
        'sourceId': sourceId,
        'type': type.storageKey,
        'title': title,
        'startedAtMs': startedAtMs,
        'accumulatedSec': accumulatedSec,
        'lastTickAtMs': lastTickAtMs,
        'lastChapterTitle': lastChapterTitle,
        'coverUrl': coverUrl,
      };

  factory ReadingSessionSnapshot.fromJson(Map<String, dynamic> json) {
    return ReadingSessionSnapshot(
      workId: (json['workId'] as String?) ?? '',
      sourceId: json['sourceId'] as String?,
      type: StatsMediaType.tryParse(json['type'] as String?) ??
          StatsMediaType.media,
      title: json['title'] as String?,
      startedAtMs: (json['startedAtMs'] as int?) ?? 0,
      accumulatedSec: (json['accumulatedSec'] as int?) ?? 0,
      lastTickAtMs: (json['lastTickAtMs'] as int?) ?? 0,
      lastChapterTitle: json['lastChapterTitle'] as String?,
      coverUrl: json['coverUrl'] as String?,
    );
  }
}

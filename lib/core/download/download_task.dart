/// 下载任务模型与状态枚举（文档 §10.1）。
library;

import 'dart:convert';

import '../models/plugin_config.dart';

/// 下载状态机：pending → downloading → completed / failed / paused / cancelled。
enum DownloadStatus {
  pending,
  downloading,
  completed,
  failed,
  paused,
  cancelled,
  waitingForWifi;

  static DownloadStatus fromString(String? raw) {
    return switch (raw) {
      'pending' => pending,
      'downloading' => downloading,
      'completed' => completed,
      'failed' => failed,
      'paused' => paused,
      'cancelled' => cancelled,
      'waitingForWifi' => waitingForWifi,
      _ => pending,
    };
  }

  String get label => switch (this) {
        pending => 'pending',
        downloading => 'downloading',
        completed => 'completed',
        failed => 'failed',
      paused => 'paused',
      cancelled => 'cancelled',
      waitingForWifi => 'waitingForWifi',
      };
}

/// 下载格式（漫画 CBZ / 散图文件夹 / 单页 JPG / 单页 PNG，小说 EPUB / TXT）。
enum DownloadFormat {
  cbz,
  folder,
  epub,
  txt,
  video,
  jpg,
  png;

  static DownloadFormat? fromString(String? raw) {
    return switch (raw) {
      'cbz' => cbz,
      'folder' => folder,
      'epub' => epub,
      'txt' => txt,
      'video' => video,
      'jpg' => jpg,
      'png' => png,
      _ => null,
    };
  }

  String get label => name;
}

/// 下载任务——记录一次离线缓存请求的完整元数据。
///
/// 按 spec §10.1：`coverUrl` 非 final（下载完成后可更新为本地路径）；
/// `localPath` 指向最终产物（.cbz / .epub / .txt / 视频文件 / 散图文件夹）。
class DownloadTask {
  final String id;
  final String title;
  final String? coverUrl;

  /// 源类型（comic / novel / media），决定使用哪个 handler。
  final SourceType sourceType;

  /// 源 ID（用于追溯解析器）。
  final String? sourceId;

  /// 内容 ID（MediaItem.id）。
  final String contentId;

  /// 下载格式。
  final DownloadFormat format;

  /// 章节范围（标题列表，用于显示和范围选择）。
  final List<String> chapterTitles;

  /// 总章节数。
  final int totalChapters;

  /// 已完成章节数。
  final int downloadedChapters;

  /// 当前状态。
  final DownloadStatus status;

  /// 错误信息（failed 时）。
  final String? error;

  /// 本地产物路径（completed 时有值）。
  ///
  /// - 视频：作品目录（`${workDir}`），内部 `NNN.mp4`/`.ts` 为每集文件；
  /// - 漫画 cbz：作品目录（`${workDir}`），内部 `NNN.cbz` 为每话归档；
  /// - 漫画 folder：作品目录（`${workDir}`），内部 `NNN/` 为每话图片子目录；
  /// - 小说：整本单文件 `title.epub`/`.txt`（沿用原 localPath 语义）。
  final String? localPath;

  /// 逐章/逐集文件绝对路径列表（与 [chapterTitles] 一一对应）。
  ///
  /// 供阅读器按"话/章/集"打开与切集，是「能在阅读器内翻话/切集」的关键数据。
  /// 旧数据（无此字段）从 [localPath] 推导（见 [DownloadManager] 恢复逻辑）。
  final List<String>? chapterFilePaths;

  /// 逐章/逐集的章节 id 列表（与 [chapterFilePaths] 平行对应）。
  ///
  /// 供阅读器把"本地文件"精确对应到"在线章节身份"——而不是按数组下标硬对应，
  /// 修正「本地/在线章节张冠李戴」类问题。旧数据（无此字段）为 null，
  /// 此时阅读器回退到 [chapterTitles] 甚至下标兜底，保证旧下载仍可看。
  final List<String>? chapterIds;

  /// 创建时间戳（毫秒）。
  final int createdAt;

  /// 完成时间戳（毫秒）。
  final int? completedAt;

  /// 封面本地路径（持久化后，coverUrl 可能为本地文件路径）。
  final String? localCoverPath;

  /// 封面合并键：同「源 + 内容」的作品共用同一张封面，避免重复下载。
  ///
  /// 取值规则见 [DownloadManager._computeCoverKey]，形如 `src1|content123`。
  /// 封面文件统一以 `${coverKey}.jpg` 落盘；同键后续批次下载时直接复用该文件，
  /// 不再重复拉取网络封面。null 表示旧数据（无此字段）或合并键无法计算。
  final String? coverKey;

  /// Whether this task has been archived (file kept on disk, hidden from main list).
  final bool archived;

  /// Archival timestamp (ms). null when not archived.
  final int? archivedAt;

  const DownloadTask({
    required this.id,
    required this.title,
    required this.sourceType,
    required this.contentId,
    required this.format,
    this.coverUrl,
    this.sourceId,
    this.chapterTitles = const <String>[],
    this.totalChapters = 0,
    this.downloadedChapters = 0,
    this.chapterProgress = 0.0,
    this.status = DownloadStatus.pending,
    this.error,
    this.localPath,
    this.chapterFilePaths,
    this.chapterIds,
    required this.createdAt,
    this.completedAt,
    this.localCoverPath,
    this.coverKey,
    this.archived = false,
    this.archivedAt,
  });

  /// 当前章节内部进度（0.0 ~ 1.0），用于单章节/单文件下载时显示更细粒度进度。
  final double chapterProgress;

  /// 进度（0.0 ~ 1.0），包含章节内细粒度进度。
  double get progress =>
      totalChapters > 0
          ? ((downloadedChapters + chapterProgress) / totalChapters)
              .clamp(0.0, 1.0)
          : 0.0;

  /// 是否已完成（用于已下载内容页过滤）。
  bool get isCompleted => status == DownloadStatus.completed;

  /// Whether the task has been archived (files kept on disk, restorable).
  bool get isArchived => archived;

  /// 是否为活跃任务（用于下载列表页过滤，排除 completed）。
  bool get isActive =>
      status == DownloadStatus.pending ||
      status == DownloadStatus.downloading ||
      status == DownloadStatus.paused ||
      status == DownloadStatus.waitingForWifi;

  DownloadTask copyWith({
    String? title,
    String? coverUrl,
    DownloadStatus? status,
    int? downloadedChapters,
    double? chapterProgress,
    int? totalChapters,
    String? error,
    String? localPath,
    List<String>? chapterFilePaths,
    List<String>? chapterIds,
    int? completedAt,
    String? localCoverPath,
    String? coverKey,
    List<String>? chapterTitles,
    bool? archived,
    int? archivedAt,
  }) =>
      DownloadTask(
        id: id,
        title: title ?? this.title,
        sourceType: sourceType,
        contentId: contentId,
        format: format,
        coverUrl: coverUrl ?? this.coverUrl,
        sourceId: sourceId,
        chapterTitles: chapterTitles ?? this.chapterTitles,
        totalChapters: totalChapters ?? this.totalChapters,
        downloadedChapters: downloadedChapters ?? this.downloadedChapters,
        chapterProgress: chapterProgress ?? this.chapterProgress,
        status: status ?? this.status,
        error: error ?? this.error,
        localPath: localPath ?? this.localPath,
        chapterFilePaths: chapterFilePaths ?? this.chapterFilePaths,
        chapterIds: chapterIds ?? this.chapterIds,
        createdAt: createdAt,
        completedAt: completedAt ?? this.completedAt,
        localCoverPath: localCoverPath ?? this.localCoverPath,
        coverKey: coverKey ?? this.coverKey,
        archived: archived ?? this.archived,
        archivedAt: archivedAt ?? this.archivedAt,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'title': title,
        'coverUrl': coverUrl,
        'sourceType': sourceType.apiName,
        'sourceId': sourceId,
        'contentId': contentId,
        'format': format.label,
        'chapterTitles': chapterTitles,
        'totalChapters': totalChapters,
        'downloadedChapters': downloadedChapters,
        'chapterProgress': chapterProgress,
        'status': status.label,
        'error': error,
        'localPath': localPath,
        'chapterFilePaths': chapterFilePaths,
        'chapterIds': chapterIds,
        'createdAt': createdAt,
        'completedAt': completedAt,
        'localCoverPath': localCoverPath,
        'coverKey': coverKey,
        'archived': archived,
        'archivedAt': archivedAt,
      };

  factory DownloadTask.fromJson(Map<String, dynamic> json) => DownloadTask(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        coverUrl: json['coverUrl'] as String?,
        sourceType: SourceType.parse(json['sourceType'] as String?) ??
            SourceType.animeSource,
        sourceId: json['sourceId'] as String?,
        contentId: json['contentId'] as String? ?? '',
        format: DownloadFormat.fromString(json['format'] as String?) ??
            DownloadFormat.video,
        chapterTitles: (json['chapterTitles'] as List<dynamic>?)
                ?.map((e) => e as String)
                .toList() ??
            const <String>[],
        totalChapters: json['totalChapters'] as int? ?? 0,
        downloadedChapters: json['downloadedChapters'] as int? ?? 0,
        chapterProgress: (json['chapterProgress'] as num?)?.toDouble() ?? 0.0,
        status: DownloadStatus.fromString(json['status'] as String?),
        error: json['error'] as String?,
        localPath: json['localPath'] as String?,
        chapterFilePaths: (json['chapterFilePaths'] as List<dynamic>?)
                ?.map((e) => e as String)
                .toList(),
        chapterIds: (json['chapterIds'] as List<dynamic>?)
                ?.map((e) => e as String)
                .toList(),
        createdAt: json['createdAt'] as int? ?? 0,
        completedAt: json['completedAt'] as int?,
        localCoverPath: json['localCoverPath'] as String?,
        coverKey: json['coverKey'] as String?,
        archived: json['archived'] as bool? ?? false,
        archivedAt: json['archivedAt'] as int?,
      );

  String toJsonString() => jsonEncode(toJson());

  static DownloadTask fromJsonString(String raw) =>
      DownloadTask.fromJson(jsonDecode(raw) as Map<String, dynamic>);
}

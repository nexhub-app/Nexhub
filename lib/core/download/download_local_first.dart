/// 在线阅读优先本地（本地优先）：小说 / 漫画已下载时优先读取本地内容。
///
/// - [findLocalDownload]：纯查询（无 context 依赖）——同一作品（contentId
///   精确匹配优先）或标题一致（兼容换源）且已完成、带 `localPath` 的下载任务；
/// - [openLocalFirstIfDownloaded]：命中则走 [openDownloadedWorkFolder] 的本地
///   阅读路径（小说逐章 txt / epub 聚合、漫画逐话目录 / cbz 归档）并返回 true，
///   否则返回 false 由调用方继续在线打开。
library;

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../local/local_content_actions.dart';
import '../local/local_content_manager.dart' show LocalMediaKind;
import '../models/plugin_config.dart' show SourceType;
import 'download_manager.dart';
import 'download_task.dart'
    show DownloadFormat, DownloadStatus, DownloadTask;

/// format → LocalMediaKind（与书架下载列表同映射）。
LocalMediaKind kindForFormat(DownloadFormat f) => switch (f) {
      DownloadFormat.cbz => LocalMediaKind.images,
      DownloadFormat.folder => LocalMediaKind.images,
      DownloadFormat.jpg => LocalMediaKind.images,
      DownloadFormat.png => LocalMediaKind.images,
      DownloadFormat.epub => LocalMediaKind.text,
      DownloadFormat.txt => LocalMediaKind.text,
      DownloadFormat.video => LocalMediaKind.video,
    };

/// 匹配规则：completed 任务中（a）contentId 与作品一致（优先），或（b）任务
/// 标题与作品标题一致（换源等场景的标题匹配兜底）。无命中返回 null。
DownloadTask? findLocalDownload(
  DownloadManager dm, {
  required SourceType sourceType,
  required String contentId,
  required String title,
}) {
  DownloadTask? byTitle;
  for (final t in dm.completedTasks) {
    if (t.status != DownloadStatus.completed) continue;
    final String? lp = t.localPath;
    if (lp == null || lp.isEmpty) continue;
    if (t.sourceType != sourceType) continue;
    if (t.contentId == contentId) return t; // 精确匹配优先。
    if (t.title == title && byTitle == null) byTitle = t;
  }
  return byTitle;
}

/// 命中本地下载则走本地阅读并返回 true；无匹配 / 打开失败返回 false。
Future<bool> openLocalFirstIfDownloaded(
  BuildContext context, {
  required SourceType sourceType,
  required String contentId,
  required String title,
  String? sourceId,
  int initialIndex = 0,
}) async {
  final DownloadManager? dm;
  try {
    dm = context.read<DownloadManager>();
  } on Object {
    return false;
  }
  if (dm == null) return false;
  final DownloadTask? matched = findLocalDownload(
    dm,
    sourceType: sourceType,
    contentId: contentId,
    title: title,
  );
  if (matched == null) return false;
  if (!context.mounted) return false;
  await openDownloadedWorkFolder(
    context,
    id: contentId,
    title: title,
    sourceId: sourceId ?? '',
    workDir: matched.localPath!,
    kind: kindForFormat(matched.format),
    initialIndex: initialIndex,
  );
  return true;
}
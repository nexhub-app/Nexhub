/// 下载处理器抽象（文档 §10.1）。
///
/// 每种源类型（漫画 / 小说 / 媒体）有自己的处理器，
/// 负责拉取内容、打包、写入本地文件，并报告进度。
library;

import 'download_task.dart';

/// 处理器进度回调。
typedef DownloadProgressCallback = void Function(
    int downloadedChapters, int totalChapters);

/// 取消检查回调：返回 true 表示用户已取消该下载任务。
///
/// 处理器应在每章/每集处理前调用，命中取消时抛出 [DownloadCancelledException]
/// 中止后续工作，使「下载进行中取消」真正停下网络与写盘（修复 132）。
typedef DownloadCancelledCheck = bool Function();

/// 用户取消下载时由处理器抛出，[DownloadManager] 捕获后清理半成品
/// 且不标记 completed / 不写 meta.json（避免取消后内容仍在写盘、
/// 重启后孤儿恢复再次出现）。
class DownloadCancelledException implements Exception {
  const DownloadCancelledException();

  @override
  String toString() => '下载已取消';
}

/// 下载结果：作品目录 + 逐章/逐集文件路径。
///
/// 引入"作品目录"概念（Mihon 风格：每部作品一个文件夹，内部每话/每集一个文件），
/// 取代原先"按任务 id 平铺/单文件"的落盘方式，使同部作品多批下载聚合进同一目录，
/// 且阅读器可凭 [chapterFilePaths] 按话/集打开与切换。
class DownloadResult {
  /// 作品目录（视频/漫画）或整本单文件（小说）。
  ///
  /// - 视频/漫画：目录路径；
  /// - 小说：整本 `.epub`/`.txt` 文件路径（沿用原 `localPath` 语义）。
  final String workPath;

  /// 逐章/逐集文件绝对路径（与章节标题一一对应）。
  ///
  /// 视频：`workPath/NNN.mp4` 或 `NNN.ts`；漫画 cbz：`workPath/NNN.cbz`、
  /// folder：`workPath/NNN/`；小说为整本单文件（即 [workPath]，列表仅含一个元素）。
  final List<String> chapterFilePaths;

  const DownloadResult({
    required this.workPath,
    required this.chapterFilePaths,
  });
}

/// 下载处理器接口。
abstract class DownloadHandler {
  /// 执行下载。
  ///
  /// [task] 任务元数据（其中 [DownloadTask.localPath] 在此约定为"作品目录"，
  /// 处理器负责在其下按章/集落盘）；[onProgress] 每完成一个章节/分片时调用；
  /// [isCancelled] 每次开始新章节/分片前检查，命中则抛出
  /// [DownloadCancelledException] 中止（供「下载进行中取消」使用）。
  /// 返回 [DownloadResult]。
  Future<DownloadResult> download(
    DownloadTask task, {
    DownloadProgressCallback? onProgress,
    DownloadCancelledCheck? isCancelled,
  });
}

/// 有界并发池：最多 [concurrency] 个任务并行执行，全部完成后返回。
///
/// 适用于以「单元（图片 / 章节）」为粒度的并行拉取——配合按索引写入，
/// 即可在并行执行下依然保持结果有序。
Future<void> runPool<T>(
  int concurrency,
  List<T> items,
  Future<void> Function(T) task,
) async {
  if (concurrency < 1) concurrency = 1;
  if (items.isEmpty) return;
  final queue = List<T>.from(items);
  Future<void> worker() async {
    while (queue.isNotEmpty) {
      final item = queue.removeLast();
      await task(item);
    }
  }

  final count = concurrency < items.length ? concurrency : items.length;
  final workers = <Future<void>>[for (var i = 0; i < count; i++) worker()];
  await Future.wait(workers);
}

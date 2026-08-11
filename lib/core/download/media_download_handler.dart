/// 媒体（视频）下载处理器（文档 §9 / §10.1）。
///
/// 按剧集拉取视频直链 → 下载字节 → 保存为按集命名的 .mp4 文件。
/// 仅支持直链视频（mp4/mkv 等），HLS(m3u8)/DASH(mpd) 流跳过该集。
library;

import 'dart:typed_data';

import '../models/episode.dart';
import '../models/plugin_config.dart';
import '../scraper/http_fetcher.dart';
import '../scraper/media_api_service.dart';
import '../utils/app_log.dart';
import 'download_file_system.dart';
import 'download_handler.dart';
import 'download_task.dart';

/// 媒体（视频）下载处理器。
class MediaDownloadHandler implements DownloadHandler {
  MediaDownloadHandler({
    required this.service,
    required this.fs,
    required this.source,
    required this.contentId,
    required this.chapters,
    this.concurrency = 1,
  });

  final MediaApiService service;
  final DownloadFileSystem fs;
  final PluginConfig source;
  final String contentId;
  final List<Episode> chapters;

  /// 章节并行拉取数（来自下载设置「线程数」），<=1 退化为顺序下载。
  final int concurrency;

  @override
  Future<String> download(
    DownloadTask task, {
    DownloadProgressCallback? onProgress,
  }) async {
    final taskDir = fs.join(fs.basePath, task.id);
    await fs.createDir(taskDir);

    var completed = 0;
    var written = 0;
    final idxList = [for (var i = 0; i < chapters.length; i++) i];
    await runPool(concurrency, idxList, (i) async {
      final ch = chapters[i];
      final video = await service.fetchVideoUrl(source, ch.url);

      // HLS / DASH 流无法作为单文件下载，跳过该集（不报错，继续下一集）。
      if (_isHlsOrDash(video.url, video.type)) {
        completed++;
        onProgress?.call(completed, chapters.length);
        return;
      }

      // 非直链视频无法直接下载，跳过该集。
      if (!_isDirectVideo(video.url, video.type)) {
        completed++;
        onProgress?.call(completed, chapters.length);
        return;
      }

      final bytes =
          await _fetchVideoBytes(video.url, extraHeaders: video.headers);
      if (bytes != null) {
        await fs.writeBytes(
          fs.join(taskDir, '${_pad(i + 1)}.mp4'),
          bytes,
        );
        written++;
      }
      completed++;
      onProgress?.call(completed, chapters.length);
    });

    // 一个直链都没写成 → 明确报错（覆盖「全部被跳过（HLS/流媒体）→ 假完成」与
    // 「全部拉取失败」两种情况），而不是静默产出空任务。
    if (written == 0) {
      AppLog.instance.e('[视频下载失败] ${task.title}: 0 个直链写入 '
          '(${chapters.length} 集，源可能为 HLS/流媒体)');
      throw Exception('本任务没有可下载的直链剧集（源为 HLS/流媒体或地址已失效）');
    }

    return taskDir;
  }

  Future<Uint8List?> _fetchVideoBytes(String url,
      {Map<String, String>? extraHeaders}) async {
    try {
      // 视频地址常带防盗链头（Episode.headers，如 Referer），源级头一并带上；
      // 不带头防盗链源会回 HTML 错误页 → 存成 .mp4 后播放失败（"打不开"）。
      final Map<String, String> merged = <String, String>{
        ...?source.fetchHeadersFor(url),
        ...?extraHeaders,
      };
      final bytes = await HttpFetcher.instance
          .getBytes(url, headers: merged.isEmpty ? null : merged,
              fetchDest: 'video');
      if (bytes.isEmpty || _looksLikeHtml(bytes)) return null;
      return Uint8List.fromList(bytes);
    } catch (_) {
      return null;
    }
  }

  /// 粗筛：跳过 HTML 错误页 / 纯文本响应（防被当视频存盘）。
  static bool _looksLikeHtml(List<int> b) {
    if (b.isEmpty) return true;
    var i = 0;
    while (i < b.length && (b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0D || b[i] == 0x0A)) {
      i++;
    }
    const htmlPrefixes = ['<!DOCTYPE', '<html', '<head', '<body'];
    if (i + 6 > b.length) return false;
    final head = String.fromCharCodes(b.sublist(i, i + 7)).toUpperCase();
    return htmlPrefixes.any((p) => head.startsWith(p.toUpperCase()));
  }

  /// 判断是否为直链视频（mp4/mkv/avi 等扩展名或 type=mp4）。
  bool _isDirectVideo(String url, String? type) {
    final lower = url.toLowerCase();
    const directExts = ['.mp4', '.mkv', '.avi', '.mov', '.webm', '.flv', '.ts'];
    if (directExts.any((e) => lower.contains(e))) return true;
    if (type == null) return true; // 无 type 默认尝试下载
    final t = type.toLowerCase();
    return t == 'mp4' || t == 'video' || t == 'direct';
  }

  /// 判断是否为 HLS(m3u8) / DASH(mpd) 流。
  bool _isHlsOrDash(String url, String? type) {
    final lower = url.toLowerCase();
    if (lower.contains('.m3u8') || lower.contains('.mpd')) return true;
    final t = type?.toLowerCase();
    return t == 'm3u8' || t == 'hls' || t == 'dash' || t == 'mpd';
  }

  static String _pad(int n, [int width = 3]) =>
      n.toString().padLeft(width, '0');
}

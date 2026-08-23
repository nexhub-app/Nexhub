/// 媒体（视频）下载处理器（文档 §9 / §10.1）。
///
/// 流程：先「嗅探/解析」拿到每集的真实下载地址（直链或 m3u8），再下载字节：
/// - 直链（mp4/mkv…）→ 直接写字节；
/// - HLS（m3u8）→ 下载全部分片并拼接成单个 .ts 文件。
///
/// 地址解析复用播放器同款能力（[VideoLinkSniffer]）：直连解析快路径 +
/// 无界面 WebView 嗅探/抽取兜底，覆盖「需要 WebView 才能拿到直链」的源
/// （如 MacCMS/jsExtractor 源）以及普通直链 / HLS 源。
library;

import 'dart:math' show max, min;
import 'dart:typed_data';

import '../models/episode.dart';
import '../models/plugin_config.dart';
import '../scraper/http_fetcher.dart';
import '../scraper/media_api_service.dart';
import '../utils/app_log.dart';
import 'download_file_system.dart';
import 'download_handler.dart';
import 'download_task.dart';
import 'video_link_sniffer.dart';

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
  Future<DownloadResult> download(
    DownloadTask task, {
    DownloadProgressCallback? onProgress,
    DownloadCancelledCheck? isCancelled,
  }) async {
    // 作品目录（由 DownloadManager 在 task.localPath 约定为该目录）。
    final taskDir = task.localPath!;
    await fs.createDir(taskDir);

    // 阶段一：逐集解析真实下载地址（后台静默嗅探 / 直连解析）。
    // 受并发上限约束（默认 1，最多 3），避免同时拉起过多无界面 WebView。
    //
    // 进度分段：嗅探占总进度前 10%、字节下载占后 90%。嗅探（原子解析 +
    // WebView 加载）没有真实进度信号 → 渐近估计填充区间，且与已解析完成的
    // 集数（真实下限）取 max，避免整个嗅探期（单集最长 25s）停在 0%。
    const sniffSpan = 0.1;
    const downloadSpan = 1.0 - sniffSpan;
    final resolved = List<SniffedVideoLink?>.filled(chapters.length, null);
    final sniffConcurrency = min(concurrency, 3).clamp(1, 3);
    final idxList = [for (var i = 0; i < chapters.length; i++) i];
    var resolvedFloor = 0.0;
    await estimateOpaqueProgress(
      () => runPool(sniffConcurrency, idxList, (i) async {
        _throwIfCancelled(isCancelled);
        try {
          resolved[i] = await VideoLinkSniffer.resolveEpisode(
            service,
            source,
            chapters[i].url,
            timeout: const Duration(seconds: 25),
          );
        } on Object catch (e) {
          AppLog.instance.w('[视频地址解析失败] ${task.title} 第${i + 1}集: $e');
          resolved[i] = null;
        }
      }, onItemDone: (completed, total) {
        resolvedFloor = completed / total;
      }),
      onValue: (v) => reportOverallProgress(onProgress,
          sniffSpan * max(v, resolvedFloor), chapters.length),
    );

    final resolvable = <int>[];
    for (var i = 0; i < chapters.length; i++) {
      if (resolved[i] != null) resolvable.add(i);
    }

    if (resolvable.isEmpty) {
      AppLog.instance.e('[视频下载失败] ${task.title}: 所有集均无法解析出可下载地址'
          '（源为 HLS/流媒体或地址已失效）');
      throw Exception('本任务没有可下载的直链剧集（源为 HLS/流媒体或地址已失效）');
    }

    // 阶段二：并行下载已解析的集（直链写字节；HLS 分段下载拼接）。
    // 每集进度映射进后 90% 区间：f = 0.1 + 0.9 * (k + fileProgress) / N，
    // k 为本集在 resolvable 中的序号——进度在阶段切换处单调接管，不回跳。
    var written = 0;
    // 逐集文件路径：下标对齐 chapters（缺则为空串，供上层跳过未下载集）。
    final List<String> chapterPaths =
        List<String>.filled(chapters.length, '');
    await runPool(concurrency, resolvable, (idx) async {
      _throwIfCancelled(isCancelled);
      // 集序号取「全局序号」：单集/分批下载时文件名与整本下载一致，
      // 避免第二批下载用本地 1..N 覆盖第一批文件（内容在管理器里对不上）。
      final int seq = chapters[idx].number ?? (idx + 1);
      final k = resolvable.indexOf(idx);
      void episodeReport(double fileProgress) => reportOverallProgress(
          onProgress,
          sniffSpan + downloadSpan * (k + fileProgress) / resolvable.length,
          chapters.length);
      final link = resolved[idx]!;
      var ok = false;
      String? path;
      if (link.isHls) {
        if (await _downloadHls(taskDir, seq, link,
            onProgress: episodeReport,
        )) {
          path = fs.join(taskDir, '${_pad(seq)}.ts');
          ok = true;
        }
      } else {
        // 直链视频：流式下载（支持进度回调），避免整块读入内存导致 OOM。
        if (await _downloadDirect(
            taskDir, seq, link.url, link.headers,
            onProgress: episodeReport,
        )) {
          path = fs.join(taskDir, '${_pad(seq)}.mp4');
          ok = true;
        }
      }
      // 主地址失败且有备用线路 → 逐条尝试。
      if (!ok && link.lines.isNotEmpty) {
        for (final VideoLine line in link.lines) {
          if (link.isHls) {
            if (await _downloadHls(
              taskDir,
              seq,
              SniffedVideoLink(url: line.url, headers: line.headers),
              onProgress: episodeReport,
            )) {
              path = fs.join(taskDir, '${_pad(seq)}.ts');
              ok = true;
            }
          } else {
            if (await _downloadDirect(
                taskDir, seq, line.url, line.headers,
                onProgress: episodeReport,
            )) {
              path = fs.join(taskDir, '${_pad(seq)}.mp4');
              ok = true;
            }
          }
          if (ok) break;
        }
      }
      if (ok && path != null) {
        chapterPaths[idx] = path;
        written++;
      }
    }, onItemDone: (completed, total) {
      reportOverallProgress(onProgress,
          sniffSpan + downloadSpan * completed / total, chapters.length);
    });

    // 一个直链都没写成 → 明确报错（覆盖「全部被跳过（HLS 拼接失败）→ 假完成」）。
    if (written == 0) {
      AppLog.instance.e('[视频下载失败] ${task.title}: 0 个直链写入 '
          '(${chapters.length} 集，源可能为 HLS/流媒体)');
      throw Exception('本任务没有可下载的直链剧集（源为 HLS/流媒体或地址已失效）');
    }

    return DownloadResult(workPath: taskDir, chapterFilePaths: chapterPaths);
  }

  /// 取消检查：命中用户取消时抛出 [DownloadCancelledException] 中止下载。
  /// 在每集解析/下载前调用，避免取消后仍在嗅探与写盘（修复 132）。
  void _throwIfCancelled(DownloadCancelledCheck? isCancelled) {
    if (isCancelled?.call() ?? false) {
      throw const DownloadCancelledException();
    }
  }

  /// HLS（m3u8）下载：下载播放列表 → 递归解析变体 → 拼接分片为单个 .ts。
  ///
  /// 返回 true 表示成功写出 `${idx+1}.ts`。加密分片（#EXT-X-KEY）暂不支持。
  /// 分片**边下载边写盘**（流式拼接），避免长视频整集在内存累积导致 OOM 卡退。
  Future<bool> _downloadHls(
    String taskDir,
    int idx,
    SniffedVideoLink link, {
    void Function(double progress)? onProgress,
  }) async {
    try {
      final bytes = await _getBytesRetry(link.url, link.headers,
          what: 'm3u8');
      if (bytes.isEmpty) return false;
      final text = String.fromCharCodes(bytes);
      if (!text.contains('#EXTM3U')) return false;
      final Stream<List<int>> out = _concatHlsStream(text, link,
          onProgress: onProgress);
      await fs.writeStream(
        fs.join(taskDir, '${_pad(idx + 1)}.ts'),
        out,
      );
      return true;
    } on Object catch (e) {
      AppLog.instance.w('[HLS 下载失败] ${link.url}: $e');
      // 清掉半截文件，避免「假完成」。
      try {
        final String path = fs.join(taskDir, '${_pad(idx + 1)}.ts');
        if (await fs.exists(path)) await fs.delete(path);
      } on Object {/* 忽略清理失败 */}
      return false;
    }
  }

  /// 解析 m3u8 文本并**流式产出**拼接后的分片字节（处理嵌套变体 / EXT-X-MAP）。
  Stream<List<int>> _concatHlsStream(
      String playlistText, SniffedVideoLink link, {
    void Function(double progress)? onProgress,
  }) async* {
    final lines =
        playlistText.split('\n').map((l) => l.trim()).toList();

    // 变体播放列表（master）：选第一条变体递归。
    final variantIdx = lines.indexWhere((l) => l.startsWith('#EXT-X-STREAM-INF'));
    if (variantIdx >= 0) {
      for (var k = variantIdx + 1; k < lines.length; k++) {
        final l = lines[k];
        if (l.isEmpty || l.startsWith('#')) continue;
        final variantUrl = _resolveSegmentUrl(link.url, l);
        final vbytes = await _getBytesRetry(variantUrl, link.headers,
            what: '变体 m3u8');
        if (vbytes.isEmpty) return;
        // 变体（master playlist）递归时透传进度回调：旧实现丢了它，
        // 自适应 HLS 全部分片下载期间没有任何进度上报。
        yield* _concatHlsStream(
            String.fromCharCodes(vbytes),
            SniffedVideoLink(url: variantUrl, headers: link.headers),
            onProgress: onProgress);
      }
      return;
    }

    // 媒体播放列表：收集分片（含初始化段）。
    String? mapUrl;
    final segments = <String>[];
    for (final l in lines) {
      if (l.startsWith('#EXT-X-KEY')) {
        // 加密分片暂不支持（需密钥解密，无法简单拼接）。
        return;
      }
      if (l.startsWith('#EXT-X-MAP')) {
        final m = RegExp(r'URI="([^"]+)"').firstMatch(l);
        if (m != null) mapUrl = _resolveSegmentUrl(link.url, m.group(1)!);
        continue;
      }
      if (l.startsWith('#')) continue;
      segments.add(_resolveSegmentUrl(link.url, l));
    }
    if (segments.isEmpty) return;

    // 初始化段（EXT-X-MAP）为可选；失败则跳过，不阻断。
    if (mapUrl != null) {
      final mapBytes = await _getSegmentTolerant(mapUrl, link.headers);
      if (mapBytes != null) yield mapBytes;
    }

    // 并行下载分片（受并发上限），按序产出拼接。
    // 单分片偶发超时/失败不阻断整集：重试几次，仍失败则跳过（带空档拼接，视频仍可播）。
    final segBytes = List<Uint8List?>.filled(segments.length, null);
    var failed = 0;
    final int totalSegs = segments.length;
    await runPool(8, [for (var k = 0; k < segments.length; k++) k], (k) async {
      final b = await _getSegmentTolerant(segments[k], link.headers);
      if (b == null) {
        failed++;
        AppLog.instance.w('[HLS 分片失败] 跳过: ${segments[k]}');
      } else {
        segBytes[k] = b;
      }
    }, onItemDone: (completed, _) {
      onProgress?.call(completed / totalSegs);
    });
    if (failed >= segments.length) {
      AppLog.instance.e('[HLS 全部分片失败] ${link.url} ($failed/${segments.length})');
      return;
    }
    if (failed > 0) {
      AppLog.instance.w('[HLS 分片缺失] $failed/${segments.length} 个分片下载失败，'
          '已跳过，其余拼接后仍可播放');
    }
    for (final b in segBytes) {
      if (b != null) yield b;
    }
  }

  /// 带重试地下载字节（应对 HLS CDN 偶发超时 / 网络抖动）。
  ///
  /// [what] 仅用于日志定位。最终仍失败则抛出，由调用方决定降级或中止。
  Future<Uint8List> _getBytesRetry(
    String url,
    Map<String, String>? headers, {
    String what = '分片',
    int retries = 3,
  }) async {
    Object? lastErr;
    for (var attempt = 0; attempt < retries; attempt++) {
      try {
        final b = await HttpFetcher.instance
            .getBytes(url, headers: headers, fetchDest: 'video');
        if (b.isNotEmpty) return Uint8List.fromList(b);
        lastErr = '空响应';
      } on Object catch (e) {
        lastErr = e;
      }
      if (attempt < retries - 1) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
    }
    throw Exception('$what 下载失败($retries 次重试): $url -> $lastErr');
  }

  /// 容错版分片下载：失败重试后仍不行返回 null（由调用方跳过该分片，不阻断整集）。
  Future<Uint8List?> _getSegmentTolerant(
    String url,
    Map<String, String>? headers,
  ) async {
    try {
      return await _getBytesRetry(url, headers, what: 'HLS 分片', retries: 3);
    } on Object catch (e) {
      AppLog.instance.w('[HLS 分片重试耗尽] $url: $e');
      return null;
    }
  }

  static String _resolveSegmentUrl(String playlistUrl, String seg) {
    final s = seg.trim();
    if (s.startsWith('http://') || s.startsWith('https://')) return s;
    final uri = Uri.tryParse(playlistUrl);
    if (uri == null) return s;
    return uri.resolve(s).toString();
  }

  /// 无 Content-Length 直链的假定单集体量（约 100MB）：仅用于渐近进度估计。
  static const int _assumedEpBytes = 100 * 1024 * 1024;

  /// 直链视频流式下载：逐块写盘（`<dir>/NNN.mp4`），内存占用恒定。
  ///
  /// 返回 true 表示成功写出；失败返回 false（由上层尝试备用线路）。
  /// 流式响应被 HTML 错误页污染时（防盗链拦截）仍会写入 → 写入前先读首块
  /// 判断是否 HTML，避免存成打不开的假视频。
  Future<bool> _downloadDirect(
    String taskDir,
    int idx,
    String url,
    Map<String, String>? extraHeaders, {
    void Function(double progress)? onProgress,
  }) async {
    try {
      final Map<String, String> merged = <String, String>{
        ...?source.fetchHeadersFor(url),
        ...?extraHeaders,
      };
      final String path = fs.join(taskDir, '${_pad(idx + 1)}.mp4');

      // 使用 getBytesStream 流式下载，通过 onHeaders 回调获取 Content-Length
      // 与 HttpFetcher 完全兼容，避免独立 HEAD/Dio.get 可能的不兼容问题
      int? totalBytes;
      var receivedBytes = 0;
      var firstChunk = true;
      await fs.writeStream(path, HttpFetcher.instance
          .getBytesStream(url,
              headers: merged.isEmpty ? null : merged,
              fetchDest: 'video',
              onHeaders: (headers) {
                final cl = headers['content-length']?.firstOrNull;
                if (cl != null) totalBytes = int.tryParse(cl);
                if (totalBytes == null) {
                  final cr = headers['content-range']?.firstOrNull;
                  if (cr != null) {
                    final match = RegExp(r'/(\d+)$').firstMatch(cr);
                    if (match != null) {
                      totalBytes = int.tryParse(match.group(1)!);
                    }
                  }
                }
              })
          .asyncMap((chunk) {
        if (firstChunk) {
          firstChunk = false;
          if (_looksLikeHtml(chunk)) {
            throw Exception('视频响应被防盗链拦截（HTML 错误页）');
          }
        }
        receivedBytes += chunk.length;
        if (totalBytes != null && totalBytes! > 0) {
          onProgress?.call((receivedBytes / totalBytes!).clamp(0.0, 1.0));
        } else {
          // 无 Content-Length（chunked 传输）算不出真实百分比：
          // 以「已收字节 / (已收字节 + 假定体量)」渐近估计，进度随字节
          // 持续增长且不会虚假封顶，下载停滞时进度也随之停止。
          onProgress?.call(receivedBytes / (receivedBytes + _assumedEpBytes));
        }
        return chunk;
      }));
      if (!await fs.exists(path)) return false;
      return true;
    } on Object catch (e) {
      AppLog.instance.w('[直链下载失败] $url: $e');
      try {
        final String path = fs.join(taskDir, '${_pad(idx + 1)}.mp4');
        if (await fs.exists(path)) await fs.delete(path);
      } on Object {}
      return false;
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

  static String _pad(int n, [int width = 3]) =>
      n.toString().padLeft(width, '0');
}

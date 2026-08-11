/// 漫画下载处理器（文档 §7.5 / §10.1）。
///
/// 按章节拉取图片 URL → 下载图片字节 → 打包 CBZ（或散图文件夹）。
library;

import 'dart:typed_data';

import '../models/episode.dart';
import '../models/plugin_config.dart';
import '../scraper/http_fetcher.dart';
import '../scraper/media_api_service.dart';
import '../utils/app_log.dart';
import 'cbz_builder.dart';
import 'download_file_system.dart';
import 'download_handler.dart';
import 'download_task.dart';

/// 漫画下载处理器。
class ComicDownloadHandler implements DownloadHandler {
  ComicDownloadHandler({
    required this.service,
    required this.fs,
    required this.source,
    required this.comicId,
    required this.chapters,
    this.format = DownloadFormat.cbz,
    this.concurrency = 1,
  });

  final MediaApiService service;
  final DownloadFileSystem fs;
  final PluginConfig source;
  final String comicId;
  final List<Episode> chapters;
  final DownloadFormat format;

  /// 章内图片并行下载数（来自下载设置「线程数」），<=1 退化为顺序下载。
  final int concurrency;

  @override
  Future<String> download(
    DownloadTask task, {
    DownloadProgressCallback? onProgress,
  }) async {
    final basePath = fs.join(fs.basePath, task.id);
    await fs.createDir(basePath);

    // 单页散图模式（folder / jpg / png）：每章一个子文件夹，章内图片按线程数并行下载。
    if (format == DownloadFormat.folder ||
        format == DownloadFormat.jpg ||
        format == DownloadFormat.png) {
      final ext = format == DownloadFormat.png ? 'png' : 'jpg';
      var writtenTotal = 0;
      for (var i = 0; i < chapters.length; i++) {
        final ch = chapters[i];
        final chDir = fs.join(basePath, _sanitize(ch.title, i));
        await fs.createDir(chDir);
        final images = await service.fetchImages(
          source,
          comicId: comicId,
          chapterId: ch.id,
        );
        final idxList = [for (var j = 0; j < images.length; j++) j];
        await runPool(concurrency, idxList, (j) async {
          final bytes = await _fetchImageBytes(images[j]);
          if (bytes != null) {
            await fs.writeBytes(
              fs.join(chDir, '${_pad(j + 1)}.$ext'),
              bytes,
            );
            writtenTotal++;
          }
        });
        onProgress?.call(i + 1, chapters.length);
      }
      // 一张都没写进 → 明确报错，避免"只有空文件夹"的假完成。
      if (writtenTotal == 0) {
        AppLog.instance.e('[漫画下载失败] ${task.title}: 0 张图写入');
        throw Exception('未能获取到任何图片，可能被源反盗链拦截或图片地址已失效');
      }
      return basePath;
    }

    // CBZ 模式：所有章节图片打包为单个 .cbz，章内图片按线程数并行下载。
    final allPages = <CbzPage>[];
    for (var i = 0; i < chapters.length; i++) {
      final ch = chapters[i];
      final images = await service.fetchImages(
        source,
        comicId: comicId,
        chapterId: ch.id,
      );
      final pageBytes = List<Uint8List?>.filled(images.length, null);
      final idxList = [for (var j = 0; j < images.length; j++) j];
      await runPool(concurrency, idxList, (j) async {
        pageBytes[j] = await _fetchImageBytes(images[j]);
      });
      for (var j = 0; j < pageBytes.length; j++) {
        final bytes = pageBytes[j];
        if (bytes != null) {
          allPages.add(CbzPage(
            filename: '${_pad(allPages.length + 1)}.jpg',
            bytes: bytes,
          ));
        }
      }
      onProgress?.call(i + 1, chapters.length);
    }

    final cbzBytes = CbzBuilder.build(pages: allPages);
    if (allPages.isEmpty) {
      AppLog.instance.e('[漫画下载失败] ${task.title}: 未获取到任何图片');
      throw Exception('未能获取到任何图片，可能被源反盗链拦截或图片地址已失效');
    }
    // 拦截图检测：真实漫画单页通常 ≥50KB；全部页平均 <20KB 基本可判定
    // 服务器统一返回了占位图/错误页（如 goda 曾出现的 ~5.8KB 拦截图）。
    // 直接抛到任务错误里展示（无需 logcat），首字节 hex 区分 HTML(3c21)/
    // WebP(5249)/JPEG(ffd8)。
    final int total =
        allPages.map((p) => p.bytes.length).fold(0, (a, b) => a + b);
    final double avg = total / allPages.length;
    if (avg < 20 * 1024) {
      final Uint8List first = allPages.first.bytes;
      final String head = first.length >= 4
          ? first.take(4).map((x) => x.toRadixString(16).padLeft(2, '0')).join()
          : 'short';
      AppLog.instance.e('[漫画下载失败] ${task.title}: 图片疑似被源拦截 '
          '(平均 ${(avg ~/ 1024)}KB/张, 首字节 0x$head)');
      throw Exception('图片疑似被源拦截（平均 ${(avg ~/ 1024)}KB/张，首字节 0x$head）。'
          '可能是防盗链/会话问题，请开启「高级设置-详细日志」重试并反馈该源。');
    }
    final cbzPath = fs.join(fs.basePath, '${task.id}.cbz');
    await fs.writeBytes(cbzPath, cbzBytes);

    // 清理临时目录
    await fs.delete(basePath);

    return cbzPath;
  }

  Future<Uint8List?> _fetchImageBytes(String url) async {
    try {
      // 必须带与在线取图一致的防盗链头（Referer/Cookie/UA），否则防盗链源
      // 回 HTML 错误页（200）→ 存成 .jpg 后解码失败 → "图片已损坏"。
      // Accept 显式去掉 image/avif：Flutter 内置解码器不支持 AVIF，声明了
      // avif 的协商 CDN 会返回 AVIF → 下载的图打不开（在线走缓存管理器无此头）。
      final Map<String, String> headers = <String, String>{
        ...?source.fetchHeadersFor(url),
        'Accept': 'image/jpeg,image/png,image/webp,image/gif,*/*;q=0.8',
      };
      final bytes =
          await HttpFetcher.instance.getBytes(url, headers: headers);
      if (bytes.isEmpty || _looksLikeHtml(bytes)) return null;
      return Uint8List.fromList(bytes);
    } catch (_) {
      return null;
    }
  }

  /// 仅拒绝 HTML/纯文本（防盗链错误页），其余二进制一律接受——
  /// 覆盖 JPEG/PNG/GIF/BMP/WebP/AVIF 等全部格式，避免把合法图片误判丢弃
  /// 导致「下载不到内容」。
  static bool _looksLikeHtml(List<int> b) {
    var i = 0;
    while (i < b.length &&
        (b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0D || b[i] == 0x0A)) {
      i++;
    }
    if (i >= b.length) return true;
    if (b[i] != 0x3C /* '<' */) return false;
    final int end = i + 8 < b.length ? i + 8 : b.length;
    final head = String.fromCharCodes(b.sublist(i, end)).toUpperCase();
    return head.startsWith('<!DOCTYPE') ||
        head.startsWith('<HTML') ||
        head.startsWith('<HEAD') ||
        head.startsWith('<BODY');
  }

  static String _sanitize(String s, int fallback) {
    final clean = s.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    return clean.isEmpty ? 'chapter_${fallback + 1}' : clean;
  }

  static String _pad(int n, [int width = 4]) =>
      n.toString().padLeft(width, '0');
}

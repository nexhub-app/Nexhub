/// 小说下载处理器（文档 §8.4 / §10.1）。
///
/// 按章节拉取正文段落与插图 → 逐章落盘为纯文本 TXT。目录组织参考通用离线
/// 阅读器：每部作品一个文件夹，内部每章一个 `NNNNN_章节标题.txt`（序号取自
/// 章节全局编号，保证跨批次顺序一致且不重名），插图存入同目录 `images/`
/// 子目录、以本地路径内联于正文。逐章独立文件从根源消除「分批下载同名覆盖、
/// 只能打开一章」的问题。EPUB 格式仍打包为整本单文件（legacy）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show md5;

import '../models/episode.dart';
import '../models/novel_block.dart';
import '../models/plugin_config.dart';
import '../local/local_novel_parser.dart' show kNexhubImgMarker;
import '../novel/novel_chinese_converter.dart';
import '../scraper/http_fetcher.dart';
import '../scraper/media_api_service.dart';
import '../utils/app_log.dart';
import 'download_file_system.dart';
import 'download_handler.dart';
import 'download_task.dart';
import 'epub_builder.dart';

/// 小说下载处理器。
class NovelDownloadHandler implements DownloadHandler {
  NovelDownloadHandler({
    required this.service,
    required this.fs,
    required this.source,
    required this.novelId,
    required this.chapters,
    this.format = DownloadFormat.epub,
    this.bookTitle = '',
    this.author,
    this.concurrency = 1,
    this.convertMode = ChineseConvertMode.none,
  });

  final MediaApiService service;
  final DownloadFileSystem fs;
  final PluginConfig source;
  final String novelId;
  final List<Episode> chapters;
  final DownloadFormat format;
  final String bookTitle;
  final String? author;

  /// 章节并行拉取数（来自下载设置「线程数」），<=1 退化为顺序下载。
  final int concurrency;

  /// 繁简转换模式：落盘前对文本块应用与阅读器一致的转换，
  /// 保证「阅读器内开繁→简后，离线缓存与显示相同」。默认不转换。
  final ChineseConvertMode convertMode;

  @override
  Future<DownloadResult> download(
    DownloadTask task, {
    DownloadProgressCallback? onProgress,
    DownloadCancelledCheck? isCancelled,
  }) async {
    final workDir = task.localPath!;
    await fs.createDir(workDir);
    final imagesDir = fs.join(workDir, 'images');
    await fs.createDir(imagesDir);

    // 并行拉取各章正文块（保留顺序），再逐章落盘（含插图下载）。
    final List<List<NovelBlock>?> fetched =
        List<List<NovelBlock>?>.filled(chapters.length, null);
    final idxList = [for (var i = 0; i < chapters.length; i++) i];
    await runPool(concurrency, idxList, (i) async {
      _throwIfCancelled(isCancelled);
      final ch = chapters[i];
      try {
        fetched[i] = await service.fetchNovelContent(
          source,
          novelId: novelId,
          chapterUrl: ch.url,
        );
      } on Object catch (e) {
        // 单章抓取失败不影响整体：置 null，后续跳过该章（写空文件会触发
        // SAF 空内容拒绝 → 整个下载失败）。与 media handler 逐集捕获一致。
        AppLog.instance.w('[小说章节抓取失败] ${task.title} 第${i + 1}章: $e');
        fetched[i] = null;
      }
    }, onItemDone: (completed, total) {
      // 获取阶段报告中间进度：downloadedChapters=0, chapterProgress=completed/total
      // 这样单个章节下载时也能看到 0%→50%→100% 的进度变化
      onProgress?.call(0, chapters.length, completed / total);
    });

    // 章节文件路径（下标对齐 chapters）
    // 与 media/comic handler 的语义一致，供阅读器跨批次聚合时正确对齐。
    final List<String> chapterFilePaths =
        List<String>.filled(chapters.length, '');
    var anyContent = false;
    for (var i = 0; i < chapters.length; i++) {
      _throwIfCancelled(isCancelled);
      final ch = chapters[i];
      final blocks = fetched[i] ?? const <NovelBlock>[];
      final seq = ch.number ?? (i + 1);
      final buffer = StringBuffer();
      for (var bIdx = 0; bIdx < blocks.length; bIdx++) {
        final b = blocks[bIdx];
        // 报告章节内处理进度（文本块/插图块处理）
        onProgress?.call(i, chapters.length, bIdx / blocks.length);
        if (b is NovelTextBlock) {
          if (b.text.trim().isNotEmpty) {
            buffer.writeln(convertChinese(b.text, convertMode));
            buffer.writeln();
          }
        } else if (b is NovelImageBlock) {
          // 插图内联：下载到本地 images/ 并写入占位行（绝对/SAF 路径），
          // 阅读器识别后走本地文件渲染（[SourceImage] 已支持本地路径）。
          if (b.isValid) {
            final local = await _downloadImage(b.url, imagesDir, source);
            if (local != null) {
              buffer.writeln('$kNexhubImgMarker$local');
              buffer.writeln();
            }
          }
        }
      }
      if (buffer.isEmpty) {
        // 该章内容为空（源抓取失败/被拦截）：跳过，不写空文件。SAF 文件系统
        // 会拒绝写入空内容（writeBytes 校验），直接写空文件会抛异常 → 整个
        // 下载失败 → 作品目录被清理（表现为"文件夹没有内容"）。
        onProgress?.call(i + 1, chapters.length, 0.0);
        continue;
      }
      anyContent = true;
      final fileName = '${_pad5(seq)}_${_sanitize(ch.title)}.txt';
      final filePath = fs.join(workDir, fileName);
      await fs.writeString(filePath, buffer.toString());
      chapterFilePaths[i] = filePath;
      onProgress?.call(i + 1, chapters.length, 0.0);
    }

    // 全部章节正文与插图都为空（源正文抓取失败/被反盗链拦截）→ 明确报错，
    // 否则产出的 TXT 只有空文件 → 打开报「本地文件读取失败」且无从排查。
    if (!anyContent) {
      AppLog.instance.e('[小说下载失败] ${task.title}: 未获取到任何章节内容 '
          '(${chapters.length} 章全部为空)');
      throw Exception(
          '未能获取到任何章节内容，可能被源拦截或章节地址已失效');
    }

    // EPUB 格式：保持整本单文件 legacy（逐章 TXT 为默认推荐格式）。
    if (format == DownloadFormat.epub) {
      final metadata = EpubMetadata(
        title: bookTitle.isNotEmpty ? bookTitle : task.title,
        author: author,
      );
      // 内嵌插图（B-04）：正文里的插图块下载后写入 EPUB 资源并在 XHTML 内
      // 引用，图文小说导出不再丢图。按 URL 去重（跨章同图只存一份字节），
      // 单张下载失败降级跳过（与 TXT 插图路径一致），不阻塞整本导出。
      final images = <String, EpubImage>{}; // url → 资源（名字 = 哈希+扩展名）
      Future<String?> imageRef(String url) async {
        final existing = images[url];
        if (existing != null) return existing.href;
        try {
          final Map<String, String> headers = <String, String>{
            ...?source.fetchHeadersFor(url),
            'Accept': 'image/jpeg,image/png,image/webp,image/gif,*/*;q=0.8',
          };
          final bytes =
              await HttpFetcher.instance.getBytes(url, headers: headers);
          if (bytes.isEmpty) return null;
          final href = 'Images/${_hash(url)}${_extFromUrl(url)}';
          images[url] =
              EpubImage(href: href, data: Uint8List.fromList(bytes));
          return href;
        } on Object {
          return null;
        }
      }

      final epubChapters = <EpubChapter>[];
      for (var i = 0; i < chapters.length; i++) {
        _throwIfCancelled(isCancelled);
        final parts = <String>[];
        for (final b in fetched[i] ?? const <NovelBlock>[]) {
          if (b is NovelTextBlock) {
            if (b.text.trim().isNotEmpty) {
              parts.add('<p>${_escape(convertChinese(b.text, convertMode))}</p>');
            }
          } else if (b is NovelImageBlock && b.isValid) {
            final ref = await imageRef(b.url);
            if (ref != null) {
              parts.add('<div><img src="$ref" alt=""/></div>');
            }
          }
        }
        epubChapters.add(EpubChapter(
          title: chapters[i].title,
          content: parts.join('\n'),
        ));
      }
      if (epubChapters.isEmpty ||
          epubChapters.every((c) => c.content.trim().isEmpty)) {
        throw Exception(
            '未能获取到任何章节内容，可能被源拦截或章节地址已失效');
      }
      final bytes = EpubBuilder.build(
        metadata: metadata,
        chapters: epubChapters,
        images: images.values.toList(growable: false),
      );
      final safeTitle =
          _sanitize(bookTitle.isNotEmpty ? bookTitle : task.title);
      final epubPath = fs.join(workDir, '$safeTitle.epub');
      await fs.writeBytes(epubPath, bytes);
      return DownloadResult(
          workPath: workDir, chapterFilePaths: <String>[epubPath]);
    }

    // TXT 逐章文件：chapterFilePaths 即本次逐章落盘的文件（供阅读器跨批次聚合）。
    // workPath 必须是**作品目录**（与 media/comic handler 一致）——`_executeDownload`
    // 会把 result.workPath 覆盖进 task.localPath，若这里返回文件路径会导致
    // localPath 变成 `.txt` 文件，后续在 `localPath` 下写 meta.json/cover.jpg
    // 时 SAF 报 "Parent document isn't a directory"。
    return DownloadResult(workPath: workDir, chapterFilePaths: chapterFilePaths);
  }

  String _pad5(int n) => n.toString().padLeft(5, '0');

  /// 取消检查：命中用户取消时抛出 [DownloadCancelledException] 中止下载。
  /// 在每章抓取/落盘前调用，避免取消后仍在拉取与写盘（修复 132）。
  void _throwIfCancelled(DownloadCancelledCheck? isCancelled) {
    if (isCancelled?.call() ?? false) {
      throw const DownloadCancelledException();
    }
  }

  String _sanitize(String s) {
    final clean = s
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), '_')
        .trim();
    return clean.isEmpty ? 'chapter' : clean;
  }

  String _escape(String s) =>
      s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

  /// 下载插图到 [imagesDir]，按 URL 哈希命名（跨章同图去重复用）。
  /// 返回本地绝对路径（或 Android SAF 编码路径）；失败返回 null（插图降级跳过）。
  Future<String?> _downloadImage(
    String url,
    String imagesDir,
    PluginConfig? source,
  ) async {
    try {
      final name = '${_hash(url)}${_extFromUrl(url)}';
      final path = fs.join(imagesDir, name);
      if (await fs.exists(path)) return path; // 已存在（同图复用）
      final Map<String, String> headers = <String, String>{
        ...?source?.fetchHeadersFor(url),
        'Accept': 'image/jpeg,image/png,image/webp,image/gif,*/*;q=0.8',
      };
      final bytes = await HttpFetcher.instance.getBytes(url, headers: headers);
      if (bytes.isEmpty) return null;
      await fs.writeBytes(path, Uint8List.fromList(bytes));
      return path;
    } on Object {
      return null;
    }
  }

  /// 从 URL 取图片扩展名（校验为常见图片格式，否则回退 .jpg）。
  String _extFromUrl(String url) {
    final idx = url.lastIndexOf('.');
    if (idx > 0 && idx < url.length - 1) {
      final e = url.substring(idx).toLowerCase().split('?').first;
      if (const <String>[
        '.jpg',
        '.jpeg',
        '.png',
        '.webp',
        '.gif',
        '.bmp'
      ].contains(e)) {
        return e;
      }
    }
    return '.jpg';
  }

  /// URL 的 MD5 十六进制（32 位），用作插图文件名，跨源/跨章唯一且稳定。
  String _hash(String s) {
    final d = md5.convert(utf8.encode(s)).bytes;
    final sb = StringBuffer();
    for (final b in d) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }
}

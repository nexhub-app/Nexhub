/// PDF 漫画支持：把 PDF 每一页渲染成图片，复用现有漫画看图管线。
///
/// PDF 不是「图片」，也不是「文本」，是独立的本地媒体类型；解析发生在应用内
/// （pdfx 用各平台原生 PDF 引擎），不写死任何站点，符合「源即插件」架构。
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart';

/// 把 PDF 每一页渲染成 JPEG 图片并存到临时目录，返回按页序的图片路径列表。
///
/// [maxWidth] 控制渲染宽度（默认 1240），过高会占用大量磁盘/内存；页数很多的
/// PDF 首次打开会稍慢（逐页渲染）。同一文件已渲染过则直接复用缓存，避免重复耗时。
Future<List<String>> extractPdfPages(String path, {int maxWidth = 1240}) async {
  final tmp = await getTemporaryDirectory();
  final cacheDir =
      Directory(p.join(tmp.path, 'nexhub_pdf', path.hashCode.toString()));

  // 已渲染过（同文件 hash）→ 直接复用，省去逐页渲染。
  if (await cacheDir.exists()) {
    final existing = cacheDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.jpg'))
        .map((f) => f.path)
        .toList()
      ..sort();
    if (existing.isNotEmpty) return existing;
  }
  await cacheDir.create(recursive: true);

  final document = await PdfDocument.openFile(path);
  final pages = <String>[];
  try {
    for (var i = 1; i <= document.pagesCount; i++) {
      final page = await document.getPage(i);
      try {
        final h = page.height > 0 && page.width > 0
            ? ((page.height * maxWidth) / page.width).round()
            : maxWidth;
        final pageImage = await page.render(
          width: maxWidth.toDouble(),
          height: h.toDouble(),
          format: PdfPageImageFormat.jpeg,
          backgroundColor: '#ffffff',
        );
        if (pageImage == null) continue;
        final bytes = pageImage.bytes;
        final file =
            File(p.join(cacheDir.path, '${i.toString().padLeft(4, '0')}.jpg'));
        await file.writeAsBytes(bytes);
        pages.add(file.path);
      } finally {
        await page.close();
      }
    }
  } finally {
    await document.close();
  }
  return pages;
}

/// 渲染 PDF 首页作为封面，返回图片路径；任何异常均返回 null（UI 回退占位图）。
Future<String?> extractPdfCover(String path) async {
  try {
    final tmp = await getTemporaryDirectory();
    final coverDir = Directory(p.join(tmp.path, 'nexhub_pdf_covers'));
    await coverDir.create(recursive: true);
    final document = await PdfDocument.openFile(path);
    try {
      if (document.pagesCount < 1) return null;
      final page = await document.getPage(1);
      try {
        final h = page.height > 0 && page.width > 0
            ? ((page.height * 800) / page.width).round()
            : 800;
        final pageImage = await page.render(
          width: 800,
          height: h.toDouble(),
          format: PdfPageImageFormat.jpeg,
          backgroundColor: '#ffffff',
        );
        if (pageImage == null) return null;
        final bytes = pageImage.bytes;
        final file = File(p.join(coverDir.path, '${path.hashCode}.jpg'));
        await file.writeAsBytes(bytes);
        return file.path;
      } finally {
        await page.close();
      }
    } finally {
      await document.close();
    }
  } catch (_) {
    return null;
  }
}

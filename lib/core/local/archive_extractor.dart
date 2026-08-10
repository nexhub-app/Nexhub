/// 多格式漫画归档解压（B 阶段扩展）。
///
/// 基于 [koni_archive]（纯 Dart，支持 ZIP/CBZ、TAR/CBT、7z/CB7、RAR/CBR 含 RAR5，
/// 无需原生库），把归档内图片抽取到临时目录供漫画阅读器逐页渲染。
/// 替换原 [archive] 包的 [ZipDecoder]（仅支持 zip 系），使 .cbr/.rar/.7z 等
/// 真正可用。按图片路径自然排序，保证页码顺序正确。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:koni_archive/io.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'local_content_manager.dart' show isImageFile;

/// 单张图片解压内存上限（50MB），防解压炸弹。漫画页通常远小于此。
const int _kMaxImageBytes = 50 << 20;

/// 解压 [path] 指向的漫画归档，返回按图片路径自然排序的临时图片文件路径列表。
///
/// 支持 ZIP/CBZ、TAR/CBT、7z/CB7、RAR/CBR 等；[path] 为 Android SAF URI
/// （`content://`）时无法用 dart:io 读取，由调用方先行拦截（见
/// [ComicReaderScreen._extractCbz]）。任何解压失败向上抛出，由阅读器转错误态。
Future<List<String>> extractArchiveImages(String path) async {
  final archive = await openArchiveFile(path);
  try {
    final entries = archive.files
        .where((e) => !e.isDirectory && isImageFile(e.path))
        .toList();
    entries.sort((a, b) => _naturalCompare(a.path, b.path));
    if (entries.isEmpty) return const <String>[];
    final tempDir = await getTemporaryDirectory();
    final out = <String>[];
    for (final entry in entries) {
      final bytes = await archive.readBytes(entry, maxSize: _kMaxImageBytes);
      final target = File(
        p.join(tempDir.path, '${entry.path.hashCode}_${p.basename(entry.path)}'),
      );
      await target.writeAsBytes(bytes);
      out.add(target.path);
    }
    return out;
  } finally {
    await archive.close();
  }
}

int _naturalCompare(String a, String b) {
  final ra = _splitNatural(a);
  final rb = _splitNatural(b);
  final n = ra.length < rb.length ? ra.length : rb.length;
  for (int i = 0; i < n; i++) {
    final ax = int.tryParse(ra[i]);
    final bx = int.tryParse(rb[i]);
    final int c;
    if (ax != null && bx != null) {
      c = ax.compareTo(bx);
    } else {
      c = ra[i].compareTo(rb[i]);
    }
    if (c != 0) return c;
  }
  return ra.length.compareTo(rb.length);
}

List<String> _splitNatural(String s) =>
    s.split(RegExp(r'(\d+|\D+)')).where((e) => e.isNotEmpty).toList();

/// 仅解压归档内自然排序第一张图片，返回临时文件路径（用于封面首图）。
///
/// 与 [extractArchiveImages] 共用排序逻辑，但只读一张，省去全量解压开销。
/// 归档不含图片时抛 [StateError]，由调用方（[_extractFirstImageFromArchive]）
/// 捕获转 null 回退占位。SAF URI（`content://`）由调用方先行拦截。
Future<String> extractFirstArchiveImage(String path) async {
  final archive = await openArchiveFile(path);
  try {
    final entry = archive.files
        .where((e) => !e.isDirectory && isImageFile(e.path))
        .toList()
      ..sort((a, b) => _naturalCompare(a.path, b.path));
    if (entry.isEmpty) throw StateError('archive contains no image: $path');
    final bytes = await archive.readBytes(entry.first, maxSize: _kMaxImageBytes);
    final tempDir = await getTemporaryDirectory();
    final target = File(
      p.join(tempDir.path, '${path.hashCode}_${p.basename(entry.first.path)}'),
    );
    await target.writeAsBytes(bytes);
    return target.path;
  } finally {
    await archive.close();
  }
}

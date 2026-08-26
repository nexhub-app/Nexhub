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

/// 归档解压结果（P3 资源回收）：除排序后的图片路径外，附带本次解压的
/// 独立临时目录，供阅读器退出时整目录删除（无需逐文件追踪）。
class ArchiveImagesExtraction {
  const ArchiveImagesExtraction({required this.dir, required this.files});

  /// 本次解压的临时根目录（`<tmp>/nexhub_arch/<归档名>_<hash>`）。
  final String dir;

  /// 按图片路径自然排序的临时图片文件路径列表。
  final List<String> files;
}

/// 解压 [path] 指向的漫画归档到独立子目录并返回追踪结果。
///
/// 与 [extractArchiveImages] 的差异仅在于输出位置：旧函数把图片平铺到系统
/// 临时目录根部、生命周期完全交给 OS；本函数按源归档隔离子目录，调用方
/// （漫画阅读器）记录 [ArchiveImagesExtraction.dir] 并在退出时递归删除，
/// 避免 CBZ/CBR/7z 解压产物长期滞留磁盘。排序与单张大小限制两者一致。
Future<ArchiveImagesExtraction> extractArchiveImagesToDir(String path) async {
  final archive = await openArchiveFile(path);
  try {
    final entries = archive.files
        .where((e) => !e.isDirectory && isImageFile(e.path))
        .toList();
    entries.sort((a, b) => _naturalCompare(a.path, b.path));
    if (entries.isEmpty) {
      throw StateError('archive contains no image: $path');
    }
    final tempDir = await getTemporaryDirectory();
    // 目录名带「源归档标识」：不同章节归档互不共享目录，重进同一归档时
    // 同名文件直接覆盖复用，不会跨归档污染。
    final outDir = Directory(p.join(
      tempDir.path,
      'nexhub_arch',
      '${p.basename(path)}_${path.hashCode}',
    ));
    await outDir.create(recursive: true);
    final out = <String>[];
    for (final entry in entries) {
      final bytes = await archive.readBytes(entry, maxSize: _kMaxImageBytes);
      // 文件名仍带条目路径 hash：同一归档内不同子目录可能存在同名图片。
      final target = File(p.join(
        outDir.path,
        '${entry.path.hashCode}_${p.basename(entry.path)}',
      ));
      await target.writeAsBytes(bytes);
      out.add(target.path);
    }
    return ArchiveImagesExtraction(dir: outDir.path, files: out);
  } finally {
    await archive.close();
  }
}
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
      // 临时文件名必须带上「源归档标识」：不同章节归档若内部图片名相同
      // （如都叫 001.jpg），否则会写出到同一临时路径互相覆盖；切话后
      // Image.file 以路径为缓存键复用旧解码图 → 表现为「切换话还是同一话」。
      final target = File(
        p.join(
          tempDir.path,
          '${p.basename(path)}_${path.hashCode}_'
          '${entry.path.hashCode}_${p.basename(entry.path)}',
        ),
      );
      await target.writeAsBytes(bytes);
      out.add(target.path);
    }
    return out;
  } finally {
    await archive.close();
  }
}

/// 常见小说归档扩展名（D9 压缩包批量导入：zip/cbz 系 + koni_archive
/// 支持的 tar/7z/rar 系）。小写比较。
const List<String> kNovelArchiveExtensions = <String>[
  '.zip', '.cbz', '.tar', '.7z', '.cb7', '.rar', '.cbr',
];

/// 路径是否为支持的归档文件（按扩展名，大小写不敏感）。
bool isNovelArchiveFile(String path) {
  final lower = path.toLowerCase();
  return kNovelArchiveExtensions.any(lower.endsWith);
}

bool _isNovelTextFile(String path) {
  final lower = path.toLowerCase();
  return lower.endsWith('.txt') || lower.endsWith('.epub');
}

/// 归档内单个小说文件的解压上限（256MB）：整本长篇 TXT/EPUB 远小于此，
/// 防解压炸弹。
const int _kMaxNovelFileBytes = 256 << 20;

/// 解压归档内的小说文件（.txt/.epub）到应用支持目录的持久化子目录，
/// 返回按归档内相对路径自然排序的文件路径列表（D9 压缩包批量导入）。
///
/// 与漫画图片解压不同：导入后这些文件**就是书库本体**（条目 path 直接指向
/// 它们），因此落盘在 `getApplicationSupportDirectory()/novel_imports/`
/// （持久目录）而非系统临时目录，不参与阅读器退出清理；目录名带源归档
/// 标识避免不同归档同名覆盖。无小说文件 / 超限 / IO 失败向上抛出。
Future<List<String>> extractNovelFilesFromArchive(String path) async {
  final archive = await openArchiveFile(path);
  try {
    final entries = archive.files
        .where((e) => !e.isDirectory && _isNovelTextFile(e.path))
        .toList()
      ..sort((a, b) => _naturalCompare(a.path, b.path));
    if (entries.isEmpty) {
      throw StateError('archive contains no novel file: $path');
    }
    final supportDir = await getApplicationSupportDirectory();
    final outDir = Directory(p.join(
      supportDir.path,
      'novel_imports',
      '${p.basename(path)}_${path.hashCode}',
    ));
    await outDir.create(recursive: true);
    final out = <String>[];
    for (final entry in entries) {
      final bytes =
          await archive.readBytes(entry, maxSize: _kMaxNovelFileBytes);
      // 条目路径 hash 防同归档不同子目录同名冲突（与图片解压同策略）。
      final target = File(p.join(
        outDir.path,
        '${entry.path.hashCode}_${p.basename(entry.path)}',
      ));
      await target.writeAsBytes(bytes);
      out.add(target.path);
    }
    return out;
  } finally {
    await archive.close();
  }
}

int _naturalCompare(String a, String b) {  final ra = _splitNatural(a);
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
    // 同步带源归档标识，避免不同归档首图同名覆盖（见 [extractArchiveImages]）。
    final target = File(
      p.join(
        tempDir.path,
        '${p.basename(path)}_${path.hashCode}_'
        'first_${p.basename(entry.first.path)}',
      ),
    );
    await target.writeAsBytes(bytes);
    return target.path;
  } finally {
    await archive.close();
  }
}

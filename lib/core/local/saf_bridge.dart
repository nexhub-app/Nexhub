/// Android 分区存储（SAF）桥接层。
///
/// 背景：file_picker 的 `getDirectoryPath` 在 Android 返回 `content://` tree URI，
/// dart:io 无法列举/读取。本层用 `saf` 包完成三件事：
///  1. 枚举选中的目录树（递归列举子文档，得到 content:// URI 列表）；
///  2. 把 content:// URI 解析为应用私有缓存里的真实文件路径（记忆化），从而复用
///     B 阶段全部读取管线（koni_archive 解压、File/epub 解析等）零改动；
///  3. 计算 SAF 条目的封面（首图 / PDF 首页）。
///
/// 仅 Android 调用其方法；非 Android 不会 import 触发平台调用。
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:saf/saf.dart';

import 'local_content_manager.dart'
    show
        LocalMediaKind,
        classifyByPath,
        isAndroidSafUri,
        naturalCompare,
        isComicArchive,
        registerSafCoverResolver;
import 'archive_extractor.dart' show extractFirstArchiveImage;
import '../local/pdf_util.dart' show extractPdfCover;

/// 单例 SAF 桥接。
final Saf saf = Saf();

bool _registered = false;
void _ensureRegistered() {
  if (_registered) return;
  registerSafCoverResolver(_computeLocalCoverSaf);
  _registered = true;
}

/// content:// SAF URI → 应用私有缓存里的真实文件路径（记忆化）。
///
/// SAF 文档无法用 dart:io 直接读取，需先落到缓存目录再交给 koni_archive / File /
/// epub 解析等既有代码（B 阶段读取管线零改动）。非 SAF 路径原样返回。
final Map<String, String> _resolvedCache = <String, String>{};

Future<String> resolveSafUri(String uriOrPath) async {
  _ensureRegistered();
  if (!isAndroidSafUri(uriOrPath)) return uriOrPath;
  final cached = _resolvedCache[uriOrPath];
  if (cached != null && File(cached).existsSync()) return cached;
  final dir = await getTemporaryDirectory();
  final target = File(p.join(dir.path, 'saf_${uriOrPath.hashCode}${_safExt(uriOrPath)}'));
  if (await target.exists()) {
    _resolvedCache[uriOrPath] = target.path;
    return target.path;
  }
  await saf.copyToLocalFile(uriOrPath, target.path);
  _resolvedCache[uriOrPath] = target.path;
  return target.path;
}

/// 从 content:// URI 末尾尽量还原扩展名（缓存文件需保留扩展名供格式识别）。
String _safExt(String uri) {
  final last = Uri.decodeComponent(uri.split('/').last);
  final dot = last.lastIndexOf('.');
  if (dot > 0 && dot < last.length - 1) {
    final ext = last.substring(dot).toLowerCase();
    if (RegExp(r'^\.[a-z0-9]{1,5}$').hasMatch(ext)) return ext;
  }
  return '';
}

/// 递归列举 SAF 目录树下的所有后代文档（深度优先）。
Future<List<SafDocumentFile>> _walkSaf(String treeUri) async {
  final out = <SafDocumentFile>[];
  final children = await saf.list(treeUri);
  for (final c in children) {
    if (c.isDir) {
      out.addAll(await _walkSaf(c.uri));
    } else {
      out.add(c);
    }
  }
  return out;
}

/// 扫描 SAF 漫画文件夹：区分「散图」与「漫画归档（含 PDF）」，分别自然排序返回
/// content:// URI 列表（镜像 [scanComicFolder]）。
Future<({List<String> rawImages, List<String> archives})> scanComicFolderSaf(
    String treeUri) async {
  final docs = await _walkSaf(treeUri);
  final raw = <SafDocumentFile>[];
  final arch = <SafDocumentFile>[];
  for (final d in docs) {
    final lower = d.name.toLowerCase();
    final ext = p.extension(lower);
    if (<String>['.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp']
        .contains(ext)) {
      raw.add(d);
    } else if (isComicArchive(lower) || lower.endsWith('.pdf')) {
      arch.add(d);
    }
  }
  raw.sort((a, b) => naturalCompare(a.name, b.name));
  arch.sort((a, b) => naturalCompare(a.name, b.name));
  return (
    rawImages: raw.map((d) => d.uri).toList(),
    archives: arch.map((d) => d.uri).toList(),
  );
}

/// 收集 SAF 文件夹中指定媒体类型的文件 content:// URI，自然排序
/// （镜像 [listFolderFilesByKind]）。
Future<List<String>> listFolderFilesByKindSaf(
    String treeUri, LocalMediaKind kind) async {
  final docs = await _walkSaf(treeUri);
  final files = docs
      .where((d) => classifyByPath(d.name) == kind)
      .map((d) => d.uri)
      .toList();
  files.sort((a, b) {
    final na = _walkName(a);
    final nb = _walkName(b);
    return naturalCompare(na, nb);
  });
  return files;
}

String _walkName(String uri) =>
    Uri.decodeComponent(uri.split('/').last);

/// 按 SAF 文件夹内真实文件的多数扩展名决定媒体类型（镜像 [classifyFolderByContent]）。
Future<LocalMediaKind?> classifyFolderByContentSaf(String treeUri) async {
  final docs = await _walkSaf(treeUri);
  final counts = <LocalMediaKind, int>{};
  for (final d in docs) {
    final k = classifyByPath(d.name);
    if (k == null) continue;
    counts[k] = (counts[k] ?? 0) + 1;
  }
  if (counts.isEmpty) return null;
  final sorted = counts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return sorted.first.key;
}

/// SAF 目录展示名：优先取系统文档名，失败回退「手机文件夹」。
Future<String> safFolderName(String treeUri) async {
  try {
    final doc = await saf.stat(treeUri);
    if (doc != null && doc.name.isNotEmpty) return doc.name;
  } on Object catch (_) {
    // 忽略，走回退名
  }
  return '手机文件夹';
}

/// 从 content:// URI 或真实路径提取展示文件名（去掉 SAF 文档 id 前缀）。
/// 对真实文件路径同样返回正确文件名，可统一替换 [p.basename]。
String safBaseName(String uriOrPath) {
  final decoded = Uri.decodeComponent(uriOrPath.split('/').last);
  final parts = decoded.split(RegExp(r'[:/]')).where((s) => s.isNotEmpty);
  return parts.isEmpty ? '文件' : parts.last;
}

/// SAF 条目封面：取首图 / PDF 首页并落盘（注入到 [computeLocalCover]）。
Future<String?> _computeLocalCoverSaf(String treeOrFilePath, LocalMediaKind kind) async {
  if (kind != LocalMediaKind.images && kind != LocalMediaKind.pdf) return null;
  try {
    final scanned = await scanComicFolderSaf(treeOrFilePath);
    if (scanned.archives.isNotEmpty) {
      final local = await resolveSafUri(scanned.archives.first);
      if (local.toLowerCase().endsWith('.pdf')) return await extractPdfCover(local);
      return await extractFirstArchiveImage(local);
    }
    if (scanned.rawImages.isNotEmpty) {
      return await resolveSafUri(scanned.rawImages.first);
    }
  } catch (_) {
    return null;
  }
  return null;
}

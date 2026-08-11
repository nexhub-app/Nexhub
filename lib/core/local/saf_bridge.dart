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
        isImageFile,
        naturalCompare,
        isComicArchive,
        registerSafCoverResolver;
import 'archive_extractor.dart' show extractFirstArchiveImage;
import '../local/pdf_util.dart' show extractPdfCover;
import '../utils/app_log.dart';

/// 单例 SAF 桥接。
final Saf saf = Saf();

/// 路径分隔符：treeUri 与相对路径段之间的分隔（content URI 中不会出现）。
/// 与 [SafFileSystem] 保持一致——下载产物用 `<treeUri>␟<rel>` 编码本地路径。
const String _kSafSep = '␟';

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

/// 把 SAF 目录 URI 归一化为 saf 包最稳定的输入形态（纯 `tree/<id>` 2 段）。
///
/// `pickDirectory` 返回的是规范化 `tree/<id>/document/<id>`（4 段）；saf 包
/// 内部 `docUriOf` 只对纯 `tree/<id>`（2 段）做 `buildDocumentUriUsingTree`
/// 转换，4 段形态下 `stat/child` 兼容性不稳定（实测 child 返回 null →
/// 下载后读取"未找到文档"→ 目录当文件读 EISDIR）。
///
/// 两步处理（**不经过 Uri.replace**，避免其把 `%3A` 解码成 `:` 导致
/// Android provider 编码匹配失败）：
/// 1. 纯字符串去掉 `/document/<id>` 后缀（4 段 → 2 段），保留原编码；
/// 2. 对 `tree/<id>` 的 id 段做「解码 → 规范重编码」（`primary:Download/nexhub`
///    → `primary%3ADownload%2Fnexhub`），与 Android 标准 tree URI 一致。
String normalizeSafTreeUri(String uri) {
  // 1. 去掉 `/document/<id>` 后缀（仅在确实含 /tree/ 时）
  final int docIdx = uri.indexOf('/document/');
  String head = uri;
  if (docIdx > 0 && uri.contains('/tree/') && uri.startsWith('content://')) {
    head = uri.substring(0, docIdx);
  }
  // 2. 规范编码 tree id 段
  final int treeIdx = head.indexOf('/tree/');
  if (treeIdx < 0) return head;
  final String prefix = head.substring(0, treeIdx + 6); // 含 /tree/
  final String idRaw = head.substring(treeIdx + 6);
  final String idDecoded;
  try {
    idDecoded = Uri.decodeComponent(idRaw);
  } on Object {
    return head;
  }
  final String idEncoded = Uri.encodeComponent(idDecoded);
  return '$prefix$idEncoded';
}

/// content:// SAF URI（或下载编码路径 `<treeUri>␟<rel>`）→ 应用私有缓存里的
/// 真实文件路径（记忆化）。
///
/// - 普通路径：原样返回（[isAndroidSafUri] 为假）。
/// - 纯 content:// 文档 URI（本地导入）：直接落缓存。
/// - 下载编码路径 `<treeUri>␟<rel>`（Android SAF 分区存储下的下载产物）：先按
///   路径段定位真实文档 URI，再落缓存（修复 107/108 下载后打不开）。
Future<String> resolveSafUri(String uriOrPath) async {
  _ensureRegistered();
  if (!isAndroidSafUri(uriOrPath)) return uriOrPath;
  final String docUri = uriOrPath.contains(_kSafSep)
      ? await _safEncodedToDocUri(uriOrPath)
      : normalizeSafTreeUri(uriOrPath);
  return _copySafToLocal(docUri, uriOrPath);
}

/// 把下载编码路径 `<treeUri>␟<rel>` 还原为 content:// 文档 URI。
///
/// 拆出 treeUri 与相对段后，用 [saf.child] 沿路径逐级定位文档；任一中间段缺失
/// 则返回 treeUri 兜底（此时 [saf.copyToLocalFile] 会因路径无效抛错，由调用方
/// 捕获并提示文件缺失）。
Future<String> _safEncodedToDocUri(String encoded) async {
  final int idx = encoded.indexOf(_kSafSep);
  if (idx < 0) return encoded;
  final String root = normalizeSafTreeUri(encoded.substring(0, idx));
  final String rel = encoded.substring(idx + _kSafSep.length);
  final List<String> segs = rel.split('/').where((s) => s.isNotEmpty).toList();
  if (segs.isEmpty) return root;
  SafDocumentFile? doc = await saf.child(root, segs);
  if (doc == null && segs.length == 1) {
    // 兜底：child 对部分 provider/URI 形态有 stat-first 兼容问题（返回 null），
    // 但文件确实在 root 下（下载写入校验已通过）。改为直接在 root 下列举，
    // 按文件名匹配（list 路径更稳）。异常/结果如实记录，便于定位。
    try {
      // 先确认 root 本身可 stat（区分「root 无效」与「文件不在列」）。
      final SafDocumentFile? rootStat = await saf.stat(root);
      if (rootStat == null) {
        AppLog.instance.e('[SAF stat 失败] root=$root 无法 stat（目录可能不存在'
            '或授权失效）');
      }
      final List<SafDocumentFile> children = await saf.list(root);
      final List<String> names = children.map((c) => c.name).toList();
      if (names.contains(segs.first)) {
        for (final c in children) {
          if (!c.isDir && c.name == segs.first) {
            doc = c;
            break;
          }
        }
      } else {
        AppLog.instance.w('[SAF list 兜底未命中] root=$root 要找=${segs.first} '
            '实际(${names.length}项)=${names.take(20).toList()}');
      }
    } on Object catch (e) {
      AppLog.instance.e('[SAF list 兜底异常] root=$root: $e');
    }
  }
  if (doc != null) return doc.uri;
  // 定位失败：路径段与树内实际文档对不上（文件被删 / 路径编码不匹配）。
  // **绝不返回 root**：root 是目录，上层会把它当文件读 → EISDIR。
  AppLog.instance.w('[SAF 定位失败] root=$root rel=$rel 未找到文档');
  throw FileSystemException(
      'SAF 下载文件不存在（可能被移动/删除，或下载未完成）', encoded);
}

/// 把 content:// 文档 URI 复制为应用私有缓存文件并返回其路径（记忆化）。
///
/// 0 字节的空文档（下载写入失败/源为空）不缓存、抛错——避免后续每次都返回
/// 空文件导致 FileImage "is empty" 崩溃。
Future<String> _copySafToLocal(String docUri, String cacheKey) async {
  final String? cached = _resolvedCache[cacheKey];
  if (cached != null &&
      File(cached).existsSync() &&
      File(cached).lengthSync() > 0) {
    return cached;
  }
  final Directory dir = await getTemporaryDirectory();
  final File target = File(
      p.join(dir.path, 'saf_${cacheKey.hashCode}${_safExt(docUri)}'));
  if (await target.exists() && target.lengthSync() > 0) {
    _resolvedCache[cacheKey] = target.path;
    return target.path;
  }
  // 重新拷贝（覆盖可能残留的 0 字节旧文件）。
  await saf.copyToLocalFile(docUri, target.path);
  if (!(await target.exists()) || target.lengthSync() == 0) {
    AppLog.instance.e('[SAF 拷贝失败] $docUri -> $target 为空或不存在');
    throw FileSystemException('SAF 源文件为空或不可读', docUri);
  }
  _resolvedCache[cacheKey] = target.path;
  return target.path;
}

/// 列举 SAF 路径下的图片并逐张落缓存，返回可阅读的本地文件路径（自然排序）。
///
/// 支持两种 SAF 路径：
/// - 纯 content:// 树 URI（本地导入的文件夹 / 单图）；
/// - 下载编码路径 `<treeUri>␟<rel>`（下载产物目录 / 单图）。
///
/// 单文件直接落缓存返回；目录则列举子文档中的图片。
Future<List<String>> gatherSafImages(String uriOrPath) async {
  _ensureRegistered();
  // 解析目录文档 URI：编码路径先拆 treeUri + 相对段定位；纯 content:// 树直接用。
  final int idx = uriOrPath.indexOf(_kSafSep);
  final String dirUri;
  if (idx >= 0) {
    final String root = normalizeSafTreeUri(uriOrPath.substring(0, idx));
    final String rel = uriOrPath.substring(idx + _kSafSep.length);
    final List<String> baseSegs =
        rel.split('/').where((s) => s.isNotEmpty).toList();
    if (baseSegs.isEmpty) {
      dirUri = root;
    } else {
      final SafDocumentFile? dirDoc = await saf.child(root, baseSegs);
      if (dirDoc == null) return const <String>[];
      dirUri = dirDoc.uri;
    }
  } else {
    dirUri = normalizeSafTreeUri(uriOrPath);
  }
  final SafDocumentFile? stat = await saf.stat(dirUri);
  if (stat != null && !stat.isDir) {
    // 单文件（纯 content:// 或编码单图），直接落缓存。
    return <String>[await resolveSafUri(uriOrPath)];
  }
  final List<SafDocumentFile> children = await saf.list(dirUri);
  final List<(String, String)> images = <(String, String)>[];
  for (final c in children) {
    if (c.isDir) continue;
    // 位图判断：扩展名优先；扩展名缺失（部分 provider）时按 MIME image/* 兜底。
    final bool isImg = isImageFile(c.name) ||
        (p.extension(c.name).isEmpty &&
            (c.mimeType ?? '').toLowerCase().startsWith('image/'));
    if (!isImg) continue;
    final SafDocumentFile? doc = await saf.child(dirUri, <String>[c.name]);
    if (doc == null) continue;
    images.add((c.name, await resolveSafUri(doc.uri)));
  }
  images.sort((a, b) => naturalCompare(a.$1, b.$1));
  return images.map((e) => e.$2).toList();
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
///
/// 单个子目录列举失败（如权限受限的系统子目录）时跳过该目录继续，避免整个
/// 扫描抛错被上层当作「导入失败」；否则全部成功返回。
Future<List<SafDocumentFile>> _walkSaf(String treeUri) async {
  final out = <SafDocumentFile>[];
  final List<SafDocumentFile> children;
  try {
    children = await saf.list(treeUri);
  } on Object {
    return out;
  }
  for (final c in children) {
    if (c.isDir) {
      out.addAll(await _walkSaf(c.uri));
    } else {
      out.add(c);
    }
  }
  return out;
}

/// SAF 文档类型识别：优先按文件名扩展名；扩展名缺失时（部分系统 provider 的
/// DISPLAY_NAME 不带扩展名）用 [mimeType] 兜底，避免「txt/epub 文件夹导入为空」。
LocalMediaKind? _classifySafDoc(SafDocumentFile d) {
  final byName = classifyByPath(d.name);
  if (byName != null) return byName;
  return _mimeKind(d.mimeType);
}

/// 按 MIME 推断本地媒体类型（仅在扩展名缺失/未知时兜底）。
LocalMediaKind? _mimeKind(String? mimeType) {
  final mime = (mimeType ?? '').toLowerCase();
  if (mime.isEmpty) return null;
  if (mime.startsWith('image/')) return LocalMediaKind.images;
  if (mime == 'application/pdf') return LocalMediaKind.pdf;
  if (mime == 'application/zip' ||
      mime == 'application/x-zip-compressed' ||
      mime == 'application/x-tar' ||
      mime.contains('comicbook') ||
      mime.contains('rar') ||
      mime.contains('7z')) {
    return LocalMediaKind.images;
  }
  if (mime.startsWith('text/') || mime == 'application/epub+zip') {
    return LocalMediaKind.text;
  }
  if (mime.startsWith('video/')) return LocalMediaKind.video;
  return null;
}

/// 扫描 SAF 漫画文件夹：区分「散图」与「漫画归档（含 PDF）」，分别自然排序返回
/// content:// URI 列表（镜像 [scanComicFolder]）。
Future<({List<String> rawImages, List<String> archives, List<String> others})>
    scanComicFolderSaf(String treeUri) async {
  final docs = await _walkSaf(normalizeSafTreeUri(treeUri));
  final raw = <SafDocumentFile>[];
  final arch = <SafDocumentFile>[];
  final other = <SafDocumentFile>[];
  for (final d in docs) {
    final lower = d.name.toLowerCase();
    final ext = p.extension(lower);
    if (<String>['.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp']
        .contains(ext)) {
      raw.add(d);
    } else if (isComicArchive(lower) || lower.endsWith('.pdf')) {
      arch.add(d);
    } else {
      // 扩展名缺失/未知：按 MIME 兜底归类（部分 provider 不返回扩展名）。
      final mime = (d.mimeType ?? '').toLowerCase();
      if (mime.startsWith('image/')) {
        raw.add(d);
      } else if (mime == 'application/pdf' ||
          mime == 'application/zip' ||
          mime == 'application/x-zip-compressed' ||
          mime == 'application/x-tar' ||
          mime.contains('comicbook') ||
          mime.contains('rar') ||
          mime.contains('7z')) {
        arch.add(d);
      } else {
        // 非图片、非已知归档的其它文件，也作为独立一话。
        other.add(d);
      }
    }
  }
  raw.sort((a, b) => naturalCompare(a.name, b.name));
  arch.sort((a, b) => naturalCompare(a.name, b.name));
  other.sort((a, b) => naturalCompare(a.name, b.name));
  return (
    rawImages: raw.map((d) => d.uri).toList(),
    archives: arch.map((d) => d.uri).toList(),
    others: other.map((d) => d.uri).toList(),
  );
}

/// 收集 SAF 文件夹中指定媒体类型的文件 content:// URI，自然排序
/// （镜像 [listFolderFilesByKind]）。
Future<List<String>> listFolderFilesByKindSaf(
    String treeUri, LocalMediaKind kind) async {
  final docs = await _walkSaf(normalizeSafTreeUri(treeUri));
  final files = docs
      .where((d) => _classifySafDoc(d) == kind)
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
  final docs = await _walkSaf(normalizeSafTreeUri(treeUri));
  final counts = <LocalMediaKind, int>{};
  for (final d in docs) {
    final k = _classifySafDoc(d);
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
    final doc = await saf.stat(normalizeSafTreeUri(treeUri));
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

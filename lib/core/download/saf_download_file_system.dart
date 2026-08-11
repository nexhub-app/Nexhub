/// 基于 Android SAF（`content://` 文档树）的下载文件系统实现。
///
/// 背景：Android 11+ 分区存储下，用户选中的「下载目录」是 `content://` tree URI，
/// dart:io 无法直接读写。本类把 [DownloadFileSystem] 的接口映射到 `saf` 包的
/// 文档树 API，使下载产物能真正落到用户指定的系统文件夹里（修复 107/108）。
///
/// 路径编码：`<treeUri>␟<relative/path>`（`␟` = U+241F 单元分隔符，不会出现在
/// content URI 中）。`basePath` 返回裸 treeUri（无分隔符），`join` 在相对段上
/// 以 `/` 拼接，从而与 [PathProviderFileSystem] 的行为保持一致。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:saf/saf.dart';

import '../local/saf_bridge.dart' show normalizeSafTreeUri;
import '../utils/app_log.dart';
import 'download_file_system.dart';

/// 路径分隔符：treeUri 与相对路径段之间的分隔（content URI 中不会出现）。
const String _kSafSep = '␟';

/// 通过 Android 存储访问框架（SAF）读写下载文件的文件系统后端。
///
/// 仅应在 Android + `content://` 路径下构造；非 Android 走 [PathProviderFileSystem]。
class SafFileSystem implements DownloadFileSystem {
  SafFileSystem(String rootUri)
      : _rootUri = normalizeSafTreeUri(rootUri);

  final String _rootUri;
  final Saf _saf = Saf();

  /// 把编码路径拆分为 (treeUri, 相对段列表)。treeUri 统一归一化为纯 tree URI。
  (String, List<String>) _split(String path) {
    final int idx = path.indexOf(_kSafSep);
    if (idx < 0) return (normalizeSafTreeUri(path), <String>[]);
    final String root = normalizeSafTreeUri(path.substring(0, idx));
    final String rel = path.substring(idx + _kSafSep.length);
    final List<String> segs =
        rel.split('/').where((s) => s.isNotEmpty).toList();
    return (root, segs);
  }

  /// 解析（必要时创建）相对段对应的目录，返回其 document URI。
  Future<String> _resolveDir(String rootUri, List<String> segs) async {
    if (segs.isEmpty) return rootUri;
    final SafDocumentFile? existing = await _saf.child(rootUri, segs);
    if (existing != null) return existing.uri;
    final SafDocumentFile created = await _saf.mkdirp(rootUri, segs);
    return created.uri;
  }

  /// 解析相对段对应的文档；不存在则抛 [FileSystemException]。
  Future<SafDocumentFile> _resolveDoc(
      String rootUri, List<String> segs, String path) async {
    if (segs.isEmpty) {
      throw FileSystemException('Cannot operate on root as a file', path);
    }
    final SafDocumentFile? doc = await _saf.child(rootUri, segs);
    if (doc == null) throw FileSystemException('Not found', path);
    return doc;
  }

  /// 依据文件扩展名推定 MIME（影响系统媒体库归类，失败回退 octet-stream）。
  String _mimeFor(String name) {
    final String lower = name.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.bmp')) return 'image/bmp';
    if (lower.endsWith('.mp4')) return 'video/mp4';
    if (lower.endsWith('.mkv')) return 'video/x-matroska';
    if (lower.endsWith('.mov')) return 'video/quicktime';
    if (lower.endsWith('.epub')) return 'application/epub+zip';
    if (lower.endsWith('.cbz') || lower.endsWith('.zip')) {
      return 'application/zip';
    }
    if (lower.endsWith('.pdf')) return 'application/pdf';
    if (lower.endsWith('.txt')) return 'text/plain';
    if (lower.endsWith('.json')) return 'application/json';
    if (lower.endsWith('.meta.json')) return 'application/json';
    return 'application/octet-stream';
  }

  @override
  String get basePath => _rootUri;

  @override
  Future<void> writeBytes(String path, Uint8List bytes) async {
    // 空内容 = 抓取失败/源无内容：拒绝写 0 字节"成功"文件（大小校验 0==0 会
    // 误通过，导致下载"成功"但文件全空 → 打开报"文件为空"）。
    if (bytes.isEmpty) {
      throw FileSystemException('拒绝写入空内容（源未返回数据）', path);
    }
    final (String rootUri, List<String> segs) = _split(path);
    if (segs.isEmpty) {
      throw FileSystemException('Cannot write to root', path);
    }
    final List<String> dirSegs = segs.sublist(0, segs.length - 1);
    final String name = segs.last;
    final String dirUri = await _resolveDir(rootUri, dirSegs);
    // 覆盖写前先删旧文档：部分 SAF provider 的 overwrite 不保证截断
    // （新内容短于旧文件时旧尾部残留 → 文件损坏），删后重建保证干净写入。
    final SafDocumentFile? existing = await _saf.child(rootUri, segs);
    if (existing != null) {
      try {
        await _saf.delete(existing.uri);
      } on Exception {
        // 删除失败不阻断：writeFileStream 的 overwrite 仍会尝试覆盖。
      }
    }
    // 清掉历史失败残留的畸形同名文件（如 xxx.cbz.zip，系统按 MIME 追加
    // 扩展名的产物），避免新写入与旧残留撞名被 provider 自动改名。
    await _cleanStaleSiblings(dirUri, name);
    // 大文件（CBZ/视频/epub）整块 writeFileBytes 一次性过方法通道会被
    // binder 截断（下载内容损坏根因），改为流式分块写入（每块 ≤1 MiB）。
    final SafDocumentFile written = await _saf.writeFileStream(
        dirUri, name, _mimeFor(name), _chunked(bytes),
        overwrite: true);
    // 写入后校验：大小不一致说明写入被截断/丢失 → 显式报错，避免静默产出
    // 空/半截文件（"下载完成但内容为空/打不开"）。
    if (written.length != bytes.length) {
      throw FileSystemException(
        '写入校验失败: 期望 ${bytes.length} 字节, 实际 ${written.length}',
        path,
      );
    }
    // 强制最终文件名与预期一致：部分 ROM 的 ExternalStorageProvider 会把
    // 「扩展名不在 MIME 规范表内」的文件名追加规范扩展名（如 .cbz 配
    // application/zip → 实际创建为 xxx.cbz.zip），导致按名回读失败，且后续
    // 按名读取同样找不到文档。创建后显式 rename 到目标名（rename 不做 MIME
    // 扩展名改写，AOSP renameDocument 只做 FAT 字符清理），并核对新名。
    if (written.name != name) {
      AppLog.instance.w('[SAF 文件名修正] 创建为 "${written.name}"，'
          '重命名为 "$name"（dir=$dirUri）');
      final SafDocumentFile renamed = await _saf.rename(written.uri, name);
      if (renamed.name != name) {
        AppLog.instance.e('[SAF 重命名后仍不符] 期望 "$name"，实际 '
            '"${renamed.name}"（uri=${renamed.uri}）');
        throw FileSystemException(
          '写入后文件名与预期不符（期望 "$name"，实际 "${renamed.name}"）',
          path,
        );
      }
    }
    // 写入后回读验证：用与读取端完全相同的定位方式（list + 按名匹配）确认
    // 文件可见，下载时即暴露，而不是等到打开才报"未找到文档"。
    try {
      final List<SafDocumentFile> children = await _saf.list(dirUri);
      final bool visible = children.any((c) => !c.isDir && c.name == name);
      if (!visible) {
        final List<String> names = children.map((c) => c.name).toList();
        AppLog.instance.e('[写入后回读失败] dirUri=$dirUri name=$name '
            '实际(${names.length}项)=${names.take(20).toList()}');
        throw FileSystemException('写入后回读不到文件（文件名被系统改写或'
            '目录不同步）', path);
      }
      // 顺带清理历史失败残留的畸形同名文件（如 xxx.cbz.zip），避免越积越多。
      await _cleanStaleSiblings(dirUri, name);
    } on Object catch (e) {
      if (e is FileSystemException) rethrow;
      AppLog.instance.w('[写入后回读异常] dirUri=$dirUri name=$name: $e');
    }
  }

  /// 删除 [dirUri] 下与 [name] 同源的历史残留（文件名以 `$name.` 开头但
  /// 不等于 [name] 的文件，如被系统按 MIME 改写成 `xxx.cbz.zip` 的失败
  /// 残留）。best-effort：任何一步失败只记日志，不阻断写入流程。
  Future<void> _cleanStaleSiblings(String dirUri, String name) async {
    try {
      final List<SafDocumentFile> children = await _saf.list(dirUri);
      for (final SafDocumentFile c in children) {
        if (c.isDir) continue;
        if (c.name != name && c.name.startsWith('$name.')) {
          try {
            await _saf.delete(c.uri);
            AppLog.instance.w('[SAF 清理残留] 删除 ${c.name}');
          } on Object catch (e) {
            AppLog.instance.w('[SAF 清理残留失败] ${c.name}: $e');
          }
        }
      }
    } on Object catch (e) {
      AppLog.instance.w('[SAF 清理残留列表异常] dir=$dirUri: $e');
    }
  }

  /// 把 [bytes] 切成不超过 1 MiB 的分块流（供 [writeFileStream] 使用）。
  Stream<List<int>> _chunked(Uint8List bytes) async* {
    const int chunkSize = 1 << 20; // 1 MiB
    for (int i = 0; i < bytes.length; i += chunkSize) {
      final int end =
          i + chunkSize < bytes.length ? i + chunkSize : bytes.length;
      yield bytes.sublist(i, end);
    }
  }

  @override
  Future<void> writeString(String path, String content) async {
    await writeBytes(path, utf8.encode(content));
  }

  @override
  Future<Uint8List> readBytes(String path) async {
    final (String rootUri, List<String> segs) = _split(path);
    final SafDocumentFile doc = await _resolveDoc(rootUri, segs, path);
    // 流式读取：整块 readFileBytes 过方法通道同样有截断风险。
    final BytesBuilder builder = BytesBuilder(copy: false);
    await for (final Uint8List chunk in await _saf.readFileStream(doc.uri)) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  @override
  Future<String> readString(String path) async {
    final Uint8List bytes = await readBytes(path);
    // 历史版本用 codeUnits(UTF-16) 写过 meta，先按 UTF-8 解码，失败再回退。
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return String.fromCharCodes(bytes);
    }
  }

  @override
  Future<bool> exists(String path) async {
    final (String rootUri, List<String> segs) = _split(path);
    if (segs.isEmpty) return true;
    return (await _saf.child(rootUri, segs)) != null;
  }

  @override
  Future<void> delete(String path) async {
    final (String rootUri, List<String> segs) = _split(path);
    if (segs.isEmpty) return; // 不删除根目录树
    final SafDocumentFile? doc = await _saf.child(rootUri, segs);
    if (doc != null) await _saf.delete(doc.uri);
  }

  @override
  Future<List<String>> listFiles(String dirPath) async {
    final (String rootUri, List<String> segs) = _split(dirPath);
    final String dirUri = await _resolveDir(rootUri, segs);
    final List<SafDocumentFile> children = await _saf.list(dirUri);
    return children.map((c) => c.name).toList();
  }

  @override
  Future<void> createDir(String path) async {
    final (String rootUri, List<String> segs) = _split(path);
    if (segs.isEmpty) return;
    await _saf.mkdirp(rootUri, segs);
  }

  @override
  String join(String a, String b) {
    if (!a.contains(_kSafSep)) return '$a$_kSafSep$b';
    final int i = a.indexOf(_kSafSep);
    final String root = a.substring(0, i);
    final String rel = a.substring(i + _kSafSep.length);
    final String newRel = rel.isEmpty ? b : '$rel/$b';
    return '$root$_kSafSep$newRel';
  }
}

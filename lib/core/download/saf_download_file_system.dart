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

  /// 宽松名匹配：真实名 == 目标，或任一侧解码后相等（部分 provider 返回的
  /// DISPLAY_NAME 是百分号编码形式，如 `%E5%B0%8F%E8%AF%B4` vs `小说`；
  /// 也可能是调用方传的段被编码过）。
  bool _nameMatches(String actual, String target) {
    if (actual == target) return true;
    bool decoded(String a, String b) {
      if (!a.contains('%') && !b.contains('%')) return false;
      try {
        return Uri.decodeComponent(a) == Uri.decodeComponent(b);
      } on Object {
        return false;
      }
    }

    return decoded(actual, target) || decoded(target, actual);
  }

  /// 解析（必要时创建）相对段对应的目录，返回其 document URI。
  ///
  /// **逐级解析**（而非一次性 [Saf.child] 多段匹配）：部分 Android provider /
  /// ROM 对多段 child 直接返回 null、或对中文段 DISPLAY_NAME 匹配不可靠
  /// （原始中文 vs 编码形式不一致），导致「父目录不是目录」/ 建出奇怪结构。
  /// 每级：单段 child → 失败用 list 按名（含解码）兜底 → 再失败才 createDir
  /// 单级，并用返回的 document URI 作为下一级的父。
  ///
  /// **关键**：[Saf.child] 按名匹配**不区分目录/文件**——同名文件被前次失败
  /// 下载建出后（mkdirp 多段 bug 把目录名建成文件），child 会命中文件并把
  /// 文件当目录用 → createDocument 报 "Parent document isn't a directory"。
  /// 因此 child/list 命中后必须校验 [SafDocumentFile.isDir]，非目录视为脏
  /// 数据删除重建。
  Future<String> _resolveDir(String rootUri, List<String> segs) async {
    if (segs.isEmpty) return rootUri;
    String cur = rootUri;
    for (final seg in segs) {
      // 1) child 命中：必须真的是目录，否则丢弃（可能是同名文件脏数据）。
      SafDocumentFile? dirDoc = await _saf.child(cur, <String>[seg]);
      if (dirDoc != null && !dirDoc.isDir) {
        AppLog.instance.w('[SAF 目录重建] "$seg" child 命中同名文件，删除重建');
        try {
          await _saf.delete(dirDoc.uri);
        } on Object catch (e) {
          AppLog.instance.w('[SAF 删除同名文件失败] $seg: $e');
        }
        dirDoc = null;
      }
      if (dirDoc == null) {
        try {
          final List<SafDocumentFile> list = await _saf.list(cur);
          // 只接受「目录」命中；同名文件视为脏数据/路径错乱（上次写入把
          // 目录名建成文件），不能当目录用（会触发 "Parent document isn't
          // a directory"）。命中同名文件时删除重建目录。
          dirDoc = list
              .where((c) => c.isDir && _nameMatches(c.name, seg))
              .firstOrNull;
          if (dirDoc == null) {
            final SafDocumentFile? file = list
                .where((c) => !c.isDir && _nameMatches(c.name, seg))
                .firstOrNull;
            if (file != null) {
              AppLog.instance.w('[SAF 目录重建] "$seg" 已存在同名文件，删除重建');
              try {
                await _saf.delete(file.uri);
              } on Object catch (e) {
                AppLog.instance.w('[SAF 删除同名文件失败] $seg: $e');
              }
            }
          }
        } on Object {
          dirDoc = null;
        }
      }
      if (dirDoc == null) {
        // 目录不存在 → 单级创建（mkdirp 对单段同样可靠）。
        final SafDocumentFile created = await _saf.mkdirp(cur, <String>[seg]);
        dirDoc = created;
      }
      // 最终校验：必须是目录，且可 stat（部分 provider 创建后需刷新/stat
      // 确认；stat 失败或非目录 → 重建一次，仍失败则抛明确错误）。
      if (!dirDoc.isDir) {
        AppLog.instance.w('[SAF 目录异常] "$seg" 非目录，删除重建');
        try {
          await _saf.delete(dirDoc.uri);
        } on Object catch (e) {
          AppLog.instance.w('[SAF 删除异常目录失败] $seg: $e');
        }
        final SafDocumentFile created = await _saf.mkdirp(cur, <String>[seg]);
        dirDoc = created;
      }
      final SafDocumentFile? reStat = await _safeStatOrNull(dirDoc.uri);
      if (reStat != null && !reStat.isDir) {
        throw FileSystemException(
            'SAF 目录 "$seg" 无法以目录方式访问（provider 返回非目录）',
            dirDoc.uri);
      }
      cur = dirDoc.uri;
    }
    return cur;
  }

  /// 安全 stat：失败返回 null（不抛）。
  Future<SafDocumentFile?> _safeStatOrNull(String uri) async {
    try {
      return await _saf.stat(uri);
    } on Object {
      return null;
    }
  }

  /// 解析相对段对应的文档；不存在返回 null（不抛错）。
  Future<SafDocumentFile?> _resolveDocOrNull(
      String rootUri, List<String> segs) async {
    if (segs.isEmpty) return null;
    SafDocumentFile? doc;
    String cur = rootUri;
    for (final seg in segs) {
      doc = await _saf.child(cur, <String>[seg]);
      if (doc == null) {
        try {
          final List<SafDocumentFile> list = await _saf.list(cur);
          doc = list.where((c) => _nameMatches(c.name, seg)).firstOrNull;
        } on Object {
          doc = null;
        }
      }
      if (doc == null) return null;
      cur = doc.uri;
    }
    return doc;
  }

  /// 解析相对段对应的文档；不存在则抛 [FileSystemException]。
  ///
  /// 逐级定位（与 [_resolveDir] 同策略）：多段 child 在部分 provider 上返回
  /// null / 中文匹配不可靠，改为每级单段 child + list 按名兜底。
  Future<SafDocumentFile> _resolveDoc(
      String rootUri, List<String> segs, String path) async {
    if (segs.isEmpty) {
      throw FileSystemException('Cannot operate on root as a file', path);
    }
    final SafDocumentFile? doc = await _resolveDocOrNull(rootUri, segs);
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
    await _writeStreamInternal(path, _chunked(bytes),
        expectedLen: bytes.length);
  }

  @override
  Future<void> writeStream(String path, Stream<List<int>> chunks) async {
    await _writeStreamInternal(path, chunks, expectedLen: null);
  }

  /// 流式写入的统一实现：目录解析 → 删旧 → 清残留 → 分块写 → 校验/改名/回读。
  ///
  /// [expectedLen] 非空时校验写入字节数（writeBytes 用）；为 null（流式，总长
  /// 未知）时跳过大小校验，但仍做改名修正与回读验证。
  Future<void> _writeStreamInternal(
    String path,
    Stream<List<int>> chunks, {
    int? expectedLen,
  }) async {
    final (String rootUri, List<String> segs) = _split(path);
    if (segs.isEmpty) {
      throw FileSystemException('Cannot write to root', path);
    }
    final List<String> dirSegs = segs.sublist(0, segs.length - 1);
    final String name = segs.last;
    final String dirUri = await _resolveDir(rootUri, dirSegs);
    // 诊断日志：解析出的目录 URI 若与预期不符（如尾段是文件名而非目录名），
    // 极可能是 provider 的 DISPLAY_NAME/child 行为异常，直接暴露而非等到
    // 写入时抛 "Parent document isn't a directory"。
    final SafDocumentFile? dirStat = await _safeStatOrNull(dirUri);
    AppLog.instance.d('[SAF 写入定位] root=$rootUri dirSegs=$dirSegs '
        'name=$name → dirUri=$dirUri stat=${dirStat?.isDir}');
    if (dirStat != null && !dirStat.isDir) {
      throw FileSystemException(
        'SAF 目标目录解析失败：$dirUri 不是目录（provider 目录定位异常）',
        path,
      );
    }
    if (dirUri.endsWith(name)) {
      throw FileSystemException(
        'SAF 目标目录解析错乱：目录 URI 与文件名相同（$dirUri）',
        path,
      );
    }
    // 覆盖写前先删旧文档：部分 SAF provider 的 overwrite 不保证截断
    // （新内容短于旧文件时旧尾部残留 → 文件损坏），删后重建保证干净写入。
    final SafDocumentFile? existing = await _resolveDocOrNull(rootUri, segs);
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
        dirUri, name, _mimeFor(name), chunks,
        overwrite: true);
    // 写入后校验：大小不一致说明写入被截断/丢失 → 显式报错，避免静默产出
    // 空/半截文件（"下载完成但内容为空/打不开"）。
    if (expectedLen != null && written.length != expectedLen) {
      throw FileSystemException(
        '写入校验失败: 期望 $expectedLen 字节, 实际 ${written.length}',
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
    return (await _resolveDocOrNull(rootUri, segs)) != null;
  }

  @override
  Future<void> delete(String path) async {
    final (String rootUri, List<String> segs) = _split(path);
    if (segs.isEmpty) return; // 不删除根目录树
    final SafDocumentFile? doc = await _resolveDocOrNull(rootUri, segs);
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
    await _resolveDir(rootUri, segs);
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

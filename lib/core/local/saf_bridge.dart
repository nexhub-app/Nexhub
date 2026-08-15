/// Android 分区存储（SAF）桥接层。
///
/// 背景：安卓分区存储下，file_picker 的 `getDirectoryPath` 在部分设备/版本返回
/// **真实文件系统路径**（如 `/storage/emulated/0/Download/xxx`），dart:io 能
/// `exists()` 却 `list()` 不出任何文件（静默空扫）——无法用于导入。因此安卓选
/// 文件夹必须走 `saf.pickDirectory()`（ACTION_OPEN_DOCUMENT_TREE + 持久授权），
/// 拿到 `content://` tree URI 后本层用 `saf` 包完成三件事：
///  1. 枚举选中的目录树（递归列举子文档，得到 content:// URI 列表）；
///  2. 把 content:// URI 解析为应用私有缓存里的真实文件路径（记忆化），从而复用
///     B 阶段全部读取管线（koni_archive 解压、File/epub 解析等）零改动；
///  3. 计算 SAF 条目的封面（首图 / PDF 首页）。
///
/// 仅 Android 调用其方法；非 Android 不会 import 触发平台调用。
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
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
        isComicIgnored,
        registerSafCoverResolver;
import 'archive_extractor.dart' show extractFirstArchiveImage;
import '../local/pdf_util.dart' show extractPdfCover;
import '../utils/app_log.dart';

/// 单例 SAF 桥接。
final Saf saf = Saf();

/// 跨平台选文件夹，统一返回「可被枚举的路径」：
/// - 安卓：`saf.pickDirectory()` → `content://` tree URI（带持久授权，[saf.list] 可枚举）；
/// - 非安卓：`file_picker.getDirectoryPath()` → 真实路径。
///
/// **不要用 `getDirectoryPath()` 直接在安卓选文件夹**：分区存储下它可能返回真实路径，
/// dart:io 会 `exists()=true` 但 `list()` 静默空扫，导致导入误报「未找到文件」。
/// 返回 null 表示用户取消。
Future<String?> pickFolderPath() async {
  if (Platform.isAndroid) {
    final SafDocumentFile? dir = await saf.pickDirectory();
    return dir?.uri;
  }
  return FilePicker.platform.getDirectoryPath();
}

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

/// 把 SAF 路径（普通 tree URI 或下载编码路径 `<treeUri>␟<rel>`）解析为实际
/// 目标文件夹的 content:// 文档 URI，供 [_walkSaf] 枚举其下后代文档。
///
/// 下载产物的 [workDir] 形如 `<treeUri>␟小说/诡秘之主`（带 `␟` 相对段）。若直接
/// 把整串喂给 [normalizeSafTreeUri]，会把 `␟rel` 误当成 tree id 的一部分拼进
/// 根 URI，导致 [saf.list] 在错误的 URI 上枚举为空，进而上层把**文件夹**当文件
/// 读 → "该路径是一个文件夹"。本函数拆出 tree 根后逐级定位到真正的作品文件夹
/// （单级 child 失败时用 list 按名兜底，兼容部分 provider）。本地导入的纯 tree
/// URI（无 `␟`）则直接返回规范化树根；非 SAF 路径原样返回。
Future<String> resolveSafDirUri(String uriOrPath) async {
  if (!isAndroidSafUri(uriOrPath)) return uriOrPath;
  final int idx = uriOrPath.indexOf(_kSafSep);
  if (idx < 0) return normalizeSafTreeUri(uriOrPath);
  final String root = normalizeSafTreeUri(uriOrPath.substring(0, idx));
  final List<String> segs = uriOrPath
      .substring(idx + _kSafSep.length)
      .split('/')
      .where((s) => s.isNotEmpty)
      .map((s) => s.contains('%') ? _tryDecodeComponent(s) : s)
      .toList();
  if (segs.isEmpty) return root;
  String cur = root;
  SafDocumentFile? dirDoc;
  for (final seg in segs) {
    dirDoc = await saf.child(cur, <String>[seg]);
    if (dirDoc == null) {
      // 部分 provider 对单级 child 返回 null，但 list 正常：按名兜底定位。
      try {
        final list = await saf.list(cur);
        dirDoc = list.where((c) => c.isDir && c.name == seg).firstOrNull ??
            list.where((c) => c.name == seg).firstOrNull;
      } on Object {
        dirDoc = null;
      }
    }
    if (dirDoc == null) {
      throw FileSystemException(
          'SAF 文件夹定位失败（中间段缺失）: $seg', uriOrPath);
    }
    cur = dirDoc.uri;
  }
  return dirDoc!.uri;
}

/// 规范化 SAF **文档** URI 的编码（保留 `/document/<id>` 后缀），供读取具体文件/子目录。
///
/// 与 [normalizeSafTreeUri] 的区别：后者把 `tree/<id>/document/<id>` 归一化为树根
/// （供 [saf.list]/[docUriOf] 枚举目录用）；本函数只重编码 tree id 段，**保留**完整
/// document 路径——`saf.list` 返回的子文档 URI 是 `tree/<id>/document/<childId>`，
/// 若拿去当树根剥掉 document，就会把文件 URI 变成目录 URI，读取时报"该路径是一个
/// 文件夹"。两步处理同样不经过 Uri.replace（避免 `%3A` 被解码成 `:`）。
String _normalizeSafDocUri(String uri) {
  final int treeIdx = uri.indexOf('/tree/');
  if (treeIdx < 0) return uri;
  final String prefix = uri.substring(0, treeIdx + 6); // 含 /tree/
  final String rest = uri.substring(treeIdx + 6);
  final int docIdx = rest.indexOf('/document/');
  final String treeIdRaw = docIdx >= 0 ? rest.substring(0, docIdx) : rest;
  final String tail = docIdx >= 0 ? rest.substring(docIdx) : '';
  final String treeIdDecoded;
  try {
    treeIdDecoded = Uri.decodeComponent(treeIdRaw);
  } on Object {
    return uri;
  }
  final String treeIdEncoded = Uri.encodeComponent(treeIdDecoded);
  return '$prefix$treeIdEncoded$tail';
}

/// content:// SAF URI（或下载编码路径 `<treeUri>␟<rel>`）→ 应用私有缓存里的
/// 真实文件路径（记忆化）。
///
/// - 普通路径：原样返回（[isAndroidSafUri] 为假）。
/// - 纯 content:// 文档 URI（本地导入）：直接落缓存。**必须是文件 URI**
///   （含 `/document/<childId>`）；若是树根目录 URI，[saf.stat] 会判为目录而报错。
/// - 下载编码路径 `<treeUri>␟<rel>`（Android SAF 分区存储下的下载产物）：先按
///   路径段定位真实文档 URI，再落缓存（修复 107/108 下载后打不开）。
Future<String> resolveSafUri(String uriOrPath) async {
  _ensureRegistered();
  if (!isAndroidSafUri(uriOrPath)) return uriOrPath;
  final String docUri = uriOrPath.contains(_kSafSep)
      ? await _safEncodedToDocUri(uriOrPath)
      : _normalizeSafDocUri(uriOrPath);
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
  // 段级兜底：下载目录名可能含 `%`（旧数据未清洗），`%` 在 content://
  // 路径里是合法转义前缀，但 Android provider 的 DISPLAY_NAME 是未编码真实名，
  // 直接带 `%` 匹配会失败。每段**仅当含 `%`** 时尝试解码（decode 对中文等
  // 非 ASCII 段会抛 "Illegal percent encoding in URI"，必须避免）。
  final List<String> segs = rel
      .split('/')
      .where((s) => s.isNotEmpty)
      .map((s) => s.contains('%') ? _tryDecodeComponent(s) : s)
      .toList();
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
  final Directory dir = await _localCacheDir();
  // 扩展名优先取 cacheKey（视频场景是带 .ts/.mp4 的编码路径，含真扩展名）；
  // docUri 为不透明 SAF 文档 URI，通常无扩展名，仅作兜底。
  final String ext = _safExt(cacheKey).isNotEmpty
      ? _safExt(cacheKey)
      : _safExt(docUri);
  final File target = File(p.join(dir.path, 'saf_${cacheKey.hashCode}$ext'));
  if (await target.exists() && target.lengthSync() > 0) {
    _resolvedCache[cacheKey] = target.path;
    return target.path;
  }
  // 重新拷贝（覆盖可能残留的 0 字节旧文件）。
  // 目录守卫：SAF 目录文档不能当文件拷贝（会失败或拷出空/垃圾内容）。
  // 出现该情况说明上层把"文件夹路径"当"文件路径"解析了（如书架直传任务文件夹）。
  try {
    final SafDocumentFile? doc = await saf.stat(docUri);
    if (doc != null && doc.isDir) {
      AppLog.instance.e('[SAF 拷贝失败] $docUri 是目录，不是文件');
      throw FileSystemException('该路径是一个文件夹，请选择具体文件', docUri);
    }
  } on FileSystemException {
    rethrow;
  } on Object catch (e) {
    AppLog.instance.e('[SAF stat 异常] $docUri: $e');
  }
  await saf.copyToLocalFile(docUri, target.path);
  if (!(await target.exists()) || target.lengthSync() == 0) {
    AppLog.instance.e('[SAF 拷贝失败] $docUri -> $target 为空或不存在');
    throw FileSystemException('SAF 源文件为空或不可读', docUri);
  }
  _resolvedCache[cacheKey] = target.path;
  return target.path;
}

/// 本地缓存落盘目录：优先 app-specific 外部存储（`Android/data/<pkg>/files`），
/// 该目录媒体_kit/mpv 在 Android 上读取最稳（裸绝对路径 + 应用自身可访问）；
/// 退回应用私有 temp 目录兜底（iOS / 极少数取不到外部目录的设备）。
Future<Directory> _localCacheDir() async {
  try {
    final Directory? ext = await getExternalStorageDirectory();
    if (ext != null) {
      await ext.create(recursive: true);
      return ext;
    }
  } on Object {
    // 取外部目录失败，退回 temp。
  }
  return getTemporaryDirectory();
}

/// 列举 SAF 路径下的图片并**返回 SAF content:// 文档 URI（不预先落缓存）**，自然排序。
///
/// 支持两种 SAF 路径：
/// - 纯 content:// 树 URI（本地导入的文件夹 / 单图）；
/// - 下载编码路径 `<treeUri>␟<rel>`（下载产物目录 / 单图）。
///
/// **懒解析**：此处只收集 URI，不在打开时把整本图片逐张拷贝到应用缓存——否则
/// 图片多时（数百张）打开漫画要等 1~2s（且首次才发生、后台清缓存后复现）。真正的
/// 落缓存（[resolveSafUri]）交给阅读器逐张显示时按需进行（见 [SourceImage]），
/// 进入阅读器即刻可见，只拷当前可见的几张。单文件同理返回 URI。
/// 安全的 [saf.stat]：树根目录 URI 调 [saf.stat] 会「判为目录」报错（见
/// [resolveSafUri] 注释），这里捕获异常当作「无法判定」返回 null，交由调用方
/// 按目录处理（走 [saf.list] 列举），避免打开图片文件夹时直接崩溃。
Future<SafDocumentFile?> _safeStat(String uri) async {
  try {
    return await saf.stat(uri);
  } on Object {
    return null;
  }
}

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
    // 纯 content://：输入可能是文件夹（树 URI）或单图（文件 URI）。先按
    // 「保留 document」形态 stat——单图文件直接落缓存；是目录才转树根去列举，
    // 避免把文件 URI 剥成树根目录导致「单图变整目录」。
    final SafDocumentFile? st =
        await _safeStat(_normalizeSafDocUri(uriOrPath));
    if (st != null && !st.isDir) {
      // 单图文件：返回 SAF URI，由阅读器懒解析落缓存。
      return <String>[uriOrPath];
    }
    dirUri = normalizeSafTreeUri(uriOrPath);
  }
  final SafDocumentFile? stat = await _safeStat(dirUri);
  if (stat != null && !stat.isDir) {
    // 单文件（纯 content:// 或编码单图），返回 SAF URI，由阅读器懒解析落缓存。
    return <String>[uriOrPath];
  }
  final List<SafDocumentFile> children;
  try {
    children = await saf.list(dirUri);
  } on Object catch (e) {
    // 列举失败（权限/URI 失效/provider 异常）不得抛出——否则异步 await 抛异常
    // 不会进 AppLog，表现为「点开无反应 + 运行日志为空」。降级返回空列表，
    // 由调用方走兜底查看器并记日志。
    AppLog.instance.eWithStack('[SAF 图片列举失败] dirUri=$dirUri', e);
    return const <String>[];
  }
  final List<(String, String)> images = <(String, String)>[];
  for (final c in children) {
    if (c.isDir) continue;
    // 位图判断：扩展名优先；扩展名缺失（部分 provider）时按 MIME image/* 兜底。
    final bool isImg = isImageFile(c.name) ||
        (p.extension(c.name).isEmpty &&
            (c.mimeType ?? '').toLowerCase().startsWith('image/'));
    if (!isImg) continue;
    // 直接用 saf.list 返回的子文档 URI（已含 document 段，与 _walkSaf 一致），
    // 不再经 saf.child(dirUri,[name])，避免对树根父目录解析出错。
    // 仅收集 URI，不在此落缓存（避免整本图片打开时逐张拷贝的 1~2s 卡顿）；
    // 真正落缓存交给阅读器逐张显示时按需进行（见 [SourceImage]）。
    images.add((c.name, c.uri));
  }
  images.sort((a, b) => naturalCompare(a.$1, b.$1));
  AppLog.instance.i('[SAF 图片收集] dirUri=$dirUri 命中 ${images.length} 张');
  return images.map((e) => e.$2).toList();
}

/// 列举 SAF 文件夹下的子文件名（不落缓存）。
///
/// 用于「按集命名、扩展名未知」的视频定位：HLS 下载写出 `.ts`、直链写出 `.mp4`，
/// 但打开时只能拿到按集序号，需枚举目录按 `NNN.<videoExt>` 精确命中真实文件。
/// 支持下载编码 `<treeUri>␟<rel>` 与纯 content:// 树 URI；rel 为文件夹相对路径
/// （可空/空 → root）。返回非目录子文件的文件名列表。
Future<List<String>> listSafChildNames(String folderUriOrPath) async {
  _ensureRegistered();
  final int idx = folderUriOrPath.indexOf(_kSafSep);
  final String dirUri;
  if (idx >= 0) {
    final String root = normalizeSafTreeUri(folderUriOrPath.substring(0, idx));
    final String rel = folderUriOrPath.substring(idx + _kSafSep.length);
    final List<String> baseSegs =
        rel.split('/').where((s) => s.isNotEmpty).toList();
    if (baseSegs.isEmpty) {
      dirUri = root;
    } else {
      // 逐级定位（而非一次性 saf.child(root, 多级)）：部分 provider 对多段 child
      // 直接返回 null，但单级 child / list 正常。任一级失败时用 list 按名兜底。
      String cur = root;
      SafDocumentFile? dirDoc;
      for (final seg in baseSegs) {
        dirDoc = await saf.child(cur, <String>[seg]);
        if (dirDoc == null) {
          try {
            final list = await saf.list(cur);
            dirDoc = list.where((c) => c.isDir && c.name == seg).firstOrNull ??
                list.where((c) => c.name == seg).firstOrNull;
          } on Object {
            dirDoc = null;
          }
        }
        if (dirDoc == null) return const <String>[];
        cur = dirDoc.uri;
      }
      dirUri = dirDoc!.uri;
    }
  } else {
    dirUri = normalizeSafTreeUri(folderUriOrPath);
  }
  final SafDocumentFile? stat = await _safeStat(dirUri);
  if (stat != null && !stat.isDir) return <String>[stat.name];
  final List<SafDocumentFile> children = await saf.list(dirUri);
  return children.where((c) => !c.isDir).map((c) => c.name).toList();
}

/// 解析「本地视频任务 / 书架」的 SAF 路径为可播放的真实视频文件。
///
/// 输入可能是：
/// - 纯 content:// 单文件 → 直接 [resolveSafUri] 落盘；
/// - 编码路径 `<treeUri>␟<folder>/001.mp4`（章节文件）→ 按 `NNN.<videoExt>`
///   在目录内精确/兜底匹配（HLS 产物 `.ts`、直链 `.mp4`）；
/// - 编码路径 `<treeUri>␟<folder>`（**任务文件夹**，书架/列表直传）→ 枚举目录
///   取首个视频文件。
/// 任一情况都返回 [resolveSafUri] 落盘后的真实文件路径；找不到则回退对原路径
/// [resolveSafUri]（目录场景会由 [_copySafToLocal] 的目录守卫报明确错误，
/// 绝不把 content:// 交给 media_kit 静默"打开成功"）。
Future<String> resolveSafVideoFile(String uriOrPath) async {
  if (!isAndroidSafUri(uriOrPath)) return uriOrPath;
  const videoExts = <String>[
    '.ts', '.mp4', '.mkv', '.avi', '.mov', '.webm', '.m4v', '.flv',
  ];
  final int idx = uriOrPath.indexOf(_kSafSep);
  if (idx < 0) return resolveSafUri(uriOrPath); // 纯 content:// 单文件
  final String rootPart = uriOrPath.substring(0, idx);
  final List<String> segs = uriOrPath
      .substring(idx + _kSafSep.length)
      .split('/')
      .where((s) => s.isNotEmpty)
      .toList();
  if (segs.isEmpty) return resolveSafUri(uriOrPath);
  final String last = segs.last;
  final bool lastIsFile = videoExts.any(last.toLowerCase().endsWith);
  // 目录编码路径（不含文件名部分）：文件形态去掉最后一节，文件夹形态就是本身。
  final List<String> dirSegs =
      lastIsFile ? segs.sublist(0, segs.length - 1) : segs;
  final String folderEncoded = dirSegs.isEmpty
      ? rootPart
      : '$rootPart$_kSafSep${dirSegs.join('/')}';

  final List<String> names = await listSafChildNames(folderEncoded);
  String? found;
  if (lastIsFile) {
    // 章节文件：优先 `NNN.<videoExt>` 精确前缀命中，其次目录内任意视频文件。
    final String prefix =
        last.contains('.') ? last.substring(0, last.lastIndexOf('.')) : last;
    for (final name in names) {
      final String lower = name.toLowerCase();
      if (lower.startsWith('$prefix.') &&
          videoExts.any((ext) => lower.endsWith(ext))) {
        found = name;
        break;
      }
    }
    if (found == null) {
      for (final name in names) {
        if (videoExts.any((ext) => name.toLowerCase().endsWith(ext))) {
          found = name;
          break;
        }
      }
    }
  } else {
    // 任务文件夹：取目录下首个视频文件（自然排序，一般 001 在前）。
    final List<String> sorted = List<String>.from(names)..sort();
    for (final name in sorted) {
      if (videoExts.any((ext) => name.toLowerCase().endsWith(ext))) {
        found = name;
        break;
      }
    }
  }
  if (found != null && found.isNotEmpty) {
    return resolveSafUri('$folderEncoded/$found');
  }
  // 找不到：回退对原路径落盘（文件场景直接可读；目录场景由目录守卫报错）。
  return resolveSafUri(uriOrPath);
}

/// 从 content:// URI 末尾尽量还原扩展名（缓存文件需保留扩展名供格式识别）。
String _safExt(String uri) {
  final lastRaw = uri.split('/').last;
  final last = lastRaw.contains('%') ? _tryDecodeComponent(lastRaw) : lastRaw;
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
  // 根目录列举失败（权限不足 / URI 无效 / SecurityException）必须向上抛出，
  // 让上层区分「扫描失败（权限/路径问题）」与「真的为空」，避免被误判成
  // 「文件夹为空或无可用文件」。子目录列举失败仍仅跳过、不中断整次扫描。
  List<SafDocumentFile> children;
  try {
    children = await saf.list(treeUri);
  } on Object catch (e) {
    throw FileSystemException(
      'SAF 列举目录失败（可能是 Android 文件夹访问权限不足）: $e',
      treeUri,
    );
  }
  for (final c in children) {
    if (c.isDir) {
      // 子目录列举失败（权限受限的系统子目录）仅跳过该目录继续。
      try {
        out.addAll(await _walkSaf(c.uri));
      } on Object {
        continue;
      }
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
  final docs = await _walkSaf(await resolveSafDirUri(treeUri));
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
    } else if (isComicIgnored(lower)) {
      // 忽略配置/元数据/文档/音视频等非漫画文件，不当作漫画章节。
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
  final docs = await _walkSaf(await resolveSafDirUri(treeUri));
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

String _walkName(String uri) {
  final last = uri.split('/').last;
  // 仅对含 `%` 的段解码（中文等非 ASCII 段直接调用 decodeComponent 会抛
  // "Illegal percent encoding in URI"——非 ASCII 未编码字符不是合法转义）。
  if (!last.contains('%')) return last;
  try {
    return Uri.decodeComponent(last);
  } on Object {
    // 含非法 % 编码的段：decode 失败时原样返回，避免拖垮整个列表操作。
    return last;
  }
}

/// 枚举 SAF 文件夹下的「源文件」（.json/.txt/.xml），自然排序返回 content:// URI。
///
/// 源扩展名不在媒体类型白名单内（[classifyByPath] 只看 txt/epub 等），
/// 因此不能用 [listFolderFilesByKindSaf]。本函数按「扩展名优先 + MIME 兜底」筛选，
/// 供插件源文件夹导入使用。部分 Android provider 的 SAF 文档 DISPLAY_NAME
/// 不带扩展名（[SafDocumentFile.name] 只有 id），此时退化用 [mimeType] 判定，
/// 避免「文件夹里有 .json/.txt/.xml 却扫描为空」。根目录列举失败由 [_walkSaf]
/// 抛出 [FileSystemException]，便于上层区分「扫描失败」与「真的没有源文件」。
Future<List<String>> listFolderSourceFilesSaf(String treeUri) async {
  final docs = await _walkSaf(normalizeSafTreeUri(treeUri));
  final files = docs
      .where((d) {
        final ext = p.extension(d.name).toLowerCase().replaceFirst('.', '');
        if (const <String>['json', 'txt', 'xml'].contains(ext)) return true;
        // 扩展名缺失/未知：用 MIME 兜底（覆盖 DISPLAY_NAME 无扩展名的 provider）。
        if (ext.isEmpty) {
          final mime = (d.mimeType ?? '').toLowerCase();
          return mime.startsWith('text/') ||
              mime == 'application/json' ||
              mime.contains('xml');
        }
        return false;
      })
      .map((d) => d.uri)
      .toList();
  files.sort((a, b) => naturalCompare(_walkName(a), _walkName(b)));
  return files;
}

/// 读取文本类文件（源 / 配置）内容，自动处理 Android SAF content:// URI：
/// 先 [resolveSafUri] 落缓存再读；普通真实路径直接读。用于源文件 / 文件夹导入，
/// 避免在 Android 上对 content:// 直接 `File().readAsString()` 抛错。
Future<String> readSourceText(String pathOrUri) async {
  final String local;
  if (isAndroidSafUri(pathOrUri)) {
    local = await resolveSafUri(pathOrUri);
  } else {
    local = pathOrUri;
  }
  return File(local).readAsString();
}

/// 按 SAF 文件夹内真实文件的多数扩展名决定媒体类型（镜像 [classifyFolderByContent]）。
Future<LocalMediaKind?> classifyFolderByContentSaf(String treeUri) async {
  final docs = await _walkSaf(await resolveSafDirUri(treeUri));
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
  final String lastRaw = uriOrPath.split('/').last;
  // 仅对含 `%` 的段解码：中文等非 ASCII 段直接 decodeComponent 会抛
  // "Illegal percent encoding in URI"（这是下载后打开小说/漫画报错的根源）。
  // 含非法 % 编码时原样返回，避免异常抛给上层（打不开/崩溃的来源）。
  final String last = lastRaw.contains('%')
      ? _tryDecodeComponent(lastRaw)
      : lastRaw;
  final parts = last.split(RegExp(r'[:/]')).where((s) => s.isNotEmpty);
  return parts.isEmpty ? '文件' : parts.last;
}

/// 安全解码单段 URI 组件：失败（非法 % 编码）时原样返回。
String _tryDecodeComponent(String s) {
  try {
    return Uri.decodeComponent(s);
  } on Object {
    return s;
  }
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

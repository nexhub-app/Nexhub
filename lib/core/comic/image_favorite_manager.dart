/// 图片收藏管理器（REQ-C2 图片收藏图库 · X-3 统一图库扩展）。
///
/// 镜像 [ComicBookmarkManager] 结构，按 作品 + 章节 + 页码 保存图片收藏到
/// Hive box `image_favorites`。支持添加 / 删除 / 切换 / 列出全部收藏，
/// 并按 createdAt 倒序返回（图库最新收藏在前）。
///
/// X-3 跨类型对齐扩展：漫画之外，播放器截图与小说插图也收藏入同一图库——
/// [ImageFavoriteSource] 区分来源；无「章节+页码」位置概念的条目（截图 /
/// 插图）走 [toggleByUrl]，以 `来源::img::URL` 为唯一键去重，漫画条目维持
/// 原有 `comicId::chapterIndex::pageIndex` 键格式（存量数据兼容）。
///
/// 本地缓存：收藏网络图片时把字节落盘到 `documents/favorite_images/`
/// （按 imageUrl 的 sha1 命名），图库离线可看、不受反盗链影响。
/// 「清理缓存」只清图片磁盘缓存（DefaultCacheManager/NexImageCacheManager）
/// 与 Cookie，不触碰该目录；**仅取消收藏时删除对应本地文件**。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../scraper/http_fetcher.dart';

/// 收藏来源模块（X-3 统一图库）。
enum ImageFavoriteSource {
  comic,
  player,
  novel;

  String get apiName => switch (this) {
        ImageFavoriteSource.comic => 'comic',
        ImageFavoriteSource.player => 'player',
        ImageFavoriteSource.novel => 'novel',
      };

  static ImageFavoriteSource parse(String? name) => switch (name) {
        'player' => ImageFavoriteSource.player,
        'novel' => ImageFavoriteSource.novel,
        _ => ImageFavoriteSource.comic,
      };
}

/// 单条收藏图片。
class ImageFavorite {
  /// 来源模块（漫画 / 播放器截图 / 小说插图）。
  final ImageFavoriteSource source;

  /// 所属作品 ID（漫画 ID / 播放器作品 ID / 小说 ID）。
  final String comicId;

  /// 章节在 chapters 列表中的索引（无章节概念的条目为 -1）。
  final int chapterIndex;

  /// 章节标题（展示用；无章节概念的条目填作品/集/章标题）。
  final String chapterTitle;

  /// 页在章节中的索引（0 起；无章节概念的条目为 -1）。
  final int pageIndex;

  /// 图片地址（URL 或本地路径）。
  final String imageUrl;

  /// 本地缓存文件路径（收藏时落盘；'' = 未缓存/本地图片无缓存副本）。
  /// 展示优先用它（离线可用），缺文件时回退 [imageUrl]。
  final String localPath;

  /// 创建时间（毫秒）。
  final int createdAt;

  /// 自定义文件夹（'' = 未分类；问题 4 文件夹管理）。
  final String folder;

  const ImageFavorite({
    this.source = ImageFavoriteSource.comic,
    required this.comicId,
    required this.chapterIndex,
    required this.chapterTitle,
    required this.pageIndex,
    required this.imageUrl,
    required this.createdAt,
    this.folder = '',
    this.localPath = '',
  });

  ImageFavorite copyWith({
    ImageFavoriteSource? source,
    String? comicId,
    int? chapterIndex,
    String? chapterTitle,
    int? pageIndex,
    String? imageUrl,
    String? localPath,
    int? createdAt,
    String? folder,
  }) =>
      ImageFavorite(
        source: source ?? this.source,
        comicId: comicId ?? this.comicId,
        chapterIndex: chapterIndex ?? this.chapterIndex,
        chapterTitle: chapterTitle ?? this.chapterTitle,
        pageIndex: pageIndex ?? this.pageIndex,
        imageUrl: imageUrl ?? this.imageUrl,
        localPath: localPath ?? this.localPath,
        createdAt: createdAt ?? this.createdAt,
        folder: folder ?? this.folder,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'source': source.apiName,
        'comicId': comicId,
        'chapterIndex': chapterIndex,
        'chapterTitle': chapterTitle,
        'pageIndex': pageIndex,
        'imageUrl': imageUrl,
        if (localPath.isNotEmpty) 'localPath': localPath,
        'createdAt': createdAt,
        'folder': folder,
      };

  factory ImageFavorite.fromJson(Map<String, dynamic> json) {
    return ImageFavorite(
      source: ImageFavoriteSource.parse(json['source'] as String?),
      comicId: json['comicId'] as String? ?? '',
      chapterIndex: (json['chapterIndex'] as num?)?.toInt() ?? 0,
      chapterTitle: json['chapterTitle'] as String? ?? '',
      pageIndex: (json['pageIndex'] as num?)?.toInt() ?? 0,
      imageUrl: json['imageUrl'] as String? ?? '',
      localPath: json['localPath'] as String? ?? '',
      createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
      folder: json['folder'] as String? ?? '',
    );
  }

  /// 复合 key：
  /// - 漫画：`comicId::chapterIndex::pageIndex`（兼容存量，同一作品同一章同一页
  ///   只保留一份）；
  /// - 截图/插图（无位置概念）：`来源::img::imageUrl`，按图片地址去重。
  String get key {
    if (source == ImageFavoriteSource.comic) {
      return '$comicId::$chapterIndex::$pageIndex';
    }
    return '${source.apiName}::img::$imageUrl';
  }
}

/// 图片收藏管理器——使用 Hive box `image_favorites`。
class ImageFavoriteManager {
  ImageFavoriteManager({Box<dynamic>? box}) : _box = box;

  /// Hive box 名。
  static const String boxName = 'image_favorites';

  final Box<dynamic>? _box;

  /// 懒加载打开 box（如未在 splash 阶段预打开）。
  Future<Box<dynamic>> _openBox() async {
    if (_box != null) return _box;
    if (Hive.isBoxOpen(boxName)) return Hive.box(boxName);
    return Hive.openBox(boxName);
  }

  /// 添加一条收藏图片，返回新建的收藏项。
  Future<ImageFavorite> add(ImageFavorite favorite) async {
    final box = await _openBox();
    await box.put(favorite.key, jsonEncode(favorite.toJson()));
    return favorite;
  }

  /// 按复合 key 删除指定收藏图片（连同本地缓存文件一起删除）。
  Future<void> remove(String key) async {
    final box = await _openBox();
    await _deleteRecordAndFile(box, key);
  }

  /// 删除一条收藏记录及其本地缓存文件（所有删除路径的统一出口）。
  Future<void> _deleteRecordAndFile(Box<dynamic> box, Object? key) async {
    final Object? raw = box.get(key);
    if (raw is String && raw.isNotEmpty) {
      try {
        final ImageFavorite f =
            ImageFavorite.fromJson(jsonDecode(raw) as Map<String, dynamic>);
        if (f.localPath.isNotEmpty) {
          final File file = File(f.localPath);
          if (file.existsSync()) await file.delete();
        }
      } on Object {
        // 损坏数据 / 文件删除失败：仍继续删记录。
      }
    }
    await box.delete(key);
  }

  /// 重命名条目标题（问题 3：长按菜单「重命名标题」）。
  ///
  /// 更新 chapterTitle 字段并落盘；找不到该 key / 空标题时返回 false。
  Future<bool> updateTitle(String key, String title) async {
    if (key.isEmpty) return false;
    final String clean = title.trim();
    if (clean.isEmpty) return false;
    try {
      final box = await _openBox();
      final Object? raw = box.get(key);
      if (raw is! String || raw.isEmpty) return false;
      final Map<String, dynamic> json =
          jsonDecode(raw) as Map<String, dynamic>;
      json['chapterTitle'] = clean;
      await box.put(key, jsonEncode(json));
      return true;
    } on Object {
      return false;
    }
  }

  /// 移动条目到文件夹（'' = 未分类）；找不到该 key 时返回 false。
  Future<bool> moveToFolder(String key, String folder) async {
    if (key.isEmpty) return false;
    try {
      final box = await _openBox();
      final Object? raw = box.get(key);
      if (raw is! String || raw.isEmpty) return false;
      final Map<String, dynamic> json =
          jsonDecode(raw) as Map<String, dynamic>;
      json['folder'] = folder;
      await box.put(key, jsonEncode(json));
      return true;
    } on Object {
      return false;
    }
  }

  /// 返回全部收藏中出现的非空文件夹名（含空文件夹需查 [folders]）。
  static const String foldersPrefsKey = 'image_favorite_folders_v1';

  /// 读自定义文件夹名列表（SharedPreferences；含空文件夹条目）。
  Future<List<String>> folders() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getStringList(foldersPrefsKey) ?? <String>[];
    } on Object {
      return <String>[];
    }
  }

  /// 保存文件夹名列表（新建 / 删除文件夹后调用）。
  Future<void> saveFolders(List<String> folders) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final List<String> clean = folders.where((f) => f.trim().isNotEmpty).toSet().toList();
      await prefs.setStringList(foldersPrefsKey, clean);
    } on Object {
      // 写入失败忽略。
    }
  }

  /// 切换收藏状态：未收藏则添加并返回 true，已收藏则删除并返回 false。
  Future<bool> toggle({
    required String comicId,
    required int chapterIndex,
    required String chapterTitle,
    required int pageIndex,
    required String imageUrl,
  }) async {
    final String key = '$comicId::$chapterIndex::$pageIndex';
    final box = await _openBox();
    final Object? raw = box.get(key);
    if (raw is String && raw.isNotEmpty) {
      // 已收藏：删除（含本地缓存文件）。
      await _deleteRecordAndFile(box, key);
      return false;
    }
    // 未收藏：新增。
    final ImageFavorite fav = ImageFavorite(
      comicId: comicId,
      chapterIndex: chapterIndex,
      chapterTitle: chapterTitle,
      pageIndex: pageIndex,
      imageUrl: imageUrl,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await box.put(key, jsonEncode(fav.toJson()));
    return true;
  }

  /// 漫画图片收藏切换（按图片地址为唯一身份去重，持久化语义修正）。
  ///
  /// 历史实现按 `comicId::章节::页码` 位置键读写：章节列表顺序漂移（源站目录
  /// 顺序不稳定 / 自然排序开关）、从待读队列等入口传入子集章节表、本地与在线
  /// comicId 不一致时，同一张图下次会话落在不同位置键下，既查不到旧收藏、
  /// 新收藏也可能互相覆盖——表现为「收藏本图重启后丢失」。改为每次先按
  /// imageUrl 全量查重（含存量位置键条目）：已存在则删除其实际键并返回 false；
  /// 新增仍写位置键（存量兼容），位置信息保留在 JSON 里供图库跳转回原页。
  Future<bool> toggleComicImage({
    required String comicId,
    required int chapterIndex,
    required String chapterTitle,
    required int pageIndex,
    required String imageUrl,
  }) async {
    if (imageUrl.isEmpty) return false;
    final box = await _openBox();
    final Object? existingKey = await _findKeyByUrl(box, imageUrl);
    if (existingKey != null) {
      // 已收藏：删除（含本地缓存文件）。
      await _deleteRecordAndFile(box, existingKey);
      return false;
    }
    final ImageFavorite fav = ImageFavorite(
      comicId: comicId,
      chapterIndex: chapterIndex,
      chapterTitle: chapterTitle,
      pageIndex: pageIndex,
      imageUrl: imageUrl,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await box.put(fav.key, jsonEncode(fav.toJson()));
    return true;
  }

  /// 按 imageUrl 查找既有条目的存储键（含存量位置键格式）；找不到返回 null。
  Future<Object?> _findKeyByUrl(Box<dynamic> box, String imageUrl) async {
    for (final Object? key in box.keys) {
      final Object? raw = box.get(key);
      if (raw is! String || raw.isEmpty) continue;
      try {
        final ImageFavorite f =
            ImageFavorite.fromJson(jsonDecode(raw) as Map<String, dynamic>);
        if (f.imageUrl == imageUrl) return key;
      } on Object {
        // 损坏数据忽略。
      }
    }
    return null;
  }

  /// 按 URL 切换收藏状态（X-3：播放器截图 / 小说插图，无章节+页码位置概念）。
  ///
  /// 以 `来源::img::imageUrl` 为唯一键去重：同一来源同一图片地址只保留一份。
  /// [workId] 为作品 ID（展示/定位用）；[workTitle] 为作品标题；[label] 为
  /// 条目标题（截图/章节名）。
  Future<bool> toggleByUrl({
    required ImageFavoriteSource source,
    required String workId,
    required String workTitle,
    required String label,
    required String imageUrl,
  }) async {
    if (imageUrl.isEmpty) return false;
    final String key = '${source.apiName}::img::$imageUrl';
    final box = await _openBox();
    final Object? raw = box.get(key);
    if (raw is String && raw.isNotEmpty) {
      // 已收藏：删除（含本地缓存文件）。
      await _deleteRecordAndFile(box, key);
      return false;
    }
    // 未收藏：新增。
    final ImageFavorite fav = ImageFavorite(
      source: source,
      comicId: workId,
      chapterIndex: -1,
      chapterTitle: workTitle,
      pageIndex: -1,
      imageUrl: imageUrl,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await box.put(key, jsonEncode(fav.toJson()));
    return true;
  }

  /// 判断指定位置是否已收藏（按 作品 + 章节 + 页码）。
  Future<bool> isFavorite(String comicId, int chapterIndex, int pageIndex) async {
    final box = await _openBox();
    final Object? raw = box.get('$comicId::$chapterIndex::$pageIndex');
    return raw is String && raw.isNotEmpty;
  }

  /// 判断图片地址是否已收藏（按 imageUrl，供无位置信息的调用方使用）。
  Future<bool> isFavoriteByUrl(String imageUrl) async {
    if (imageUrl.isEmpty) return false;
    final List<ImageFavorite> favorites = await list();
    return favorites.any((f) => f.imageUrl == imageUrl);
  }

  /// 列出全部收藏图片（按 createdAt 倒序）。
  Future<List<ImageFavorite>> list() async {
    final box = await _openBox();
    final List<ImageFavorite> result = <ImageFavorite>[];
    for (final Object? key in box.keys) {
      final Object? raw = box.get(key);
      if (raw is! String || raw.isEmpty) continue;
      try {
        result.add(
          ImageFavorite.fromJson(jsonDecode(raw) as Map<String, dynamic>),
        );
      } on Object {
        // 损坏数据忽略。
      }
    }
    result.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return result;
  }

  // ─────────────── 本地缓存（收藏即落盘） ───────────────

  /// 收藏图片本地缓存目录名（位于应用文档目录下）。
  ///
  /// 「清理缓存」只清 DefaultCacheManager / NexImageCacheManager 与 Cookie，
  /// 不触碰该目录；**仅取消收藏时删除对应文件**（见 [_deleteRecordAndFile]）。
  static const String localDirName = 'favorite_images';

  /// 收藏图本地缓存路径（按 imageUrl 的 sha1 命名，同 URL 稳定同路径）。
  /// 非 http(s) 地址（本地路径/截图）返回 ''，无需缓存。
  Future<String> _localPathFor(String imageUrl) async {
    if (!imageUrl.startsWith('http://') && !imageUrl.startsWith('https://')) {
      return '';
    }
    final Directory docs = await getApplicationDocumentsDirectory();
    final String name =
        '${sha1.convert(utf8.encode(imageUrl))}${_extOf(imageUrl)}';
    return p.join(docs.path, localDirName, name);
  }

  static String _extOf(String imageUrl) {
    final String clean = imageUrl.split('?').first;
    final int dot = clean.lastIndexOf('.');
    if (dot < 0) return '.jpg';
    final String e = clean.substring(dot).toLowerCase();
    if (e.length < 2 || e.length > 5) return '.jpg';
    return RegExp(r'^\.[a-z0-9]+$').hasMatch(e) ? e : '.jpg';
  }

  /// 把网络图片字节缓存到本地（best-effort），返回落盘路径；'' = 失败/无需缓存。
  ///
  /// [referer]：部分源按「图片↔所属章节页」绑定校验 Referer（400/403），
  /// 由调用方（阅读器）传入推导值；已缓存过直接返回既有路径（幂等）。
  Future<String> cacheLocally(String imageUrl, {String? referer}) async {
    try {
      final String path = await _localPathFor(imageUrl);
      if (path.isEmpty) return '';
      final File file = File(path);
      if (file.existsSync() && file.lengthSync() > 0) return path;
      final Directory dir = file.parent;
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final Map<String, String> headers = <String, String>{
        'Accept': 'image/jpeg,image/png,image/webp,image/gif,*/*;q=0.8',
        'User-Agent': HttpFetcher.instance.userAgentForUrl(imageUrl),
        if (referer != null && referer.isNotEmpty) 'Referer': referer,
      };
      final List<int> bytes =
          await HttpFetcher.instance.getBytes(imageUrl, headers: headers);
      // HTML/纯文本错误页拒收（防盗链源常回 200 HTML）。
      if (bytes.isEmpty || bytes.first == 0x3C) return '';
      await file.writeAsBytes(bytes, flush: true);
      return path;
    } on Object {
      return '';
    }
  }

  /// 收藏成功后调用：异步缓存图片并把 localPath 写回收藏记录（best-effort）。
  ///
  /// 缓存完成时发现收藏已被取消（竞态）→ 本地文件一并清理。
  Future<void> attachLocalCache(String imageUrl, {String? referer}) async {
    final String path = await cacheLocally(imageUrl, referer: referer);
    if (path.isEmpty) return;
    try {
      final box = await _openBox();
      final Object? key = await _findKeyByUrl(box, imageUrl);
      if (key == null) {
        final File file = File(path);
        if (file.existsSync()) await file.delete();
        return;
      }
      final Object? raw = box.get(key);
      if (raw is! String || raw.isEmpty) return;
      final Map<String, dynamic> json =
          jsonDecode(raw) as Map<String, dynamic>;
      if ((json['localPath'] as String? ?? '').isNotEmpty) return;
      json['localPath'] = path;
      await box.put(key, jsonEncode(json));
    } on Object {
      // 忽略：图库展示回退网络 URL。
    }
  }

  /// 按图片地址删除本地缓存文件（记录已单独删除时兜底；文件缺失静默忽略）。
  Future<void> deleteLocalImage(String imageUrl) async {
    try {
      final String path = await _localPathFor(imageUrl);
      if (path.isEmpty) return;
      final File file = File(path);
      if (file.existsSync()) await file.delete();
    } on Object {
      // 忽略。
    }
  }
}

/// 收藏图展示地址：本地缓存文件存在 → 本地路径（离线可用、不受反盗链影响）；
/// 未缓存或文件缺失（用户手动清理）→ 回退原 imageUrl。
String imageFavoriteDisplayUrl(ImageFavorite f) {
  final String p = f.localPath;
  if (p.isNotEmpty && File(p).existsSync()) return p;
  return f.imageUrl;
}

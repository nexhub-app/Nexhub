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
library;

import 'dart:convert';

import 'package:hive/hive.dart';

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

  /// 创建时间（毫秒）。
  final int createdAt;

  const ImageFavorite({
    this.source = ImageFavoriteSource.comic,
    required this.comicId,
    required this.chapterIndex,
    required this.chapterTitle,
    required this.pageIndex,
    required this.imageUrl,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'source': source.apiName,
        'comicId': comicId,
        'chapterIndex': chapterIndex,
        'chapterTitle': chapterTitle,
        'pageIndex': pageIndex,
        'imageUrl': imageUrl,
        'createdAt': createdAt,
      };

  factory ImageFavorite.fromJson(Map<String, dynamic> json) {
    return ImageFavorite(
      source: ImageFavoriteSource.parse(json['source'] as String?),
      comicId: json['comicId'] as String? ?? '',
      chapterIndex: (json['chapterIndex'] as num?)?.toInt() ?? 0,
      chapterTitle: json['chapterTitle'] as String? ?? '',
      pageIndex: (json['pageIndex'] as num?)?.toInt() ?? 0,
      imageUrl: json['imageUrl'] as String? ?? '',
      createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
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

  /// 按复合 key 删除指定收藏图片。
  Future<void> remove(String key) async {
    final box = await _openBox();
    await box.delete(key);
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
      // 已收藏：删除。
      await box.delete(key);
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
      // 已收藏：删除。
      await box.delete(key);
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
}

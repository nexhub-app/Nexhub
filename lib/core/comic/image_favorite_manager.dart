/// 图片收藏管理器（REQ-C2 图片收藏图库）。
///
/// 镜像 [ComicBookmarkManager] 结构，按 作品 + 章节 + 页码 保存图片收藏到
/// Hive box `image_favorites`。支持添加 / 删除 / 切换 / 列出全部收藏，
/// 并按 createdAt 倒序返回（图库最新收藏在前）。
library;

import 'dart:convert';

import 'package:hive/hive.dart';

/// 单条收藏图片。
class ImageFavorite {
  /// 所属漫画 ID。
  final String comicId;

  /// 章节在 chapters 列表中的索引。
  final int chapterIndex;

  /// 章节标题（展示用）。
  final String chapterTitle;

  /// 页在章节中的索引（0 起）。
  final int pageIndex;

  /// 图片地址（URL 或本地路径）。
  final String imageUrl;

  /// 创建时间（毫秒）。
  final int createdAt;

  const ImageFavorite({
    required this.comicId,
    required this.chapterIndex,
    required this.chapterTitle,
    required this.pageIndex,
    required this.imageUrl,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'comicId': comicId,
        'chapterIndex': chapterIndex,
        'chapterTitle': chapterTitle,
        'pageIndex': pageIndex,
        'imageUrl': imageUrl,
        'createdAt': createdAt,
      };

  factory ImageFavorite.fromJson(Map<String, dynamic> json) {
    return ImageFavorite(
      comicId: json['comicId'] as String? ?? '',
      chapterIndex: (json['chapterIndex'] as num?)?.toInt() ?? 0,
      chapterTitle: json['chapterTitle'] as String? ?? '',
      pageIndex: (json['pageIndex'] as num?)?.toInt() ?? 0,
      imageUrl: json['imageUrl'] as String? ?? '',
      createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
    );
  }

  /// 复合 key：`comicId::chapterIndex::pageIndex`，唯一标识一条收藏图片
  /// （同一作品同一章同一页只保留一份）。
  String get key => '$comicId::$chapterIndex::$pageIndex';
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

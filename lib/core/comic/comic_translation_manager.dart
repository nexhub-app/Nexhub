/// 漫画页翻译缓存管理器（漫画翻译功能）。
///
/// 按 作品 + 章 + 页 + 目标语言 缓存单页的识别/译文区域列表到
/// Hive box `comic_translations`（JSON 字符串存储，免注册 TypeAdapter，
/// 对齐 [NovelTranslationManager] 的做法）。翻回已翻译页时直接命中缓存，
/// 不再重复请求 AI。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../ai/vision_translation_client.dart';

/// 单页翻译缓存记录。
class ComicPageTranslation {
  /// 页面图片 URL / 本地路径（与请求时一致，用于校验缓存对应同一页）。
  final String imageUrl;

  /// 目标语言标记（变更语言后旧缓存自然失效）。
  final String lang;

  /// 识别 + 翻译出的文字区域（坐标为千分比 0–1000）。
  final List<VisionTextSegment> segments;
  final int updatedAt;

  const ComicPageTranslation({
    required this.imageUrl,
    required this.lang,
    required this.segments,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'imageUrl': imageUrl,
        'lang': lang,
        'segments': <Map<String, dynamic>>[
          for (final s in segments) s.toJson(),
        ],
        'updatedAt': updatedAt,
      };

  factory ComicPageTranslation.fromJson(Map<String, dynamic> json) =>
      ComicPageTranslation(
        imageUrl: json['imageUrl'] as String? ?? '',
        lang: json['lang'] as String? ?? 'zh',
        segments: <VisionTextSegment>[
          for (final s in (json['segments'] as List<dynamic>? ??
              const <dynamic>[]))
            if (s is Map<String, dynamic>)
              VisionTextSegment.fromJson(s)
            else if (s is Map)
              VisionTextSegment.fromJson(s.cast<String, dynamic>()),
        ],
        updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
      );

  /// 页面是否确实无文字（空页缓存也要记录，避免重复请求）。
  bool get isEmptyPage => segments.isEmpty;
}

/// 漫画翻译缓存管理器——Hive box `comic_translations`，
/// 键 `comicId|chapterKey|pageIndex|lang`。
class ComicTranslationManager extends ChangeNotifier {
  ComicTranslationManager({Box<dynamic>? box}) : _box = box;

  static const String boxName = 'comic_translations';

  Box<dynamic>? _box;

  Future<void> init() async {
    if (_box != null) return;
    if (Hive.isBoxOpen(boxName)) {
      _box = Hive.box(boxName);
      return;
    }
    _box = await Hive.openBox(boxName);
  }

  Future<Box<dynamic>> _ensureBox() async {
    if (_box != null) return _box!;
    await init();
    return _box!;
  }

  /// 缓存键：章键允许为空（本地单文件模式无章节概念）。
  static String keyFor(
    String comicId,
    String chapterKey,
    int pageIndex, {
    String lang = 'zh',
  }) =>
      '$comicId|$chapterKey|$pageIndex|$lang';

  Future<void> save({
    required String comicId,
    required String chapterKey,
    required int pageIndex,
    required String lang,
    required ComicPageTranslation translation,
  }) async {
    final box = await _ensureBox();
    await box.put(
      keyFor(comicId, chapterKey, pageIndex, lang: lang),
      jsonEncode(translation.toJson()),
    );
    notifyListeners();
  }

  Future<ComicPageTranslation?> load({
    required String comicId,
    required String chapterKey,
    required int pageIndex,
    required String lang,
  }) async {
    final box = await _ensureBox();
    final raw =
        box.get(keyFor(comicId, chapterKey, pageIndex, lang: lang));
    if (raw is! String || raw.isEmpty) return null;
    try {
      return ComicPageTranslation.fromJson(
          jsonDecode(raw) as Map<String, dynamic>);
    } on Object {
      return null; // 损坏数据按无缓存处理。
    }
  }

  /// 清空某部作品的全部翻译缓存（语言切换后旧缓存自动失效，无需手动清理；
  /// 此接口供高级设置/调试使用）。
  Future<int> clearForComic(String comicId) async {
    final box = await _ensureBox();
    final keys = box.keys
        .whereType<String>()
        .where((k) => k.startsWith('$comicId|'))
        .toList();
    await box.deleteAll(keys);
    notifyListeners();
    return keys.length;
  }
}

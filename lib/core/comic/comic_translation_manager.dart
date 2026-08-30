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

  /// 缓存条数上限（B5）：save 后惰性裁剪，按 updatedAt 升序淘汰最旧条目，
  /// 防止长期使用磁盘无限膨胀。
  static const int defaultMaxEntries = 5000;

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

  /// 容量裁剪（B5）：按 updatedAt 升序淘汰超出 [maxEntries] 的最旧条目。
  /// 无时间戳的记录按 0 处理（最先淘汰）。返回删除条数。
  Future<int> trimToLimit(int maxEntries) async {
    if (maxEntries <= 0) return 0;
    final box = await _ensureBox();
    if (box.length <= maxEntries) return 0;
    final entries = <(String, int)>[];
    for (final key in box.keys) {
      if (key is! String) continue;
      final raw = box.get(key);
      int ts = 0;
      if (raw is String && raw.isNotEmpty) {
        try {
          ts = (jsonDecode(raw) as Map<String, dynamic>)['updatedAt'] as int? ??
              0;
        } on Object {
          ts = 0; // 损坏数据视为最旧，优先淘汰。
        }
      }
      entries.add((key, ts));
    }
    if (entries.length <= maxEntries) return 0;
    entries.sort((a, b) => a.$2.compareTo(b.$2));
    final victims = entries.take(entries.length - maxEntries).map((e) => e.$1).toList();
    await box.deleteAll(victims);
    notifyListeners();
    return victims.length;
  }

  /// 当前缓存条数（B5，设置页展示用；box 未打开返回 0）。
  int count() =>
      Hive.isBoxOpen(boxName) ? Hive.box(boxName).length : 0;

  /// 清空全部缓存（B5 设置页「清除翻译缓存」入口）。返回删除条数。
  Future<int> clearAll() async {
    final box = await _ensureBox();
    final n = box.length;
    await box.clear();
    notifyListeners();
    return n;
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

  // ── F10 翻译缓存导出 / 导入（translations.json，跨设备复用不再计费）──

  /// 从缓存键解析四段标识（comicId|chapterKey|pageIndex|lang）。
  ///
  /// chapterKey 自身可能含 `|`，按「首段=comicId、末两段=pageIndex/lang、
  /// 中间整体=chapterKey」从两端解析。
  static (String comicId, String chapterKey, int pageIndex, String lang)?
      _parseKey(String key) {
    final parts = key.split('|');
    if (parts.length < 4) return null;
    final lang = parts.last;
    final pageIndex = int.tryParse(parts[parts.length - 2]);
    if (pageIndex == null) return null;
    final comicId = parts.first;
    final chapterKey = parts.sublist(1, parts.length - 2).join('|');
    return (comicId, chapterKey, pageIndex, lang);
  }

  /// 导出全部漫画翻译缓存为 JSON 字符串（按作品分块）：
  /// `{"version":1,"comics":{"<comicId>":{"pages":[{chapterKey,pageIndex,
  /// imageUrl,lang,segments,updatedAt}]}}}`。
  Future<String> exportJson() async {
    final box = await _ensureBox();
    final comics = <String, List<Map<String, dynamic>>>{};
    for (final key in box.keys) {
      if (key is! String) continue;
      final parsed = _parseKey(key);
      if (parsed == null) continue;
      final raw = box.get(key);
      if (raw is! String || raw.isEmpty) continue;
      try {
        final t =
            ComicPageTranslation.fromJson(jsonDecode(raw) as Map<String, dynamic>);
        comics
            .putIfAbsent(parsed.$1, () => <Map<String, dynamic>>[])
            .add(<String, dynamic>{
          'chapterKey': parsed.$2,
          'pageIndex': parsed.$3,
          'lang': parsed.$4,
          'imageUrl': t.imageUrl,
          'segments': <Map<String, dynamic>>[
            for (final s in t.segments) s.toJson(),
          ],
          'updatedAt': t.updatedAt,
        });
      } on Object {
        // 损坏数据忽略。
      }
    }
    return jsonEncode(<String, dynamic>{
      'version': 1,
      'comics': comics,
    });
  }

  /// 导入漫画翻译缓存（合并策略：已存在的缓存键跳过，不覆盖不重复请求）。
  /// 返回 (导入条数, 跳过条数)。格式非法时抛 [FormatException]。
  Future<(int, int)> importJson(String raw) async {
    final box = await _ensureBox();
    final dynamic decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('翻译数据格式应为对象');
    }
    final comics = decoded['comics'];
    if (comics is! Map<String, dynamic>) {
      throw const FormatException('缺少 comics 字段');
    }
    var imported = 0;
    var skipped = 0;
    for (final entry in comics.entries) {
      final comicId = entry.key;
      final pages = entry.value;
      if (pages is! List) continue;
      for (final page in pages) {
        if (page is! Map) continue;
        final m = page.cast<String, dynamic>();
        final chapterKey = m['chapterKey'] as String? ?? '';
        final pageIndex = (m['pageIndex'] as num?)?.toInt();
        final lang = m['lang'] as String? ?? 'zh';
        if (pageIndex == null) continue;
        final key = keyFor(comicId, chapterKey, pageIndex, lang: lang);
        if (box.containsKey(key)) {
          skipped++;
          continue;
        }
        final segments = <VisionTextSegment>[
          for (final s in (m['segments'] as List<dynamic>? ?? const <dynamic>[]))
            if (s is Map<String, dynamic>) VisionTextSegment.fromJson(s),
        ];
        final t = ComicPageTranslation(
          imageUrl: m['imageUrl'] as String? ?? '',
          lang: lang,
          segments: segments,
          updatedAt: (m['updatedAt'] as num?)?.toInt() ?? 0,
        );
        await box.put(key, jsonEncode(t.toJson()));
        imported++;
      }
    }
    if (imported > 0) notifyListeners();
    return (imported, skipped);
  }
}

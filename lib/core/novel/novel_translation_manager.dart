/// 小说段落翻译缓存管理器（O3 / F5）。
///
/// 按 书 + 章 + 目标语言 缓存整章译文（与原始文本块索引对齐的字符串列表）
/// 到 Hive box `novel_translations`。阅读器双语面板读取展示；导出层
/// （[F5] 翻译缓存随导出附带）按书枚举生成附录。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

/// 单条章节翻译缓存记录。
class NovelChapterTranslation {
  final String novelId;
  final String chapterId;
  final String chapterTitle;

  /// 目标语言标记（默认 `zh`；语言变更时旧缓存自然失效）。
  final String lang;

  /// 与章节文本块索引对齐的译文列表。
  final List<String> translations;

  /// 与 [translations] 对齐的原文列表（F5/F10：润色对照、审查证据、
  /// 双语导出用；旧缓存无此字段为 null，导出按「译文优先」降级）。
  final List<String>? sources;
  final int updatedAt;

  const NovelChapterTranslation({
    required this.novelId,
    required this.chapterId,
    required this.chapterTitle,
    required this.lang,
    required this.translations,
    this.sources,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'novelId': novelId,
        'chapterId': chapterId,
        'chapterTitle': chapterTitle,
        'lang': lang,
        'translations': translations,
        if (sources != null) 'sources': sources,
        'updatedAt': updatedAt,
      };

  factory NovelChapterTranslation.fromJson(Map<String, dynamic> json) =>
      NovelChapterTranslation(
        novelId: json['novelId'] as String? ?? '',
        chapterId: json['chapterId'] as String? ?? '',
        chapterTitle: json['chapterTitle'] as String? ?? '',
        lang: json['lang'] as String? ?? 'zh',
        translations: <String>[
          for (final t in (json['translations'] as List<dynamic>? ??
              const <dynamic>[]))
            t as String? ?? '',
        ],
        sources: (json['sources'] as List<dynamic>?)?.cast<String>(),
        updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
      );
}

/// 翻译缓存管理器——Hive box `novel_translations`，键 `novelId|chapterId|lang`。
class NovelTranslationManager extends ChangeNotifier {
  NovelTranslationManager({Box<dynamic>? box}) : _box = box;

  static const String boxName = 'novel_translations';
  static const String defaultLang = 'zh';

  /// 缓存条数上限（B5）：save 后惰性裁剪，按 updatedAt 升序淘汰最旧条目。
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

  static String keyFor(String novelId, String chapterId,
          {String lang = defaultLang}) =>
      '$novelId|$chapterId|$lang';

  // ── F4 断点续译：分块检查点 ──

  /// 检查点键后缀（与正式缓存同 box，避免导出/展示把半成品当完整章节）。
  static const String checkpointSuffix = '|checkpoint';

  static String checkpointKeyFor(String novelId, String chapterId,
          {String lang = defaultLang}) =>
      '${keyFor(novelId, chapterId, lang: lang)}$checkpointSuffix';

  /// 保存分块检查点（译文列表可含空串 = 未完成段）。
  ///
  /// 原子写：先落临时键、成功后替换正式键、再删临时键——任一环节中断
  /// 都不会把半块数据暴露给读取方。
  Future<void> saveCheckpoint(NovelChapterTranslation t) async {
    final box = await _ensureBox();
    final key = checkpointKeyFor(t.novelId, t.chapterId, lang: t.lang);
    final value = jsonEncode(t.toJson());
    await box.put('$key|tmp', value);
    await box.put(key, value);
    await box.delete('$key|tmp');
  }

  /// 读取分块检查点；无检查点返回 null。
  Future<NovelChapterTranslation?> loadCheckpoint(String novelId,
      String chapterId, {String lang = defaultLang}) async {
    final box = await _ensureBox();
    final raw =
        box.get(checkpointKeyFor(novelId, chapterId, lang: lang));
    if (raw is! String || raw.isEmpty) return null;
    try {
      return NovelChapterTranslation.fromJson(
          jsonDecode(raw) as Map<String, dynamic>);
    } on Object {
      return null;
    }
  }

  /// 清除分块检查点（完整译文落盘后调用；也可用于放弃续译）。
  Future<void> clearCheckpoint(String novelId, String chapterId,
      {String lang = defaultLang}) async {
    final box = await _ensureBox();
    final key = checkpointKeyFor(novelId, chapterId, lang: lang);
    await box.delete(key);
    await box.delete('$key|tmp');
  }

  /// 章节是否存在未完成的检查点（翻译面板入口提示用）。
  Future<bool> hasCheckpoint(String novelId, String chapterId,
      {String lang = defaultLang}) async {
    final box = await _ensureBox();
    return box.containsKey(checkpointKeyFor(novelId, chapterId, lang: lang));
  }

  // ── F5 多阶段质量：润色独立槽位 ──

  /// 润色结果键前缀（独立于初译缓存；重译章节后旧润色结果失效删除）。
  static const String polishedSuffix = '|polished';

  static String polishedKeyFor(String novelId, String chapterId,
          {String lang = defaultLang}) =>
      '${keyFor(novelId, chapterId, lang: lang)}$polishedSuffix';

  /// 保存章节润色结果（与初译分段对齐）。
  Future<void> savePolished(NovelChapterTranslation t) async {
    final box = await _ensureBox();
    await box.put(polishedKeyFor(t.novelId, t.chapterId, lang: t.lang),
        jsonEncode(t.toJson()));
    notifyListeners();
  }

  /// 读取章节润色结果；无润色记录返回 null。
  Future<NovelChapterTranslation?> loadPolished(String novelId,
      String chapterId, {String lang = defaultLang}) async {
    final box = await _ensureBox();
    final raw = box.get(polishedKeyFor(novelId, chapterId, lang: lang));
    if (raw is! String || raw.isEmpty) return null;
    try {
      return NovelChapterTranslation.fromJson(
          jsonDecode(raw) as Map<String, dynamic>);
    } on Object {
      return null;
    }
  }

  /// 清除章节润色结果（章节重译后旧润色失效）。
  Future<void> clearPolished(String novelId, String chapterId,
      {String lang = defaultLang}) async {
    final box = await _ensureBox();
    await box.delete(polishedKeyFor(novelId, chapterId, lang: lang));
    notifyListeners();
  }

  /// 枚举有章节译文的全部作品（去重），供翻译审查入口（F5）。
  Future<List<String>> listNovelIds() async {
    final box = await _ensureBox();
    final ids = <String>{};
    for (final key in box.keys) {
      if (key is! String) continue;
      if (key.endsWith(checkpointSuffix) ||
          key.endsWith('|tmp') ||
          key.endsWith(polishedSuffix)) {
        continue;
      }
      final raw = box.get(key);
      if (raw is! String || raw.isEmpty) continue;
      try {
        final t = NovelChapterTranslation.fromJson(
            jsonDecode(raw) as Map<String, dynamic>);
        if (t.novelId.isNotEmpty) ids.add(t.novelId);
      } on Object {
        // 损坏数据忽略。
      }
    }
    final result = ids.toList()..sort();
    return result;
  }

  Future<void> save(NovelChapterTranslation t) async {
    final box = await _ensureBox();
    await box.put(keyFor(t.novelId, t.chapterId, lang: t.lang),
        jsonEncode(t.toJson()));
    // B5：保存后惰性裁剪，防止长期使用磁盘无限膨胀。
    unawaited(trimToLimit(defaultMaxEntries));
    notifyListeners();
  }

  Future<NovelChapterTranslation?> load(String novelId, String chapterId,
      {String lang = defaultLang}) async {
    final box = await _ensureBox();
    final raw = box.get(keyFor(novelId, chapterId, lang: lang));
    if (raw is! String || raw.isEmpty) return null;
    try {
      return NovelChapterTranslation.fromJson(
          jsonDecode(raw) as Map<String, dynamic>);
    } on Object {
      return null; // 损坏数据按无缓存处理。
    }
  }

  Future<void> remove(String novelId, String chapterId,
      {String lang = defaultLang}) async {
    final box = await _ensureBox();
    await box.delete(keyFor(novelId, chapterId, lang: lang));
    notifyListeners();
  }

  /// 枚举某本书全部有译文的章节（按更新时间倒序），供导出附带（F5）。
  ///
  /// F4 检查点键（`…|checkpoint` / `…|tmp`）不属于完整章节译文，跳过。
  Future<List<NovelChapterTranslation>> listForNovel(String novelId,
      {String lang = defaultLang}) async {
    final box = await _ensureBox();
    final result = <NovelChapterTranslation>[];
    for (final key in box.keys) {
      if (key is String &&
          (key.endsWith(checkpointSuffix) ||
              key.endsWith('|tmp') ||
              key.endsWith(polishedSuffix))) {
        continue;
      }
      final raw = box.get(key);
      if (raw is! String || raw.isEmpty) continue;
      try {
        final t =
            NovelChapterTranslation.fromJson(jsonDecode(raw) as Map<String, dynamic>);
        if (t.novelId == novelId && t.lang == lang && t.translations.isNotEmpty) {
          result.add(t);
        }
      } on Object {
        // 损坏数据忽略。
      }
    }
    result.sort((a, b) => a.chapterTitle.compareTo(b.chapterTitle));
    return result;
  }

  /// 当前缓存条数（B5，设置页展示用；box 未打开返回 0）。
  int count() => Hive.isBoxOpen(boxName) ? Hive.box(boxName).length : 0;

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
          ts = (jsonDecode(raw) as Map<String, dynamic>)['updatedAt'] as int? ?? 0;
        } on Object {
          ts = 0; // 损坏数据视为最旧，优先淘汰。
        }
      }
      entries.add((key, ts));
    }
    if (entries.length <= maxEntries) return 0;
    entries.sort((a, b) => a.$2.compareTo(b.$2));
    final victims =
        entries.take(entries.length - maxEntries).map((e) => e.$1).toList();
    await box.deleteAll(victims);
    notifyListeners();
    return victims.length;
  }

  /// 清空全部缓存（B5 设置页「清除翻译缓存」入口）。返回删除条数。
  Future<int> clearAll() async {
    final box = await _ensureBox();
    final n = box.length;
    await box.clear();
    notifyListeners();
    return n;
  }
}

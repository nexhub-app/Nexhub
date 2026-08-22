/// 小说划线 / 高亮 / 摘录管理器（P1-5）。
///
/// 按书 + 章节保存划线到 Hive box `novel_highlights`。
/// 锚点模型（对标 P2-11）：每条划线存「选中文本 quote + 前后各 ≤48 字符上下文
/// contextBefore/contextAfter」+ 颜色 + 可选笔记；重开阅读器时由选区控制器按
/// 上下文打分重定位（仅接受唯一最高分），使划线在换排版/换源后仍能就近归位。
///
/// 结构镜像 [NovelBookmarkManager]（`novel_bookmarks`），保持一致性。
library;

import 'dart:convert';

import 'package:hive/hive.dart';

/// 单条划线（高亮 / 摘录）。
class NovelHighlight {
  /// 所属小说 ID。
  final String novelId;

  /// 章节在 chapters 列表中的索引。
  final int chapterIndex;

  /// 章节 ID（便于跨页恢复时定位）。
  final String chapterId;

  /// 章节标题（展示用）。
  final String chapterTitle;

  /// 选中文本（划线原文）。
  final String quote;

  /// 选中文本前 ≤48 字符上下文（重定位锚点）。
  final String contextBefore;

  /// 选中文本后 ≤48 字符上下文（重定位锚点）。
  final String contextAfter;

  /// 高亮色（ARGB int）。
  final int color;

  /// 可选笔记 / 摘录。
  final String? note;

  /// 创建时间（毫秒）。
  final int createdAt;

  const NovelHighlight({
    required this.novelId,
    required this.chapterIndex,
    required this.chapterId,
    required this.chapterTitle,
    required this.quote,
    required this.contextBefore,
    required this.contextAfter,
    required this.color,
    required this.createdAt,
    this.note,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'novelId': novelId,
        'chapterIndex': chapterIndex,
        'chapterId': chapterId,
        'chapterTitle': chapterTitle,
        'quote': quote,
        'contextBefore': contextBefore,
        'contextAfter': contextAfter,
        'color': color,
        'createdAt': createdAt,
        if (note != null) 'note': note,
      };

  factory NovelHighlight.fromJson(Map<String, dynamic> json) {
    return NovelHighlight(
      novelId: json['novelId'] as String? ?? '',
      chapterIndex: (json['chapterIndex'] as num?)?.toInt() ?? 0,
      chapterId: json['chapterId'] as String? ?? '',
      chapterTitle: json['chapterTitle'] as String? ?? '',
      quote: json['quote'] as String? ?? '',
      contextBefore: json['contextBefore'] as String? ?? '',
      contextAfter: json['contextAfter'] as String? ?? '',
      color: (json['color'] as num?)?.toInt() ?? 0xFFFFFF00,
      createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
      note: json['note'] as String?,
    );
  }

  /// 复合 key：`novelId::chapterIndex::createdAt`，唯一标识一条划线。
  String get key => '$novelId::$chapterIndex::$createdAt';
}

/// 划线管理器——使用 Hive box `novel_highlights`。
class NovelHighlightManager {
  NovelHighlightManager({Box<dynamic>? box}) : _box = box;

  /// Hive box 名。
  static const String boxName = 'novel_highlights';

  final Box<dynamic>? _box;

  /// 懒加载打开 box（如未在 splash 阶段预打开）。
  Future<Box<dynamic>> _openBox() async {
    if (_box != null) return _box;
    if (Hive.isBoxOpen(boxName)) return Hive.box(boxName);
    return Hive.openBox(boxName);
  }

  /// 添加一条划线，返回新建的划线。
  Future<NovelHighlight> add(NovelHighlight highlight) async {
    final box = await _openBox();
    await box.put(highlight.key, jsonEncode(highlight.toJson()));
    return highlight;
  }

  /// 删除指定划线。
  Future<void> remove(String key) async {
    final box = await _openBox();
    await box.delete(key);
  }

  /// 按复合 key 读取单条划线。
  Future<NovelHighlight?> getByKey(String key) async {
    final box = await _openBox();
    final raw = box.get(key);
    if (raw is! String || raw.isEmpty) return null;
    try {
      return NovelHighlight.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on Object {
      return null;
    }
  }

  /// 更新一条划线的笔记 / 颜色，写回 Hive。
  Future<NovelHighlight?> update({
    required String key,
    String? note,
    int? color,
  }) async {
    final existing = await getByKey(key);
    if (existing == null) return null;
    final updated = NovelHighlight(
      novelId: existing.novelId,
      chapterIndex: existing.chapterIndex,
      chapterId: existing.chapterId,
      chapterTitle: existing.chapterTitle,
      quote: existing.quote,
      contextBefore: existing.contextBefore,
      contextAfter: existing.contextAfter,
      color: color ?? existing.color,
      createdAt: existing.createdAt,
      note: note ?? existing.note,
    );
    final box = await _openBox();
    await box.put(key, jsonEncode(updated.toJson()));
    return updated;
  }

  /// 列出某本书的全部划线（按创建时间倒序）。
  Future<List<NovelHighlight>> listFor(String novelId) async {
    final box = await _openBox();
    final result = <NovelHighlight>[];
    for (final key in box.keys) {
      final raw = box.get(key);
      if (raw is! String || raw.isEmpty) continue;
      try {
        final hl = NovelHighlight.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
        if (hl.novelId == novelId) result.add(hl);
      } on Object {
        // 损坏数据忽略
      }
    }
    result.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return result;
  }

  /// 列出某本书某章节的划线（按章节内出现顺序由调用方再排）。
  Future<List<NovelHighlight>> listForChapter(
    String novelId,
    int chapterIndex,
  ) async {
    final all = await listFor(novelId);
    return all.where((h) => h.chapterIndex == chapterIndex).toList();
  }
}

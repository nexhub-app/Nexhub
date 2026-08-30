/// 全书预扫描持久化（F3：章节摘要 + 全书概述注入）。
///
/// 按 书 + 语言 维度把预扫描产物存到 Hive box `novel_prescans`：
/// - 每章 1–2 句摘要（按章落盘，中断可续）；
/// - 全书概述（约 200 字，全部章节摘要完成后汇总生成）；
/// - 作品更新（章节列表变化）时按 chapterId 保留仍然有效的摘要、概述失效。
///
/// 注入格式见 [novelBookContext]；摘要生成走 features/novel/domain 的
/// 预扫描服务（本文件不依赖 feature 层）。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

/// 单章摘要。
class NovelPrescanChapterSummary {
  final String chapterId;
  final String title;
  final String summary;

  const NovelPrescanChapterSummary({
    required this.chapterId,
    required this.title,
    required this.summary,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'chapterId': chapterId,
        'title': title,
        'summary': summary,
      };

  factory NovelPrescanChapterSummary.fromJson(Map<String, dynamic> json) =>
      NovelPrescanChapterSummary(
        chapterId: json['chapterId'] as String? ?? '',
        title: json['title'] as String? ?? '',
        summary: json['summary'] as String? ?? '',
      );
}

/// 一本书的预扫描产物。
class NovelPrescanData {
  final String novelId;
  final String lang;
  final String novelTitle;
  final List<NovelPrescanChapterSummary> chapters;

  /// 全书概述；null = 尚未生成（章节全部完成后汇总）。
  final String? overview;
  final int updatedAt;

  const NovelPrescanData({
    required this.novelId,
    required this.lang,
    required this.novelTitle,
    required this.chapters,
    this.overview,
    required this.updatedAt,
  });

  NovelPrescanChapterSummary? summaryFor(String chapterId) {
    for (final c in chapters) {
      if (c.chapterId == chapterId) return c;
    }
    return null;
  }

  /// 章节摘要是否全部完成。
  bool get chaptersComplete => chapters.isNotEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'novelId': novelId,
        'lang': lang,
        'novelTitle': novelTitle,
        'chapters': <Map<String, dynamic>>[
          for (final c in chapters) c.toJson(),
        ],
        if (overview != null) 'overview': overview,
        'updatedAt': updatedAt,
      };

  factory NovelPrescanData.fromJson(Map<String, dynamic> json) =>
      NovelPrescanData(
        novelId: json['novelId'] as String? ?? '',
        lang: json['lang'] as String? ?? 'zh',
        novelTitle: json['novelTitle'] as String? ?? '',
        chapters: <NovelPrescanChapterSummary>[
          for (final c in (json['chapters'] as List<dynamic>? ??
              const <dynamic>[]))
            if (c is Map<String, dynamic>)
              NovelPrescanChapterSummary.fromJson(c),
        ],
        overview: json['overview'] as String?,
        updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
      );

  NovelPrescanData copyWith({
    String? novelTitle,
    List<NovelPrescanChapterSummary>? chapters,
    String? overview,
    bool clearOverview = false,
    int? updatedAt,
  }) =>
      NovelPrescanData(
        novelId: novelId,
        lang: lang,
        novelTitle: novelTitle ?? this.novelTitle,
        chapters: chapters ?? this.chapters,
        overview: clearOverview ? null : (overview ?? this.overview),
        updatedAt: updatedAt ?? this.updatedAt,
      );
}

/// 预扫描管理器——Hive box `novel_prescans`，键 `novelId|lang`。
class NovelPrescanManager extends ChangeNotifier {
  NovelPrescanManager({Box<dynamic>? box}) : _box = box;

  static const String boxName = 'novel_prescans';

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

  static String keyFor(String novelId, String lang) => '$novelId|$lang';

  Future<NovelPrescanData?> load(String novelId, {String lang = 'zh'}) async {
    final box = await _ensureBox();
    final raw = box.get(keyFor(novelId, lang));
    if (raw is! String || raw.isEmpty) return null;
    try {
      return NovelPrescanData.fromJson(
          jsonDecode(raw) as Map<String, dynamic>);
    } on Object {
      return null; // 损坏数据按未扫描处理。
    }
  }

  Future<void> save(NovelPrescanData data) async {
    final box = await _ensureBox();
    await box.put(keyFor(data.novelId, data.lang), jsonEncode(data.toJson()));
    notifyListeners();
  }

  Future<void> remove(String novelId, {String lang = 'zh'}) async {
    final box = await _ensureBox();
    await box.delete(keyFor(novelId, lang));
    notifyListeners();
  }

  /// 作品更新后合并旧摘要：按 chapterId 保留仍有效的章节摘要、概述失效。
  NovelPrescanData mergeWithCurrentChapters({
    required NovelPrescanData existing,
    required String novelTitle,
    required List<({String id, String title})> currentChapters,
  }) {
    final kept = <NovelPrescanChapterSummary>[
      for (final c in currentChapters)
        if (existing.summaryFor(c.id) != null)
          existing.summaryFor(c.id)!,
    ];
    return existing.copyWith(
      novelTitle: novelTitle,
      chapters: kept,
      clearOverview: true,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// 组装注入提示词的作品语境（F3）：《书名》概述 + 本章摘要。
  /// 无可用语境时返回 null。
  static String? novelBookContext(
    NovelPrescanData? data,
    String chapterId,
  ) {
    if (data == null) return null;
    final buf = StringBuffer();
    final overview = data.overview?.trim();
    if (overview != null && overview.isNotEmpty) {
      buf.write('《${data.novelTitle}》概述：$overview');
    }
    final chapter = data.summaryFor(chapterId);
    if (chapter != null && chapter.summary.trim().isNotEmpty) {
      if (buf.isNotEmpty) buf.write('。');
      buf.write('本章前情：${chapter.summary.trim()}');
    }
    final s = buf.toString();
    return s.isEmpty ? null : s;
  }
}

/// 漫画阅读进度管理（按 comicId 持久化）。
///
/// 记录当前章节与页码；切章节时同步 [lastReadChapterIndex]，供书架「续读」使用。
/// 同时维护「每章页码」表（[ReadingProgress.chapterPages]），供「回到上一话」
/// 等跨章导航恢复到上次离开该话时读到的页（连续阅读）。
library;

import 'dart:convert';

import 'models/reader_preferences.dart';

/// 单部作品的阅读进度。
class ReadingProgress {
  final String chapterId;
  final int currentPage;
  final int chapterIndex;
  final int? totalChapters;

  /// 每章页码（key = 章节索引字符串）：记录「在该章读到的最后一页」。
  /// 用于回到上一话时恢复到离开页，而非固定首页/末页。
  final Map<String, int> chapterPages;

  const ReadingProgress({
    required this.chapterId,
    required this.currentPage,
    required this.chapterIndex,
    this.totalChapters,
    this.chapterPages = const <String, int>{},
  });

  factory ReadingProgress.fromJson(Map<String, dynamic> json) {
    final Map<String, int> pages = <String, int>{};
    final dynamic raw = json['chapterPages'];
    if (raw is Map<String, dynamic>) {
      for (final MapEntry<String, dynamic> e in raw.entries) {
        final int v = e.value is num ? (e.value as num).toInt() : -1;
        if (v >= 0) pages[e.key] = v;
      }
    }
    return ReadingProgress(
      chapterId: json['chapterId'] as String? ?? '',
      currentPage: json['currentPage'] as int? ?? 0,
      chapterIndex: json['chapterIndex'] as int? ?? 0,
      totalChapters: json['totalChapters'] as int?,
      chapterPages: pages,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'chapterId': chapterId,
        'currentPage': currentPage,
        'chapterIndex': chapterIndex,
        'totalChapters': totalChapters,
        'chapterPages': chapterPages,
      };

  ReadingProgress copyWith({Map<String, int>? chapterPages}) => ReadingProgress(
        chapterId: chapterId,
        currentPage: currentPage,
        chapterIndex: chapterIndex,
        totalChapters: totalChapters,
        chapterPages: chapterPages ?? this.chapterPages,
      );
}

/// 进度存储（可注入后端：默认 shared_preferences，测试用内存后端）。
class ComicProgressManager {
  ComicProgressManager({PrefsBackend? backend})
      : _backend = backend ?? const SharedPrefsBackend();

  final PrefsBackend _backend;
  final Map<String, ReadingProgress> _cache = {};

  static const String _prefix = 'comic_progress_';

  /// 读取进度（无记录返回 null）。
  Future<ReadingProgress?> get(String comicId) async {
    final cached = _cache[comicId];
    if (cached != null) return cached;
    final raw = await _backend.get('$_prefix$comicId');
    if (raw == null || raw.isEmpty) return null;
    try {
      final p = ReadingProgress.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      _cache[comicId] = p;
      return p;
    } on Object {
      return null;
    }
  }

  /// 保存进度（同步 lastReadChapterIndex）。
  Future<void> save(
    String comicId,
    String chapterId,
    int currentPage,
    int chapterIndex, {
    int? totalChapters,
  }) async {
    final p = ReadingProgress(
      chapterId: chapterId,
      currentPage: currentPage,
      chapterIndex: chapterIndex,
      totalChapters: totalChapters ?? _cache[comicId]?.totalChapters,
      // 保留既有每章页码表；当前章的页随单条记录一并刷新。
      chapterPages: Map<String, int>.of(_cache[comicId]?.chapterPages ?? const {}),
    );
    _cache[comicId] = p;
    await _backend.set(_prefix + comicId, jsonEncode(p.toJson()));
  }

  /// 记录「某章读到的页」（供回到上一话恢复离开页）。不改变最近章+页的单条记录。
  Future<void> saveChapterPage(
    String comicId,
    int chapterIndex,
    int page,
  ) async {
    final ReadingProgress? cur = await get(comicId);
    final Map<String, int> pages =
        Map<String, int>.of(cur?.chapterPages ?? const {});
    pages['$chapterIndex'] = page;
    final ReadingProgress base = cur ?? const ReadingProgress(
      chapterId: '',
      currentPage: 0,
      chapterIndex: 0,
    );
    final p = base.copyWith(chapterPages: pages);
    _cache[comicId] = p;
    await _backend.set(_prefix + comicId, jsonEncode(p.toJson()));
  }

  /// 读取某章读到的页；该章无记录返回 null。
  Future<int?> getChapterPage(String comicId, int chapterIndex) async {
    final ReadingProgress? cur = await get(comicId);
    if (cur == null) return null;
    final int? v = cur.chapterPages['$chapterIndex'];
    return v;
  }

  /// 清除进度（如移除书架）。
  Future<void> clear(String comicId) async {
    _cache.remove(comicId);
    await _backend.set('$_prefix$comicId', '');
  }
}

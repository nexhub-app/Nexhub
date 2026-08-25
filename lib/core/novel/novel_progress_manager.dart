/// 小说阅读进度管理（按 novelId 持久化）。
///
/// 镜像 [ComicProgressManager] 结构，记录当前章节与页码；
/// 切章节时同步 lastReadChapterIndex，供书架「续读」使用。
library;

import 'dart:convert';

import '../comic/models/reader_preferences.dart' show PrefsBackend, SharedPrefsBackend;

/// 单部小说的阅读进度。
class NovelReadingProgress {
  final String chapterId;
  final int currentPage;
  final int? charOffset;
  final int chapterIndex;
  final int? totalChapters;

  const NovelReadingProgress({
    required this.chapterId,
    required this.currentPage,
    this.charOffset,
    required this.chapterIndex,
    this.totalChapters,
  });

  factory NovelReadingProgress.fromJson(Map<String, dynamic> json) =>
      NovelReadingProgress(
        chapterId: json['chapterId'] as String? ?? '',
        currentPage: json['currentPage'] as int? ?? 0,
        charOffset: json['charOffset'] as int?,
        chapterIndex: json['chapterIndex'] as int? ?? 0,
        totalChapters: json['totalChapters'] as int?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'chapterId': chapterId,
        'currentPage': currentPage,
        'charOffset': charOffset,
        'chapterIndex': chapterIndex,
        'totalChapters': totalChapters,
      };
}

/// 小说进度存储（可注入后端：默认 shared_preferences，测试用内存后端）。
class NovelProgressManager {
  NovelProgressManager({PrefsBackend? backend})
      : _backend = backend ?? const SharedPrefsBackend();

  final PrefsBackend _backend;
  final Map<String, NovelReadingProgress> _cache = {};

  /// 进度存储键前缀（P2-8 云同步枚举本地全部进度用）。
  static const String prefix = 'novel_progress_';

  /// 读取进度（无记录返回 null）。
  Future<NovelReadingProgress?> get(String novelId) async {
    final cached = _cache[novelId];
    if (cached != null) return cached;
    final raw = await _backend.get('${prefix}$novelId');
    if (raw == null || raw.isEmpty) return null;
    try {
      return NovelReadingProgress.fromJson(
          jsonDecode(raw) as Map<String, dynamic>);
    } on Object {
      return null;
    }
  }

  /// 保存进度。
  Future<void> save(
    String novelId,
    String chapterId,
    int currentPage,
    int chapterIndex, {
    int? charOffset,
    int? totalChapters,
  }) async {
    final p = NovelReadingProgress(
      chapterId: chapterId,
      currentPage: currentPage,
      charOffset: charOffset,
      chapterIndex: chapterIndex,
      // 未显式传入时使用已缓存的总章数，避免章节切换时清掉总数。
      totalChapters: totalChapters ?? _cache[novelId]?.totalChapters,
    );
    _cache[novelId] = p;
    await _backend.set('${prefix}$novelId', jsonEncode(p.toJson()));
  }

  /// 清除进度（如移除书架）。
  Future<void> clear(String novelId) async {
    _cache.remove(novelId);
    await _backend.set('${prefix}$novelId', '');
  }
}

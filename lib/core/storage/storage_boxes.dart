/// 全应用持久化 box 单一事实源（SSOT）。
///
/// 任何需要"打开哪些 Hive box / 备份哪些 box"的代码都必须从这里读，
/// 避免历史上 `_exportToArchive` 白名单漏 box 导致用户备份丢一半的 bug
/// （参见 2026-08-02 修复：原白名单仅 11 个，splash 实际打开 20 个，漏 9 个：
/// sources / download_tasks / danmaku_cache / settings / source_mirrors /
/// chapter_fetch_times / bangumi_subject_links / source_library_bookmarks /
/// source_library_subs —— 这些 box 一旦用户备份就丢，恢复后看不到源/下载/设置等）。
///
/// 新增 box 时**只在这一个常量里加一行**，splash 启动与云同步自动覆盖。
library;

import '../comic/image_favorite_manager.dart';
import '../services/bangumi/subject_link_store.dart';
import '../services/source_library_bookmarks.dart';
import '../services/source_library_subscription.dart';
import '../stats/stats_box.dart';

/// 应用冷启动时打开的全部 Hive box 名称（与 [SplashScreen._initialize]
/// 的 `Future.wait([Hive.openBox(...)])` 一一对应）。
///
/// ⚠️ 顺序不敏感（Hive.openBox 互不依赖），但请保持与 splash 一致便于审阅。
const List<String> kStorageBoxNames = <String>[
  'sources',
  'favorites',
  'media_progress',
  'comic_progress',
  'novel_progress',
  'download_tasks',
  'danmaku_cache',
  'book_sources',
  'rss_feeds',
  'article_feeds',
  'settings',
  'novel_bookmarks',
  'novel_highlights',
  'comic_bookmarks',
  // 漫画阅读器收藏的图片（图库页数据，REQ-C2）
  ImageFavoriteManager.boxName, // 'image_favorites'
  'media_watched',
  'media_playback_position',
  'source_mirrors',
  'chapter_fetch_times',
  // 命名常量由对应类的 boxName 静态字段提供（保持类型安全，避免硬编码漂移）。
  SubjectLinkStore.boxName, // 'bangumi_subject_links'
  SourceLibraryBookmarks.boxName, // 'source_library_bookmarks'
  SourceLibrarySubscription.boxName, // 'source_library_subs',
  // 阅读/观看统计（按作品聚合 + 按天聚合）
  kReadingStatsBoxName, // 'reading_stats_v1'
  kReadingDailyBoxName, // 'reading_daily_v1'
];

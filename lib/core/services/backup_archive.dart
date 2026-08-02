/// 统一备份归档模块 —— 本地文件导入/导出与云同步共用的底层能力。
///
/// 之前两套机制不一致：本地导入/导出只处理 plugins/favorites/history 三类
/// （[SourceRepository]/[FavoritesManager]/[HistoryManager] 各自 exportToJson），
/// 而云同步导出的是全部 Hive box（[kStorageBoxNames]）+ SharedPreferences 的 ZIP。
/// 这导致「本地备份」和「云备份」互不兼容、且本地备份丢了大量数据。
///
/// 本模块把归档逻辑统一为单一 bundle 结构：
/// ```json
/// {
///   "format": "nexhub-backup",
///   "version": 1,
///   "createdAt": 1700000000000,
///   "boxes": { "<boxName>": { "<key>": <value>, ... }, ... },
///   "preferences": { "<prefKey>": <value>, ... }   // 仅当选中「设置与偏好」
/// }
/// ```
/// 本地导出保存为单个 JSON 文件；云同步在 [CloudSyncService] 中把它再压成 ZIP。
/// 二者可互相导入。
library;

import 'dart:convert';

import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../storage/storage_boxes.dart';

/// 备份内容分类（用户可见粒度）。
enum BackupCategory {
  /// 源与订阅：书源 / 媒体源 / RSS / 文章源 / 镜像 / 章节抓取时间 / 库订阅书签。
  source,

  /// 收藏与书签：收藏 / 漫画书签 / 小说书签 / Bangumi 条目绑定。
  bookmark,

  /// 进度与历史：阅读 / 播放 / 观看进度与历史。
  progress,

  /// 设置与偏好：settings Hive box + 全部 SharedPreferences（播放器 / 阅读器 / 弹幕等）。
  settings,

  /// 下载任务。
  download,

  /// 弹幕缓存。
  danmaku,

  /// 其它未归类 box。
  other,
}

/// 各分类包含的 Hive box（[kStorageBoxNames] 的子集分组，单一事实源）。
const Map<BackupCategory, List<String>> kBackupCategoryBoxes =
    <BackupCategory, List<String>>{
  BackupCategory.source: <String>[
    'sources',
    'book_sources',
    'rss_feeds',
    'article_feeds',
    'source_mirrors',
    'chapter_fetch_times',
    'source_library_bookmarks',
    'source_library_subs',
  ],
  BackupCategory.bookmark: <String>[
    'favorites',
    'comic_bookmarks',
    'novel_bookmarks',
    'bangumi_subject_links',
  ],
  BackupCategory.progress: <String>[
    'media_progress',
    'comic_progress',
    'novel_progress',
    'media_watched',
    'media_playback_position',
  ],
  BackupCategory.settings: <String>[
    'settings',
  ],
  BackupCategory.download: <String>[
    'download_tasks',
  ],
  BackupCategory.danmaku: <String>[
    'danmaku_cache',
  ],
  BackupCategory.other: <String>[
    // 当前所有命名 box 均已归类；此处保留以便未来扩展。
  ],
};

/// bundle 结构标识。
const String kBackupFormat = 'nexhub-backup';
const int kBackupVersion = 1;

/// 把分类集合解析为需要导出的 box 名集合。
Set<String> resolveBoxNames(Set<BackupCategory> categories) {
  final names = <String>{};
  for (final c in categories) {
    names.addAll(kBackupCategoryBoxes[c] ?? const <String>[]);
  }
  return names;
}

/// 选中「设置与偏好」时一并导出 SharedPreferences。
bool _includesPreferences(Set<BackupCategory> categories) =>
    categories.contains(BackupCategory.settings);

dynamic _encodeHiveValue(dynamic v) {
  if (v == null) return null;
  if (v is String || v is num || v is bool) return v;
  if (v is List) return v.map(_encodeHiveValue).toList();
  if (v is Map) {
    return v.map((k, v) => MapEntry(k.toString(), _encodeHiveValue(v)));
  }
  try {
    final toJson = (v as dynamic).toJson;
    if (toJson != null) return toJson.call();
  } on Object {
    // 忽略：非自定义对象
  }
  return v.toString();
}

dynamic _decodeHiveValue(dynamic v) {
  if (v == null) return null;
  if (v is String || v is num || v is bool) return v;
  if (v is List) return v.map(_decodeHiveValue).toList();
  if (v is Map) {
    return v.map((k, v) => MapEntry(k, _decodeHiveValue(v)));
  }
  return v;
}

/// 构建备份 bundle（仅含选中分类的 box；选中设置时含 SharedPreferences）。
///
/// [categories] 为空集合时返回空 bundle（调用方应先校验非空）。
Future<Map<String, dynamic>> buildBackupBundle({
  required Set<BackupCategory> categories,
}) async {
  final boxNames = resolveBoxNames(categories);
  final hiveData = <String, dynamic>{};
  for (final name in boxNames) {
    if (!Hive.isBoxOpen(name)) continue;
    final box = Hive.box(name);
    hiveData[name] = box
        .toMap()
        .map((k, v) => MapEntry(k.toString(), _encodeHiveValue(v)));
  }
  final bundle = <String, dynamic>{
    'format': kBackupFormat,
    'version': kBackupVersion,
    'createdAt': DateTime.now().millisecondsSinceEpoch,
    'boxes': hiveData,
  };
  if (_includesPreferences(categories)) {
    final prefs = await SharedPreferences.getInstance();
    final prefsData = <String, dynamic>{};
    for (final key in prefs.getKeys()) {
      final v = prefs.get(key);
      if (v != null) prefsData[key] = v;
    }
    bundle['preferences'] = prefsData;
  }
  return bundle;
}

/// 统计 bundle 中待恢复的数据条数（各 box 条目数 + SharedPreferences 条目数）。
int countBundleEntries(Map<String, dynamic> bundle) {
  var total = 0;
  final boxes = bundle['boxes'];
  if (boxes is Map) {
    for (final entry in (boxes as Map<String, dynamic>).entries) {
      final data = entry.value;
      if (data is Map) total += data.length;
    }
  }
  final prefs = bundle['preferences'];
  if (prefs is Map) total += prefs.length;
  return total;
}

/// 将 bundle 应用到本地。
///
/// - [merge] = true：逐键写入（同名键以 bundle 为准，last-write-wins），保留本地其它键。
/// - [merge] = false：**覆盖**——先清空目标 box 再写入（SharedPreferences 仅写入备份中的键，不删其它）。
/// - [categories] 非空时只应用这些分类下的 box（其余 box 不受影响）。
Future<void> applyBackupBundle(
  Map<String, dynamic> bundle, {
  required bool merge,
  Set<BackupCategory>? categories,
}) async {
  final boxesRaw = bundle['boxes'];
  if (boxesRaw is Map<String, dynamic>) {
    final allowedBoxes =
        categories == null ? null : resolveBoxNames(categories);
    for (final entry in boxesRaw.entries) {
      final name = entry.key;
      if (allowedBoxes != null && !allowedBoxes.contains(name)) continue;
      final data = entry.value;
      if (data is! Map) continue;
      if (!Hive.isBoxOpen(name)) continue;
      final box = Hive.box(name);
      if (!merge) {
        try {
          await box.clear();
        } on Object {
          // 忽略清空失败（继续写入）
        }
      }
      for (final kv in data.entries) {
        try {
          await box.put(kv.key, _decodeHiveValue(kv.value));
        } on Object {
          // 跳过无法写入的条目
        }
      }
    }
  }

  final prefsRaw = bundle['preferences'];
  if (prefsRaw is Map<String, dynamic>) {
    if (categories != null && !categories.contains(BackupCategory.settings)) {
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    for (final entry in prefsRaw.entries) {
      final v = entry.value;
      try {
        if (v is String) {
          await prefs.setString(entry.key, v);
        } else if (v is int) {
          await prefs.setInt(entry.key, v);
        } else if (v is double) {
          await prefs.setDouble(entry.key, v);
        } else if (v is bool) {
          await prefs.setBool(entry.key, v);
        } else if (v is List) {
          await prefs.setStringList(
            entry.key,
            v.map((e) => e.toString()).toList(),
          );
        }
      } on Object {
        // 跳过无法写入的条目
      }
    }
  }
}

/// 校验 bundle 是否为本应用备份格式。
bool isValidBackupBundle(Map<String, dynamic>? bundle) {
  if (bundle == null) return false;
  return bundle['format'] == kBackupFormat && bundle['boxes'] is Map;
}

/// 把 bundle 序列化为带缩进的 JSON 字符串。
String encodeBackupBundle(Map<String, dynamic> bundle) =>
    const JsonEncoder.withIndent('  ').convert(bundle);

/// 解析备份 JSON 字符串；非 Map / 非本格式返回 null。
Map<String, dynamic>? decodeBackupBundle(String text) {
  try {
    final data = jsonDecode(text);
    if (data is Map<String, dynamic>) return data;
  } on Object {
    // 解析失败
  }
  return null;
}

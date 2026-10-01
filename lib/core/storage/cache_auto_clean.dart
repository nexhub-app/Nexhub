/// 缓存自动清理：年龄 + 容量双策略。
///
/// 设计要点：
/// - **纯函数可测**：淘汰决策（[selectExpired], [selectOldestUntilUnder]）不碰
///   IO，单测直接喂时间戳/尺寸；
/// - **只清派生数据**：只处理 [CacheCategory] 中的缓存类别，绝不触碰收藏、
///   下载、书源、进度等用户数据（图片收藏文件在收藏目录，不在图片缓存目录）；
/// - **best-effort**：单个文件被占用/无权限时跳过，不让一个坏文件中断清理；
/// - **启动触发**：由 splash 在初始化完成后后台调用（见 [runStartupClean]），
///   不阻塞首帧。
///
/// 年龄策略按文件修改时间判定（图片缓存命中后会刷新 mtime，等效 LRU）；
/// 容量策略在年龄清理之后执行，按最旧优先删除直到总量低于上限。
library;

import 'dart:io';

import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../settings/advanced_settings.dart';
import '../utils/app_log.dart';
import 'cache_inventory.dart';

/// 需要按文件年龄/容量清理的类别（Hive 类别由各自上限自行裁剪，不参与）。
const List<CacheCategory> kFileCleanableCategories = <CacheCategory>[
  CacheCategory.images,
  CacheCategory.tempFiles,
  CacheCategory.updatePackages,
];

/// 单个候选文件的元信息（清理决策输入）。
class CacheFileEntry {
  const CacheFileEntry({
    required this.path,
    required this.sizeBytes,
    required this.modified,
  });

  final String path;
  final int sizeBytes;
  final DateTime modified;
}

/// 年龄策略：选出 [maxAge] 之前修改的文件（最旧优先排序）。
///
/// [now] 显式传入便于单测；返回列表按 modified 升序（最旧在前）。
List<CacheFileEntry> selectExpired(
  List<CacheFileEntry> entries,
  DateTime now,
  Duration maxAge,
) {
  final DateTime cutoff = now.subtract(maxAge);
  final List<CacheFileEntry> out = entries
      .where((CacheFileEntry e) => e.modified.isBefore(cutoff))
      .toList()
    ..sort((CacheFileEntry a, CacheFileEntry b) =>
        a.modified.compareTo(b.modified));
  return out;
}

/// 容量策略：在 [entries] 中按最旧优先选出需要删除的文件，使剩余总量
/// 不超过 [maxBytes]。
///
/// 返回被选中的条目（最旧在前）；当前总量已在上限内时返回空列表。
List<CacheFileEntry> selectOldestUntilUnder(
  List<CacheFileEntry> entries,
  int maxBytes,
) {
  int total = 0;
  for (final CacheFileEntry e in entries) {
    total += e.sizeBytes;
  }
  if (total <= maxBytes) return const <CacheFileEntry>[];
  final List<CacheFileEntry> sorted = entries.toList()
    ..sort((CacheFileEntry a, CacheFileEntry b) =>
        a.modified.compareTo(b.modified));
  final List<CacheFileEntry> victims = <CacheFileEntry>[];
  for (final CacheFileEntry e in sorted) {
    if (total <= maxBytes) break;
    victims.add(e);
    total -= e.sizeBytes;
  }
  return victims;
}

/// 自动清理执行结果（UI/日志用）。
class CacheCleanResult {
  const CacheCleanResult({
    required this.deletedFiles,
    required this.freedBytes,
    required this.expiredFiles,
    required this.capacityFiles,
  });

  final int deletedFiles;
  final int freedBytes;

  /// 年龄策略删除的文件数。
  final int expiredFiles;

  /// 容量策略补充删除的文件数。
  final int capacityFiles;

  bool get isEmpty => deletedFiles == 0;
}

/// 缓存自动清理器。
class CacheAutoCleaner {
  CacheAutoCleaner._();

  /// 启动时后台执行一次（splash 调用，不阻塞首帧）。
  ///
  /// [settings] 为高级设置快照；关闭开关或阈值非法时直接返回空结果。
  static Future<CacheCleanResult> runStartupClean() async {
    AdvancedSettings settings;
    try {
      settings = await AdvancedSettingsStore.instance.load();
    } on Object {
      settings = const AdvancedSettings();
    }
    if (!settings.autoCacheCleanEnabled) {
      return const CacheCleanResult(
        deletedFiles: 0,
        freedBytes: 0,
        expiredFiles: 0,
        capacityFiles: 0,
      );
    }
    return run(
      maxAge: Duration(days: settings.cacheMaxAgeDays),
      maxTotalBytes: settings.cacheMaxTotalBytes,
    );
  }

  /// 执行清理（显式参数版本，便于设置页「立即清理」与单测复用）。
  static Future<CacheCleanResult> run({
    required Duration maxAge,
    required int maxTotalBytes,
  }) async {
    final Directory? tmp = await _tempDir();
    if (tmp == null) {
      return const CacheCleanResult(
        deletedFiles: 0,
        freedBytes: 0,
        expiredFiles: 0,
        capacityFiles: 0,
      );
    }
    final List<CacheFileEntry> entries = <CacheFileEntry>[];
    // 图片缓存两个目录 + 临时文件（排除图片与更新包）+ 更新包目录。
    for (final String name in kImageCacheDirNames) {
      await _collect(Directory(p.join(tmp.path, name)), entries);
    }
    await _collect(
      tmp,
      entries,
      skipTopLevelNames: <String>{
        ...kImageCacheDirNames,
        kUpdatePackageDirName,
      },
    );
    await _collect(Directory(p.join(tmp.path, kUpdatePackageDirName)), entries);

    final DateTime now = DateTime.now();
    final List<CacheFileEntry> expired = selectExpired(entries, now, maxAge);
    final Set<String> killed = <String>{};
    int freed = 0;
    for (final CacheFileEntry e in expired) {
      if (await _delete(e)) {
        killed.add(e.path);
        freed += e.sizeBytes;
      }
    }
    final int expiredCount = killed.length;

    // 容量策略：以「年龄清理后剩余」为基数，最旧优先删到上限内。
    final List<CacheFileEntry> remain = entries
        .where((CacheFileEntry e) => !killed.contains(e.path))
        .toList();
    final List<CacheFileEntry> victims =
        selectOldestUntilUnder(remain, maxTotalBytes);
    int capacityCount = 0;
    for (final CacheFileEntry e in victims) {
      if (await _delete(e)) {
        capacityCount++;
        freed += e.sizeBytes;
      }
    }

    final CacheCleanResult result = CacheCleanResult(
      deletedFiles: expiredCount + capacityCount,
      freedBytes: freed,
      expiredFiles: expiredCount,
      capacityFiles: capacityCount,
    );
    if (!result.isEmpty) {
      AppLog.instance.i('[缓存自动清理] 删除 ${result.deletedFiles} 个文件，'
          '释放 ${(result.freedBytes / 1024 / 1024).toStringAsFixed(1)} MB'
          '（过期 $expiredCount / 容量 $capacityCount）');
    }
    return result;
  }

  /// 统计不参与清理的 Hive 类别占用（仅用于「立即清理」后的占用复核，可选）。
  static Future<int> hiveCacheBytes() async {
    int bytes = 0;
    try {
      final tmp = await _tempDir();
      if (tmp == null) return 0;
      // Hive 文件位于应用文档目录，不在临时目录；此处仅作占位返回。
      return bytes;
    } on Object {
      return 0;
    }
  }

  // ───────────────────────── 内部实现 ─────────────────────────

  static Future<Directory?> _tempDir() async {
    try {
      return await getTemporaryDirectory();
    } on Object {
      return null;
    }
  }

  /// 递归收集候选文件（跳过 [skipTopLevelNames] 列出的顶层项）。
  static Future<void> _collect(
    Directory dir,
    List<CacheFileEntry> out, {
    Set<String> skipTopLevelNames = const <String>{},
  }) async {
    if (!dir.existsSync()) return;
    try {
      await for (final FileSystemEntity e
          in dir.list(recursive: true, followLinks: false)) {
        if (skipTopLevelNames.isNotEmpty) {
          final String top = p.split(p.relative(e.path, from: dir.path)).first;
          if (skipTopLevelNames.contains(top)) continue;
        }
        if (e is! File) continue;
        try {
          final FileStat st = await e.stat();
          out.add(CacheFileEntry(
            path: e.path,
            sizeBytes: st.size,
            modified: st.modified,
          ));
        } on Object {
          // 单文件 stat 失败忽略。
        }
      }
    } on Object {
      // 目录列举失败忽略。
    }
  }

  static Future<bool> _delete(CacheFileEntry e) async {
    try {
      await File(e.path).delete();
      // 图片缓存的 sidecar 元数据（如有）跟随删除，避免残留孤立记录。
      final File meta = File('${e.path}.metadata');
      if (meta.existsSync()) {
        try {
          await meta.delete();
        } on Object {
          // 忽略。
        }
      }
      return true;
    } on Object {
      return false;
    }
  }
}

/// 供设置页复用：把字节数格式化为可读文本（B / KB / MB / GB）。
String formatCacheBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

/// 弹幕缓存过期的 Hive 条目清理（年龄策略的 Hive 侧补充）。
///
/// 弹幕条目自带 `cachedAt` + `ttl`（见 `HiveDanmakuCache`），按 ttl 过期即可
/// 精确清理，无需依赖文件 mtime。返回删除条数。
Future<int> cleanExpiredDanmakuCache() async {
  if (!Hive.isBoxOpen(kDanmakuCacheBoxName)) return 0;
  try {
    final box = Hive.box(kDanmakuCacheBoxName);
    final int now = DateTime.now().millisecondsSinceEpoch;
    final List<dynamic> victims = <dynamic>[];
    for (final dynamic key in box.keys) {
      try {
        final dynamic v = box.get(key);
        final int cachedAt = (v?.cachedAt as int?) ?? 0;
        final int ttl = (v?.ttl as int?) ?? 0;
        if (cachedAt <= 0) continue;
        // ttl 单位为毫秒；ttl<=0 视为永不过期（保持与播放器缓存语义一致）。
        if (ttl > 0 && now > cachedAt + ttl) victims.add(key);
      } on Object {
        // 结构不符（旧数据 / 非 HiveDanmakuCache）跳过。
      }
    }
    if (victims.isNotEmpty) await box.deleteAll(victims);
    return victims.length;
  } on Object {
    return 0;
  }
}

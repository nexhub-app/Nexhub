/// 缓存分类清单（缓存分类 + 自动清理的唯一事实源）。
///
/// 全应用可清理的缓存按「类别」聚合，供高级设置「缓存管理」页逐类展示占用
/// 与单独清理，同时作为 [CacheAutoCleaner] 的统计/清理底座：
/// - [CacheCategory.images]：图片磁盘缓存（`libCachedImageData` 历史遗留 +
///   `nexCachedImageData` 统一缓存，见 `DioImageFileService`）；
/// - [CacheCategory.danmaku]：弹幕缓存 Hive box `danmaku_cache`（视频弹幕
///   分集缓存，随播放自然增长）；
/// - [CacheCategory.translations]：翻译缓存三个 Hive box
///   （小说 `novel_translations` / 漫画 `comic_translations` / 字幕
///   `subtitle_translations`）；
/// - [CacheCategory.webview]：内嵌浏览器数据（WebView 缓存 / localStorage /
///   IndexedDB，使用 `flutter_inappwebview` 的 WebStorageManager 清理）；
/// - [CacheCategory.tempFiles]：系统临时目录中的派生文件（PDF 逐页渲染、
///   归档解压、EPUB 封面、分享导出等）。**不含**图片缓存目录与更新包目录，
///   避免类别重叠导致统计双算 / 清理误删；
/// - [CacheCategory.updatePackages]：应用内更新的安装包与残留版本目录
///   （`<tmp>/updates/`）。
///
/// 目录统计与清理全部 best-effort：单个文件被占用 / 无权限时跳过，
/// 绝不让一个坏文件中断整类清理（Android 上临时文件被 mmap 占用是常态）。
library;

import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../network/dio_image_file_service.dart';

/// 可清理缓存的类别。
enum CacheCategory {
  /// 图片磁盘缓存（封面 / 漫画页 / RSS 内嵌图共用）。
  images,

  /// 弹幕缓存（Hive box `danmaku_cache`）。
  danmaku,

  /// 翻译缓存（小说 / 漫画 / 字幕三个 Hive box）。
  translations,

  /// WebView 数据（缓存 + 本地存储）。
  webview,

  /// 系统临时目录中的派生文件。
  tempFiles,

  /// 更新安装包残留。
  updatePackages,
}

/// 单个类别的占用统计。
class CacheCategoryUsage {
  const CacheCategoryUsage({
    required this.category,
    required this.bytes,
    this.fileCount = 0,
    this.unknown = false,
  });

  final CacheCategory category;

  /// 磁盘占用字节数；[unknown] 为 true 时该值无意义（平台无法统计）。
  final int bytes;

  /// 可统计的文件数（Hive box 为 0）。
  final int fileCount;

  /// 占用量无法统计（如 WebView 数据目录平台相关）：UI 显示「无法统计」，
  /// 仅提供清理入口。
  final bool unknown;
}

/// 全部类别占用快照。
class CacheUsageSnapshot {
  const CacheUsageSnapshot(this.usages);

  final List<CacheCategoryUsage> usages;

  int get totalBytes =>
      usages.fold<int>(0, (int sum, CacheCategoryUsage u) => sum + u.bytes);

  CacheCategoryUsage usageOf(CacheCategory c) => usages.firstWhere(
        (CacheCategoryUsage u) => u.category == c,
        orElse: () => CacheCategoryUsage(category: c, bytes: 0),
      );
}

/// 图片缓存目录名（与 `settings_advanced_screen` 历史实现保持一致）。
///
/// - `libCachedImageData`：flutter_cache_manager 默认管理器遗留目录；
/// - `nexCachedImageData`：`NexImageCacheManager` 统一缓存目录。
const List<String> kImageCacheDirNames = <String>[
  'libCachedImageData',
  'nexCachedImageData',
];

/// 更新包目录名（`<tmp>/updates/<tag>/…`，见 `UpdateManager`）。
const String kUpdatePackageDirName = 'updates';

/// 弹幕缓存 Hive box 名。
const String kDanmakuCacheBoxName = 'danmaku_cache';

/// 翻译缓存 Hive box 名（小说 / 漫画 / 字幕）。
const List<String> kTranslationBoxNames = <String>[
  'novel_translations',
  'comic_translations',
  'subtitle_translations',
];

/// 缓存清单：统计各类别占用 + 按类清理。
class CacheInventory {
  CacheInventory._();

  /// 统计全部类别占用。任何子项失败按 0 计，不抛异常。
  static Future<CacheUsageSnapshot> snapshot() async {
    final List<CacheCategoryUsage> out = <CacheCategoryUsage>[];
    for (final CacheCategory c in CacheCategory.values) {
      out.add(await usage(c));
    }
    return CacheUsageSnapshot(out);
  }

  /// 统计单类占用。
  static Future<CacheCategoryUsage> usage(CacheCategory category) async {
    try {
      switch (category) {
        case CacheCategory.images:
          final Directory? tmp = await _tempDir();
          if (tmp == null) return _zero(category);
          int bytes = 0;
          int count = 0;
          for (final String name in kImageCacheDirNames) {
            final (int b, int n) = await _dirUsage(Directory(p.join(tmp.path, name)));
            bytes += b;
            count += n;
          }
          return CacheCategoryUsage(
              category: category, bytes: bytes, fileCount: count);
        case CacheCategory.danmaku:
          return _hiveUsage(category, <String>[kDanmakuCacheBoxName]);
        case CacheCategory.translations:
          return _hiveUsage(category, kTranslationBoxNames);
        case CacheCategory.webview:
          // WebView 数据目录由平台/内核决定，无稳定公开 API 统计占用；
          // 标记 unknown，UI 只提供清理入口。
          return CacheCategoryUsage(
              category: category, bytes: 0, unknown: true);
        case CacheCategory.tempFiles:
          final Directory? tmp = await _tempDir();
          if (tmp == null) return _zero(category);
          final (int b, int n) = await _dirUsage(
            tmp,
            skipTopLevelNames: <String>{
              ...kImageCacheDirNames,
              kUpdatePackageDirName,
            },
          );
          return CacheCategoryUsage(
              category: category, bytes: b, fileCount: n);
        case CacheCategory.updatePackages:
          final Directory? tmp = await _tempDir();
          if (tmp == null) return _zero(category);
          final (int b, int n) = await _dirUsage(
              Directory(p.join(tmp.path, kUpdatePackageDirName)));
          return CacheCategoryUsage(
              category: category, bytes: b, fileCount: n);
      }
    } on Object {
      return _zero(category);
    }
  }

  /// 清理单类缓存，返回释放的字节数（无法预先统计的类别返回 0）。
  static Future<int> clear(CacheCategory category) async {
    switch (category) {
      case CacheCategory.images:
        final int before = (await usage(category)).bytes;
        // 先走缓存管理器自身的 emptyCache（清理其索引/元数据），再兜底删目录
        // 内容——管理器未初始化（测试环境 / 从未加载图片）时仅删文件即可。
        try {
          await DefaultCacheManager().emptyCache();
        } on Object {
          // 管理器不可用时忽略。
        }
        try {
          await NexImageCacheManager.instance.emptyCache();
        } on Object {
          // 管理器不可用时忽略。
        }
        final Directory? tmp = await _tempDir();
        if (tmp != null) {
          for (final String name in kImageCacheDirNames) {
            await _deleteDirContents(Directory(p.join(tmp.path, name)));
          }
        }
        _clearFlutterImageCache();
        return before;
      case CacheCategory.danmaku:
        return _clearHiveBoxes(<String>[kDanmakuCacheBoxName]);
      case CacheCategory.translations:
        return _clearHiveBoxes(kTranslationBoxNames);
      case CacheCategory.webview:
        // WebView 数据清理由调用方（设置页）经 WebStorageManager 完成，
        // 本层只负责分类口径统一，不引入 flutter_inappwebview 依赖。
        return 0;
      case CacheCategory.tempFiles:
        final int before = (await usage(category)).bytes;
        final Directory? tmp = await _tempDir();
        if (tmp == null) return 0;
        await _deleteDirContents(
          tmp,
          skipTopLevelNames: <String>{
            ...kImageCacheDirNames,
            kUpdatePackageDirName,
          },
        );
        return before;
      case CacheCategory.updatePackages:
        final int before = (await usage(category)).bytes;
        final Directory? tmp = await _tempDir();
        if (tmp == null) return 0;
        await _deleteDirContents(
            Directory(p.join(tmp.path, kUpdatePackageDirName)));
        return before;
    }
  }

  // ───────────────────────── 内部实现 ─────────────────────────

  static CacheCategoryUsage _zero(CacheCategory c) =>
      CacheCategoryUsage(category: c, bytes: 0);

  /// 释放 Flutter 内存图片缓存（磁盘清理后同步清内存，避免继续显示已删图）。
  static void _clearFlutterImageCache() {
    try {
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    } on Object {
      // 绑定未初始化（纯单元测试）时忽略。
    }
  }

  static Future<Directory?> _tempDir() async {
    try {
      return await getTemporaryDirectory();
    } on Object {
      return null;
    }
  }

  /// 计算目录占用。跳过 [skipTopLevelNames] 中列出的顶层项（类别互斥）。
  static Future<(int bytes, int files)> _dirUsage(
    Directory dir, {
    Set<String> skipTopLevelNames = const <String>{},
  }) async {
    if (!dir.existsSync()) return (0, 0);
    int bytes = 0;
    int files = 0;
    await for (final FileSystemEntity e
        in dir.list(recursive: true, followLinks: false)) {
      final String top = p.split(p.relative(e.path, from: dir.path)).first;
      if (skipTopLevelNames.contains(top)) continue;
      if (e is! File) continue;
      try {
        bytes += await e.length();
        files++;
      } on Object {
        // 单文件统计失败忽略（被占用 / 已删除）。
      }
    }
    return (bytes, files);
  }

  /// 删除目录内容（保留目录本身）。逐项 best-effort。
  static Future<void> _deleteDirContents(
    Directory dir, {
    Set<String> skipTopLevelNames = const <String>{},
  }) async {
    if (!dir.existsSync()) return;
    try {
      for (final FileSystemEntity e in dir.listSync(followLinks: false)) {
        if (skipTopLevelNames.contains(p.basename(e.path))) continue;
        try {
          await e.delete(recursive: true);
        } on Object {
          // 单个项删除失败（占用 / 权限）跳过，不影响其余项。
        }
      }
    } on Object {
      // 目录列举失败忽略。
    }
  }

  /// Hive box 占用：box 未打开或无对应文件时按 0 计。
  static Future<CacheCategoryUsage> _hiveUsage(
    CacheCategory category,
    List<String> boxNames,
  ) async {
    int bytes = 0;
    for (final String name in boxNames) {
      if (!Hive.isBoxOpen(name)) continue;
      try {
        final String? path = Hive.box(name).path;
        if (path == null || path.isEmpty) continue;
        final File f = File('$path.hive');
        if (f.existsSync()) bytes += await f.length();
      } on Object {
        // 单 box 统计失败忽略。
      }
    }
    return CacheCategoryUsage(category: category, bytes: bytes);
  }

  /// 清空 Hive box（仅已打开的 box：未打开说明本次会话未使用，无需清理）。
  static Future<int> _clearHiveBoxes(List<String> boxNames) async {
    int cleared = 0;
    for (final String name in boxNames) {
      if (!Hive.isBoxOpen(name)) continue;
      try {
        final box = Hive.box(name);
        cleared += box.length;
        await box.clear();
      } on Object {
        // 单 box 清理失败忽略。
      }
    }
    return cleared;
  }
}

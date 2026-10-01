/// 缓存分类清单单测：类别枚举、占用聚合与类别互斥（不重叠统计）。
///
/// 只测纯逻辑与内存构造的数据结构；目录 IO 由 [CacheInventory] 的
/// best-effort 实现承担（真机/集成验证），此处不依赖文件系统。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/storage/cache_inventory.dart';

void main() {
  group('CacheCategory', () {
    test('六个类别齐备且无重复', () {
      expect(CacheCategory.values.length, 6);
      expect(
        CacheCategory.values.map((c) => c.name).toSet().length,
        CacheCategory.values.length,
      );
    });

    test('类别覆盖需求验收项', () {
      const names = <String>{
        'images',
        'danmaku',
        'translations',
        'webview',
        'tempFiles',
        'updatePackages',
      };
      expect(CacheCategory.values.map((c) => c.name).toSet(), names);
    });
  });

  group('CacheUsageSnapshot', () {
    test('总占用为各类别之和', () {
      const snap = CacheUsageSnapshot(<CacheCategoryUsage>[
        CacheCategoryUsage(category: CacheCategory.images, bytes: 100),
        CacheCategoryUsage(category: CacheCategory.danmaku, bytes: 50),
        CacheCategoryUsage(
          category: CacheCategory.webview,
          bytes: 0,
          unknown: true,
        ),
      ]);
      expect(snap.totalBytes, 150);
    });

    test('缺失类别按 0 返回而不抛异常', () {
      const snap = CacheUsageSnapshot(<CacheCategoryUsage>[
        CacheCategoryUsage(category: CacheCategory.images, bytes: 10),
      ]);
      expect(snap.usageOf(CacheCategory.translations).bytes, 0);
      expect(snap.usageOf(CacheCategory.translations).unknown, isFalse);
    });

    test('unknown 类别保留标记（UI 显示「无法统计」）', () {
      const snap = CacheUsageSnapshot(<CacheCategoryUsage>[
        CacheCategoryUsage(
          category: CacheCategory.webview,
          bytes: 0,
          unknown: true,
        ),
      ]);
      expect(snap.usageOf(CacheCategory.webview).unknown, isTrue);
    });
  });

  group('类别互斥常量', () {
    test('图片缓存目录与更新包目录不重叠', () {
      // 临时文件统计必须排除图片目录与更新包目录，否则总量会双算。
      for (final String name in kImageCacheDirNames) {
        expect(name, isNot(kUpdatePackageDirName));
      }
      expect(kImageCacheDirNames.toSet().length, kImageCacheDirNames.length);
    });

    test('翻译缓存三个 box 与弹幕 box 不重叠', () {
      expect(kTranslationBoxNames, contains('novel_translations'));
      expect(kTranslationBoxNames, contains('comic_translations'));
      expect(kTranslationBoxNames, contains('subtitle_translations'));
      expect(kTranslationBoxNames, isNot(contains(kDanmakuCacheBoxName)));
      expect(kTranslationBoxNames.toSet().length, kTranslationBoxNames.length);
    });
  });
}

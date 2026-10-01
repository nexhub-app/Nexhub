/// 缓存自动清理策略单测（年龄 + 容量双策略的纯函数决策）。
///
/// 只测决策逻辑（不碰文件系统）：淘汰哪些文件由
/// [selectExpired] / [selectOldestUntilUnder] 决定，IO 层仅做 best-effort 删除。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/settings/advanced_settings.dart';
import 'package:nexhub/core/storage/cache_auto_clean.dart';

CacheFileEntry _e(String path, int size, DateTime modified) =>
    CacheFileEntry(path: path, sizeBytes: size, modified: modified);

void main() {
  final DateTime now = DateTime(2026, 9, 30, 12);

  group('年龄策略 selectExpired', () {
    test('只选超过保留时长的文件', () {
      final entries = <CacheFileEntry>[
        _e('old', 100, now.subtract(const Duration(days: 40))),
        _e('fresh', 100, now.subtract(const Duration(days: 5))),
        _e('edge', 100, now.subtract(const Duration(days: 30))),
      ];
      final expired = selectExpired(entries, now, const Duration(days: 30));
      // 恰好 30 天（边界）不算过期：isBefore(cutoff) 严格小于。
      expect(expired.map((e) => e.path).toList(), <String>['old']);
    });

    test('结果按最旧优先排序', () {
      final entries = <CacheFileEntry>[
        _e('a', 1, now.subtract(const Duration(days: 50))),
        _e('b', 1, now.subtract(const Duration(days: 90))),
        _e('c', 1, now.subtract(const Duration(days: 70))),
      ];
      final expired = selectExpired(entries, now, const Duration(days: 30));
      expect(expired.map((e) => e.path).toList(), <String>['b', 'c', 'a']);
    });

    test('空输入与全新鲜输入返回空', () {
      expect(selectExpired(<CacheFileEntry>[], now, Duration.zero), isEmpty);
      expect(
        selectExpired(
          <CacheFileEntry>[_e('x', 1, now)],
          now,
          const Duration(days: 30),
        ),
        isEmpty,
      );
    });
  });

  group('容量策略 selectOldestUntilUnder', () {
    test('未超上限时不动任何文件', () {
      final entries = <CacheFileEntry>[
        _e('a', 100, now),
        _e('b', 100, now),
      ];
      expect(selectOldestUntilUnder(entries, 1024), isEmpty);
    });

    test('超上限时按最旧优先删除直到低于上限', () {
      final entries = <CacheFileEntry>[
        _e('newest', 300, now),
        _e('oldest', 300, now.subtract(const Duration(days: 10))),
        _e('middle', 300, now.subtract(const Duration(days: 5))),
      ];
      // 总量 900，上限 500：删掉最旧（300）后剩 600 仍超，继续删 middle（300）→ 300 达标。
      final victims = selectOldestUntilUnder(entries, 500);
      expect(victims.map((e) => e.path).toList(),
          <String>['oldest', 'middle']);
    });

    test('单个大文件即可满足上限', () {
      final entries = <CacheFileEntry>[
        _e('huge', 900, now.subtract(const Duration(days: 3))),
        _e('small', 100, now),
      ];
      final victims = selectOldestUntilUnder(entries, 500);
      expect(victims.map((e) => e.path).toList(), <String>['huge']);
    });

    test('上限为 0 时清空全部（最旧优先）', () {
      final entries = <CacheFileEntry>[
        _e('b', 10, now.subtract(const Duration(days: 2))),
        _e('a', 10, now.subtract(const Duration(days: 4))),
      ];
      final victims = selectOldestUntilUnder(entries, 0);
      expect(victims.map((e) => e.path).toList(), <String>['a', 'b']);
    });
  });

  group('AdvancedSettings 自动清理配置', () {
    test('默认值：开启 / 30 天 / 1024MB', () {
      const s = AdvancedSettings();
      expect(s.autoCacheCleanEnabled, isTrue);
      expect(s.cacheMaxAgeDays, 30);
      expect(s.cacheMaxTotalMb, 1024);
      expect(s.cacheMaxTotalBytes, 1024 * 1024 * 1024);
    });

    test('JSON 往返保持字段', () {
      const s = AdvancedSettings(
        autoCacheCleanEnabled: false,
        cacheMaxAgeDays: 7,
        cacheMaxTotalMb: 2048,
      );
      final back = AdvancedSettings.fromJson(s.toJson());
      expect(back.autoCacheCleanEnabled, isFalse);
      expect(back.cacheMaxAgeDays, 7);
      expect(back.cacheMaxTotalMb, 2048);
    });

    test('旧数据缺字段时回落到默认值', () {
      final back = AdvancedSettings.fromJson(<String, dynamic>{
        'detailedLogging': true,
        'defaultUserAgent': 'UA',
      });
      expect(back.autoCacheCleanEnabled, isTrue);
      expect(back.cacheMaxAgeDays, 30);
      expect(back.cacheMaxTotalMb, 1024);
      expect(back.detailedLogging, isTrue);
      expect(back.defaultUserAgent, 'UA');
    });

    test('非法数值被夹到合法区间', () {
      final back = AdvancedSettings.fromJson(<String, dynamic>{
        'cacheMaxAgeDays': 0,
        'cacheMaxTotalMb': 5,
      });
      expect(back.cacheMaxAgeDays, 1);
      expect(back.cacheMaxTotalMb, 128);
    });
  });

  group('formatCacheBytes', () {
    test('按量级选择单位', () {
      expect(formatCacheBytes(0), '0 B');
      expect(formatCacheBytes(512), '512 B');
      expect(formatCacheBytes(2048), '2.0 KB');
      expect(formatCacheBytes(3 * 1024 * 1024), '3.0 MB');
      expect(formatCacheBytes(2 * 1024 * 1024 * 1024), '2.00 GB');
    });
  });
}

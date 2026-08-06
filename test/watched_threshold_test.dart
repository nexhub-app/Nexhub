// 已看阈值设置单测（Task 4）：
// - GeneralSettings 默认值 / fromJson 裁剪 / 持久化往返；
// - progressReachesWatchedThreshold 纯函数：达到/超过阈值标记、未达到不标记；
// - GeneralSettingsStore.setWatchedThresholdPercent 裁剪到 50–100 并持久化。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/comic/models/reader_preferences.dart'
    show InMemoryBackend;
import 'package:nexhub/core/settings/general_settings.dart';

void main() {
  group('GeneralSettings.watchedThresholdPercent', () {
    test('default is 90', () {
      const s = GeneralSettings();
      expect(s.watchedThresholdPercent, 90);
    });

    test('fromJson clamps below-range value to 50', () {
      final s = GeneralSettings.fromJson(
        <String, dynamic>{'watchedThresholdPercent': 30},
      );
      expect(s.watchedThresholdPercent, 50);
    });

    test('fromJson clamps above-range value to 100', () {
      final s = GeneralSettings.fromJson(
        <String, dynamic>{'watchedThresholdPercent': 200},
      );
      expect(s.watchedThresholdPercent, 100);
    });

    test('fromJson preserves in-range value', () {
      final s = GeneralSettings.fromJson(
        <String, dynamic>{'watchedThresholdPercent': 75},
      );
      expect(s.watchedThresholdPercent, 75);
    });

    test('json round-trip preserves value', () {
      const s = GeneralSettings(watchedThresholdPercent: 80);
      final back = GeneralSettings.fromJson(s.toJson());
      expect(back.watchedThresholdPercent, 80);
    });

    test('copyWith updates threshold', () {
      const s = GeneralSettings();
      final next = s.copyWith(watchedThresholdPercent: 60);
      expect(next.watchedThresholdPercent, 60);
      // 原对象不变
      expect(s.watchedThresholdPercent, 90);
    });
  });

  group('progressReachesWatchedThreshold', () {
    test('marks at exactly the threshold', () {
      expect(progressReachesWatchedThreshold(0.9, 90), isTrue);
      expect(progressReachesWatchedThreshold(0.5, 50), isTrue);
      expect(progressReachesWatchedThreshold(1.0, 100), isTrue);
    });

    test('marks above the threshold', () {
      expect(progressReachesWatchedThreshold(0.95, 90), isTrue);
      expect(progressReachesWatchedThreshold(1.0, 90), isTrue);
    });

    test('does not mark below the threshold', () {
      expect(progressReachesWatchedThreshold(0.89, 90), isFalse);
      expect(progressReachesWatchedThreshold(0.49, 50), isFalse);
      expect(progressReachesWatchedThreshold(0.0, 90), isFalse);
    });

    test('clamps out-of-range threshold defensively', () {
      // 200 → 视为 100，需 100% 才标记
      expect(progressReachesWatchedThreshold(0.99, 200), isFalse);
      expect(progressReachesWatchedThreshold(1.0, 200), isTrue);
      // 30 → 视为 50
      expect(progressReachesWatchedThreshold(0.49, 30), isFalse);
      expect(progressReachesWatchedThreshold(0.5, 30), isTrue);
    });
  });

  group('GeneralSettingsStore.setWatchedThresholdPercent', () {
    test('clamps and persists (below-range -> 50)', () async {
      final store = GeneralSettingsStore(backend: InMemoryBackend());
      await store.load();
      expect(store.watchedThresholdPercent, 90);

      await store.setWatchedThresholdPercent(20);
      expect(store.watchedThresholdPercent, 50);
      expect(store.settings.watchedThresholdPercent, 50);
    });

    test('clamps and persists (above-range -> 100)', () async {
      final store = GeneralSettingsStore(backend: InMemoryBackend());
      await store.load();

      await store.setWatchedThresholdPercent(999);
      expect(store.watchedThresholdPercent, 100);
    });

    test('persists in-range value and survives reload', () async {
      final backend = InMemoryBackend();
      final store = GeneralSettingsStore(backend: backend);
      await store.load();

      await store.setWatchedThresholdPercent(70);
      expect(store.watchedThresholdPercent, 70);

      // 新实例从同一后端加载，应读到 70。
      final reloaded = GeneralSettingsStore(backend: backend);
      final settings = await reloaded.load();
      expect(settings.watchedThresholdPercent, 70);
      expect(reloaded.watchedThresholdPercent, 70);
    });

    test('notifies listeners on change', () async {
      final store = GeneralSettingsStore(backend: InMemoryBackend());
      await store.load();

      var notifications = 0;
      store.addListener(() => notifications++);

      await store.setWatchedThresholdPercent(80);
      expect(notifications, greaterThan(0));
      expect(store.watchedThresholdPercent, 80);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/comic/models/reader_preferences.dart';
import 'package:nexhub/core/comic/reader_image_cache_policy.dart';

void main() {
  group('resolveComicImageCacheBytes（P3 图片缓存预算）', () {
    test('未知内存 / 非 Android 返回默认 100MB', () {
      expect(resolveComicImageCacheBytes(null), 100 << 20);
      expect(resolveComicImageCacheBytes(0), 100 << 20);
    });

    test('低内存设备（<3GB）维持默认 100MB', () {
      expect(
        resolveComicImageCacheBytes(2 * 1024 * 1024 * 1024),
        kComicImageCacheDefaultBytes,
      );
    });

    test('中等内存（3–6GB）200MB', () {
      expect(resolveComicImageCacheBytes(4 << 30), 200 << 20);
    });

    test('大内存（≥6GB）500MB', () {
      expect(resolveComicImageCacheBytes(8 << 30), 500 << 20);
    });
  });

  group('ReaderPreferences.webtoonLimitDecodeSize（P3 解码限幅）', () {
    test('默认开启，JSON 序列化往返保持', () {
      const prefs = ReaderPreferences();
      expect(prefs.webtoonLimitDecodeSize, isTrue);

      final json = prefs.toJson();
      expect(json['webtoonLimitDecodeSize'], isTrue);

      final restored = ReaderPreferences.fromJson(json);
      expect(restored.webtoonLimitDecodeSize, isTrue);
    });

    test('关闭后可序列化与 copyWith 恢复', () {
      final off = const ReaderPreferences()
          .copyWith(webtoonLimitDecodeSize: false);
      expect(off.webtoonLimitDecodeSize, isFalse);

      final restored =
          ReaderPreferences.fromJson(off.toJson());
      expect(restored.webtoonLimitDecodeSize, isFalse);

      final back = restored.copyWith(webtoonLimitDecodeSize: true);
      expect(back.webtoonLimitDecodeSize, isTrue);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/novel/novel_reader_preferences.dart';

void main() {
  group('A7 双页模式偏好', () {
    test('默认关闭；JSON 往返保持', () {
      const prefs = NovelReaderPreferences();
      expect(prefs.twoPageMode, isFalse);

      final on = prefs.copyWith(twoPageMode: true);
      expect(on.twoPageMode, isTrue);

      final restored = NovelReaderPreferences.fromJson(on.toJson());
      expect(restored.twoPageMode, isTrue);

      final off = NovelReaderPreferences.fromJson(prefs.toJson());
      expect(off.twoPageMode, isFalse);
    });
  });
}

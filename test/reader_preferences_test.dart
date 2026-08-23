import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/comic/models/reader_preferences.dart';
import 'package:nexhub/core/theme/reader_tokens.dart';

void main() {
  test('json round-trip preserves all fields', () {
    const prefs = ReaderPreferences(
      readingMode: ReadingMode.webtoonWithGap,
      background: ReaderBackgroundColor.gray,
      tapZoneLayout: ReaderTapZoneLayout.kindle,
      orientation: ScreenOrientation.lockLandscape,
      doubleTapZoom: false,
      minScale: 1.5,
      maxScale: 5.0,
      preloadImageCount: 8,
    );
    final back = ReaderPreferences.fromJson(prefs.toJson());
    expect(back.readingMode, ReadingMode.webtoonWithGap);
    expect(back.background, ReaderBackgroundColor.gray);
    expect(back.tapZoneLayout, ReaderTapZoneLayout.kindle);
    expect(back.orientation, ScreenOrientation.lockLandscape);
    expect(back.doubleTapZoom, false);
    expect(back.minScale, 1.5);
    expect(back.maxScale, 5.0);
    expect(back.preloadImageCount, 8);
  });

  test('preloadImageCount defaults to 4 and is clamped to 1..16', () {
    expect(const ReaderPreferences().preloadImageCount, 4);
    final low = ReaderPreferences.fromJson(
        <String, dynamic>{'preloadImageCount': 0});
    expect(low.preloadImageCount, 1);
    final high = ReaderPreferences.fromJson(
        <String, dynamic>{'preloadImageCount': 99});
    expect(high.preloadImageCount, 16);
    final missing = ReaderPreferences.fromJson(<String, dynamic>{});
    expect(missing.preloadImageCount, 4);
  });

  test('seamlessReading and showChapterSeparator default to true and round-trip',
      () {
    const def = ReaderPreferences();
    expect(def.seamlessReading, true);
    expect(def.showChapterSeparator, true);
    // 显式关闭可经 JSON 往返保留。
    const custom = ReaderPreferences(
        seamlessReading: false, showChapterSeparator: false);
    final back = ReaderPreferences.fromJson(custom.toJson());
    expect(back.seamlessReading, false);
    expect(back.showChapterSeparator, false);
    // 缺省键回落默认 true。
    final missing = ReaderPreferences.fromJson(<String, dynamic>{});
    expect(missing.seamlessReading, true);
    expect(missing.showChapterSeparator, true);
  });

  test('seamlessReading and showChapterSeparator copyWith and mergedWith', () {
    const custom = ReaderPreferences(
        seamlessReading: false, showChapterSeparator: false);
    expect(custom.copyWith().seamlessReading, false);
    expect(custom.copyWith().showChapterSeparator, false);
    expect(custom.copyWith(seamlessReading: true).seamlessReading, true);
    expect(custom.copyWith(showChapterSeparator: true).showChapterSeparator,
        true);

    // 未自定义时回落全局默认，自定义时覆盖。
    const base = ReaderPreferences(seamlessReading: false);
    expect(const ReaderPreferences().mergedWith(base).seamlessReading, false);
    expect(custom.mergedWith(base).seamlessReading, false);
  });

  test('preloadImageCount copyWith and mergedWith', () {
    const custom = ReaderPreferences(preloadImageCount: 12);
    expect(custom.copyWith().preloadImageCount, 12);
    expect(custom.copyWith(preloadImageCount: 3).preloadImageCount, 3);

    // 未自定义时回落全局默认，自定义时覆盖。
    const base = ReaderPreferences(preloadImageCount: 10);
    expect(const ReaderPreferences().mergedWith(base).preloadImageCount, 10);
    expect(custom.mergedWith(base).preloadImageCount, 12);
  });

  test('defaults applied for unknown / missing values', () {
    final prefs = ReaderPreferences.fromJson(<String, dynamic>{'readingMode': 'nope'});
    expect(prefs.readingMode, ReadingMode.singleLTR);
    expect(prefs.background, ReaderBackgroundColor.black);
  });

  test('store returns default then persists', () async {
    final store = ReaderPreferencesStore(backend: InMemoryBackend());
    expect((await store.get('x')).readingMode, ReadingMode.singleLTR);
    await store.save('x', const ReaderPreferences(readingMode: ReadingMode.singleRTL));
    expect((await store.get('x')).readingMode, ReadingMode.singleRTL);
  });

  test('resolveBackgroundColor maps preset index', () {
    const black = ReaderPreferences(background: ReaderBackgroundColor.black);
    const autoDark = ReaderPreferences(background: ReaderBackgroundColor.auto);
    expect(black.resolveBackgroundColor(false), ReaderTokens.bgPresets[0]);
    expect(autoDark.resolveBackgroundColor(true), ReaderTokens.bgPresets[0]);
    expect(autoDark.resolveBackgroundColor(false), ReaderTokens.bgPresets[2]);
  });

  test('reading mode helpers', () {
    expect(ReadingMode.webtoon.isWebtoon, true);
    expect(ReadingMode.webtoonWithGap.isWebtoon, true);
    expect(ReadingMode.singleLTR.isPaged, true);
    expect(ReadingMode.singleVertical.isPaged, true);
  });

  test('Phase C fields default and round-trip', () {
    const def = ReaderPreferences();
    expect(def.readerPageSpacing, 0);
    expect(def.showSingleImageOnFirstPage, false);
    expect(def.showClockBattery, false);
    expect(def.clockBatteryPosition, ClockBatteryPosition.topLeft);
    expect(def.readerBrightness, 0.0);
    expect(def.nightLightEnabled, false);
    expect(def.nightLightOpacity, 0.4);
    expect(def.autoDownloadChapters, false);
    expect(def.skipReadChapters, false);
    expect(def.skipFilteredChapters, false);
    expect(def.skipDuplicateChapters, false);
    expect(def.readerScreenPicNumberForPortrait, 1);
    expect(def.readerScreenPicNumberForLandscape, 1);

    const custom = ReaderPreferences(
      readerPageSpacing: 20,
      showSingleImageOnFirstPage: true,
      showClockBattery: true,
      clockBatteryPosition: ClockBatteryPosition.bottomRight,
      clockBatteryMargin: 12,
      clockBatteryOpacity: 0.5,
      clockBatteryFontSize: 16,
      readerBrightness: -0.5,
      nightLightEnabled: true,
      nightLightOpacity: 0.65,
      autoDownloadChapters: true,
      skipReadChapters: true,
      skipFilteredChapters: true,
      skipDuplicateChapters: true,
      readerScreenPicNumberForPortrait: 3,
      readerScreenPicNumberForLandscape: 4,
    );
    final back = ReaderPreferences.fromJson(custom.toJson());
    expect(back.readerPageSpacing, 20);
    expect(back.showSingleImageOnFirstPage, true);
    expect(back.showClockBattery, true);
    expect(back.clockBatteryPosition, ClockBatteryPosition.bottomRight);
    expect(back.clockBatteryMargin, 12);
    expect(back.clockBatteryOpacity, 0.5);
    expect(back.clockBatteryFontSize, 16);
    expect(back.readerBrightness, -0.5);
    expect(back.nightLightEnabled, true);
    expect(back.nightLightOpacity, 0.65);
    expect(back.autoDownloadChapters, true);
    expect(back.skipReadChapters, true);
    expect(back.skipFilteredChapters, true);
    expect(back.skipDuplicateChapters, true);
    expect(back.readerScreenPicNumberForPortrait, 3);
    expect(back.readerScreenPicNumberForLandscape, 4);
  });

  test('Phase C fields clamp on parse', () {
    final prefs = ReaderPreferences.fromJson(<String, dynamic>{
      'readerPageSpacing': 999,
      'readerBrightness': 5.0,
      'nightLightOpacity': 0.99,
      'clockBatteryOpacity': 0.05,
      'readerScreenPicNumberForPortrait': 9,
      'readerScreenPicNumberForLandscape': 0,
    });
    expect(prefs.readerPageSpacing, 50);
    expect(prefs.readerBrightness, 1.0);
    // 夜览强度按 VeneraX toOpacity 范围 0.1–0.85 clamp。
    expect(prefs.nightLightOpacity, 0.85);
    expect(prefs.clockBatteryOpacity, 0.1);
    expect(prefs.readerScreenPicNumberForPortrait, 5);
    expect(prefs.readerScreenPicNumberForLandscape, 1);
  });

  test('Phase C fields copyWith and mergedWith', () {
    const custom = ReaderPreferences(
      readerBrightness: 0.4,
      showClockBattery: true,
      skipDuplicateChapters: true,
      readerScreenPicNumberForPortrait: 2,
    );
    expect(custom.copyWith().readerBrightness, 0.4);
    expect(custom.copyWith(readerBrightness: -0.2).readerBrightness, -0.2);
    expect(custom.copyWith(showClockBattery: false).showClockBattery, false);
    // 夜览：copyWith 生效，mergedWith 未自定义时回落全局默认、自定义时覆盖。
    final nightLight = custom.copyWith(
        nightLightEnabled: true, nightLightOpacity: 0.7);
    expect(nightLight.nightLightEnabled, true);
    expect(nightLight.nightLightOpacity, 0.7);

    const base = ReaderPreferences(readerBrightness: 0.7);
    // 未自定义时回落全局默认，自定义时覆盖。
    expect(const ReaderPreferences().mergedWith(base).readerBrightness, 0.7);
    expect(custom.mergedWith(base).readerBrightness, 0.4);
    expect(custom.mergedWith(base).showClockBattery, true);
    expect(custom.mergedWith(base).skipDuplicateChapters, true);
    expect(custom.mergedWith(base).readerScreenPicNumberForPortrait, 2);
    // 全局层可配置夜览默认：未自定义回落全局，自定义覆盖。
    final nightBase =
        base.copyWith(nightLightEnabled: true, nightLightOpacity: 0.5);
    expect(const ReaderPreferences().mergedWith(nightBase).nightLightEnabled,
        true);
    expect(const ReaderPreferences().mergedWith(nightBase).nightLightOpacity,
        0.5);
    expect(nightLight.mergedWith(nightBase).nightLightOpacity, 0.7);
  });

  test('getReaderSetting resolves three tiers (REQ-C9)', () {
    const work = ReaderPreferences(background: ReaderBackgroundColor.white);
    const device = ReaderPreferences(background: ReaderBackgroundColor.gray);
    // device 层未设置 → 取作品层。
    expect(
      getReaderSetting(work, null, (p) => p.background),
      ReaderBackgroundColor.white,
    );
    // device 层设置后 → 取设备层。
    expect(
      getReaderSetting(work, device, (p) => p.background),
      ReaderBackgroundColor.gray,
    );
    // 非冲突字段互不影响。
    expect(
      getReaderSetting(work, device, (p) => p.readingMode),
      work.readingMode,
    );
  });
}

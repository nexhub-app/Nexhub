/// 详情页外观（动态取色 + 设置模型）单元测试。
///
/// 取色测试直接注入 rawRgba 字节（[accentFromRgba] 纯像素统计，不依赖
/// 图片解码器）；设置模型走 JSON 往返 + 内存后端持久化验证。
library;

import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flutter/painting.dart' show HSLColor;
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/comic/models/reader_preferences.dart';
import 'package:nexhub/core/settings/detail_appearance_settings.dart';
import 'package:nexhub/core/theme/image_accent_extractor.dart';

/// 生成纯色 rawRgba 字节（32×32）。
Uint8List solidRgba(int r, int g, int b) {
  final Uint8List px = Uint8List(32 * 32 * 4);
  for (int i = 0; i < px.length; i += 4) {
    px[i] = r;
    px[i + 1] = g;
    px[i + 2] = b;
    px[i + 3] = 255;
  }
  return px;
}

/// 断言取色结果被归一化为「鲜而不刺」的中间调种子。
///
/// 容差比 clamp 区间略宽：种子色经 toColor() 量化为 8-bit RGB 后重新求
/// HSL 会有 ~0.003 的漂移，属正常精度损失。
void expectNormalizedSeed(Color accent) {
  final HSLColor hsl = HSLColor.fromColor(accent);
  expect(hsl.saturation, inInclusiveRange(0.38, 0.88));
  expect(hsl.lightness, inInclusiveRange(0.40, 0.62));
}

void main() {
  group('accentFromRgba 纯色统计', () {
    test('橙色封面 → 提取出橙色系强调色（中间调、较饱和）', () {
      final Color? accent = accentFromRgba(solidRgba(255, 140, 60));
      expect(accent, isNotNull);
      final HSLColor hsl = HSLColor.fromColor(accent!);
      expect(hsl.hue, inInclusiveRange(10, 35));
      expectNormalizedSeed(accent);
    });

    test('全灰封面 → 返回 null（保持默认强调色）', () {
      expect(accentFromRgba(solidRgba(128, 128, 128)), isNull);
      expect(accentFromRgba(solidRgba(250, 250, 250)), isNull);
    });

    test('黑边 + 主体色：主体色胜出（黑边被重罚）', () {
      // 前 1/4 为近黑，其余为青蓝：主色应落在蓝青色相（~200°）。
      final Uint8List px = Uint8List(32 * 32 * 4);
      void fill(int from, int to, int r, int g, int b) {
        for (int i = from; i < to; i += 4) {
          px[i] = r;
          px[i + 1] = g;
          px[i + 2] = b;
          px[i + 3] = 255;
        }
      }

      fill(0, 256, 5, 5, 5); // 256 像素 = 32×32 的 1/4
      fill(256, px.length, 14, 165, 233);
      final Color? accent = accentFromRgba(px);
      expect(accent, isNotNull);
      final double hue = HSLColor.fromColor(accent!).hue;
      expect(hue, inInclusiveRange(180, 220));
    });
  });

  group('DetailAppearanceSettings', () {
    test('JSON 往返保持字段', () {
      const DetailAppearanceSettings s = DetailAppearanceSettings(
        dynamicAccentEnabled: true,
        blurredBackgroundEnabled: true,
        backgroundBlurSigma: 18.0,
      );
      final DetailAppearanceSettings restored =
          DetailAppearanceSettings.fromJson(s.toJson());
      expect(restored.dynamicAccentEnabled, true);
      expect(restored.blurredBackgroundEnabled, true);
      expect(restored.backgroundBlurSigma, 18.0);
    });

    test('脏数据 / 缺省回落安全侧（默认关闭、强度夹取）', () {
      final DetailAppearanceSettings empty =
          DetailAppearanceSettings.fromJson(<String, dynamic>{});
      expect(empty.dynamicAccentEnabled, false);
      expect(empty.blurredBackgroundEnabled, false);
      expect(empty.backgroundBlurSigma, 30.0);

      final DetailAppearanceSettings dirty =
          DetailAppearanceSettings.fromJson(<String, dynamic>{
        'dynamicAccentEnabled': 'oops',
        'backgroundBlurSigma': 999,
      });
      expect(dirty.dynamicAccentEnabled, false);
      expect(dirty.backgroundBlurSigma, kDetailBlurSigmaMax);
    });

    test('Store 走内存后端持久化并广播', () async {
      final DetailAppearanceStore store =
          DetailAppearanceStore(backend: InMemoryBackend());
      int notified = 0;
      store.addListener(() => notified++);
      await store.load();
      await store.setDynamicAccentEnabled(true);
      await store.setBackgroundBlurSigma(15);
      expect(notified, greaterThanOrEqualTo(3)); // load + 2 次 save
      expect(store.settings.dynamicAccentEnabled, true);
      expect(store.settings.backgroundBlurSigma, 15.0);

      // 新实例（空后端）仍是默认值，load 幂等不抛错。
      final DetailAppearanceStore second =
          DetailAppearanceStore(backend: InMemoryBackend());
      await second.load();
      expect(second.settings.dynamicAccentEnabled, false);
    });
  });
}

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/comic/models/reader_preferences.dart';
import 'package:nexhub/core/theme/app_tokens.dart';
import 'package:nexhub/core/theme/palette_style.dart';
import 'package:nexhub/core/theme/theme_controller.dart';

void main() {
  group('ThemeController.paletteStyle', () {
    test('默认 tonalSpot，setPaletteStyle 生效并持久化', () async {
      final backend = InMemoryBackend();
      final controller = ThemeController(backend: backend);

      expect(controller.paletteStyle, PaletteStyle.tonalSpot);

      controller.setPaletteStyle(PaletteStyle.vibrant);
      expect(controller.paletteStyle, PaletteStyle.vibrant);

      // 持久化写入新字段。
      final raw = await backend.get(ThemeController.storageKey);
      expect(raw, isNotNull);
      expect(raw!.contains('"paletteStyle":"vibrant"'), isTrue);
    });

    test('旧版本 JSON（无 paletteStyle 字段）向后兼容：保持默认 tonalSpot', () async {
      final backend = InMemoryBackend();
      await backend.set(
        ThemeController.storageKey,
        '{"mode":"dark","seed":4283191674,"useMonet":true}',
      );

      final controller = ThemeController(backend: backend);
      await controller.load();

      expect(controller.paletteStyle, PaletteStyle.tonalSpot);
      expect(controller.mode, ThemeMode.dark);
    });

    test('读取未知风格名时回退默认（脏数据不崩溃）', () async {
      final backend = InMemoryBackend();
      await backend.set(
        ThemeController.storageKey,
        '{"mode":"light","useMonet":false,"paletteStyle":"noSuchStyle"}',
      );

      final controller = ThemeController(backend: backend);
      await controller.load();

      expect(controller.paletteStyle, PaletteStyle.tonalSpot);
    });

    test('lightTheme/darkTheme 非标准风格走 fromSeed(variant) 重播种', () {
      final controller = ThemeController(useMonet: false)
        ..setPaletteStyle(PaletteStyle.monochrome);

      final light = controller.lightTheme();
      final dark = controller.darkTheme();

      // 单色风格：primary 与 onSurface 同为无彩灰阶（色相饱和度归零）。
      final hsl = HSLColor.fromColor(light.colorScheme.primary);
      expect(hsl.saturation, lessThan(0.05));
      expect(light.colorScheme.brightness, Brightness.light);
      expect(dark.colorScheme.brightness, Brightness.dark);
    });

    test('玄色优先于莫奈：选玄色 + 开莫奈仍渲染玄色手工主题（回归）', () {
      final controller = ThemeController(useMonet: true)
        ..setSeed(AppTokens.seedXuanSe);
      // setSeed 会关闭莫奈；模拟旧数据「玄色 + 莫奈同时开」的组合。
      controller.setUseMonet(true);
      expect(controller.isXuanSe, isTrue);
      expect(controller.useMonet, isTrue);

      final systemScheme = ColorScheme.fromSeed(
        seedColor: const Color(0xFF6750A4),
      );
      final theme = controller.lightTheme(systemScheme);

      // 玄色标志：近黑 surface，而非紫色调的动态取色 surface。
      expect(theme.colorScheme.surface, AppTokens.xuanSeInk);
    });

    test('莫奈 + 非标准风格：取系统 primary 重播种（壁纸 + 风格组合）', () {
      final controller = ThemeController(useMonet: true)
        ..setPaletteStyle(PaletteStyle.fruitSalad);

      final systemScheme = ColorScheme.fromSeed(
        seedColor: const Color(0xFF6750A4),
      );
      final rebuilt = controller.lightTheme(systemScheme);

      // 对照：同 seed 直接以 fruitSalad 变体生成，二者 primary 应一致。
      final expected = ColorScheme.fromSeed(
        seedColor: systemScheme.primary,
        brightness: Brightness.light,
        dynamicSchemeVariant: DynamicSchemeVariant.fruitSalad,
      );
      expect(rebuilt.colorScheme.primary, expected.primary);
    });

    test('莫奈 + 默认 tonalSpot：沿用系统 scheme 本体（壁纸取色不重播种）', () {
      final controller = ThemeController(useMonet: true);

      final systemScheme = ColorScheme.fromSeed(
        seedColor: const Color(0xFF6750A4),
      );
      final theme = controller.lightTheme(systemScheme);

      expect(theme.colorScheme.primary, systemScheme.primary);
    });
  });
}

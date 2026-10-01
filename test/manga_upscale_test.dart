/// 漫画图片超分（GPU 实时 shader）单测：档位解析、纹理上限判定与偏好往返。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/comic/manga_upscale.dart';
import 'package:nexhub/core/comic/models/reader_preferences.dart';
import 'package:nexhub/core/settings/reader_default_settings.dart';

void main() {
  group('MangaUpscaleMode', () {
    test('enabled 仅 off 为 false', () {
      expect(MangaUpscaleMode.off.enabled, isFalse);
      expect(MangaUpscaleMode.resample.enabled, isTrue);
      expect(MangaUpscaleMode.sharpen.enabled, isTrue);
    });

    test('shaderMode 仅 sharpen 档开启锐化', () {
      expect(MangaUpscaleMode.off.shaderMode, 0.0);
      expect(MangaUpscaleMode.resample.shaderMode, 0.0);
      expect(MangaUpscaleMode.sharpen.shaderMode, 1.0);
    });

    test('l10nKey 与枚举一一对应且无重复', () {
      final keys =
          MangaUpscaleMode.values.map((m) => m.l10nKey()).toSet();
      expect(keys.length, MangaUpscaleMode.values.length);
    });

    test('parseMangaUpscaleMode 容错回退 off', () {
      expect(parseMangaUpscaleMode('sharpen'), MangaUpscaleMode.sharpen);
      expect(parseMangaUpscaleMode('resample'), MangaUpscaleMode.resample);
      expect(parseMangaUpscaleMode('bogus'), MangaUpscaleMode.off);
      expect(parseMangaUpscaleMode(null), MangaUpscaleMode.off);
      expect(parseMangaUpscaleMode(42), MangaUpscaleMode.off);
    });

    test('纹理上限判定：超限回退普通渲染', () {
      expect(MangaUpscaleShader.fitsTextureLimit(1200, 1800), isTrue);
      expect(
        MangaUpscaleShader.fitsTextureLimit(kMangaUpscaleMaxTextureSide, 100),
        isTrue,
      );
      expect(
        MangaUpscaleShader.fitsTextureLimit(kMangaUpscaleMaxTextureSide + 1, 100),
        isFalse,
      );
      // 超长条漫（高数千 px 超过纹理上限）必须回退。
      expect(MangaUpscaleShader.fitsTextureLimit(1200, 20000), isFalse);
      // 非法尺寸不进入 shader 路径。
      expect(MangaUpscaleShader.fitsTextureLimit(0, 100), isFalse);
    });
  });

  group('ReaderPreferences.upscaleMode', () {
    test('默认关闭（与历史行为一致）', () {
      expect(const ReaderPreferences().upscaleMode, MangaUpscaleMode.off);
    });

    test('JSON 往返保持档位', () {
      const p = ReaderPreferences(upscaleMode: MangaUpscaleMode.sharpen);
      final back = ReaderPreferences.fromJson(p.toJson());
      expect(back.upscaleMode, MangaUpscaleMode.sharpen);
    });

    test('旧数据（无 upscaleMode 字段）回退 off', () {
      final json = const ReaderPreferences().toJson()
        ..remove('upscaleMode');
      expect(ReaderPreferences.fromJson(json).upscaleMode,
          MangaUpscaleMode.off);
    });

    test('copyWith 可单独切换档位', () {
      const p = ReaderPreferences();
      expect(p.copyWith(upscaleMode: MangaUpscaleMode.resample).upscaleMode,
          MangaUpscaleMode.resample);
      // 未传该字段时保持原值。
      expect(
        p
            .copyWith(upscaleMode: MangaUpscaleMode.sharpen)
            .copyWith(filterBrightness: 0.5)
            .upscaleMode,
        MangaUpscaleMode.sharpen,
      );
    });

    test('作品层覆盖合并：仅列出的键生效', () {
      const work = ReaderPreferences(upscaleMode: MangaUpscaleMode.sharpen);
      const base = ReaderPreferences();
      final merged = work.mergedWithKeys(base, <String>{'upscaleMode'});
      expect(merged.upscaleMode, MangaUpscaleMode.sharpen);
      // 未列入覆盖键时跟随全局默认。
      final follow = work.mergedWithKeys(base, <String>{'filterBrightness'});
      expect(follow.upscaleMode, MangaUpscaleMode.off);
    });

    test('comicPrefsChangedKeys 能识别超分档位变更', () {
      const a = ReaderPreferences();
      const b = ReaderPreferences(upscaleMode: MangaUpscaleMode.resample);
      expect(comicPrefsChangedKeys(a, b), contains('upscaleMode'));
    });
  });

  group('ReaderDefaultSettings 超分桥接', () {
    test('默认关闭并映射到阅读器偏好', () {
      const s = ReaderDefaultSettings();
      expect(s.comicUpscaleMode, MangaUpscaleMode.off);
      expect(s.toReaderPreferences().upscaleMode, MangaUpscaleMode.off);
    });

    test('JSON 往返保持档位', () {
      const s = ReaderDefaultSettings(
        comicUpscaleMode: MangaUpscaleMode.sharpen,
      );
      final back = ReaderDefaultSettings.fromJson(s.toJson());
      expect(back.comicUpscaleMode, MangaUpscaleMode.sharpen);
      expect(back.toReaderPreferences().upscaleMode,
          MangaUpscaleMode.sharpen);
    });

    test('旧数据（无 comicUpscaleMode）回退 off', () {
      final json = const ReaderDefaultSettings().toJson()
        ..remove('comicUpscaleMode');
      expect(ReaderDefaultSettings.fromJson(json).comicUpscaleMode,
          MangaUpscaleMode.off);
    });
  });
}

//  超分辨率 shader：PlayerSettings.upscaleShader 序列化 / 剧集覆盖合并 /
// Anime4K 档位预设映射的纯单元验证。
//
// 完整 Player 构造需原生 libmpv（同 player_screen_test 的限制），故不覆盖
// setProperty('glsl-shaders') 通路，仅测无原生依赖的部分。

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/comic/models/reader_preferences.dart';
import 'package:nexhub/core/player/anime4k_shaders.dart';
import 'package:nexhub/core/settings/player_settings.dart';

void main() {
  group(' PlayerSettings.upscaleShader', () {
    test('默认关闭，toJson 随键持久化', () {
      const s = PlayerSettings();
      expect(s.upscaleShader, UpscaleShaderMode.off);
      expect(s.toJson()['upscaleShader'], 'off');
    });

    test('roundtrip：quality 保存后加载还原', () async {
      final store = PlayerSettingsStore(backend: InMemoryBackend());
      await store.save(const PlayerSettings().copyWith(
        upscaleShader: UpscaleShaderMode.quality,
      ));
      expect((await store.load()).upscaleShader, UpscaleShaderMode.quality);
    });

    test('未知值回退 off，缺键回退 off', () {
      final base = const PlayerSettings().toJson();
      expect(
        PlayerSettings.fromJson(<String, dynamic>{
          ...base,
          'upscaleShader': 'ultra',
        }).upscaleShader,
        UpscaleShaderMode.off,
      );
      base.remove('upscaleShader');
      expect(
        PlayerSettings.fromJson(base).upscaleShader,
        UpscaleShaderMode.off,
      );
    });

    test('剧集覆盖合并：单集 quality 优先于全局默认 off', () async {
      final prefs = InMemoryBackend();
      final episodeStore = EpisodePlayerSettingsStore(backend: prefs);
      await episodeStore.setField('item_1', 'upscaleShader', 'performance');
      final merged = await episodeStore.loadMerged(
        const PlayerSettings(),
        'item_1',
      );
      expect(merged.upscaleShader, UpscaleShaderMode.performance);
      // 其它剧集不受影响，仍跟随全局。
      final untouched = await episodeStore.loadMerged(
        const PlayerSettings(),
        'item_2',
      );
      expect(untouched.upscaleShader, UpscaleShaderMode.off);
    });
  });

  group(' Anime4kShaderCatalog', () {
    test('off 档直接返回空串（清空已加载 shader）', () async {
      expect(
        await Anime4kShaderCatalog.mpvShaderList(UpscaleShaderMode.off),
        '',
      );
    });

    test('两档预设与官方 Mode A Fast/HQ 组合一致', () {
      const fast = <String>[
        'Anime4K_Clamp_Highlights.glsl',
        'Anime4K_Restore_CNN_M.glsl',
        'Anime4K_Upscale_CNN_x2_M.glsl',
        'Anime4K_AutoDownscalePre_x2.glsl',
        'Anime4K_AutoDownscalePre_x4.glsl',
        'Anime4K_Upscale_CNN_x2_S.glsl',
      ];
      const hq = <String>[
        'Anime4K_Clamp_Highlights.glsl',
        'Anime4K_Restore_CNN_VL.glsl',
        'Anime4K_Upscale_CNN_x2_VL.glsl',
        'Anime4K_AutoDownscalePre_x2.glsl',
        'Anime4K_AutoDownscalePre_x4.glsl',
        'Anime4K_Upscale_CNN_x2_S.glsl',
      ];
      expect(kAnime4kPresetFiles[UpscaleShaderMode.performance], fast);
      expect(kAnime4kPresetFiles[UpscaleShaderMode.quality], hq);
      // off 无预设文件。
      expect(kAnime4kPresetFiles.containsKey(UpscaleShaderMode.off), isFalse);
    });

    test('部署版本标记存在（shader 更新时递增以强制重拷）', () {
      expect(kAnime4kDeployVersion, greaterThan(0));
    });
  });
}

// 动态效果设置模型：序列化往返 / 目录完整性 / 单效果开关 / 参数覆盖 /
// 引擎配置组装（EffectConfig 组装失败即引擎 fail-fast，测试直接暴露）。
import 'package:comic_motion/comic_motion.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/comic/models/motion_effect_settings.dart';

void main() {
  group('MotionEffectSettings 序列化', () {
    test('默认值往返一致', () {
      const m = MotionEffectSettings();
      final back = MotionEffectSettings.fromJson(m.toJson());
      expect(back, m);
      expect(back.enabled, isFalse);
      expect(back.effects, MotionEffectSettings.defaultEffectNames);
      expect(back.fps, MotionEffectSettings.defaultFps);
      expect(back.durationSec, MotionEffectSettings.defaultDurationSec);
      expect(back.maxDimension, MotionEffectSettings.defaultMaxDimension);
    });

    test('全字段往返一致（含参数覆盖）', () {
      final m = const MotionEffectSettings(enabled: true).withParam(
        'parallax',
        'amplitude',
        0.02,
      );
      final back = MotionEffectSettings.fromJson(m.toJson());
      expect(back, m);
      expect(back.paramOverrides['parallax']?['amplitude'], 0.02);
    });

    test('未知名效果被过滤且按目录排序', () {
      final m = MotionEffectSettings.fromJson(const {
        'enabled': true,
        'effects': ['rain', 'not_a_kind', 'parallax', 'breathing'],
      });
      expect(m.effects, ['parallax', 'breathing', 'rain']);
    });

    test('数值字段越界钳制', () {
      final m = MotionEffectSettings.fromJson(const {
        'fps': 999,
        'durationSec': 99,
        'maxDimension': 99,
      });
      expect(m.fps, 24);
      expect(m.durationSec, 6.0);
      expect(m.maxDimension, 480);
    });

    test('渲染时机不同则不相等（驱动阅读器重估调度）', () {
      const a = MotionEffectSettings();
      final b = a.copyWith(webtoonRenderMode: MotionWebtoonRenderMode.follow);
      expect(a == b, isFalse);
      expect(a == a.copyWith(), isTrue);
    });

    test('webtoonRenderMode 往返与非法值回退', () {
      const m = MotionEffectSettings(
          webtoonRenderMode: MotionWebtoonRenderMode.follow);
      final back = MotionEffectSettings.fromJson(m.toJson());
      expect(back.webtoonRenderMode, MotionWebtoonRenderMode.follow);
      // 非法值 / 缺失 → dwell。
      final fallback = MotionEffectSettings.fromJson(const {
        'webtoonRenderMode': 'bogus',
      });
      expect(fallback.webtoonRenderMode, MotionWebtoonRenderMode.dwell);
      expect(
        MotionEffectSettings.fromJson(const {}),
        const MotionEffectSettings(),
      );
    });

    test('非 Map 输入回退默认', () {
      expect(MotionEffectSettings.fromJson(null), const MotionEffectSettings());
      expect(
        MotionEffectSettings.fromJson('junk'),
        const MotionEffectSettings(),
      );
    });
  });

  group('MotionEffectCatalog', () {
    test('目录覆盖引擎全部效果且分组无重漏', () {
      final engineKinds = EffectKind.values.map((e) => e.name).toSet();
      expect(MotionEffectCatalog.allKinds.toSet(), engineKinds);
      final groupedAll = MotionEffectCatalog.grouped.values
          .expand((l) => l.map((s) => s.kind))
          .toSet();
      expect(groupedAll, engineKinds);
    });

    test('预设组合均由已知效果构成', () {
      final known = MotionEffectCatalog.allKinds.toSet();
      for (final p in MotionEffectCatalog.presets) {
        expect(p.effects.every(known.contains), isTrue, reason: p.id);
      }
    });
  });

  group('单效果开关与参数', () {
    test('withEffectEnabled 开/关', () {
      const m = MotionEffectSettings();
      final off = m.withEffectEnabled('ambient', false);
      expect(off.effects, ['parallax', 'breathing']);
      final onAgain = off.withEffectEnabled('rain', true);
      expect(onAgain.effects.contains('rain'), isTrue);
      expect(m.effects, MotionEffectSettings.defaultEffectNames); // 原值不变
    });

    test('withParam 设置与清除回默认', () {
      final spec = MotionEffectCatalog.specOf('parallax')!;
      final amp = spec.params.firstWhere((p) => p.key == 'amplitude');
      final m = const MotionEffectSettings().withParam('parallax', 'amplitude', 0.03);
      expect(m.paramValue(spec, amp), 0.03);
      final cleared = m.withParam('parallax', 'amplitude', null);
      expect(cleared.paramValue(spec, amp), amp.def);
      expect(cleared.paramOverrides.isEmpty, isTrue);
    });
  });

  group('toEffectConfig 组装', () {
    test('开关与参数覆盖生效', () {
      final m = const MotionEffectSettings(
        fps: 10,
        durationSec: 4.0,
        maxDimension: 640,
      ).withEffectEnabled('ambient', false).withParam('parallax', 'amplitude', 0.03);
      final cfg = m.toEffectConfig();
      expect(cfg.fps, 10);
      expect(cfg.durationSec, 4.0);
      expect(cfg.maxDimension, 640);
      expect(cfg.effects.map((e) => e.name), ['parallax', 'breathing']);
      expect(cfg.parallax.amplitude, 0.03);
      // 未覆盖参数保持引擎默认。
      expect(cfg.parallax.periodSec, const ParallaxParams().periodSec);
    });

    test('toFastEffectConfig 降耗但保留效果与参数', () {
      final m = const MotionEffectSettings(
        fps: 12,
        durationSec: 3.0,
        maxDimension: 720,
      ).withParam('parallax', 'amplitude', 0.03);
      final fast = m.toFastEffectConfig();
      expect(fast.fps, MotionEffectSettings.fastFpsCap);
      expect(fast.durationSec, MotionEffectSettings.fastDurationSecCap);
      expect(fast.maxDimension, MotionEffectSettings.fastMaxDimensionCap);
      // 效果组合与参数覆盖保持不变。
      expect(fast.effects.map((e) => e.name), m.effects);
      expect(fast.parallax.amplitude, 0.03);
      // 用户设置本就低于上限：不降。
      final mild = const MotionEffectSettings(
        fps: 6,
        durationSec: 2.0,
        maxDimension: 480,
      ).toFastEffectConfig();
      expect(mild.fps, 6);
      expect(mild.durationSec, 2.0);
      expect(mild.maxDimension, 480);
    });

    test('空组合回退默认且全未知名不崩溃', () {
      const m = MotionEffectSettings(effects: ['nope', 'nada']);
      final cfg = m.toEffectConfig();
      expect(cfg.effects.map((e) => e.name),
          MotionEffectSettings.defaultEffectNames);
    });
  });
}

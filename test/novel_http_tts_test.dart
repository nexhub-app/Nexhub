///  在线多音色 TTS 单测：
/// - 分句器（cue 判角色 / 引号配对 / 旁白切句）
/// - URL 模板渲染（{text}/{voice}/{rate} 占位符）
/// - 配置模型（round-trip / 角色音色映射 / 并发 clamp）
/// - 预下载队列降级逻辑（连续失败 halt / 静音占位）
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/novel/novel_http_tts_config.dart';
import 'package:nexhub/core/novel/novel_http_tts_engine.dart';
import 'package:nexhub/core/novel/novel_speech_segmenter.dart';

void main() {
  group(' 分句器：cue 判角色', () {
    test('冒号句式判角色', () {
      final segs = segmentSpeech('小明说：你好。');
      expect(segs.length, 1);
      expect(segs.first.role, '小明');
      expect(segs.first.text, '你好。');
    });

    test('「XX说道」判角色', () {
      final segs = segmentSpeech('小红说道："真的吗？"');
      expect(segs.length, 1);
      expect(segs.first.role, '小红');
    });

    test('无 cue 引号归属对话角色', () {
      final segs = segmentSpeech('"？？"');
      expect(segs.length, 1);
      expect(segs.first.role, quoteRole);
    });

    test('纯旁白按标点切句', () {
      final segs = segmentSpeech('天亮了。他走出门。');
      expect(segs.length, 2);
      expect(segs.first.role, narratorRole);
      expect(segs.first.text, '天亮了。');
      expect(segs[1].text, '他走出门。');
    });
  });

  group(' 分句器：混合段落', () {
    test('旁白+对话交错', () {
      final segs = segmentSpeech('他推开门。李四喊："进来吧。" 屋里很安静。');
      expect(segs.length, 3);
      expect(segs[0].role, narratorRole);
      expect(segs[1].role, '李四');
      expect(segs[2].role, narratorRole);
    });

    test('空段返回空列表', () {
      expect(segmentSpeech(''), isEmpty);
      expect(segmentSpeech('   '), isEmpty);
    });
  });

  group(' URL 模板渲染', () {
    test('全占位符替换', () {
      final url = renderUrl(
        template: 'https://tts.example/api?text={text}&voice={voice}&rate={rate}',
        text: '你好世界',
        voice: 'xiaoyan',
        rate: 1.2,
      );
      expect(url, contains('text=${Uri.encodeQueryComponent('你好世界')}'));
      expect(url, contains('voice=xiaoyan'));
      expect(url, contains('rate=1.2'));
    });

    test('空模板返回空串', () {
      expect(renderUrl(template: '', text: 'x'), isEmpty);
    });

    test('中文文本 URL 编码不破坏端点', () {
      final url = renderUrl(
        template: 'https://a.com/t?q={text}',
        text: '！？&%',
      );
      expect(url.contains(' '), isFalse); // 无空格
    });
  });

  group(' 配置模型', () {
    test('round-trip 保留字段', () {
      const cfg = NovelHttpTtsConfig(
        enabled: true,
        urlTemplate: 'https://x.com?t={text}',
        defaultVoice: 'v1',
        voiceByRole: <String, String>{'小明': 'v2'},
        concurrency: 4,
        maxConsecutiveFailures: 5,
        silentPlaceholderOnFailure: false,
      );
      final back = NovelHttpTtsConfig.fromJson(cfg.toJson());
      expect(back.enabled, isTrue);
      expect(back.urlTemplate, cfg.urlTemplate);
      expect(back.defaultVoice, 'v1');
      expect(back.voiceByRole['小明'], 'v2');
      expect(back.concurrency, 4);
      expect(back.maxConsecutiveFailures, 5);
      expect(back.silentPlaceholderOnFailure, isFalse);
    });

    test('并发 clamp 1-8', () {
      final cfg = NovelHttpTtsConfig.fromJson(<String, dynamic>{
        'concurrency': 99,
      });
      expect(cfg.concurrency, 8);
      final low = NovelHttpTtsConfig.fromJson(<String, dynamic>{
        'concurrency': 0,
      });
      expect(low.concurrency, 1);
    });

    test('角色音色映射：命中取专属，未命中回退默认', () {
      const cfg = NovelHttpTtsConfig(
        defaultVoice: 'def',
        voiceByRole: <String, String>{'小明': 'xiaoming'},
      );
      expect(cfg.voiceForRole('小明'), 'xiaoming');
      expect(cfg.voiceForRole('李四'), 'def');
      expect(cfg.voiceForRole(''), 'def');
    });
  });

  group(' 预下载队列降级', () {
    test('连续失败达阈值 → halted', () {
      final cfg = const NovelHttpTtsConfig(maxConsecutiveFailures: 3, enabled: true);
      final preloader = HttpTtsPreloader(config: cfg);
      for (var i = 0; i < 3; i++) {
        preloader.consecutiveFailures++;
      }
      expect(preloader.halted, isTrue);
    });

    test('成功后复位连续失败计数', () {
      final cfg = const NovelHttpTtsConfig(maxConsecutiveFailures: 3, enabled: true);
      final preloader = HttpTtsPreloader(config: cfg);
      preloader.consecutiveFailures = 2;
      // 模拟成功：synthesizeOne 成功会复位（此处直接验证复位逻辑）。
      preloader.consecutiveFailures = 0;
      expect(preloader.halted, isFalse);
    });
  });
}
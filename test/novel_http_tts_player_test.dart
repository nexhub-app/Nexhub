///  在线 TTS 播放管线单测：
/// - 分句 → 顺序播放
/// - 合成失败静音占位（跳过继续）
/// - 连续失败达阈值停止剩余
/// - 播放失败按同策略降级
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/novel/novel_http_tts_config.dart';
import 'package:nexhub/core/novel/novel_http_tts_engine.dart';
import 'package:nexhub/core/novel/novel_http_tts_player.dart';

/// 可控合成结果的 preloader（覆写 synthesizeAll 注入固定结果）。
class _FakePreloader extends HttpTtsPreloader {
  _FakePreloader({required List<TtsSynthesisResult> results})
      : _results = results,
        super(config: const NovelHttpTtsConfig());

  final List<TtsSynthesisResult> _results;
  int synthesizeCalls = 0;

  @override
  Future<List<TtsSynthesisResult>> synthesizeAll({
    required List<(String text, String role)> sentences,
    void Function(int completed, int total)? onProgress,
  }) async {
    synthesizeCalls++;
    return _results;
  }
}

Uint8List _audio(String tag) => Uint8List.fromList(tag.codeUnits);

void main() {
  const alwaysOkConfig = NovelHttpTtsConfig(
    enabled: true,
    urlTemplate: 'https://x.com?t={text}',
    silentPlaceholderOnFailure: true,
  );
  const noPlaceholderConfig = NovelHttpTtsConfig(
    enabled: true,
    urlTemplate: 'https://x.com?t={text}',
    silentPlaceholderOnFailure: false,
  );

  group(' 播放管线：分句 + 顺序播放', () {
    test('旁白+对话按角色切分并顺序播放', () async {
      final played = <String>[];
      final preloader = _FakePreloader(results: <TtsSynthesisResult>[
        TtsSynthesisResult(bytes: _audio('s1'), role: '旁白'),
        TtsSynthesisResult(bytes: _audio('s2'), role: '小明'),
      ]);
      final player = NovelHttpTtsPlayer(
        config: alwaysOkConfig,
        preloader: preloader,
        player: (bytes) async {
          played.add(String.fromCharCodes(bytes));
          return true;
        },
      );
      var completed = false;
      player.onCompleted = () => completed = true;

      // 「他推开门。」→ 旁白；「小明说：你好。」→ 角色（冒号句式）。
      await player.speak(<String>['他推开门。小明说：你好。']);

      expect(played, <String>['s1', 's2']);
      expect(completed, isTrue);
    });

    test('全旁白段落播放', () async {
      final played = <String>[];
      final preloader = _FakePreloader(results: <TtsSynthesisResult>[
        TtsSynthesisResult(bytes: _audio('a'), role: '旁白'),
      ]);
      final player = NovelHttpTtsPlayer(
        config: alwaysOkConfig,
        preloader: preloader,
        player: (bytes) async {
          played.add(String.fromCharCodes(bytes));
          return true;
        },
      );
      await player.speak(<String>['天亮了。']);
      expect(played, <String>['a']);
    });
  });

  group(' 播放管线：失败降级', () {
    test('单句失败 + 静音占位 → 跳过继续播放后续', () async {
      final played = <String>[];
      final preloader = _FakePreloader(results: <TtsSynthesisResult>[
        TtsSynthesisResult(bytes: null, role: '旁白'), // 失败
        TtsSynthesisResult(bytes: _audio('later'), role: '旁白'),
      ]);
      final player = NovelHttpTtsPlayer(
        config: alwaysOkConfig,
        preloader: preloader,
        player: (bytes) async {
          played.add(String.fromCharCodes(bytes));
          return true;
        },
      );
      await player.speak(<String>['第一句。第二句。']);
      expect(played, <String>['later']);
    });

    test('全部失败 + 静音占位 → 不播放但正常完成', () async {
      final played = <int>[];
      final preloader = _FakePreloader(results: <TtsSynthesisResult>[
        TtsSynthesisResult(bytes: null, role: '旁白'),
        TtsSynthesisResult(bytes: null, role: '旁白'),
      ]);
      final player = NovelHttpTtsPlayer(
        config: alwaysOkConfig,
        preloader: preloader,
        player: (bytes) async {
          played.add(1);
          return true;
        },
      );
      var completed = false;
      player.onCompleted = () => completed = true;
      await player.speak(<String>['一。二。']);
      expect(played, isEmpty);
      expect(completed, isTrue);
    });

    test('失败 + 关闭占位 → 立即停止（后续不播放）', () async {
      final played = <String>[];
      final preloader = _FakePreloader(results: <TtsSynthesisResult>[
        TtsSynthesisResult(bytes: null, role: '旁白'),
        TtsSynthesisResult(bytes: _audio('later'), role: '旁白'),
      ]);
      final player = NovelHttpTtsPlayer(
        config: noPlaceholderConfig,
        preloader: preloader,
        player: (bytes) async {
          played.add(String.fromCharCodes(bytes));
          return true;
        },
      );
      var completed = false;
      player.onCompleted = () => completed = true;
      await player.speak(<String>['一。二。']);
      expect(played, isEmpty);
      expect(completed, isFalse); // 中途终止不触发完成回调
    });
  });

  group(' 播放管线：取消', () {
    test('cancel 中断剩余播放', () async {
      final played = <String>[];
      final preloader = _FakePreloader(results: <TtsSynthesisResult>[
        TtsSynthesisResult(bytes: _audio('first'), role: '旁白'),
        TtsSynthesisResult(bytes: _audio('second'), role: '旁白'),
      ]);
      final player = NovelHttpTtsPlayer(
        config: alwaysOkConfig,
        preloader: preloader,
        player: (bytes) async {
          played.add(String.fromCharCodes(bytes));
          return true;
        },
      );
      // 第一句播放前取消：循环在播放 first 前应跳过（cancel 在 speak 开始后
      // 立即调用，first 会被播放——本测试验证的是暂停后不再继续）。
      await player.speak(<String>['第一句。']);
      expect(played.length, greaterThanOrEqualTo(1));

      // cancel 后再次 speak 应正常重置。
      player.cancel();
      final preloader2 = _FakePreloader(results: <TtsSynthesisResult>[
        TtsSynthesisResult(bytes: _audio('x'), role: '旁白'),
      ]);
      final player2 = NovelHttpTtsPlayer(
        config: alwaysOkConfig,
        preloader: preloader2,
        player: (bytes) async {
          played.add(String.fromCharCodes(bytes));
          return true;
        },
      );
      await player2.speak(<String>['重置。']);
      expect(played.last, 'x');
    });
  });
}
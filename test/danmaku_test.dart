import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/widgets/danmaku.dart';

void main() {
  group('DanmakuController', () {
    test('pending returns items at or before position, once', () {
      final items = <DanmakuItem>[
        DanmakuItem(text: 'a', time: const Duration(seconds: 1)),
        DanmakuItem(text: 'b', time: const Duration(seconds: 3)),
        DanmakuItem(text: 'c', time: const Duration(seconds: 5)),
      ];
      final ctrl = DanmakuController(items);

      expect(ctrl.pending(const Duration(seconds: 2)), hasLength(1));
      // 同一位置再次调用不会重复给出已展示的弹幕
      expect(ctrl.pending(const Duration(seconds: 2)), isEmpty);
      // 推进时间后给出剩余弹幕
      expect(ctrl.pending(const Duration(seconds: 6)), hasLength(2));
      expect(ctrl.pending(const Duration(seconds: 6)), isEmpty);
    });

    test('reset clears shown state', () {
      final items = <DanmakuItem>[
        DanmakuItem(text: 'a', time: const Duration(seconds: 1)),
      ];
      final ctrl = DanmakuController(items);
      expect(ctrl.pending(const Duration(seconds: 2)), hasLength(1));
      ctrl.reset();
      expect(ctrl.pending(const Duration(seconds: 2)), hasLength(1));
    });

    test('demo produces requested count', () {
      final demo = DanmakuController.demo(10);
      expect(demo, hasLength(10));
      expect(demo.first.time, const Duration(seconds: 0));
      expect(demo[1].time, const Duration(seconds: 2));
    });

    test('F-20: same text within 5s window merged, kept beyond window', () {
      final items = <DanmakuItem>[
        DanmakuItem(text: '哈哈哈', time: const Duration(seconds: 10)),
        DanmakuItem(text: '哈哈哈', time: const Duration(seconds: 12)),
        DanmakuItem(text: '哈哈哈', time: const Duration(seconds: 14)),
        // 距上一次保留(10s)已超 5s → 保留
        DanmakuItem(text: '哈哈哈', time: const Duration(seconds: 16)),
        // 不同文本不受影响
        DanmakuItem(text: '名场面', time: const Duration(seconds: 11)),
      ];
      final merged = DanmakuController.mergeDuplicates(items);
      expect(merged, hasLength(3));
      expect(merged.map((e) => e.time.inSeconds), <int>[10, 11, 16]);
    });

    test('F-20: self-sent danmaku never merged', () {
      final items = <DanmakuItem>[
        DanmakuItem(text: '我发的', time: const Duration(seconds: 1)),
        DanmakuItem(
            text: '我发的', time: const Duration(seconds: 2), selfSend: true),
      ];
      final merged = DanmakuController.mergeDuplicates(items);
      expect(merged, hasLength(2));
    });

    test('F-20: setItems dedupes and pending reflects merged list', () {
      final ctrl = DanmakuController(<DanmakuItem>[
        DanmakuItem(text: '刷屏', time: const Duration(seconds: 1)),
        DanmakuItem(text: '刷屏', time: const Duration(seconds: 2)),
      ]);
      expect(ctrl.pending(const Duration(seconds: 5)), hasLength(1));
    });
  });
}

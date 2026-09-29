// 条漫动态效果：可见条目选取纯函数（webtoonMotionFlatIndices）。
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/features/manga/presentation/comic_reader_screen.dart';

void main() {
  group('webtoonMotionFlatIndices', () {
    test('完整可见的长图入选', () {
      // 一张占满视口的长图：可见比例 100%。
      final r = webtoonMotionFlatIndices([
        (index: 0, leading: 0.0, trailing: 1.0),
      ]);
      expect(r, [0]);
    });

    test('部分可见（滚入/滚出中）的条目不入选', () {
      final r = webtoonMotionFlatIndices([
        (index: 0, leading: -0.5, trailing: 0.4), // 可见 40%
        (index: 1, leading: 0.45, trailing: 1.4), // 可见 55%（<60% 阈值）
      ]);
      expect(r, isEmpty);
    });

    test('短图一屏多张：全部可见项入选且按索引升序', () {
      final r = webtoonMotionFlatIndices([
        (index: 5, leading: 0.75, trailing: 1.0),
        (index: 3, leading: 0.0, trailing: 0.25),
        (index: 4, leading: 0.25, trailing: 0.75),
        (index: 2, leading: -0.4, trailing: 0.02), // 滚出中，可见 ~2%
      ]);
      expect(r, [3, 4, 5]);
    });

    test('长图仅视口内部分可见：按可见/自身高度计比例入选', () {
      // 高度 2 倍视口的长图，视口展示其中 40% 的部分：可见比例 = 40%，
      // 但它就是「正在阅读的那张」——阈值按【条目自身】计，这里不入选属预期
      // （滚到其中段时它还没占满 60% 自身高度的场景较少见）。
      final r = webtoonMotionFlatIndices([
        (index: 0, leading: -0.6, trailing: 1.0), // 自身 80% 可见 → 入选
      ]);
      expect(r, [0]);
    });

    test('超过上限时截断到前 maxCount 条', () {
      final items = <({int index, double leading, double trailing})>[
        for (var i = 0; i < 8; i++)
          (index: i, leading: i * 0.125, trailing: (i + 1) * 0.125),
      ];
      expect(webtoonMotionFlatIndices(items), [0, 1, 2, 3]);
    });

    test('零高度条目被忽略', () {
      final r = webtoonMotionFlatIndices([
        (index: 0, leading: 0.5, trailing: 0.5),
        (index: 1, leading: 0.0, trailing: 0.9),
      ]);
      expect(r, [1]);
    });
  });
}

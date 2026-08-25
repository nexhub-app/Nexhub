/// 九区点按动作自测（N2）：枚举解析、九区索引换算、经典映射完整性。
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/novel/novel_tap_action.dart';

void main() {
  group('NovelTapAction', () {
    test('tryParse 合法名与未知值', () {
      expect(NovelTapAction.tryParse('menu'), NovelTapAction.menu);
      expect(
          NovelTapAction.tryParse('purifyToggle'), NovelTapAction.purifyToggle);
      expect(NovelTapAction.tryParse('bogus'), isNull);
      expect(NovelTapAction.tryParse(null), isNull);
    });

    test('经典映射覆盖 9 区且与旧 lShape 语义一致', () {
      expect(kNovelTapZoneClassic.length, 9);
      // 左列 prev / 中列 menu / 右列 next
      for (var row = 0; row < 3; row++) {
        expect(kNovelTapZoneClassic[row * 3], NovelTapAction.prevPage);
        expect(kNovelTapZoneClassic[row * 3 + 1], NovelTapAction.menu);
        expect(kNovelTapZoneClassic[row * 3 + 2], NovelTapAction.nextPage);
      }
    });
  });

  group('novelTapGridIndexOf', () {
    test('四角与中心命中正确区域', () {
      const size = Size(300, 600);
      int at(double dx, double dy) =>
          novelTapGridIndexOf(Offset(dx, dy), size);

      expect(at(10, 10), 0); // 左上
      expect(at(150, 10), 1); // 上中
      expect(at(290, 10), 2); // 右上
      expect(at(10, 300), 3); // 左中
      expect(at(150, 300), 4); // 中心
      expect(at(290, 300), 5); // 右中
      expect(at(10, 590), 6); // 左下
      expect(at(290, 590), 8); // 右下
    });

    test('零尺寸不抛异常（防御，回退中心区）', () {
      expect(novelTapGridIndexOf(Offset.zero, Size.zero), 4);
    });
  });
}

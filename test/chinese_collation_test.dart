/// 中文拼音序比较器自测（M2）：GBK 一级字库近似拼音序、ASCII 前置、回退安全。
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/utils/chinese_collation.dart';

void main() {
  group('compareZhPinyin', () {
    test('按拼音首字母排序（a < b < c）', () {
      final titles = <String>['曹操', '白雪', '安徒生'];
      titles.sort(compareZhPinyin);
      expect(titles, <String>['安徒生', '白雪', '曹操']);
    });

    test('同首字母按后续音节细分（dou < du）', () {
      expect(compareZhPinyin('斗破苍穹', '独孤天下'), lessThan(0));
    });

    test('相同字符串相等', () {
      expect(compareZhPinyin('诡秘之主', '诡秘之主'), 0);
    });

    test('ASCII 标题排在汉字之前', () {
      expect(compareZhPinyin('Re0', '斗破苍穹'), lessThan(0));
    });

    test('前缀短的在前', () {
      expect(compareZhPinyin('凡人', '凡人修仙传'), lessThan(0));
    });
  });
}

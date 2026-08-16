import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/utils/natural_sort.dart';

void main() {
  test('纯数字文件名按数值排序（REQ-C0）', () {
    final list = <String>['10.jpg', '2.jpg', '1.jpg', '3.jpg']
      ..sort(naturalCompare);
    expect(list, <String>['1.jpg', '2.jpg', '3.jpg', '10.jpg']);
  });

  test('混合前缀数字排序', () {
    final list = <String>['page-2', 'page-10', 'page-1', 'page-1a', 'page-1b']
      ..sort(naturalCompare);
    expect(list,
        <String>['page-1', 'page-1a', 'page-1b', 'page-2', 'page-10']);
  });

  test('数值相等时回退字典序（前导零）', () {
    expect(naturalCompare('001', '1'), lessThan(0));
    expect(naturalCompare('01', '1'), lessThan(0));
    expect(naturalCompare('1', '001'), greaterThan(0));
  });

  test('无数字段按字典序', () {
    final list = <String>['b.jpg', 'a.jpg', 'c.jpg']..sort(naturalCompare);
    expect(list, <String>['a.jpg', 'b.jpg', 'c.jpg']);
  });

  test('相同字符串相等，前缀较短的排前', () {
    expect(naturalCompare('a', 'a'), 0);
    expect(naturalCompare('a', 'ab'), lessThan(0));
    expect(naturalCompare('ab', 'a'), greaterThan(0));
  });
}

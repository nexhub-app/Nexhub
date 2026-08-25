/// 中文拼音序比较器（书架「中文书名」排序用，M2）。
///
/// GBK 编码的一级汉字区（3755 个常用字）本身即按拼音顺序排列，因此把
/// 字符串编码为 GBK 字节序列后逐字节比较，即可得到近似拼音序，无需引入
/// 拼音标注库。生僻字位于二级字库，会排在常用字之后（可接受的近似）；
/// ASCII 字符（数字/字母）按字节序排在汉字之前。
library;

import 'package:fast_gbk/fast_gbk.dart';

/// 按近似拼音序比较两个中文标题。
///
/// 统一小写后编码为 GBK 字节逐位比较；任一侧编码失败时回退到 Dart
/// 码元序 [String.compareTo]。
int compareZhPinyin(String a, String b) {
  final la = a.toLowerCase();
  final lb = b.toLowerCase();
  if (la == lb) return 0;
  List<int>? ea;
  List<int>? eb;
  try {
    ea = gbk.encode(la);
    eb = gbk.encode(lb);
  } on Object {
    return la.compareTo(lb);
  }
  final n = ea.length < eb.length ? ea.length : eb.length;
  for (var i = 0; i < n; i++) {
    final c = ea[i].compareTo(eb[i]);
    if (c != 0) return c;
  }
  return ea.length.compareTo(eb.length);
}

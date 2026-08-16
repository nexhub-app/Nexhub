/// 自然排序（数字感知比较器）。
///
/// 按「数字段数值 + 非数字段字典序」逐段比较，使纯数字文件名
/// `1.jpg / 2.jpg / 10.jpg` 按 1→2→10 排序（而非字典序 1→10→2）。
/// 与 CBZ 归档解压路径的排序保持一致（共享同一比较器）。
int naturalCompare(String a, String b) {
  final RegExp chunk = RegExp(r'\d+|\D+');
  final Iterable<Match> am = chunk.allMatches(a);
  final Iterable<Match> bm = chunk.allMatches(b);
  final Iterator<Match> ai = am.iterator;
  final Iterator<Match> bi = bm.iterator;
  while (true) {
    final bool ha = ai.moveNext();
    final bool hb = bi.moveNext();
    if (!ha && !hb) return 0;
    if (!ha) return -1;
    if (!hb) return 1;
    final String sa = ai.current.group(0)!;
    final String sb = bi.current.group(0)!;
    final int? na = int.tryParse(sa);
    final int? nb = int.tryParse(sb);
    if (na != null && nb != null) {
      if (na != nb) return na.compareTo(nb);
      // 数值相等（如前导零差异）时回退字典序，保证稳定。
      final int c = sa.compareTo(sb);
      if (c != 0) return c;
    } else {
      final int c = sa.compareTo(sb);
      if (c != 0) return c;
    }
  }
}

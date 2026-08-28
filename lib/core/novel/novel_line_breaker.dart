/// 中文逐字断行 + 禁首禁尾标点处理器（/ A5，对标 ZhLayout 语义）。
///
/// 输入一段文本与排版约束（可用宽度、样式），输出按「逐字符断行 + 禁则
/// 处理」切出的视觉行列表。与 [NovelPaginator._breakParagraph]（原生折行）
/// 二选一，由 `prefs.lineBreakMode` 决定。
///
/// 禁则规则（推挤式，无行溢出风险）：
/// - **行首禁排**（闭合标点不得出现在行首）：`」』】〕）、。，！？` 等 ——
///   遇之则连同前一字符一起推到下一行（标点落在次行第二位起）。
/// - **行尾禁排**（开启标点不得出现在行尾）：`「『【〔（` 等 ——
///   该开启标点随下一字符一起换到新行。
/// - 回退迭代直到断点两侧均满足禁则；保证每行至少 1 字符（防死循环）。
///
/// 测宽用 [TextPainter]（与分页器/渲染同源样式），保证断行结果与渲染一致。
library;

import 'package:flutter/widgets.dart';

/// 行首禁排字符集（闭合类标点）。
const String kLineStartForbidden = '」』】〕）｝〉》，．!?？；：、。，…‥·"\'％℃‰';

/// 行尾禁排字符集（开启类标点）。
const String kLineEndForbidden = '「『【〔（｛〈《"\'';

/// 判定字符是否禁止出现在行首。
bool isLineStartForbidden(String ch) =>
    ch.isNotEmpty && kLineStartForbidden.contains(ch);

/// 判定字符是否禁止出现在行尾。
bool isLineEndForbidden(String ch) =>
    ch.isNotEmpty && kLineEndForbidden.contains(ch);

/// 单条断行结果行。
class BrokenLine {
  /// 行文本。
  final String text;

  /// 行内各字符的左边缘 x 坐标（相对行首；供命中测试/选区复用）。
  final List<double> charLefts;

  const BrokenLine({required this.text, required this.charLefts});
}

/// 中文禁则断行器。
abstract final class NovelLineBreaker {
  /// 把段落 [para] 按「逐字断行 + 禁则」切行。
  ///
  /// [style] / [dir] / [scaler] 与正文渲染一致；[width] 为可用行宽。
  /// 算法：
  /// 1. 逐字符测累计宽度（单字符独立布局近似测宽：CJK 等宽字体无误差；
  ///    比例字体取保守值，断行偏早不偏晚，不会超宽溢出）；
  /// 2. 累计超过 [width] 时在当前位置断行，并按禁则向前回退调整断点；
  /// 3. 断行后对每行整体布局重测各字符左边缘（保证与渲染坐标一致）。
  static List<BrokenLine> breakParagraph(
    String para,
    TextStyle style,
    double width,
    TextDirection dir,
    TextScaler scaler,
  ) {
    if (para.isEmpty) return const <BrokenLine>[];
    if (width <= 0) {
      // 退化：每字符一行（防御性，正常排版约束不会出现）。
      return <BrokenLine>[
        for (var i = 0; i < para.length; i++)
          BrokenLine(text: para[i], charLefts: const <double>[0]),
      ];
    }

    final probe = TextPainter(
      text: TextSpan(text: '中', style: style),
      textDirection: dir,
      textScaler: scaler,
    )..layout(maxWidth: double.infinity);

    // 字符宽度探针：以单个字符独立布局测宽。
    double charWidthOf(String ch) {
      probe.text = TextSpan(text: ch, style: style);
      probe.layout(maxWidth: double.infinity);
      return probe.maxIntrinsicWidth;
    }

    final lines = <BrokenLine>[];
    var lineStart = 0; // 当前行起始下标
    var lineWidth = 0.0; // 当前行已累计宽度
    var i = 0;
    while (i < para.length) {
      final w = charWidthOf(para[i]);
      if (lineWidth + w > width && i > lineStart) {
        // 超宽：候选断点 = i（当前行取 [lineStart, i)）。按禁则回退：
        // 「新行行首为闭合标点」或「本行行尾为开启标点」都继续回退一位，
        // 直至满足或只剩 1 字符（防死循环）。
        var end = i;
        while (end > lineStart + 1 &&
            (isLineStartForbidden(para[end]) ||
                isLineEndForbidden(para[end - 1]))) {
          end--;
        }
        lines.add(
            _measureLine(para, lineStart, end, style, dir, scaler));
        lineStart = end;
        lineWidth = 0;
        i = lineStart;
        continue;
      }
      lineWidth += w;
      i++;
    }
    probe.dispose();
    if (lineStart < para.length) {
      lines.add(
          _measureLine(para, lineStart, para.length, style, dir, scaler));
    }
    return lines;
  }

  /// 对 [para] 的 [start]–[end] 子串整体布局，产出最终行文本与
  /// 逐字符左边缘坐标（与渲染断行完全一致）。
  static BrokenLine _measureLine(
    String para,
    int start,
    int end,
    TextStyle style,
    TextDirection dir,
    TextScaler scaler,
  ) {
    final text = para.substring(start, end);
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: dir,
      textScaler: scaler,
    )..layout(maxWidth: double.infinity);
    final charLefts = <double>[];
    for (var c = 0; c < text.length; c++) {
      final caret = tp.getOffsetForCaret(TextPosition(offset: c), Rect.zero);
      charLefts.add(caret.dx);
    }
    tp.dispose();
    return BrokenLine(text: text, charLefts: charLefts);
  }
}

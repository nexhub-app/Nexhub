/// 漫画译文「气泡内回填」排版引擎（F7 漫画排版回填）。
///
/// 纯函数、零渲染依赖（宽度用字符类别估算：全角/CJK ≈ 字号，
/// 半角拉丁/数字 ≈ 0.55 字号），保证同一会话内字号/换行确定性一致：
/// - **按 bbox 宽度换行**：CJK 逐字断行（禁则处理：行首禁排收尾标点、
///   行尾禁排起始标点），拉丁单词保持完整；
/// - **字号自适应**：在 [maxFont]–[minFont] 区间二分搜索「换行后总高度
///   恰好放进 bbox」的字号；
/// - **竖排降级**：竖排（日漫）气泡 v1 一律横排居中渲染（产品说明中
///   标注限制），由渲染层处理，本引擎不做方向变换；
/// - 渲染层对每行再包 FittedBox 兜底，估算误差不会导致溢出。
library;

import 'package:characters/characters.dart';

/// 排版结果：选定字号 + 断好的行。
class BackfillLayoutResult {
  final double fontSize;
  final List<String> lines;

  const BackfillLayoutResult({required this.fontSize, required this.lines});
}

/// 行首禁排（收尾类标点不可出现在行首）。
const String _kNoLineStart =
    '」』）】〉》〕］｝．。，、；：？！…‥＿ー!"),.;:?]';

/// 行尾禁排（起始类标点不可出现在行尾）。
const String _kNoLineEnd = '（【〔［｛「『〈《（([{"\'';

/// 回填排版。
abstract final class BackfillLayout {
  /// 单字符宽度估算（字号基准）。
  static double charWidth(String ch, double fontSize) {
    if (ch.isEmpty) return 0;
    final code = ch.runes.first;
    // CJK / 全角标点 / 假名 / 谚文 → 全宽。
    if (code >= 0x1100 && (code <= 0x115F || // 谚文 Jamo
        code == 0x2329 ||
        code == 0x232A ||
        (code >= 0x2E80 && code <= 0xA4CF && code != 0x303F) || // CJK 部首~谚文音节
        (code >= 0xA960 && code <= 0xA97F) ||
        (code >= 0xAC00 && code <= 0xD7A3) ||
        (code >= 0xF900 && code <= 0xFAFF) ||
        (code >= 0xFE10 && code <= 0xFE19) ||
        (code >= 0xFE30 && code <= 0xFE6F) ||
        (code >= 0xFF00 && code <= 0xFF60) ||
        (code >= 0xFFE0 && code <= 0xFFE6) ||
        (code >= 0x20000 && code <= 0x3FFFD))) {
      return fontSize;
    }
    return fontSize * 0.55; // 拉丁 / 数字 / 半角标点估算。
  }

  static bool _isLatinWordChar(String ch) {
    if (ch.isEmpty) return false;
    final code = ch.runes.first;
    return (code >= 0x30 && code <= 0x39) || // 0-9
        (code >= 0x41 && code <= 0x5A) || // A-Z
        (code >= 0x61 && code <= 0x7A) || // a-z
        code == 0x27 ||
        code == 0x2D; // ' 与 -（连字符保词）
  }

  /// 把一行文本按宽度 [maxWidthPx] 断行（禁则处理）。
  static List<String> breakLine(String text, double maxWidthPx, double fontSize) {
    if (maxWidthPx <= 0) return <String>[text];
    final lines = <String>[];
    final buffer = <String>[]; // 当前行字符缓冲。
    double width = 0;
    var i = 0;
    final chars = text.characters.toList();
    String? pendingLatin;
    double pendingLatinWidth = 0;

    void flushLine() {
      lines.add(buffer.join());
      buffer.clear();
      width = 0;
    }

    while (i < chars.length) {
      final ch = chars[i];
      // 拉丁单词整词处理（含后续字母/数字/'/-）。
      if (_isLatinWordChar(ch)) {
        final word = StringBuffer();
        var j = i;
        while (j < chars.length && _isLatinWordChar(chars[j])) {
          word.write(chars[j]);
          j++;
        }
        pendingLatin = word.toString();
        pendingLatinWidth = pendingLatin.runes
            .fold(0.0, (w, _) => w + fontSize * 0.55);
        i = j;
        continue;
      }
      // 先落盘待排单词。
      if (pendingLatin != null) {
        if (width + pendingLatinWidth > maxWidthPx && buffer.isNotEmpty) {
          flushLine();
        }
        buffer.add(pendingLatin);
        width += pendingLatinWidth;
        pendingLatin = null;
        continue;
      }
      final w = charWidth(ch, fontSize);
      if (width + w > maxWidthPx && buffer.isNotEmpty) {
        // 行首禁则：收尾标点不可落单行首 → 追加到当前行再换行。
        if (_kNoLineStart.contains(ch)) {
          buffer.add(ch);
          flushLine();
          i++;
          continue;
        }
        // 行尾禁则：起始标点不可留行尾 → 移到下一行（可能连续），
        // 回退 i 让被移字符在新行重新参与断行。
        var back = 0;
        while (buffer.isNotEmpty && _kNoLineEnd.contains(buffer.last)) {
          buffer.removeLast();
          back++;
        }
        if (buffer.isNotEmpty) {
          flushLine();
          i -= back;
          continue;
        }
        // 整行都是起始标点的极端情况：按普通断行处理，避免死循环。
        flushLine();
        i -= back;
        continue;
      }
      buffer.add(ch);
      width += w;
      i++;
    }
    // 收尾：残余拉丁词与残余字符。
    if (pendingLatin != null) {
      if (width + pendingLatinWidth > maxWidthPx && buffer.isNotEmpty) {
        flushLine();
      }
      buffer.add(pendingLatin);
    }
    if (buffer.isNotEmpty) lines.add(buffer.join());
    return lines.isEmpty ? <String>[text] : lines;
  }

  /// 整段文本按字号 [fontSize] 断行。
  static List<String> wrap(String text, double maxWidthPx, double fontSize) {
    final result = <String>[];
    for (final paragraph in text.split('\n')) {
      if (paragraph.trim().isEmpty) {
        continue;
      }
      result.addAll(breakLine(paragraph, maxWidthPx, fontSize));
    }
    return result.isEmpty ? const <String>[''] : result;
  }

  /// 自适应排版：二分搜索能放进 [boxW]×[boxH] 的最大字号。
  ///
  /// [lineHeight] 为行高倍率；找不到合适字号时回落 [minFont]（渲染层
  /// 再以 FittedBox 兜底收缩）。
  static BackfillLayoutResult layout({
    required String text,
    required double boxW,
    required double boxH,
    double minFont = 8,
    double maxFont = 48,
    double lineHeight = 1.22,
  }) {
    if (text.trim().isEmpty || boxW <= 0 || boxH <= 0) {
      return BackfillLayoutResult(fontSize: minFont, lines: <String>[text]);
    }
    var best = minFont;
    var bestLines = wrap(text, boxW, minFont);
    double lo = minFont;
    double hi = maxFont;
    // 二分 18 次足够收敛到 0.01px 级别。
    for (var iter = 0; iter < 18; iter++) {
      final mid = (lo + hi) / 2;
      final lines = wrap(text, boxW, mid);
      final totalHeight = lines.length * mid * lineHeight;
      if (totalHeight <= boxH) {
        best = mid;
        bestLines = lines;
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return BackfillLayoutResult(fontSize: best, lines: bestLines);
  }

  /// 竖排启发式（F7 v1 降级标记）：bbox 高宽比大且原文含 CJK 时疑似竖排。
  /// 仅用于 UI 提示与统计，回填渲染一律横排居中。
  static bool looksVertical({required double boxW, required double boxH, required String sourceText}) {
    if (boxW <= 0 || boxH <= 0) return false;
    final hasCjk = sourceText.runes.any((c) =>
        (c >= 0x3040 && c <= 0x30FF) || // 假名
        (c >= 0x4E00 && c <= 0x9FFF)); // CJK 统一表意
    return boxH / boxW >= 1.6 && hasCjk;
  }
}

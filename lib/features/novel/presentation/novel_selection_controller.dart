/// 小说阅读器选区控制器（P1-5 / N6）。
///
/// 维护「章节全局字符偏移」坐标系下的选区与已存划线，使它们锚定到同一处文字，
/// 对字号 / 边距 / 排版变化恒定（复用阅读器既有的 _charOffsetForPage /
/// _pageForCharOffset 模型：章节文本流 = 各页各行 `line.text` 直接拼接，行间
/// 不加分隔符）。
///
/// 活动选区与已存划线都以半开区间 [start, end) 表示（end 不含）。
library;

import 'package:flutter/foundation.dart';

import 'package:nexhub/core/models/novel_block.dart';
import 'novel_highlight_manager.dart';
import 'novel_paginator.dart';

/// 划线效果枚举。
enum HighlightEffect {
  bg,
  underline,
  wavy,
  dotted;

  String get l10nKey => switch (this) {
        HighlightEffect.bg => 'highlightEffectBg',
        HighlightEffect.underline => 'highlightEffectUnderline',
        HighlightEffect.wavy => 'highlightEffectWavy',
        HighlightEffect.dotted => 'highlightEffectDotted',
      };
}

/// 单行内需要背景高亮的字符区间 [start, end)（半开）。
///
/// 公开类型：渲染层（[_NovelPageWidget]）需跨库引用。
class HighlightSpan {
  const HighlightSpan(this.start, this.end, this.color, this.isActive, {this.effect = HighlightEffect.bg});

  final int start;
  final int end;
  final int color;

  /// 是否为活动选区（渲染优先级最高）。
  final bool isActive;

  /// 划线效果（默认背景高亮）。
  final HighlightEffect effect;
}

/// 已解析（已重定位）的划线，用于渲染与跳转。
class _ResolvedHighlight {
  const _ResolvedHighlight(this.start, this.end, this.color, this.key, {this.effect = HighlightEffect.bg});

  final int start;
  final int end;
  final int color;

  /// 对应 [NovelHighlight.key]，便于点击/删除时回查。
  final String key;

  /// 划线效果。
  final HighlightEffect effect;
}

/// 选区 / 划线控制器。
///
/// 由阅读器在每章分页完成后调用 [setPagination] 注入分页结果；手势层调用
/// [setSelection] / [clearSelection]；渲染层调用 [lineSpans] 获取某行应高亮的
/// 区间；持久化层调用 [setPersistedHighlights] 注入已存划线（内部自动重定位）。
class NovelSelectionController extends ChangeNotifier {
  /// 活动选区颜色（半透明蓝）。
  static const int activeColor = 0x809FCCF3;

  NovelPaginationResult? _pagination;
  String _chapterText = '';
  int? _selectionStart;
  int? _selectionEnd;
  final List<_ResolvedHighlight> _highlights = <_ResolvedHighlight>[];

  NovelPaginationResult? get pagination => _pagination;

  bool get hasSelection =>
      _selectionStart != null &&
      _selectionEnd != null &&
      _selectionStart != _selectionEnd;

  int? get selectionStart => _selectionStart;
  int? get selectionEnd => _selectionEnd;

  /// 是否正在长按拖拽选区（用于通知外层翻页手势让出指针）。
  bool _selecting = false;
  bool get isSelecting => _selecting;
  void setSelecting(bool v) {
    if (_selecting == v) return;
    _selecting = v;
  }

  /// 长按起始锚点（章节全局偏移）；拖拽中用于和当前落点构成选区。
  int? _anchor;
  int? get selectionAnchor => _anchor;
  void setSelectionAnchor(int? v) => _anchor = v;

  /// 注入本章分页结果：重建章节文本流并清空活动选区（已存划线由
  /// [setPersistedHighlights] 重新解析）。
  void setPagination(NovelPaginationResult pagination) {
    _pagination = pagination;
    final buf = StringBuffer();
    for (final page in pagination.pages) {
      for (final item in page) {
        if (item is NovelTextLineItem) buf.write(item.line.text);
      }
    }
    _chapterText = buf.toString();
    _selectionStart = null;
    _selectionEnd = null;
    notifyListeners();
  }

  /// 滚动模式入口：直接注入章节 [blocks]（与分页同源，文本流一致）。
  ///
  /// 分页模式下 [setPagination] 由 blocks 分页后重建文本流；滚动模式无分页，
  /// 这里直接用同一份 blocks 重建同一文本流，使选区 / 划线坐标系完全共用。
  void setBlocks(List<NovelBlock> blocks) {
    _pagination = null;
    final buf = StringBuffer();
    for (final b in blocks) {
      if (b is NovelTextBlock) buf.write(b.text);
    }
    _chapterText = buf.toString();
    _selectionStart = null;
    _selectionEnd = null;
    notifyListeners();
  }

  /// 滚动模式：返回某文本块（按 [blockIndex] 在注入 blocks 中的顺序）在章节
  /// 文本流中的起始全局偏移。
  int _globalStartOfBlock(int blockIndex, List<NovelBlock> blocks) {
    var offset = 0;
    for (var i = 0; i < blockIndex; i++) {
      final b = blocks[i];
      if (b is NovelTextBlock) offset += b.text.length;
    }
    return offset;
  }

  /// 滚动模式：把「块内字符下标」映射为章节全局偏移。
  ///
  /// [blocks] 为注入的章节块列表（调用方持有，与 [setBlocks] 同源）。
  int globalOffsetForBlock(
    List<NovelBlock> blocks,
    int blockIndex,
    int charIndexInBlock,
  ) =>
      _globalStartOfBlock(blockIndex, blocks) + charIndexInBlock;

  /// 滚动模式：返回某文本块应高亮的本地字符区间列表（活动选区 + 已存划线）。
  ///
  /// [blocks] 为注入的章节块列表；[blockIndex] 为该块在列表中的下标；
  /// 仅在 [b] 为 [NovelTextBlock] 时返回非空区间。
  List<HighlightSpan> blockSpans(List<NovelBlock> blocks, int blockIndex, String text) {
    final blockLen = text.length;
    final lineGlobal = _globalStartOfBlock(blockIndex, blocks);
    final result = <HighlightSpan>[];
    if (hasSelection) {
      final s = (_selectionStart! - lineGlobal).clamp(0, blockLen);
      final e = (_selectionEnd! - lineGlobal).clamp(0, blockLen);
      if (e > s) result.add(HighlightSpan(s, e, activeColor, true));
    }
    for (final h in _highlights) {
      final s = (h.start - lineGlobal).clamp(0, blockLen);
      final e = (h.end - lineGlobal).clamp(0, blockLen);
      if (e > s) result.add(HighlightSpan(s, e, h.color, false, effect: h.effect));
    }
    return result;
  }

  /// 计算某页某行（页内下标）在章节文本流中的起始全局偏移。
  int _globalStartOfLine(int pageIndex, int lineIndexInPage) {
    final pages = _pagination?.pages;
    if (pages == null) return 0;
    var offset = 0;
    for (var p = 0; p < pageIndex; p++) {
      for (final item in pages[p]) {
        if (item is NovelTextLineItem) offset += item.line.text.length;
      }
    }
    final page = pages[pageIndex];
    for (var i = 0; i < lineIndexInPage; i++) {
      final item = page[i];
      if (item is NovelTextLineItem) offset += item.line.text.length;
    }
    return offset;
  }

  /// 把「页内行 + 行内字符下标」映射为章节全局偏移。
  int globalOffsetFor(int pageIndex, int lineIndexInPage, int charIndexInLine) =>
      _globalStartOfLine(pageIndex, lineIndexInPage) + charIndexInLine;

  /// 返回包含某全局偏移的行的段落下标；找不到返回 null。
  int? paragraphIndexAt(int globalOffset) {
    final pages = _pagination?.pages;
    if (pages == null) return null;
    for (final page in pages) {
      for (final item in page) {
        if (item is! NovelTextLineItem) continue;
        final start = _globalStartOfLine(
          _pagination!.pages.indexOf(page),
          page.indexOf(item),
        );
        final end = start + item.line.text.length;
        if (globalOffset >= start && globalOffset < end) {
          return item.line.paragraphIndex;
        }
      }
    }
    return null;
  }

  /// 返回包含某全局偏移的「词/句」在章内文本流中的起止偏移 [start, end)。
  ///
  /// 切分规则（对标决策「标点/空白切分 + 字符级」）：以 [globalOffset] 为中心，
  /// 向左/右延伸至遇到空白或标点（CJK 汉字 / 字母数字视为词内字符，标点与
  /// 空白为断点）。中文长按即选中「标点之间的整句」，英文选中单词；拖拽时
  /// 由 [setSelection] 重定义为锚点→落点，覆盖此默认选区。
  ({int start, int end})? wordRangeAt(int globalOffset) {
    if (_chapterText.isEmpty) return null;
    final o = globalOffset.clamp(0, _chapterText.length - 1);
    var s = o;
    while (s > 0 && _isWordChar(_chapterText[s - 1])) {
      s--;
    }
    var e = o + 1;
    while (e < _chapterText.length && _isWordChar(_chapterText[e])) {
      e++;
    }
    if (e <= s) return null;
    return (start: s, end: e);
  }

  /// 词内字符判定：CJK 汉字、字母、数字视为词内；空白与标点（其它符号）为断点。
  static bool _isWordChar(String ch) {
    if (ch.trim().isEmpty) return false;
    final code = ch.codeUnitAt(0);
    final isCjk = code >= 0x4E00 && code <= 0x9FFF;
    final isLetterDigit = (code >= 0x30 && code <= 0x39) ||
        (code >= 0x41 && code <= 0x5A) ||
        (code >= 0x61 && code <= 0x7A);
    return isCjk || isLetterDigit;
  }

  /// 某段落（[paragraphIndex]）在章内文本流中的全局起止偏移 [start, end)。
  /// 跨页段落会取全部出现行的最小起点与最大终点；无匹配返回 null。
  ({int start, int end})? paragraphGlobalRange(int paragraphIndex) {
    final pages = _pagination?.pages;
    if (pages == null) return null;
    var minStart = -1;
    var maxEnd = -1;
    for (var p = 0; p < pages.length; p++) {
      final page = pages[p];
      for (var i = 0; i < page.length; i++) {
        final item = page[i];
        if (item is! NovelTextLineItem) continue;
        if (item.line.paragraphIndex != paragraphIndex) continue;
        final start = _globalStartOfLine(p, i);
        final end = start + item.line.text.length;
        if (minStart < 0 || start < minStart) minStart = start;
        if (end > maxEnd) maxEnd = end;
      }
    }
    if (minStart < 0) return null;
    return (start: minStart, end: maxEnd);
  }

  /// 设置活动选区（传入两个全局偏移，自动归一化顺序）。
  void setSelection(int a, int b) {
    if (a == b) {
      clearSelection();
      return;
    }
    _selectionStart = a < b ? a : b;
    _selectionEnd = a < b ? b : a;
    notifyListeners();
  }

  /// 把活动选区扩展为整段（传入命中行所属段落的全局起止偏移）。
  void setSelectionRange(int start, int end) => setSelection(start, end);

  void clearSelection() {
    if (_selectionStart == null && _selectionEnd == null) return;
    _selectionStart = null;
    _selectionEnd = null;
    notifyListeners();
  }

  /// 取某页某行应高亮的本地字符区间列表（活动选区 + 已存划线）。
  /// 渲染层据此绘制背景：活动选区优先级最高。
  List<HighlightSpan> lineSpans(int pageIndex, int lineIndexInPage) {
    final pages = _pagination?.pages;
    if (pages == null || pageIndex < 0 || pageIndex >= pages.length) {
      return const <HighlightSpan>[];
    }
    final page = pages[pageIndex];
    if (lineIndexInPage < 0 || lineIndexInPage >= page.length) {
      return const <HighlightSpan>[];
    }
    final item = page[lineIndexInPage];
    if (item is! NovelTextLineItem) return const <HighlightSpan>[];
    final lineLen = item.line.text.length;
    final lineGlobal = _globalStartOfLine(pageIndex, lineIndexInPage);
    final result = <HighlightSpan>[];
    if (hasSelection) {
      final s = (_selectionStart! - lineGlobal).clamp(0, lineLen);
      final e = (_selectionEnd! - lineGlobal).clamp(0, lineLen);
      if (e > s) result.add(HighlightSpan(s, e, activeColor, true));
    }
    for (final h in _highlights) {
      final s = (h.start - lineGlobal).clamp(0, lineLen);
      final e = (h.end - lineGlobal).clamp(0, lineLen);
      if (e > s) result.add(HighlightSpan(s, e, h.color, false, effect: h.effect));
    }
    return result;
  }

  /// 当前活动选区的选中文本（章节文本流子串）。
  String get quote {
    if (!hasSelection) return '';
    return _chapterText.substring(_selectionStart!, _selectionEnd!);
  }

  /// 当前活动选区前后各 ≤[max] 字符上下文（重定位锚点）。
  ({String before, String after}) context({int max = 48}) {
    if (!hasSelection) return (before: '', after: '');
    final s = _selectionStart!;
    final e = _selectionEnd!;
    final beforeStart = s - max < 0 ? 0 : s - max;
    final afterEnd = e + max > _chapterText.length
        ? _chapterText.length
        : e + max;
    return (
      before: _chapterText.substring(beforeStart, s),
      after: _chapterText.substring(e, afterEnd),
    );
  }

  /// 直接添加一条已解析的划线（跳过重定位），用于保存后即时显示。
  void addResolvedHighlight(int start, int end, int color, String key, {HighlightEffect effect = HighlightEffect.bg}) {
    // 移除已存在的同 key 划线（更新场景）
    _highlights.removeWhere((h) => h.key == key);
    _highlights.add(_ResolvedHighlight(start, end, color, key, effect: effect));
    notifyListeners();
  }

  /// 注入某章已存划线并自动重定位。
  ///
  /// 每条 [NovelHighlight] 用 `contextBefore + quote + contextAfter` 在章节文本流中
  /// 打分搜索：命中唯一最高分才接受（避免歧义），否则丢弃该条（源/正文变化过大）。
  /// 仅接受唯一最高分的设计来自 P2-11 锚点重定位规范。
  void setPersistedHighlights(List<NovelHighlight> highlights) {
    _highlights.clear();
    for (final h in highlights) {
      final resolved = _relocate(h.contextBefore, h.quote, h.contextAfter);
      if (resolved != null) {
        _highlights.add(_ResolvedHighlight(
          resolved,
          resolved + h.quote.length,
          h.color,
          h.key,
          effect: HighlightEffect.values.firstWhere(
            (e) => e.name == h.effect,
            orElse: () => HighlightEffect.bg,
          ),
        ));
      }
    }
    notifyListeners();
  }

  /// 在章节文本流中为 (before, quote, after) 找唯一最佳匹配起点。
  ///
  /// 返回 quote 的起始全局偏移；无唯一最佳匹配返回 null。
  int? _relocate(String before, String quote, String after) {
    if (quote.isEmpty || _chapterText.isEmpty) return null;
    // 候选：所有 quote 出现位置。
    final candidates = <int>[];
    var from = 0;
    while (from < _chapterText.length) {
      final idx = _chapterText.indexOf(quote, from);
      if (idx < 0) break;
      candidates.add(idx);
      from = idx + 1;
    }
    if (candidates.isEmpty) return null;
    if (candidates.length == 1) return candidates.first;

    // 多候选：用上下文打分，取唯一最高分。
    var best = -1;
    var bestScore = -1;
    var tie = false;
    for (final c in candidates) {
      final score = _contextScore(c, quote.length, before, after);
      if (score > bestScore) {
        bestScore = score;
        best = c;
        tie = false;
      } else if (score == bestScore) {
        tie = true;
      }
    }
    return tie ? null : best;
  }

  int _contextScore(
    int quoteStart,
    int quoteLen,
    String before,
    String after,
  ) {
    var score = 0;
    if (before.isNotEmpty) {
      final windowStart =
          quoteStart - before.length < 0 ? 0 : quoteStart - before.length;
      final window = _chapterText.substring(windowStart, quoteStart);
      // 后缀越长匹配得分越高（越长越唯一）。
      for (var k = 1; k <= before.length; k++) {
        final tail = before.substring(before.length - k);
        if (window.endsWith(tail)) {
          score += k;
        } else {
          break;
        }
      }
    }
    if (after.isNotEmpty) {
      final quoteEnd = quoteStart + quoteLen;
      final windowEnd = quoteEnd + after.length > _chapterText.length
          ? _chapterText.length
          : quoteEnd + after.length;
      final window = _chapterText.substring(quoteEnd, windowEnd);
      for (var k = 1; k <= after.length; k++) {
        final head = after.substring(0, k);
        if (window.startsWith(head)) {
          score += k;
        } else {
          break;
        }
      }
    }
    return score;
  }
}

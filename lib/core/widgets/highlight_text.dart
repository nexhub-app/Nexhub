/// 关键词高亮文本：把 [query] 在 [text] 中的命中片段以主题色加粗强调。
///
/// 搜索结果列表/网格共用（修复「搜索结果关键词没有强调」）。匹配忽略大小写，
/// 不修改原文大小写；query 为空时退化为普通 [Text]，对既有调用零影响。
library;

import 'package:flutter/material.dart';

class HighlightText extends StatelessWidget {
  final String text;

  /// 高亮关键词（null/空 → 不高亮）。
  final String? query;
  final int? maxLines;
  final TextOverflow overflow;
  final TextStyle? style;

  const HighlightText({
    super.key,
    required this.text,
    this.query,
    this.maxLines,
    this.overflow = TextOverflow.clip,
    this.style,
  });

  @override
  Widget build(BuildContext context) {
    final q = query?.trim() ?? '';
    if (q.isEmpty || text.isEmpty) {
      return Text(text, maxLines: maxLines, overflow: overflow, style: style);
    }

    final spans = highlightSpans(
      text: text,
      query: q,
      baseStyle: style,
      highlightStyle: (base) => base == null
          ? TextStyle(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
            )
          : base.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
    );
    return Text.rich(
      TextSpan(children: spans),
      maxLines: maxLines,
      overflow: overflow,
    );
  }
}

/// 构建高亮 [TextSpan] 列表：[query] 命中片段用 [highlightStyle] 强调，
/// 其余用 [baseStyle]。匹配忽略大小写；未命中返回单个整段 span。
List<TextSpan> highlightSpans({
  required String text,
  required String query,
  TextStyle? baseStyle,
  TextStyle? Function(TextStyle? base)? highlightStyle,
}) {
  final spans = <TextSpan>[];
  final lowerText = text.toLowerCase();
  final lowerQuery = query.toLowerCase();
  var start = 0;
  while (true) {
    final idx = lowerText.indexOf(lowerQuery, start);
    if (idx < 0) break;
    if (idx > start) {
      spans.add(TextSpan(text: text.substring(start, idx), style: baseStyle));
    }
    spans.add(TextSpan(
      text: text.substring(idx, idx + query.length),
      style: highlightStyle?.call(baseStyle) ?? baseStyle,
    ));
    start = idx + query.length;
  }
  if (start < text.length) {
    spans.add(TextSpan(text: text.substring(start), style: baseStyle));
  }
  if (spans.isEmpty) {
    spans.add(TextSpan(text: text, style: baseStyle));
  }
  return spans;
}

/// 构建阅读器正文搜索高亮 spans：[regex] 非空时按表达式匹配（优先，
/// 跳过空匹配），否则按 [query] 忽略大小写子串匹配。
///
/// 与 [highlightSpans] 的差异：
/// - 面向阅读器正文行/段落渲染，**未命中返回 null**（调用方保持原渲染
///   路径，如分页模式的虚线下划线变体）；
/// - 支持正则模式（书内搜索「使用正则」开关）；
/// - 命中样式由调用方给出（基础样式由外层 [TextSpan] 携带，普通片段
///   不带样式、自然继承）。
List<TextSpan>? searchHitSpans({
  required String text,
  String? query,
  RegExp? regex,
  TextStyle? hitStyle,
}) {
  if (text.isEmpty) return null;
  final spans = <TextSpan>[];
  if (regex != null) {
    var start = 0;
    for (final m in regex.allMatches(text)) {
      if (m.end <= m.start) continue; // 空匹配不切片，避免零宽匹配问题。
      if (m.start > start) {
        spans.add(TextSpan(text: text.substring(start, m.start)));
      }
      spans.add(TextSpan(text: text.substring(m.start, m.end), style: hitStyle));
      start = m.end;
    }
    if (spans.isEmpty) return null;
    if (start < text.length) {
      spans.add(TextSpan(text: text.substring(start)));
    }
    return spans;
  }
  final q = query?.trim() ?? '';
  if (q.isEmpty) return null;
  final lowerText = text.toLowerCase();
  final lowerQuery = q.toLowerCase();
  var start = 0;
  while (true) {
    final idx = lowerText.indexOf(lowerQuery, start);
    if (idx < 0) break;
    if (idx > start) {
      spans.add(TextSpan(text: text.substring(start, idx)));
    }
    spans.add(TextSpan(text: text.substring(idx, idx + q.length), style: hitStyle));
    start = idx + q.length;
  }
  if (spans.isEmpty) return null;
  if (start < text.length) {
    spans.add(TextSpan(text: text.substring(start)));
  }
  return spans;
}

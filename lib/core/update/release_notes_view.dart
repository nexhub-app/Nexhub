/// 应用内更新说明（GitHub Release 正文）的轻量 Markdown 渲染视图。
///
/// GitHub Releases 的 `body` 是完整 Markdown 文档（标题 / 引用块 / 列表 /
/// 分隔线 / 加粗 / 行内代码 / 链接）。直接按纯文本展示会出现满屏 `##`、`**`
/// 记号且需截断；本组件针对发布说明实际用到的语法子集做块级 + 行内两级解析，
/// 渲染为贴合应用主题的原生组件，不引入第三方 Markdown 依赖。
///
/// 解析层（[ReleaseNotesParser]）为纯 Dart 无 Flutter 依赖，可单测。
library;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme/app_tokens.dart';

// ── 解析层：块级模型 ──

/// 更新说明的块级元素基类。
sealed class ReleaseNoteBlock {
  const ReleaseNoteBlock();
}

/// 标题（`#` ~ `######`）。
class ReleaseNoteHeading extends ReleaseNoteBlock {
  final int level;
  final String text;

  const ReleaseNoteHeading(this.level, this.text);
}

/// 段落（可能含多行，按 `\n` 保留作者换行）。
class ReleaseNoteParagraph extends ReleaseNoteBlock {
  final String text;

  const ReleaseNoteParagraph(this.text);
}

/// 水平分隔线（`---` / `***` / `___`）。
class ReleaseNoteDivider extends ReleaseNoteBlock {
  const ReleaseNoteDivider();
}

/// 引用块（`> ` 前缀，内部可再含标题 / 列表 / 段落等块级结构）。
class ReleaseNoteQuote extends ReleaseNoteBlock {
  final List<ReleaseNoteBlock> children;

  const ReleaseNoteQuote(this.children);
}

/// 列表（有序 / 无序，支持缩进嵌套）。
class ReleaseNoteList extends ReleaseNoteBlock {
  final bool ordered;
  final List<ReleaseNoteListItem> items;

  const ReleaseNoteList({required this.ordered, required this.items});
}

/// 列表项（含子级嵌套项）。
class ReleaseNoteListItem {
  final String text;
  final List<ReleaseNoteListItem> children;

  const ReleaseNoteListItem(this.text, {this.children = const <ReleaseNoteListItem>[]});
}

// ── 解析层：行内模型 ──

/// 行内元素基类。
sealed class ReleaseNoteInline {
  const ReleaseNoteInline();
}

/// 普通文本。
class ReleaseNoteText extends ReleaseNoteInline {
  final String text;

  const ReleaseNoteText(this.text);
}

/// 加粗（`**text**`）。
class ReleaseNoteBold extends ReleaseNoteInline {
  final String text;

  const ReleaseNoteBold(this.text);
}

/// 斜体（`*text*`）。
class ReleaseNoteItalic extends ReleaseNoteInline {
  final String text;

  const ReleaseNoteItalic(this.text);
}

/// 行内代码（`` `text` ``）。
class ReleaseNoteCode extends ReleaseNoteInline {
  final String text;

  const ReleaseNoteCode(this.text);
}

/// 链接（`[label](url)`；图片 `![alt](url)` 降级为同款链接）。
class ReleaseNoteLink extends ReleaseNoteInline {
  final String label;
  final String url;

  const ReleaseNoteLink(this.label, this.url);
}

/// 更新说明解析器：块级 + 行内两级，纯 Dart、无 Flutter 依赖。
abstract final class ReleaseNotesParser {
  /// 行内记号：图片 → 链接 → 加粗 → 行内代码 → 斜体（同一起点的优先级即
  /// 交替顺序；`[^*\n]` 保证加粗优先于斜体匹配，未闭合记号保持字面量）。
  static final RegExp _inlinePattern = RegExp(
    r'!\[([^\]]*)\]\(([^)\s]+)\)'
    r'|\[([^\]]+)\]\(([^)\s]+)\)'
    r'|\*\*([^*\n]+)\*\*'
    r'|`([^`\n]+)`'
    r'|\*([^*\n]+)\*',
  );

  /// 水平分隔线：三个及以上相同符号（`-` / `*` / `_`，允许空格分隔）。
  static final RegExp _hrPattern =
      RegExp(r'^ {0,3}(?:(?:-\s*){3,}|(?:\*\s*){3,}|(?:_\s*){3,})$');

  /// ATX 标题：`#` ~ `######`，允许结尾装饰 `#`。
  static final RegExp _headingPattern =
      RegExp(r'^ {0,3}(#{1,6})\s+(.+?)\s*#*\s*$');

  /// 无序 / 有序列表项：捕获缩进、标记与内容。
  static final RegExp _listItemPattern =
      RegExp(r'^(\s*)([-*+]|\d{1,9}[.)])\s+(.*)$');

  /// 引用行：`>`（允许嵌套 `>`，此处只剥一层，其余交给递归）。
  static final RegExp _quotePattern = RegExp(r'^ {0,3}>\s?(.*)$');

  /// 解析完整 Markdown 文本为块级列表。空文本返回空列表。
  static List<ReleaseNoteBlock> parse(String markdown) {
    final String normalized =
        markdown.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final List<String> lines = normalized.split('\n');
    return _parseBlocks(lines);
  }

  static List<ReleaseNoteBlock> _parseBlocks(List<String> lines) {
    final List<ReleaseNoteBlock> blocks = <ReleaseNoteBlock>[];
    int i = 0;
    while (i < lines.length) {
      final String line = lines[i];
      if (line.trim().isEmpty) {
        i++;
        continue;
      }
      // 标题
      final RegExpMatch? heading = _headingPattern.firstMatch(line);
      if (heading != null) {
        blocks.add(ReleaseNoteHeading(
          heading.group(1)!.length,
          heading.group(2)!,
        ));
        i++;
        continue;
      }
      // 分隔线（须在列表项之前判，避免 `---` 被当列表）
      if (_hrPattern.hasMatch(line)) {
        blocks.add(const ReleaseNoteDivider());
        i++;
        continue;
      }
      // 引用块：收集连续引用行，剥一层 `>` 后递归解析内部块
      final RegExpMatch? quote = _quotePattern.firstMatch(line);
      if (quote != null) {
        final List<String> inner = <String>[];
        while (i < lines.length) {
          final RegExpMatch? m = _quotePattern.firstMatch(lines[i]);
          if (m == null) break;
          inner.add(m.group(1)!);
          i++;
        }
        blocks.add(ReleaseNoteQuote(_parseBlocks(inner)));
        continue;
      }
      // 列表：收集连续列表行，按缩进建嵌套树；有序/无序标记切换视为新列表。
      final RegExpMatch? item = _listItemPattern.firstMatch(line);
      if (item != null) {
        final bool ordered = _isOrderedMarker(item.group(2)!);
        final List<_RawListItem> raws = <_RawListItem>[];
        while (i < lines.length) {
          final RegExpMatch? m = _listItemPattern.firstMatch(lines[i]);
          if (m == null || _isOrderedMarker(m.group(2)!) != ordered) break;
          raws.add(_RawListItem(
            indent: m.group(1)!.length,
            marker: m.group(2)!,
            text: m.group(3)!,
          ));
          i++;
        }
        blocks.add(_buildList(raws, ordered: ordered));
        continue;
      }
      // 段落：连续普通行并为一段，行间换行原样保留（发布说明的作者换行
      // 多为刻意的分段展示，不按严格 Markdown 折叠成空格）。
      final List<String> paragraph = <String>[line];
      i++;
      while (i < lines.length) {
        final String next = lines[i];
        if (next.trim().isEmpty ||
            _headingPattern.hasMatch(next) ||
            _hrPattern.hasMatch(next) ||
            _quotePattern.hasMatch(next) ||
            _listItemPattern.hasMatch(next)) {
          break;
        }
        paragraph.add(next);
        i++;
      }
      blocks.add(ReleaseNoteParagraph(paragraph.join('\n')));
    }
    return blocks;
  }

  /// 无序标记（`-` / `*` / `+`）以外的列表标记视为有序。
  static bool _isOrderedMarker(String marker) =>
      marker != '-' && marker != '*' && marker != '+';

  /// 将平铺的列表行（带缩进）组装为嵌套列表块。
  ///
  /// 嵌套判定：相对首个条目的缩进每多 2 空格加一层。
  static ReleaseNoteList _buildList(
    List<_RawListItem> raws, {
    required bool ordered,
  }) {
    final int baseIndent = raws.first.indent;
    final List<ReleaseNoteListItem> roots = <ReleaseNoteListItem>[];
    // 栈中保存「当前各层最后一个节点」，新节点挂到栈顶的 children。
    final List<ReleaseNoteListItem> stack = <ReleaseNoteListItem>[];
    for (final _RawListItem r in raws) {
      final int depth =
          ((r.indent - baseIndent) / 2).floor().clamp(0, stack.length);
      final ReleaseNoteListItem node = ReleaseNoteListItem(
        r.text,
        children: <ReleaseNoteListItem>[],
      );
      while (stack.length > depth) {
        stack.removeLast();
      }
      if (stack.isEmpty) {
        roots.add(node);
      } else {
        stack.last.children.add(node);
      }
      stack.add(node);
    }
    return ReleaseNoteList(ordered: ordered, items: roots);
  }

  /// 解析行内记号为元素序列。未闭合 / 不匹配的部分保持字面量。
  static List<ReleaseNoteInline> parseInline(String text) {
    final List<ReleaseNoteInline> out = <ReleaseNoteInline>[];
    int start = 0;
    for (final RegExpMatch m in _inlinePattern.allMatches(text)) {
      if (m.start > start) {
        out.add(ReleaseNoteText(text.substring(start, m.start)));
      }
      final String? imageAlt = m.group(1);
      final String? imageUrl = m.group(2);
      final String? linkLabel = m.group(3);
      final String? linkUrl = m.group(4);
      final String? bold = m.group(5);
      final String? code = m.group(6);
      final String? italic = m.group(7);
      if (imageUrl != null) {
        out.add(ReleaseNoteLink(imageAlt ?? '', imageUrl));
      } else if (linkUrl != null) {
        out.add(ReleaseNoteLink(linkLabel ?? '', linkUrl));
      } else if (bold != null) {
        out.add(ReleaseNoteBold(bold));
      } else if (code != null) {
        out.add(ReleaseNoteCode(code));
      } else if (italic != null) {
        out.add(ReleaseNoteItalic(italic));
      }
      start = m.end;
    }
    if (start < text.length) {
      out.add(ReleaseNoteText(text.substring(start)));
    }
    return out;
  }
}

class _RawListItem {
  final int indent;
  final String marker;
  final String text;

  const _RawListItem({
    required this.indent,
    required this.marker,
    required this.text,
  });
}

// ── 渲染层 ──

/// 更新说明渲染视图：把 [markdown] 渲染为贴合主题的块级组件纵列。
///
/// 链接通过系统浏览器打开（外部应用模式）。通常放在限高的
/// [SingleChildScrollView] 内使用（见更新弹窗）。
class ReleaseNotesView extends StatelessWidget {
  final String markdown;

  const ReleaseNotesView({super.key, required this.markdown});

  void _openLink(String url) {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return;
    launchUrl(uri, mode: LaunchMode.externalApplication).ignore();
  }

  @override
  Widget build(BuildContext context) {
    final List<ReleaseNoteBlock> blocks = ReleaseNotesParser.parse(markdown);
    final List<Widget> children = <Widget>[];
    for (int i = 0; i < blocks.length; i++) {
      // 标题与其上一块之间留出段落级间距，制造章节呼吸感。
      final bool isFirst = children.isEmpty;
      children.add(_buildBlock(context, blocks[i], gapAbove: !isFirst));
    }
    if (children.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  Widget _buildBlock(
    BuildContext context,
    ReleaseNoteBlock block, {
    bool gapAbove = true,
  }) {
    switch (block) {
      case ReleaseNoteHeading(:final level, :final text):
        return _HeadingTile(level: level, text: text, gapAbove: gapAbove);
      case ReleaseNoteParagraph(:final text):
        return Padding(
          padding: EdgeInsets.only(
            top: gapAbove ? AppTokens.spaceSm : 0,
            bottom: AppTokens.spaceXs,
          ),
          child: Text.rich(
            _buildInline(context, text),
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        );
      case ReleaseNoteDivider():
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: AppTokens.spaceSm),
          child: Divider(height: 1),
        );
      case ReleaseNoteQuote(:final children):
        final ColorScheme scheme = Theme.of(context).colorScheme;
        return Padding(
          padding: EdgeInsets.only(top: gapAbove ? AppTokens.spaceSm : 0),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsetsDirectional.only(
              start: AppTokens.spaceMd,
              end: AppTokens.spaceSm,
              top: AppTokens.spaceXxs,
              bottom: AppTokens.spaceXxs,
            ),
            decoration: BoxDecoration(
              border: BorderDirectional(
                start: BorderSide(
                  width: 3,
                  color: scheme.primary.withValues(alpha: 0.45),
                ),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (int i = 0; i < children.length; i++)
                  _buildBlock(context, children[i], gapAbove: i > 0),
              ],
            ),
          ),
        );
      case ReleaseNoteList(:final ordered, :final items):
        return Padding(
          padding: EdgeInsets.only(
            top: gapAbove ? AppTokens.spaceSm : 0,
            bottom: AppTokens.spaceXs,
          ),
          child: _buildListTiles(context, ordered, items, 0),
        );
    }
  }

  /// 列表渲染：悬挂缩进（标记列 + 内容 Expanded），子级按深度递进缩进。
  Widget _buildListTiles(
    BuildContext context,
    bool ordered,
    List<ReleaseNoteListItem> items,
    int depth,
  ) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final List<Widget> rows = <Widget>[];
    for (int i = 0; i < items.length; i++) {
      final ReleaseNoteListItem item = items[i];
      final String marker = ordered ? '${i + 1}.' : '•';
      rows.add(
        Padding(
          padding: EdgeInsetsDirectional.only(
            start: AppTokens.spaceXl * depth,
            bottom: AppTokens.spaceXxs,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(
                width: AppTokens.spaceLg,
                child: Text(
                  marker,
                  textAlign: TextAlign.end,
                  style: (textTheme.bodyMedium ?? const TextStyle()).copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
              ),
              const SizedBox(width: AppTokens.spaceSm),
              Expanded(
                child: Text.rich(
                  _buildInline(context, item.text),
                  style: textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ),
      );
      if (item.children.isNotEmpty) {
        rows.add(_buildListTiles(context, ordered, item.children, depth + 1));
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: rows,
    );
  }

  WidgetSpan _codeSpan(BuildContext context, String code) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;
    return WidgetSpan(
      alignment: PlaceholderAlignment.baseline,
      baseline: TextBaseline.alphabetic,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppTokens.spaceXs,
          vertical: 1,
        ),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
          borderRadius: const BorderRadius.all(Radius.circular(AppTokens.radiusXs)),
        ),
        child: Text(
          code,
          style: (textTheme.bodyMedium ?? const TextStyle()).copyWith(
            fontFamily: 'monospace',
            fontSize: (textTheme.bodyMedium?.fontSize ?? 14) - 1.5,
            color: scheme.onSurface,
          ),
        ),
      ),
    );
  }

  InlineSpan _buildInline(BuildContext context, String text) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;
    final List<InlineSpan> spans = <InlineSpan>[];
    for (final ReleaseNoteInline seg in ReleaseNotesParser.parseInline(text)) {
      switch (seg) {
        case ReleaseNoteText(:final text):
          spans.add(TextSpan(text: text));
        case ReleaseNoteBold(:final text):
          spans.add(TextSpan(
            text: text,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ));
        case ReleaseNoteItalic(:final text):
          spans.add(TextSpan(
            text: text,
            style: const TextStyle(fontStyle: FontStyle.italic),
          ));
        case ReleaseNoteCode(:final text):
          spans.add(_codeSpan(context, text));
        case ReleaseNoteLink(:final label, :final url):
          spans.add(WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: GestureDetector(
              onTap: () => _openLink(url),
              child: Text(
                label,
                style: (textTheme.bodyMedium ?? const TextStyle()).copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w500,
                  decoration: TextDecoration.underline,
                  decorationColor: scheme.primary.withValues(alpha: 0.4),
                ),
              ),
            ),
          ));
      }
    }
    return TextSpan(children: spans);
  }
}

/// 标题块：h1~h2 章节级（主色）、h3~h4 小节级、其余加粗正文。
class _HeadingTile extends StatelessWidget {
  final int level;
  final String text;
  final bool gapAbove;

  const _HeadingTile({
    required this.level,
    required this.text,
    required this.gapAbove,
  });

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    TextStyle style;
    switch (level) {
      case 1:
        style = (textTheme.titleLarge ?? const TextStyle())
            .copyWith(fontWeight: FontWeight.w700);
      case 2:
        style = (textTheme.titleMedium ?? const TextStyle()).copyWith(
          fontWeight: FontWeight.w600,
          color: scheme.primary,
        );
      case 3:
      case 4:
        style = (textTheme.titleSmall ?? const TextStyle())
            .copyWith(fontWeight: FontWeight.w600);
      default:
        style = (textTheme.bodyMedium ?? const TextStyle())
            .copyWith(fontWeight: FontWeight.w600);
    }
    return Padding(
      padding: EdgeInsets.only(
        top: gapAbove ? AppTokens.spaceLg : 0,
        bottom: AppTokens.spaceXs,
      ),
      child: Text(
        text,
        style: style,
      ),
    );
  }
}

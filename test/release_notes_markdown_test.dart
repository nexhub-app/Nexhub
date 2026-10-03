/// 更新说明 Markdown 解析器单测：块级结构（标题 / 分隔线 / 引用块 / 列表 /
/// 段落）与行内记号（加粗 / 斜体 / 行内代码 / 链接 / 图片降级）。
///
/// 只测纯 Dart 解析层（[ReleaseNotesParser]），渲染层由组件自身承担；
/// 样例语法覆盖仓库 RELEASE_BODY 实际使用的子集。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/update/release_notes_view.dart';

void main() {
  group('块级解析', () {
    test('空文本与纯空白返回空列表', () {
      expect(ReleaseNotesParser.parse(''), isEmpty);
      expect(ReleaseNotesParser.parse('\n \n\t\n'), isEmpty);
    });

    test('标题等级解析并剥除结尾装饰 #', () {
      final blocks = ReleaseNotesParser.parse('# 大标题\n## 二级 ###');
      expect(blocks.length, 2);
      final h1 = blocks[0] as ReleaseNoteHeading;
      final h2 = blocks[1] as ReleaseNoteHeading;
      expect(h1.level, 1);
      expect(h1.text, '大标题');
      expect(h2.level, 2);
      expect(h2.text, '二级');
    });

    test('分隔线与列表项区分：--- 是线，- x 是列表', () {
      final blocks = ReleaseNotesParser.parse('---\n- 条目\n***\n- - -');
      expect(blocks, hasLength(4));
      expect(blocks[0], isA<ReleaseNoteDivider>());
      expect(blocks[1], isA<ReleaseNoteList>());
      expect(blocks[2], isA<ReleaseNoteDivider>());
      expect(blocks[3], isA<ReleaseNoteDivider>());
    });

    test('无序列表收连续行；有序列表按序号渲染标记', () {
      final blocks = ReleaseNotesParser.parse('- 甲\n- 乙\n1. 丙\n2. 丁');
      final unordered = blocks[0] as ReleaseNoteList;
      expect(unordered.ordered, isFalse);
      expect(unordered.items.map((i) => i.text), <String>['甲', '乙']);
      final ordered = blocks[1] as ReleaseNoteList;
      expect(ordered.ordered, isTrue);
      expect(ordered.items.map((i) => i.text), <String>['丙', '丁']);
    });

    test('缩进两空格构成嵌套子列表', () {
      final blocks = ReleaseNotesParser.parse('- 父\n  - 子\n  - 子二\n- 父二');
      final list = blocks[0] as ReleaseNoteList;
      expect(list.items, hasLength(2));
      expect(list.items[0].text, '父');
      expect(list.items[0].children.map((i) => i.text), <String>['子', '子二']);
      expect(list.items[1].children, isEmpty);
    });

    test('引用块递归解析内部列表与段落', () {
      final blocks = ReleaseNotesParser.parse(
        '> - **甲**：说明\n> - 乙\n>\n> 尾行',
      );
      final quote = blocks[0] as ReleaseNoteQuote;
      expect(quote.children, hasLength(2));
      final list = quote.children[0] as ReleaseNoteList;
      expect(list.items, hasLength(2));
      expect(list.items[0].text, '**甲**：说明');
      final tail = quote.children[1] as ReleaseNoteParagraph;
      expect(tail.text, '尾行');
    });

    test('连续普通行并为一段且保留换行；空行分段', () {
      final blocks = ReleaseNotesParser.parse('第一行\n第二行\n\n第三行');
      expect(blocks, hasLength(2));
      final p1 = blocks[0] as ReleaseNoteParagraph;
      expect(p1.text, '第一行\n第二行');
      expect((blocks[1] as ReleaseNoteParagraph).text, '第三行');
    });

    test('CRLF 行尾归一化', () {
      final blocks = ReleaseNotesParser.parse('# 标\r\n\r\n正文\r\n');
      expect(blocks, hasLength(2));
      expect((blocks[0] as ReleaseNoteHeading).text, '标');
    });

    test('整篇发布说明样例：结构齐全', () {
      const sample = '''
# NexHub v1.2.3

> 提示：**无破坏性变更**，可直接覆盖安装。

---

## ✨ 核心变化

- **新功能**：三档作用域
- **修复**：见 `lib/core/CHANGELOG.md`

下载请到 [Releases](https://example.com/d)。
''';
      final blocks = ReleaseNotesParser.parse(sample);
      expect(blocks, hasLength(6));
      expect(blocks[0], isA<ReleaseNoteHeading>());
      expect(blocks[1], isA<ReleaseNoteQuote>());
      expect(blocks[2], isA<ReleaseNoteDivider>());
      expect(blocks[3], isA<ReleaseNoteHeading>());
      expect(blocks[4], isA<ReleaseNoteList>());
      expect(blocks[5], isA<ReleaseNoteParagraph>());
    });
  });

  group('行内解析', () {
    List<ReleaseNoteInline> parse(String s) => ReleaseNotesParser.parseInline(s);

    test('纯文本不加记号', () {
      final segs = parse('普通文本');
      expect(segs, hasLength(1));
      expect(segs.single, isA<ReleaseNoteText>());
    });

    test('加粗与斜体', () {
      final segs = parse('前**粗**中*斜*后');
      expect(segs, hasLength(5));
      expect((segs[0] as ReleaseNoteText).text, '前');
      expect((segs[1] as ReleaseNoteBold).text, '粗');
      expect((segs[2] as ReleaseNoteText).text, '中');
      expect((segs[3] as ReleaseNoteItalic).text, '斜');
      expect((segs[4] as ReleaseNoteText).text, '后');
    });

    test('行内代码', () {
      final segs = parse('见 `lib/core/models/plugin_config.dart` 字段');
      expect(segs, hasLength(3));
      expect((segs[1] as ReleaseNoteCode).text,
          'lib/core/models/plugin_config.dart');
    });

    test('链接拆出 label 与 url', () {
      final segs = parse('反馈 → [Issues](https://example.com/issues) 谢谢');
      expect(segs, hasLength(3));
      final link = segs[1] as ReleaseNoteLink;
      expect(link.label, 'Issues');
      expect(link.url, 'https://example.com/issues');
    });

    test('图片降级为链接（alt 作 label）', () {
      final segs = parse('![截图](https://example.com/a.png)');
      expect(segs, hasLength(1));
      final link = segs[0] as ReleaseNoteLink;
      expect(link.label, '截图');
      expect(link.url, 'https://example.com/a.png');
    });

    test('未闭合记号保持字面量', () {
      final segs = parse('a **b c');
      expect(segs, hasLength(1));
      expect((segs[0] as ReleaseNoteText).text, 'a **b c');
    });

    test('混合记号顺序保持原序', () {
      final segs = parse('**架构**：`arm64-v8a`，详见 [文档](https://e.com/d)');
      expect(segs.map((s) => s.runtimeType), <Type>[
        ReleaseNoteBold,
        ReleaseNoteText,
        ReleaseNoteCode,
        ReleaseNoteText,
        ReleaseNoteLink,
      ]);
    });
  });

  group('渲染视图冒烟', () {
    testWidgets('全语法样例渲染不抛错且文本可见、链接可命中', (tester) async {
      const markdown = '''
# NexHub v1.2.3

> 提示：**无破坏性变更**。

---

- **新功能**：三档作用域
  - 子项 `代码`
- 下载见 [Releases](https://example.com/d)
''';
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: ReleaseNotesView(markdown: markdown)),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('NexHub v1.2.3'), findsOneWidget);
      // Text.rich 内的行内记号按整段纯文本匹配。
      expect(find.textContaining('子项'), findsOneWidget);
      expect(find.text('代码'), findsOneWidget);
      expect(find.text('Releases'), findsOneWidget);
    });

    testWidgets('空内容渲染为空视图', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: ReleaseNotesView(markdown: '')),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(SizedBox), findsOneWidget);
    });
  });
}

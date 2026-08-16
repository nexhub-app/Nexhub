/// TXT 行级章节切分自测（B-01/B-02）：
/// 单换行分隔文件正确分章、英文章节名命中、双换行文件回归、
/// 前言独立成章、无标题兜底硬切、超长章二次切分、正文误引过滤。
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/local/local_novel_parser.dart';

/// 生成一段长正文（确保相邻标题间隔超过阈值）。
String _para(int seed, {int lines = 40}) {
  final buf = StringBuffer();
  for (var i = 0; i < lines; i++) {
    buf.writeln('这是第${seed + 1}章的正文内容第$i行，占位文字用于拉开标题间隔。');
  }
  return buf.toString();
}

void main() {
  test('B-02: 段落仅以单换行分隔的 TXT 正确分章', () {
    final buf = StringBuffer();
    buf.writeln('第一章 起点');
    buf.write(_para(0, lines: 60));
    buf.writeln('第二章 转折');
    buf.write(_para(1, lines: 60));
    buf.writeln('第三章 结局');
    buf.write(_para(2, lines: 60));

    final chapters = LocalNovelParser.splitTxtChapters(
      buf.toString(),
      fallbackTitle: '书名',
    );
    expect(chapters.length, 3);
    expect(chapters[0].title, contains('第一章'));
    expect(chapters[1].title, contains('第二章'));
    expect(chapters[2].title, contains('第三章'));
    expect(chapters[1].content.first, contains('这是第2章的正文内容第0行'));
  });

  test('B-01: 英文章节名（阿拉伯数字与拼写数字）命中切分', () {
    final buf = StringBuffer();
    buf.writeln('Chapter 1 The Beginning');
    buf.write(_para(0, lines: 60));
    buf.writeln('Chapter Twelve The Twist');
    buf.write(_para(1, lines: 60));
    buf.writeln('CHAPTER 23 The End');
    buf.write(_para(2, lines: 60));

    final chapters = LocalNovelParser.splitTxtChapters(
      buf.toString(),
      fallbackTitle: 'book',
    );
    expect(chapters.length, 3);
    expect(chapters[0].title, contains('Chapter 1'));
    expect(chapters[1].title, contains('Chapter Twelve'));
    expect(chapters[2].title, contains('CHAPTER 23'));
  });

  test('双换行经典排版仍正确分章（回归）', () {
    final buf = StringBuffer();
    buf.writeln('第一章 开始\n');
    buf.writeln('${_para(0, lines: 60)}\n');
    buf.writeln('第二章 继续\n');
    buf.writeln('${_para(1, lines: 60)}\n');

    final chapters = LocalNovelParser.splitTxtChapters(
      buf.toString(),
      fallbackTitle: '书名',
    );
    expect(chapters.length, 2);
    expect(chapters[0].title, contains('第一章'));
    expect(chapters[1].title, contains('第二章'));
  });

  test('首个标题前的长正文独立为前言章', () {
    final buf = StringBuffer();
    buf.write(_para(0, lines: 60)); // 开头正文 > 500 字符
    buf.writeln('第一章 正式开始');
    buf.write(_para(1, lines: 60));

    final chapters = LocalNovelParser.splitTxtChapters(
      buf.toString(),
      fallbackTitle: '书名',
    );
    expect(chapters.length, 2);
    expect(chapters[0].title, '前言');
    expect(chapters[1].title, contains('第一章'));
  });

  test('无任何章节标题：小文件保持整本单章（标题用 fallbackTitle）', () {
    final text = '这是一本没有章节标题的小书。\n只有寥寥数行。\n就此结尾。';
    final chapters = LocalNovelParser.splitTxtChapters(text,
        fallbackTitle: '无名之书');
    expect(chapters.length, 1);
    expect(chapters[0].title, '无名之书');
    expect(chapters[0].content.length, 3);
  });

  test('无任何章节标题：大文件按粒度兜底硬切', () {
    final buf = StringBuffer();
    for (var i = 0; i < 1200; i++) {
      buf.writeln('没有标题的长文第$i行，内容都是普通正文段落文字。'); // ~30KB
    }
    final chapters = LocalNovelParser.splitTxtChapters(
      buf.toString(),
      fallbackTitle: '大书',
    );
    expect(chapters.length, greaterThan(1));
    expect(chapters.first.title, contains('第 1 部分'));
    // 兜底切分不丢内容
    final total = chapters.fold<int>(
        0, (sum, c) => sum + c.content.fold<int>(0, (s, p) => s + p.length));
    expect(total, greaterThan(25 * 1024));
  });

  test('超长单章按段落边界二次切分并加 (N) 序号', () {
    final buf = StringBuffer();
    buf.writeln('第一章 超级长章');
    for (var i = 0; i < 9000; i++) {
      buf.writeln('超长章正文第$i行，占位文字。'); // ~180KB > 100KB
    }
    final chapters = LocalNovelParser.splitTxtChapters(
      buf.toString(),
      fallbackTitle: '书名',
    );
    expect(chapters.length, greaterThan(1));
    expect(chapters.every((c) => c.title.contains('超级长章')), isTrue);
    expect(chapters[1].title, anyOf(contains('(1)'), contains('(2)')));
  });

  test('正文中以章节样式开头的短行被间隔校验吸收（不误切）', () {
    final buf = StringBuffer();
    buf.writeln('第一章 真章节');
    buf.write(_para(0, lines: 60));
    // 对话里引用章名，距上一标题很近 → 并入第一章
    buf.writeln('他说：「第一章的内容其实是骗人的。」');
    buf.write(_para(1, lines: 60));
    buf.writeln('第二章 下一章');
    buf.write(_para(2, lines: 60));

    final chapters = LocalNovelParser.splitTxtChapters(
      buf.toString(),
      fallbackTitle: '书名',
    );
    expect(chapters.length, 2);
    expect(
      chapters[0].content.any((p) => p.contains('骗人的')),
      isTrue,
    );
  });

  test('序章/楔子等固定名命中切分', () {
    final buf = StringBuffer();
    buf.writeln('楔子');
    buf.write(_para(0, lines: 60));
    buf.writeln('第一章 正文');
    buf.write(_para(1, lines: 60));

    final chapters = LocalNovelParser.splitTxtChapters(
      buf.toString(),
      fallbackTitle: '书名',
    );
    expect(chapters.length, 2);
    expect(chapters[0].title, '楔子');
    expect(chapters[1].title, contains('第一章'));
  });

  test('isVolumeTitle：卷级标题判定（目录分卷分组用）', () {
    expect(LocalNovelParser.isVolumeTitle('第一卷 风起'), isTrue);
    expect(LocalNovelParser.isVolumeTitle('第二部'), isTrue);
    expect(LocalNovelParser.isVolumeTitle('卷三'), isTrue);
    expect(LocalNovelParser.isVolumeTitle('Volume 12'), isTrue);
    expect(LocalNovelParser.isVolumeTitle('Part 2'), isTrue);
    expect(LocalNovelParser.isVolumeTitle('第一章 开始'), isFalse);
    expect(LocalNovelParser.isVolumeTitle('第三回'), isFalse);
    expect(LocalNovelParser.isVolumeTitle('他说到第一卷的内容如何如何'), isFalse);
  });

  test('卷级标题章节切分（TXT 含分卷结构）', () {
    final buf = StringBuffer();
    buf.writeln('第一卷 风起');
    buf.write(_para(0, lines: 60));
    buf.writeln('第一章 少年');
    buf.write(_para(1, lines: 60));
    buf.writeln('第二章 江湖');
    buf.write(_para(2, lines: 60));
    buf.writeln('第二卷 云涌');
    buf.write(_para(3, lines: 60));

    final chapters = LocalNovelParser.splitTxtChapters(
      buf.toString(),
      fallbackTitle: '书名',
    );
    expect(chapters.length, 4);
    expect(chapters[0].title, contains('第一卷'));
    expect(LocalNovelParser.isVolumeTitle(chapters[0].title), isTrue);
    expect(LocalNovelParser.isVolumeTitle(chapters[3].title), isTrue);
  });
}

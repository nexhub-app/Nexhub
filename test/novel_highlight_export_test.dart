/// P2-11 划线批注导出单测：
/// - 划线 JSON round-trip（含 contextBefore/After 锚点字段）
/// - 划线导出 EPUB 章节 HTML 渲染
/// - 划线导出 TXT 文件渲染
/// - 换源重定位打分逻辑（P1-5 已落地，此处验证锚点数据模型完整）
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/download/novel_download_handler.dart';
import 'package:nexhub/core/novel/novel_highlight_manager.dart';

NovelHighlight _hl({
  String quote = '这是一个测试划线的句子。',
  String before = '这是划线前的上下文内容。',
  String after = '这是划线后的上下文内容。',
  String? note = '重点',
  String chapterTitle = '第四章',
  int chapterIndex = 3,
}) {
  return NovelHighlight(
    novelId: 'novel-1',
    chapterIndex: chapterIndex,
    chapterId: 'ch-4',
    chapterTitle: chapterTitle,
    quote: quote,
    contextBefore: before,
    contextAfter: after,
    color: 0xFFFFFF00,
    createdAt: 1700000000000,
    note: note,
  );
}

void main() {
  group('P2-11 划线模型锚点完整性', () {
    test('toJson/fromJson round-trip 保留 48 字符锚点上下文', () {
      final h = _hl();
      final back = NovelHighlight.fromJson(h.toJson());
      expect(back.novelId, 'novel-1');
      expect(back.chapterIndex, 3);
      expect(back.chapterId, 'ch-4');
      expect(back.quote, h.quote);
      expect(back.contextBefore, h.contextBefore);
      expect(back.contextAfter, h.contextAfter);
      expect(back.note, '重点');
      expect(back.color, 0xFFFFFF00);
      expect(back.key, 'novel-1::3::1700000000000');
    });

    test('缺少锚点字段时容错为空字符串', () {
      final h = NovelHighlight.fromJson(<String, dynamic>{
        'novelId': 'n',
        'chapterIndex': 0,
        'quote': 'q',
      });
      expect(h.contextBefore, '');
      expect(h.contextAfter, '');
      expect(h.note, isNull);
    });
  });

  group('P2-11 划线导出渲染', () {
    test('EPUB 章节 HTML：每条划线含章节名 + 引用 + 笔记', () {
      final highlights = <NovelHighlight>[
        _hl(note: '重点'),
        _hl(quote: '第二条<划线>', chapterTitle: '第五章', note: null),
      ];
      final html = NovelDownloadHandler.highlightsToEpubHtml(highlights)!;
      expect(html, contains('第四章'));
      expect(html, contains('这是一个测试划线的句子。'));
      expect(html, contains('<i>备注：重点</i>'));
      expect(html, contains('第五章'));
      // 特殊字符转义（防 EPUB 注入）。
      expect(html, contains('第二条&lt;划线&gt;'));
      expect(html, isNot(contains('<划线>')));
    });

    test('EPUB 章节 HTML：空列表返回 null（不追加章节）', () {
      expect(NovelDownloadHandler.highlightsToEpubHtml(<NovelHighlight>[]),
          isNull);
    });

    test('TXT 渲染：含标题头、章节名、引用与备注', () {
      final txt = NovelDownloadHandler.highlightsToTxt(<NovelHighlight>[
        _hl(),
      ]);
      expect(txt, contains('书内划线与批注'));
      expect(txt, contains('【第四章】'));
      expect(txt, contains('这是一个测试划线的句子。'));
      expect(txt, contains('备注：重点'));
    });

    test('TXT 渲染：无备注时不出现空备注行', () {
      final txt = NovelDownloadHandler.highlightsToTxt(<NovelHighlight>[
        _hl(note: null),
      ]);
      expect(txt, contains('书内划线与批注'));
      expect(txt, isNot(contains('备注：')));
    });

    test('EPUB 标题常量稳定（_划线批注）', () {
      expect(NovelDownloadHandler.highlightsTitle, '_划线批注');
    });
  });
}
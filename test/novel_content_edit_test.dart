import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:nexhub/core/local/local_novel_parser.dart';
import 'package:nexhub/core/models/novel_block.dart';
import 'package:nexhub/core/novel/novel_content_edit_manager.dart';

void main() {
  group('N7 内容编辑：可编辑文本序列化', () {
    test('块列表 → 编辑文本 → 块列表 往返保持', () {
      final blocks = <NovelBlock>[
        const NovelTextBlock('第十二章 风起', isHeading: true),
        const NovelTextBlock('　　夜色渐深，他推门而出。'),
        NovelImageBlock('https://example.com/img/1.jpg'),
        const NovelTextBlock('　　门外无人，只有风。'),
      ];
      final text = NovelContentEditManager.encodeBlocksToEditableText(blocks);
      expect(text, contains('$kNexhubHeadingMarker第十二章 风起'));
      expect(text, contains('${kNexhubImgMarker}https://example.com/img/1.jpg'));

      final parsed = NovelContentEditManager.parseEditableText(text);
      expect(parsed.length, 4);
      final h = parsed[0] as NovelTextBlock;
      expect(h.isHeading, isTrue);
      expect(h.text, '第十二章 风起');
      final img = parsed[2] as NovelImageBlock;
      expect(img.url, 'https://example.com/img/1.jpg');
      expect((parsed[3] as NovelTextBlock).text, '　　门外无人，只有风。');
    });

    test('空行分段；空段与空标记行被丢弃', () {
      final text =
          '第一段\n\n\n$kNexhubImgMarker  \n\n第二段\n续行不拆分';
      final parsed = NovelContentEditManager.parseEditableText(text);
      // 空白图片标记行丢弃；「第二段\n续行」为一个文本块。
      expect(parsed.length, 2);
      expect((parsed[1] as NovelTextBlock).text, '第二段\n续行不拆分');
    });

    test('JSON 序列化往返保持（含标题 / 图片 / style）', () {
      const edit = NovelContentEdit(
        novelId: 'n1',
        chapterId: 'c1',
        chapterIndex: 3,
        chapterTitle: '测试章',
        blocks: <NovelBlock>[
          NovelTextBlock('标题', isHeading: true),
          NovelImageBlock('https://x/i.png'),
        ],
        updatedAt: 12345,
      );
      final restored = NovelContentEdit.fromJson(edit.toJson());
      expect(restored.novelId, 'n1');
      expect(restored.chapterId, 'c1');
      expect(restored.chapterIndex, 3);
      expect(restored.blocks.length, 2);
      expect((restored.blocks[0] as NovelTextBlock).isHeading, isTrue);
      expect((restored.blocks[1] as NovelImageBlock).url, 'https://x/i.png');
    });
  });

  group('N7 内容编辑：管理器持久化', () {
    late Directory tempDir;
    late NovelContentEditManager manager;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('novel_edit_test');
      Hive.init(tempDir.path);
      manager = NovelContentEditManager();
      await manager.init();
    });

    tearDown(() async {
      await Hive.deleteBoxFromDisk(NovelContentEditManager.boxName);
      try {
        await tempDir.delete(recursive: true);
      } on Object {
        // 清理失败忽略。
      }
    });

    test('save/load/remove 全链路（按 书+章 键隔离）', () async {
      final edit = NovelContentEdit(
        novelId: 'book',
        chapterId: 'ch-1',
        chapterIndex: 0,
        chapterTitle: '第一章',
        blocks: const <NovelBlock>[NovelTextBlock('改后的正文')],
        updatedAt: 1,
      );
      await manager.save(edit);
      expect(await manager.hasEdit('book', 'ch-1'), isTrue);
      expect(await manager.hasEdit('book', 'ch-2'), isFalse);

      final loaded = await manager.load('book', 'ch-1');
      expect(loaded, isNotNull);
      expect((loaded!.blocks.single as NovelTextBlock).text, '改后的正文');

      // 其他书同章节 ID 不受影响。
      expect(await manager.load('other', 'ch-1'), isNull);

      await manager.remove('book', 'ch-1');
      expect(await manager.load('book', 'ch-1'), isNull);
    });

    test('listForNovel 按更新时间倒序返回该书编辑', () async {
      for (final (cid, ts) in [('a', 10), ('b', 30), ('c', 20)]) {
        await manager.save(NovelContentEdit(
          novelId: cid == 'b' ? 'book' : 'book',
          chapterId: cid,
          chapterIndex: 0,
          chapterTitle: cid,
          blocks: const <NovelBlock>[NovelTextBlock('v')],
          updatedAt: ts,
        ));
      }
      await manager.save(NovelContentEdit(
        novelId: 'another',
        chapterId: 'a',
        chapterIndex: 0,
        chapterTitle: 'a',
        blocks: const <NovelBlock>[NovelTextBlock('v')],
        updatedAt: 99,
      ));
      final list = await manager.listForNovel('book');
      expect(list.map((e) => e.chapterId).toList(), <String>['b', 'c', 'a']);
    });
  });
}

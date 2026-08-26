import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:nexhub/core/download/novel_download_handler.dart';
import 'package:nexhub/core/novel/novel_translation_manager.dart';
import 'package:nexhub/features/novel/domain/novel_translation_service.dart';

void main() {
  group('O3 批量译文协议', () {
    test('encodeBatch 生成编号分隔格式', () {
      final encoded = NovelTranslationService.encodeBatch(<String>['甲', '乙']);
      expect(encoded, contains('<<<1>>>'));
      expect(encoded, contains('<<<2>>>'));
      expect(encoded, contains('乙'));
    });

    test('parseBatched 顺序完整返回', () {
      final parsed = NovelTranslationService.parseBatched(
        '<<<1>>>\nA one\n<<<2>>>\nB two\n<<<3>>>\nC three\n',
        3,
      );
      expect(parsed, <String>['A one', 'B two', 'C three']);
    });

    test('parseBatched 段数不足 / 空串 → null（触发分块回退）', () {
      expect(
          NovelTranslationService.parseBatched(
              '<<<1>>>x\n<<<2>>>y\n<<<3>>>z\n', 4),
          isNull);
      expect(NovelTranslationService.parseBatched('', 2), isNull);
      expect(
          NovelTranslationService.parseBatched('没有标记的输出', 1), isNull);
    });

    test('parseBatched 序号乱序按标记对位', () {
      final parsed = NovelTranslationService.parseBatched(
        '<<<2>>>第二\n<<<1>>>第一\n',
        2,
      );
      expect(parsed, <String>['第一', '第二']);
    });
  });

  group('F5/O3 翻译缓存管理器与导出渲染', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('novel_tr_test');
      Hive.init(tempDir.path);
    });

    tearDown(() async {
      await Hive.deleteBoxFromDisk(NovelTranslationManager.boxName);
      try {
        await tempDir.delete(recursive: true);
      } on Object {
        // 清理失败忽略。
      }
    });

    test('save/load/listForNovel 往返 + 语言隔离', () async {
      final manager = NovelTranslationManager();
      await manager.init();
      const t = NovelChapterTranslation(
        novelId: 'n1',
        chapterId: 'c1',
        chapterTitle: '第一章',
        lang: 'zh',
        translations: <String>['译句一', '译句二'],
        updatedAt: 5,
      );
      await manager.save(t);
      final loaded = await manager.load('n1', 'c1');
      expect(loaded, isNotNull);
      expect(loaded!.translations, <String>['译句一', '译句二']);
      // 其他语言无缓存。
      expect(await manager.load('n1', 'c1', lang: 'en'), isNull);

      final list = await manager.listForNovel('n1');
      expect(list.length, 1);
      // 其他书不混入。
      expect(await manager.listForNovel('n2'), isEmpty);
    });

    test('translationsToEpubHtml / translationsToTxt 渲染', () {
      const t = NovelChapterTranslation(
        novelId: 'n',
        chapterId: 'c',
        chapterTitle: '<第一章>',
        lang: 'zh',
        translations: <String>['译文甲', '译文乙'],
        updatedAt: 0,
      );
      final html = NovelDownloadHandler.translationsToEpubHtml(<NovelChapterTranslation>[t]);
      expect(html, isNotNull);
      expect(html, contains('&lt;第一章&gt;'));
      expect(html, contains('<p>译文甲</p>'));

      final txt = NovelDownloadHandler.translationsToTxt(<NovelChapterTranslation>[t]);
      expect(txt, contains('【<第一章>】'));
      expect(txt, contains('译文乙'));

      // 空列表：EPUB 返回 null（不追加附录），TXT 输出头尾。
      expect(
        NovelDownloadHandler.translationsToEpubHtml(const <NovelChapterTranslation>[]),
        isNull,
      );
    });
  });
}

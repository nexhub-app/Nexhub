/// F10（导出增强）单元测试。
///
/// - 漫画翻译缓存导出/导入：JSON 回环、导入合并跳过已有键、
///   chapterKey 含 `|` 的键往返无损、导入后 load 命中（不再发请求）；
/// - 小说译文附录排版：译文优先 / 原文优先 / 双语对照（无原文回落）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:nexhub/core/comic/comic_translation_manager.dart';
import 'package:nexhub/core/ai/vision_translation_client.dart';
import 'package:nexhub/core/download/novel_download_handler.dart';
import 'package:nexhub/core/novel/novel_translation_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

NovelChapterTranslation _chapter({
  List<String>? sources,
}) =>
    NovelChapterTranslation(
      novelId: 'book',
      chapterId: 'ch1',
      chapterTitle: '第一章',
      lang: '中文',
      translations: const <String>['译甲', '译乙'],
      sources: sources,
      updatedAt: 1,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('F10 漫画翻译缓存导出/导入', () {
    late Directory tempDir;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, String>{});
      tempDir = await Directory.systemTemp.createTemp('nexhub_f10_comic');
      Hive.init(tempDir.path);
    });

    tearDown(() async {
      if (Hive.isBoxOpen(ComicTranslationManager.boxName)) {
        await Hive.deleteBoxFromDisk(ComicTranslationManager.boxName);
      }
      try {
        await tempDir.delete(recursive: true);
      } on Object {
        // 清理失败忽略。
      }
    });

    test('导出→清空→导入：load 命中缓存（不再发请求）；已有键跳过', () async {
      final m = ComicTranslationManager();
      await m.save(
        comicId: 'comic1',
        chapterKey: 'ch/1',
        pageIndex: 0,
        lang: 'zh',
        translation: const ComicPageTranslation(
          imageUrl: 'http://img/1.jpg',
          lang: 'zh',
          segments: <VisionTextSegment>[
            VisionTextSegment(
                x1: 0, y1: 0, x2: 500, y2: 100,
                text: '原文', translation: '译文'),
          ],
          updatedAt: 111,
        ),
      );
      await m.save(
        comicId: 'comic1',
        chapterKey: 'a|b', // chapterKey 含管道符。
        pageIndex: 3,
        lang: 'zh',
        translation: const ComicPageTranslation(
          imageUrl: 'http://img/2.jpg',
          lang: 'zh',
          segments: <VisionTextSegment>[],
          updatedAt: 222,
        ),
      );
      final json = await m.exportJson();
      expect(json, contains('comic1'));
      expect(json, contains('a|b'));

      // 清空后导入：两页全部导入，load 命中。
      await m.clearAll();
      final (imported, skipped) = await m.importJson(json);
      expect(imported, 2);
      expect(skipped, 0);
      final restored = await m.load(
          comicId: 'comic1', chapterKey: 'ch/1', pageIndex: 0, lang: 'zh');
      expect(restored, isNotNull);
      expect(restored!.segments.single.translation, '译文');
      final piped = await m.load(
          comicId: 'comic1', chapterKey: 'a|b', pageIndex: 3, lang: 'zh');
      expect(piped, isNotNull);
      expect(piped!.isEmptyPage, isTrue); // 空页缓存同样复原。

      // 再次导入：全部跳过（不覆盖）。
      final (imported2, skipped2) = await m.importJson(json);
      expect(imported2, 0);
      expect(skipped2, 2);
    });

    test('非法格式抛 FormatException', () async {
      final m = ComicTranslationManager();
      await expectLater(
        m.importJson('{"foo":1}'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('F10 小说译文附录排版', () {
    test('translationFirst 仅译文；sourceFirst 仅原文；bilingual 逐段对照', () {
      final t = _chapter(sources: const <String>['原甲', '原乙']);
      final html = NovelDownloadHandler.translationsToEpubHtml(<NovelChapterTranslation>[t],
          layout: 'bilingual')!;
      expect(html, contains('<p>原甲</p>'));
      expect(html, contains('<p>译甲</p>'));
      final htmlSrc = NovelDownloadHandler.translationsToEpubHtml(
          <NovelChapterTranslation>[t],
          layout: 'sourceFirst')!;
      expect(htmlSrc, contains('<p>原甲</p>'));
      expect(htmlSrc, isNot(contains('<p>译甲</p>')));
      final htmlTr = NovelDownloadHandler.translationsToEpubHtml(
          <NovelChapterTranslation>[t])!;
      expect(htmlTr, contains('<p>译甲</p>'));
      expect(htmlTr, isNot(contains('<p>原甲</p>')));
    });

    test('无原文（旧缓存）时双语/原文优先回落为译文', () {
      final t = _chapter(); // sources == null。
      final htmlBi = NovelDownloadHandler.translationsToEpubHtml(
          <NovelChapterTranslation>[t],
          layout: 'bilingual')!;
      expect(htmlBi, contains('<p>译甲</p>'));
      expect(htmlBi, isNot(contains('<p>原甲</p>')));
      final htmlSrc = NovelDownloadHandler.translationsToEpubHtml(
          <NovelChapterTranslation>[t],
          layout: 'sourceFirst')!;
      expect(htmlSrc, contains('<p>译甲</p>'));
    });

    test('TXT 版本同样按排版输出', () {
      final t = _chapter(sources: const <String>['原甲', '原乙']);
      final txt = NovelDownloadHandler.translationsToTxt(
          <NovelChapterTranslation>[t],
          layout: 'bilingual');
      expect(txt, contains('原甲'));
      expect(txt, contains('译甲'));
    });
  });
}

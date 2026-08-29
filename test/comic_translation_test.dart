/// 漫画/视频翻译功能的单元测试：
/// - [VisionTextSegment] JSON 宽容解析（markdown 围栏 / bbox 数组 / 平铺字段）；
/// - [ComicPageTranslation] 缓存 JSON 往返；
/// - [ComicTranslationManager] 缓存键与存取（内存 Hive）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:nexhub/core/ai/vision_translation_client.dart';
import 'package:nexhub/core/comic/comic_translation_manager.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VisionTextSegment JSON 解析', () {
    test('解析纯 JSON 数组（bbox 数组形式）', () {
      const raw =
          '[{"bbox":[100,200,400,500],"text":"こんにちは","translation":"你好"}]';
      final segments = VisionTranslationClient.parseSegmentsJson(raw);
      expect(segments, hasLength(1));
      expect(segments.first.text, 'こんにちは');
      expect(segments.first.translation, '你好');
      expect(segments.first.hasBbox, isTrue);
      expect(segments.first.x1, 100);
      expect(segments.first.y2, 500);
    });

    test('剥离 markdown 代码围栏', () {
      const raw = '```json\n'
          '[{"bbox":[1,2,3,4],"text":"a","translation":"b"}]\n'
          '```';
      final segments = VisionTranslationClient.parseSegmentsJson(raw);
      expect(segments, hasLength(1));
      expect(segments.first.translation, 'b');
    });

    test('容忍前后杂文（模型废话）', () {
      const raw = '好的，以下是识别结果：\n'
          '[{"x1":10,"y1":20,"x2":300,"y2":80,"text":"hi","translation":"嗨"}]'
          '\n以上。';
      final segments = VisionTranslationClient.parseSegmentsJson(raw);
      expect(segments, hasLength(1));
      expect(segments.first.x2, 300);
    });

    test('空文本段被丢弃', () {
      const raw = '[{"text":"","translation":""},{"text":"x","translation":"y"}]';
      final segments = VisionTranslationClient.parseSegmentsJson(raw);
      expect(segments, hasLength(1));
      expect(segments.first.text, 'x');
    });

    test('非 JSON 输入返回空列表', () {
      expect(VisionTranslationClient.parseSegmentsJson('抱歉，我无法识别'),
          isEmpty);
      expect(VisionTranslationClient.parseSegmentsJson(''), isEmpty);
    });

    test('无坐标段 hasBbox 为 false（视频 OCR 行）', () {
      const raw = '[{"text":"hello","translation":"你好"}]';
      final segments = VisionTranslationClient.parseSegmentsJson(raw);
      expect(segments.first.hasBbox, isFalse);
    });
  });

  group('ComicPageTranslation 缓存往返', () {
    test('toJson/fromJson 保留区域与语言', () {
      const t = ComicPageTranslation(
        imageUrl: 'https://example.com/p1.jpg',
        lang: 'zh',
        segments: [
          VisionTextSegment(
              x1: 10, y1: 20, x2: 30, y2: 40, text: 'a', translation: '甲'),
        ],
        updatedAt: 12345,
      );
      final restored = ComicPageTranslation.fromJson(t.toJson());
      expect(restored.imageUrl, t.imageUrl);
      expect(restored.lang, t.lang);
      expect(restored.updatedAt, 12345);
      expect(restored.segments, hasLength(1));
      expect(restored.segments.first.translation, '甲');
      expect(restored.isEmptyPage, isFalse);
    });

    test('空段列表标记空页', () {
      const t = ComicPageTranslation(
          imageUrl: 'x', lang: 'zh', segments: [], updatedAt: 1);
      expect(t.isEmptyPage, isTrue);
    });
  });

  group('ComicTranslationManager（临时目录 Hive）', () {
    late ComicTranslationManager manager;

    setUpAll(() async {
      final dir = await Directory.systemTemp.createTemp('nexhub_test_ct');
      Hive.init(p.join(dir.path, 'hive'));
      manager = ComicTranslationManager();
      await manager.init();
    });

    test('save/load 往返与语言隔离', () async {
      const t = ComicPageTranslation(
        imageUrl: 'https://example.com/page.jpg',
        lang: 'zh',
        segments: [
          VisionTextSegment(x1: 0, y1: 0, x2: 100, y2: 100,
              text: 'src', translation: 'dst'),
        ],
        updatedAt: 42,
      );
      await manager.save(
        comicId: 'comic1',
        chapterKey: 'ch1',
        pageIndex: 3,
        lang: 'zh',
        translation: t,
      );
      final loaded = await manager.load(
        comicId: 'comic1',
        chapterKey: 'ch1',
        pageIndex: 3,
        lang: 'zh',
      );
      expect(loaded, isNotNull);
      expect(loaded!.segments.first.translation, 'dst');
      // 换语言不命中。
      final other = await manager.load(
        comicId: 'comic1',
        chapterKey: 'ch1',
        pageIndex: 3,
        lang: 'en',
      );
      expect(other, isNull);
    });

    test('clearForComic 只清本作品', () async {
      await manager.save(
        comicId: 'comic2',
        chapterKey: 'ch1',
        pageIndex: 0,
        lang: 'zh',
        translation: const ComicPageTranslation(
            imageUrl: 'u', lang: 'zh', segments: [], updatedAt: 1),
      );
      final n = await manager.clearForComic('comic2');
      expect(n, 1);
      final gone = await manager.load(
          comicId: 'comic2', chapterKey: 'ch1', pageIndex: 0, lang: 'zh');
      expect(gone, isNull);
    });
  });
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/download/epub_builder.dart';
import 'package:nexhub/core/download/novel_download_handler.dart';
import 'package:nexhub/core/novel/novel_export_template.dart';
import 'package:nexhub/core/services/cloud_sync_service.dart';
import 'package:nexhub/core/services/novel_export_upload_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('F4 EpubBuilder 自定义模板', () {
    final chapters = <EpubChapter>[
      const EpubChapter(title: '第一章', content: '<p>正文一</p>'),
      const EpubChapter(title: '第二章', content: '<p>正文二</p>'),
    ];

    String entryText(Archive archive, String name) =>
        utf8.decode(List<int>.from(archive.findFile(name)!.content as List));

    test('css 注入 style.css 且每章 head 引用；无 css 时不出现在包内', () {
      final bytes = EpubBuilder.build(
        metadata: const EpubMetadata(title: '书'),
        chapters: chapters,
        css: 'body { font-family: serif }',
      );
      final archive = ZipDecoder().decodeBytes(bytes);
      final css = entryText(archive, 'OEBPS/style.css');
      expect(css, contains('font-family'));
      final ch1 = entryText(archive, 'OEBPS/chapter-1.xhtml');
      expect(ch1, contains('style.css'));

      final plain = EpubBuilder.build(
        metadata: const EpubMetadata(title: '书'),
        chapters: chapters,
      );
      final plainArchive = ZipDecoder().decodeBytes(plain);
      expect(plainArchive.findFile('OEBPS/style.css'), isNull);
    });

    test('封面生成 cover.xhtml 首个 spine 项与 meta name=cover', () {
      final bytes = EpubBuilder.build(
        metadata: const EpubMetadata(title: '书'),
        chapters: chapters,
        coverImage: EpubImage(
            href: 'Images/cover.jpg', data: Uint8List.fromList(<int>[1, 2, 3])),
        introHtml: '<p>简介内容</p>',
      );
      final archive = ZipDecoder().decodeBytes(bytes);
      expect(archive.findFile('OEBPS/cover.xhtml'), isNotNull);
      expect(archive.findFile('OEBPS/intro.xhtml'), isNotNull);
      expect(archive.findFile('OEBPS/Images/cover.jpg'), isNotNull);

      final opf = entryText(archive, 'OEBPS/content.opf');
      expect(opf, contains('<meta name="cover" content="coverImg"/>'));
      // spine 顺序：封面 → 简介 → 章节。
      final coverIdx = opf.indexOf('idref="coverPage"');
      final introIdx = opf.indexOf('idref="introPage"');
      final chIdx = opf.indexOf('idref="ch1"');
      expect(coverIdx, inInclusiveRange(0, chIdx));
      expect(introIdx, greaterThan(coverIdx));
      expect(chIdx, greaterThan(introIdx));

      final ncx = entryText(archive, 'OEBPS/toc.ncx');
      expect(ncx, contains('cover.xhtml'));
      expect(ncx.indexOf('cover.xhtml'),
          lessThan(ncx.indexOf('chapter-1.xhtml')));
    });
  });

  group('F4 模板模型 / 简介渲染', () {
    test('renderIntroHtml 替换占位符、空行分段并转义', () {
      final html = NovelDownloadHandler.renderIntroHtml(
        '{book}\n\n作者：{author}\n\n<b>不是标签</b>',
        bookTitle: '测试书名',
        author: '测试作者',
      );
      expect(html, contains('<p>测试书名</p>'));
      expect(html, contains('<p>作者：测试作者</p>'));
      expect(html, contains('&lt;b&gt;不是标签&lt;/b&gt;'));
    });

    test('NovelExportTemplate JSON 往返', () {
      const t = NovelExportTemplate(
        customCss: 'p { margin: 0 }',
        intro: '简介',
        includeCover: false,
        includeIntro: false,
      );
      final restored = NovelExportTemplate.fromJson(t.toJson());
      expect(restored.customCss, t.customCss);
      expect(restored.intro, t.intro);
      expect(restored.includeCover, isFalse);
      expect(restored.includeIntro, isFalse);
    });

    test('模板存储 SharedPreferences 往返', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = NovelExportTemplateStore.instance;
      await store.save(const NovelExportTemplate(customCss: 'h1{}'));
      expect(store.template.customCss, 'h1{}');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('novel_export_template_v1'), isNotNull);
    });
  });

  group('F6 云同步配置 autoUploadNovelExports', () {
    test('默认关闭，JSON 往返保持', () {
      const cfg = CloudSyncConfig();
      expect(cfg.autoUploadNovelExports, isFalse);

      final next = cfg.copyWith(autoUploadNovelExports: true);
      expect(next.autoUploadNovelExports, isTrue);

      final restored = CloudSyncConfig.fromJson(next.toJson());
      expect(restored.autoUploadNovelExports, isTrue);
    });
  });

  group('F6 上传服务远端路径', () {
    test('remoteNameFor 取 basename 并替换非法字符', () {
      final service = NovelExportUploadService();
      expect(service.remoteNameFor('/a/b/书名:卷一.epub'),
          '书名_卷一.epub');
      expect(service.remoteNameFor('plain.epub'), 'plain.epub');
    });

    test('buildUrl 去除根地址尾斜杠', () {
      final service = NovelExportUploadService();
      expect(service.buildUrl('https://dav.example.com/', 'nexhub/exports'),
          'https://dav.example.com/nexhub/exports');
    });
  });
}

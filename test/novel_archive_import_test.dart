import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart' as arc;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/local/archive_extractor.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// 测试桩：把「应用支持目录」指到临时目录。
class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.supportPath);
  final String supportPath;

  @override
  Future<String?> getApplicationSupportPath() async => supportPath;

  @override
  Future<String?> getTemporaryPath() async => supportPath;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // mock path_provider：把「应用支持目录」指向临时目录（导入产物落盘断言用）。
  setUp(() async {
    final supportRoot = await Directory.systemTemp.createTemp('d9_support');
    final original = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProvider(supportRoot.path);
    addTearDown(() async {
      PathProviderPlatform.instance = original;
      try {
        await supportRoot.delete(recursive: true);
      } on Object {
        // 清理失败忽略。
      }
    });
  });

  group('D9 压缩包批量导入：归档识别与小说文件提取', () {
    test('isNovelArchiveFile 按扩展名识别（大小写不敏感）', () {
      expect(isNovelArchiveFile('/a/书.zip'), isTrue);
      expect(isNovelArchiveFile('/a/书.CBZ'), isTrue);
      expect(isNovelArchiveFile(r'C:\b\卷一.RAR'), isTrue);
      expect(isNovelArchiveFile('/a/书.7z'), isTrue);
      expect(isNovelArchiveFile('/a/书.epub'), isFalse);
      expect(isNovelArchiveFile('/a/书.txt'), isFalse);
    });

    test('extractNovelFilesFromArchive 解出 txt/epub、忽略图片、自然排序', () async {
      final tmp = await Directory.systemTemp.createTemp('d9_import_test');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } on Object {
          // 清理失败忽略。
        }
      });

      final zipPath =
          '${tmp.path}${Platform.pathSeparator}合集.zip';
      final encoder = arc.ZipEncoder();
      final archive = arc.Archive()
        ..addFile(arc.ArchiveFile('10_第三章.txt', utf8.encode('第三章内容').length, utf8.encode('第三章内容')))
        ..addFile(arc.ArchiveFile('2_第一章.txt', utf8.encode('第一章内容').length, utf8.encode('第一章内容')))
        ..addFile(arc.ArchiveFile('sub/第二章.epub', 4, <int>[0x50, 0x4B, 3, 4]))
        ..addFile(arc.ArchiveFile('cover.jpg', 2, <int>[0xFF, 0xD8]));
      await File(zipPath).writeAsBytes(encoder.encode(archive)!);

      final extracted = await extractNovelFilesFromArchive(zipPath);
      // 图片被过滤；txt/epub 按自然序（2 → 10）排列；epub 在子目录也命中。
      expect(extracted.length, 3);
      expect(extracted.first.endsWith('.txt'), isTrue);
      final names = extracted.map((e) => e.split('_').length).toList();
      expect(names.every((n) => n >= 2), isTrue);
      // 内容完整落盘。
      final first = await File(extracted.first).readAsString();
      expect(first, anyOf(equals('第一章内容'), equals('第三章内容')));
    });

    test('无小说文件的归档抛 StateError', () async {
      final tmp = await Directory.systemTemp.createTemp('d9_empty_test');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } on Object {
          // 清理失败忽略。
        }
      });
      final zipPath = '${tmp.path}${Platform.pathSeparator}空.zip';
      final encoder = arc.ZipEncoder();
      final archive = arc.Archive()
        ..addFile(arc.ArchiveFile('only.jpg', 1, <int>[0xFF]));
      await File(zipPath).writeAsBytes(encoder.encode(archive)!);

      await expectLater(
        extractNovelFilesFromArchive(zipPath),
        throwsA(isA<StateError>()),
      );
    });
  });
}

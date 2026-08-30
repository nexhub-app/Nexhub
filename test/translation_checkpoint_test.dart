/// F4（批次级检查点与断点续译）单元测试。
///
/// - 检查点存储：save/load/clear 回环、原子临时键不残留、listForNovel
///   不把检查点当完整章节；
/// - 续译路径：已完成块不重复请求；中途失败的快照已落盘，续跑补齐剩余段。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:nexhub/core/ai/glossary_manager.dart';
import 'package:nexhub/core/novel/novel_translation_manager.dart';
import 'package:nexhub/features/novel/domain/novel_translation_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 可注入失败的分块回声适配器：响应「译N」按块内序号；[failAt] 指定第几
/// 个请求（从 1 起）失败，模拟 mid-chunk 中断。
class _FailEchoAdapter implements HttpClientAdapter {
  _FailEchoAdapter({this.failAt});

  /// 第 failAt 个请求抛错（null = 全部成功）。
  final int? failAt;
  int requests = 0;
  final List<List<String>> chunkTexts = <List<String>>[];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    if (failAt != null && requests == failAt) {
      throw Exception('SocketException: connection reset');
    }
    final dynamic data = options.data;
    final String userContent = (data['messages'] as List<dynamic>)
        .cast<Map<dynamic, dynamic>>()
        .lastWhere((m) => m['role'] == 'user')['content'] as String;
    final matches =
        RegExp(r'<<<\s*(\d+)\s*>>>').allMatches(userContent).toList();
    chunkTexts.add(<String>[
      for (var i = 0; i < matches.length; i++)
        userContent
            .substring(
              matches[i].end,
              i + 1 < matches.length ? matches[i + 1].start : userContent.length,
            )
            .trim(),
    ]);
    final buf = StringBuffer();
    for (var i = 0; i < matches.length; i++) {
      buf.writeln('<<<${i + 1}>>>');
      buf.writeln('译${matches[i].group(1)}');
    }
    return ResponseBody.fromString(
      jsonEncode(<String, dynamic>{
        'choices': <Map<String, dynamic>>[
          <String, dynamic>{
            'message': <String, dynamic>{'content': buf.toString()},
          },
        ],
      }),
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('F4 检查点存储', () {
    late Directory tempDir;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, String>{});
      tempDir = await Directory.systemTemp.createTemp('nexhub_f4_box');
      Hive.init(tempDir.path);
    });

    tearDown(() async {
      if (Hive.isBoxOpen(NovelTranslationManager.boxName)) {
        await Hive.deleteBoxFromDisk(NovelTranslationManager.boxName);
      }
      try {
        await tempDir.delete(recursive: true);
      } on Object {
        // 清理失败忽略。
      }
    });

    NovelChapterTranslation partial({required List<String> translations}) =>
        NovelChapterTranslation(
          novelId: 'book',
          chapterId: 'ch1',
          chapterTitle: '第一章',
          lang: '中文',
          translations: translations,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        );

    test('save/load/clear 回环；临时键不残留', () async {
      final m = NovelTranslationManager();
      await m.saveCheckpoint(partial(translations: <String>['甲', '', '丙']));
      expect(await m.hasCheckpoint('book', 'ch1', lang: '中文'), isTrue);
      final loaded =
          await m.loadCheckpoint('book', 'ch1', lang: '中文');
      expect(loaded, isNotNull);
      expect(loaded!.translations, <String>['甲', '', '丙']);
      // 原子写不留临时键。
      final box = Hive.box(NovelTranslationManager.boxName);
      expect(
        box.keys
            .whereType<String>()
            .where((k) => k.endsWith('|tmp'))
            .toList(),
        isEmpty,
      );
      await m.clearCheckpoint('book', 'ch1', lang: '中文');
      expect(await m.hasCheckpoint('book', 'ch1', lang: '中文'), isFalse);
      expect(await m.loadCheckpoint('book', 'ch1', lang: '中文'), isNull);
    });

    test('listForNovel 不包含检查点记录', () async {
      final m = NovelTranslationManager();
      await m.saveCheckpoint(partial(translations: <String>['甲', '']));
      // 完整译文另存。
      await m.save(partial(translations: <String>['甲', '乙']));
      final listed = await m.listForNovel('book', lang: '中文');
      expect(listed, hasLength(1));
      expect(listed.single.translations, <String>['甲', '乙']);
    });
  });

  group('F4 断点续译服务', () {
    late Directory tempDir;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, String>{
        'novel_overview_api_base_v1': 'http://test.local',
      });
      tempDir = await Directory.systemTemp.createTemp('nexhub_f4_svc');
      Hive.init(tempDir.path);
    });

    tearDown(() async {
      for (final name in const <String>[
        NovelTranslationManager.boxName,
        GlossaryManager.boxName,
      ]) {
        if (Hive.isBoxOpen(name)) {
          await Hive.deleteBoxFromDisk(name);
        }
      }
      try {
        await tempDir.delete(recursive: true);
      } on Object {
        // 清理失败忽略。
      }
    });

    test('已完成块不重复请求；快照逐块落盘', () async {
      final adapter = _FailEchoAdapter(failAt: 2);
      final dio = Dio()..httpClientAdapter = adapter;
      final service = NovelTranslationService(dio: dio);
      final paragraphs =
          List<String>.generate(24, (i) => '段落${i + 1}');
      // 每块 12 段 → 2 块。首次翻译第 2 块失败（failAt=2）。
      final snapshots = <List<String>>[];
      Object? caught;
      try {
        await service.translateParagraphs(
          paragraphs,
          batchSize: 12, // 显式分块（24 段本可 one-shot，此处验证分块检查点）。
          existing: const <String>[],
          onChunkPersisted: snapshots.add,
        );
      } on Object catch (e) {
        caught = e;
      }
      expect(caught, isNotNull);
      // 第 1 块已完成的快照在失败前落盘。
      expect(snapshots, isNotEmpty);
      expect(snapshots.last.take(12).every((t) => t.isNotEmpty), isTrue);
      expect(snapshots.last.skip(12).every((t) => t.isEmpty), isTrue);

      // 续跑：传入已有快照 → 只请求第 2 块（增量 1 次请求）。
      final requestsBefore = adapter.requests;
      final resume = await service.translateParagraphs(
        paragraphs,
        batchSize: 12,
        existing: snapshots.last,
      );
      expect(resume, hasLength(24));
      expect(resume.take(12), snapshots.last.take(12));
      expect(resume.skip(12).every((t) => t.isNotEmpty), isTrue);
      expect(adapter.requests - requestsBefore, 1); // 已完成块不重复计费。
      final secondChunk = adapter.chunkTexts.last;
      expect(secondChunk, hasLength(12));
      expect(secondChunk.first, '段落13');
    });

    test('全部完成时直接返回不发请求', () async {
      final adapter = _FailEchoAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final service = NovelTranslationService(dio: dio);
      final done = List<String>.generate(5, (i) => '译${i + 1}');
      final result = await service.translateParagraphs(
        List<String>.generate(5, (i) => '段落${i + 1}'),
        existing: done,
      );
      expect(result, done);
      expect(adapter.requests, 0);
    });
  });
}

/// F5（多阶段质量：润色 + 证据驱动审查）单元测试。
///
/// - 润色服务：编号协议批量回声、进度回调、输入长度校验；
/// - 审查引擎：术语一致性 / 疑似漏译 / 疑似直译腔 三类证据（含位置）；
/// - 管理器：润色独立槽位 save/load/clear；审查报告 Hive 回环 + 摘要截断。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:nexhub/core/ai/glossary_manager.dart';
import 'package:nexhub/core/novel/novel_review_manager.dart';
import 'package:nexhub/core/novel/novel_translation_manager.dart';
import 'package:nexhub/features/novel/domain/novel_polish_service.dart';
import 'package:nexhub/features/novel/domain/novel_review_service.dart';
import 'package:nexhub/features/novel/domain/novel_summary_service.dart'
    show NovelSummaryConfig;
import 'package:shared_preferences/shared_preferences.dart';

class _EchoAdapter implements HttpClientAdapter {
  final List<String> systemPrompts = <String>[];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final dynamic data = options.data;
    systemPrompts.add((data['messages'][0] as Map)['content'] as String);
    final String userContent = (data['messages'] as List<dynamic>)
        .cast<Map<dynamic, dynamic>>()
        .lastWhere((m) => m['role'] == 'user')['content'] as String;
    final matches =
        RegExp(r'<<<\s*(\d+)\s*>>>').allMatches(userContent).toList();
    final buf = StringBuffer();
    for (var i = 0; i < matches.length; i++) {
      buf.writeln('<<<${i + 1}>>>');
      buf.writeln('润${matches[i].group(1)}');
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

NovelChapterTranslation _chapter({
  required List<String> translations,
  List<String>? sources,
  String chapterId = 'ch1',
}) =>
    NovelChapterTranslation(
      novelId: 'book',
      chapterId: chapterId,
      chapterTitle: '第一章',
      lang: '中文',
      translations: translations,
      sources: sources,
      updatedAt: 1,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const cfg = NovelSummaryConfig(
    baseUrl: 'http://test.local',
    apiKey: 'key',
    model: 'test-model',
  );

  group('F5 润色服务', () {
    test('批量回声按块内序号；进度回调到总量', () async {
      final adapter = _EchoAdapter();
      final done = <int>[];
      final totals = <int>[];
      final result = await NovelPolishService(dio: Dio()..httpClientAdapter = adapter)
          .polishParagraphs(
        cfg: cfg,
        lang: '中文',
        sources: List<String>.generate(10, (i) => '原文${i + 1}'),
        translations: List<String>.generate(10, (i) => '初译${i + 1}'),
        onProgress: (d, t) { done.add(d); totals.add(t); },
      );
      expect(result, hasLength(10));
      expect(result[0], '润1');
      // 第二块按块内序号回声：第 9/10 段 → 润1/润2。
      expect(result[8], '润1');
      expect(result[9], '润2');
      // 分块 8 → 两批；进度到达 8 与 10。
      expect(done, <int>[8, 10]);
      expect(totals.every((t) => t == 10), isTrue);
      expect(adapter.systemPrompts, hasLength(2)); // 分块 8 → 两批请求。
      expect(adapter.systemPrompts.first, contains('共 8 段'));
    });

    test('原文译文长度不一致直接拒绝', () async {
      await expectLater(
        NovelPolishService(dio: Dio()..httpClientAdapter = _EchoAdapter())
            .polishParagraphs(
          cfg: cfg,
          lang: '中文',
          sources: const <String>['a', 'b'],
          translations: const <String>['甲'],
        ),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('F5 审查引擎', () {
    test('术语一致性 / 漏译 / 直译腔 三类证据齐备', () {
      const glossary = <GlossaryEntry>[
        GlossaryEntry(id: '1', term: 'サクラ', preferred: '小樱'),
      ];
      final findings = NovelReviewService.review(
        chapters: <NovelChapterTranslation>[
          _chapter(
            chapterId: 'ch1',
            translations: <String>[
              '沙克拉笑了。', // 术语偏离 → glossary。
              '', // 空译文 → missing。
              '今日はいい天気だ', // 与原文相同 → literal。
              '完美译文',
            ],
            sources: const <String>[
              'サクラは笑った。',
              '彼は驚いた。',
              '今日はいい天気だ',
              '彼女は静かに頷いた。',
            ],
          ),
        ],
        lang: '中文',
        glossary: glossary,
      );
      final types = findings.map((f) => f.type).toList();
      expect(types, containsAll(<String>[
        ReviewFindingType.glossary,
        ReviewFindingType.missing,
        ReviewFindingType.literal,
      ]));
      final glossaryFinding =
          findings.firstWhere((f) => f.type == ReviewFindingType.glossary);
      expect(glossaryFinding.paragraphIndex, 0);
      expect(glossaryFinding.source, contains('サクラ'));
      expect(glossaryFinding.detail, contains('小樱'));
    });

    test('长度异常收缩按直译腔记录；正常段落零发现', () {
      final findings = NovelReviewService.review(
        chapters: <NovelChapterTranslation>[
          _chapter(
            translations: const <String>['好'],
            sources: const <String>[
              'この文章は非常に長くて、内容も複雑で、複数のキャラクターと出来事が絡み合っている。',
            ],
          ),
        ],
        lang: '中文',
      );
      expect(findings, hasLength(1));
      expect(findings.single.type, ReviewFindingType.literal);
      expect(findings.single.detail, contains('25%'));
    });

    test('旧缓存（无 sources）只做空译文检查', () {
      final findings = NovelReviewService.review(
        chapters: <NovelChapterTranslation>[
          _chapter(translations: <String>['', '译文']),
        ],
        lang: '中文',
      );
      expect(findings, hasLength(1));
      expect(findings.single.type, ReviewFindingType.missing);
    });
  });

  group('F5 管理器', () {
    late Directory tempDir;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, String>{});
      tempDir = await Directory.systemTemp.createTemp('nexhub_f5_box');
      Hive.init(tempDir.path);
    });

    tearDown(() async {
      for (final name in const <String>[
        NovelTranslationManager.boxName,
        NovelReviewManager.boxName,
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

    test('润色槽位独立于初译缓存；listForNovel / listNovelIds 不混入', () async {
      final m = NovelTranslationManager();
      await m.save(_chapter(translations: <String>['初译甲']));
      await m.savePolished(_chapter(translations: <String>['润色甲']));
      final polished =
          await m.loadPolished('book', 'ch1', lang: '中文');
      expect(polished!.translations, <String>['润色甲']);
      // 初译不受影响。
      final translated =
          await m.load('book', 'ch1', lang: '中文');
      expect(translated!.translations, <String>['初译甲']);
      // 枚举不混入润色槽位。
      expect(await m.listNovelIds(), <String>['book']);
      final listed = await m.listForNovel('book', lang: '中文');
      expect(listed, hasLength(1));
      // 清除。
      await m.clearPolished('book', 'ch1', lang: '中文');
      expect(await m.loadPolished('book', 'ch1', lang: '中文'), isNull);
    });

    test('审查报告 Hive 回环与摘要版截断', () async {
      final m = NovelReviewManager();
      final findings = <TranslationReviewFinding>[
        for (var i = 0; i < 150; i++)
          TranslationReviewFinding(
            type: ReviewFindingType.literal,
            chapterId: 'ch1',
            chapterTitle: '第一章',
            paragraphIndex: i,
            source: '原文$i',
            translation: '译$i',
            detail: 'detail$i',
          ),
      ];
      final full = TranslationReviewReport(
        novelId: 'book',
        lang: '中文',
        novelTitle: '测试之书',
        createdAt: 7,
        chaptersReviewed: 3,
        findings: findings,
        truncated: true,
      );
      await m.save(full);
      final loaded = await m.load('book', lang: '中文');
      expect(loaded, isNotNull);
      expect(loaded!.findings, hasLength(150));
      expect(loaded.truncated, isTrue);
      expect(loaded.countsByType[ReviewFindingType.literal], 150);
      expect(
        await m.listReviewedNovelIds(),
        <String>{'book'},
      );
    });
  });
}

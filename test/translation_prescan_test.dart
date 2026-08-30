/// F3（全书预扫描：章节摘要 + 全书概述注入）单元测试。
///
/// - 摘要服务：编号协议批量生成、批次上限、概述请求；
/// - 管理器：save/load 回环、章节更新合并（保留有效摘要、概述失效）、
///   作品语境（novelBookContext）组装。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:nexhub/core/novel/novel_prescan_manager.dart';
import 'package:nexhub/features/novel/domain/novel_prescan_service.dart';
import 'package:nexhub/features/novel/domain/novel_summary_service.dart'
    show NovelSummaryConfig;
import 'package:shared_preferences/shared_preferences.dart';

/// 记录请求并按编号协议回声「摘要N」的假适配器；最后一条 user 消息
/// 中含「概述」关键字时回声整段概述。
class _EchoAdapter implements HttpClientAdapter {
  final List<int> markerCounts = <int>[];
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
    markerCounts.add(matches.length);
    String content;
    if (matches.isEmpty) {
      content = '主角成长为主线，团结伴与试炼构成全书骨架。';
    } else {
      final buf = StringBuffer();
      for (var i = 0; i < matches.length; i++) {
        buf.writeln('<<<${i + 1}>>>');
        buf.writeln('摘要${matches[i].group(1)}');
      }
      content = buf.toString();
    }
    return ResponseBody.fromString(
      jsonEncode(<String, dynamic>{
        'choices': <Map<String, dynamic>>[
          <String, dynamic>{
            'message': <String, dynamic>{'content': content},
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

NovelSummaryConfig config() => const NovelSummaryConfig(
      baseUrl: 'http://test.local',
      apiKey: 'key',
      model: 'test-model',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  NovelSummaryConfig cfg() => const NovelSummaryConfig(
        baseUrl: 'http://test.local',
        apiKey: 'key',
        model: 'test-model',
      );

  // 让 PrescanChapterInput 的 cfg 类型测试可用：直接复用真实
  // NovelSummaryConfig（同包内可见）。
  group('F3 预扫描服务', () {
    late _EchoAdapter adapter;

    setUp(() {
      SharedPreferences.setMockInitialValues(<String, String>{
        'novel_overview_api_base_v1': 'http://test.local',
      });
      adapter = _EchoAdapter();
    });

    test('章节摘要按批次回声且顺序一致；批次 ≤ 8', () async {
      final service = NovelPrescanService(dio: Dio()..httpClientAdapter = adapter);
      final items = <PrescanChapterInput>[
        for (var i = 1; i <= 20; i++)
          PrescanChapterInput(
            chapterId: 'ch$i',
            title: '第$i章',
            head: '第$i章的开头内容',
          ),
      ];
      final summaries = await service.summarizeChapters(
        cfg: cfg(),
        lang: '中文',
        items: items,
      );
      expect(summaries, hasLength(20));
      expect(summaries[0], '摘要1');
      expect(summaries[7], '摘要8');
      expect(summaries[8], '摘要9');
      expect(summaries[19], '摘要20');
      // ceil(20/8) = 3 次请求；每批 marker 数 = 本批章数。
      expect(adapter.markerCounts, <int>[8, 8, 4]);
    });

    test('全书概述请求不带编号标记', () async {
      final service = NovelPrescanService(dio: Dio()..httpClientAdapter = adapter);
      final overview = await service.bookOverview(
        cfg: cfg(),
        lang: '中文',
        novelTitle: '测试之书',
        chapterSummaries: const <String>['第一章发生了一件事', '第二章发生了另一件事'],
      );
      expect(overview, contains('全书骨架'));
      expect(adapter.markerCounts.last, 0); // 概述请求无编号标记。
      expect(adapter.systemPrompts.last, contains('全书概述'));
    });
  });

  group('F3 预扫描管理器', () {
    late Directory tempDir;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, String>{});
      tempDir = await Directory.systemTemp.createTemp('nexhub_f3_box');
      Hive.init(tempDir.path);
    });

    tearDown(() async {
      if (Hive.isBoxOpen(NovelPrescanManager.boxName)) {
        await Hive.deleteBoxFromDisk(NovelPrescanManager.boxName);
      }
      try {
        await tempDir.delete(recursive: true);
      } on Object {
        // 清理失败忽略。
      }
    });

    test('save/load 回环与概述标记', () async {
      final m = NovelPrescanManager();
      final data = NovelPrescanData(
        novelId: 'book',
        lang: '中文',
        novelTitle: '测试之书',
        chapters: const <NovelPrescanChapterSummary>[
          NovelPrescanChapterSummary(
              chapterId: 'ch1', title: '第一章', summary: '主角登场'),
        ],
        overview: '这是一本测试之书。',
        updatedAt: 1,
      );
      await m.save(data);
      final loaded = await m.load('book', lang: '中文');
      expect(loaded, isNotNull);
      expect(loaded!.novelTitle, '测试之书');
      expect(loaded.summaryFor('ch1')!.summary, '主角登场');
      expect(loaded.overview, isNotNull);
    });

    test('章节更新合并：保留有效摘要、概述失效', () async {
      final m = NovelPrescanManager();
      final existing = NovelPrescanData(
        novelId: 'book',
        lang: '中文',
        novelTitle: '旧标题',
        chapters: const <NovelPrescanChapterSummary>[
          NovelPrescanChapterSummary(
              chapterId: 'ch1', title: '第一章', summary: '主角登场'),
          NovelPrescanChapterSummary(
              chapterId: 'ch2', title: '第二章', summary: '离队'),
        ],
        overview: '旧概述',
        updatedAt: 1,
      );
      final merged = m.mergeWithCurrentChapters(
        existing: existing,
        novelTitle: '测试之书',
        currentChapters: const <({String id, String title})>[
          (id: 'ch1', title: '第一章'),
          (id: 'ch3', title: '第三章'),
        ],
      );
      expect(merged.summaryFor('ch1'), isNotNull); // 仍存在 → 保留。
      expect(merged.summaryFor('ch2'), isNull); // 已删除 → 丢弃。
      expect(merged.summaryFor('ch3'), isNull); // 新章节 → 待扫。
      expect(merged.overview, isNull); // 概述失效。
      expect(merged.novelTitle, '测试之书');
    });

    test('novelBookContext 组装概述+本章前情；缺失时返回 null', () {
      final data = NovelPrescanData(
        novelId: 'book',
        lang: '中文',
        novelTitle: '测试之书',
        chapters: const <NovelPrescanChapterSummary>[
          NovelPrescanChapterSummary(
              chapterId: 'ch2', title: '第二章', summary: '主角离队修行'),
        ],
        overview: '一本关于成长的书。',
        updatedAt: 1,
      );
      final ctx = NovelPrescanManager.novelBookContext(data, 'ch2');
      expect(ctx, contains('《测试之书》概述'));
      expect(ctx, contains('本章前情'));
      expect(ctx, contains('离队修行'));
      // 本章无摘要但有概述 → 只注入概述。
      final partialCtx = NovelPrescanManager.novelBookContext(data, 'ch9');
      expect(partialCtx, contains('概述'));
      expect(partialCtx, isNot(contains('本章前情')));
      // 完全无数据 → null。
      expect(NovelPrescanManager.novelBookContext(null, 'ch1'), isNull);
    });
  });
}

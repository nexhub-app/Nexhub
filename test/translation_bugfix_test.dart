/// 翻译功能 B1–B9 修复的回归测试（见 ku/translate/translation-bugs-and-roadmap.md）。
///
/// - B1 视频 OCR 防重入：上一次视觉请求未返回时新 tick 不再并发发起；
/// - B2 漫画翻译并发信号量：连续 5 页并发请求峰值 ≤ 2；
/// - B3 小说 one-shot 预算保护：超大章直接分块、不发必然截断的整章请求；
/// - B4 字幕单句重试：先失败 2 次再成功，调用数 == 3 且译文就位；
/// - B5 缓存容量上限：三个 box 的 trimToLimit / 清空；
/// - B6 图片缩放：解码尺寸 / 长边下采样（codec 释放收口在工具类）；
/// - B7 错误归一化：连接 / 超时 / 其他 → 可读文案；
/// - B8 OCR 兜底轨道检测：有字幕轨不触发 OCR，无轨 / 换轨后恢复。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:nexhub/core/ai/image_resizer.dart';
import 'package:nexhub/core/ai/glossary_manager.dart';
import 'package:nexhub/core/ai/translation_exception.dart';
import 'package:nexhub/core/ai/vision_translation_client.dart';
import 'package:nexhub/core/comic/comic_translation_manager.dart';
import 'package:nexhub/core/novel/novel_translation_manager.dart';
import 'package:nexhub/core/player/subtitle_translation_controller.dart';
import 'package:nexhub/features/manga/presentation/comic_translation_controller.dart';
import 'package:nexhub/features/novel/domain/novel_translation_service.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

// ─────────────────────────── 测试假件 ───────────────────────────

/// 可计数 / 可阻塞 / 可注入失败的假视觉客户端。
class _FakeVisionClient extends VisionTranslationClient {
  _FakeVisionClient({this.failTranslateTimes = 0, this.recognizeDelayMs = 0});

  int recognizeCalls = 0;
  int translateCalls = 0;
  int concurrentRecognize = 0;
  int maxConcurrentRecognize = 0;

  /// 非 null 时阻塞进行中的识别调用（B1 防重入测试用）。
  Completer<void>? recognizeGate;
  int recognizeDelayMs;
  final int failTranslateTimes;

  @override
  Future<List<VisionTextSegment>> recognizeImage({
    required AiEndpointConfig config,
    required Uint8List imageBytes,
    required String mimeType,
    required String systemPrompt,
    int maxSide = 1600,
  }) async {
    recognizeCalls++;
    concurrentRecognize++;
    if (concurrentRecognize > maxConcurrentRecognize) {
      maxConcurrentRecognize = concurrentRecognize;
    }
    try {
      final gate = recognizeGate;
      if (gate != null) await gate.future;
      if (recognizeDelayMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: recognizeDelayMs));
      }
      return const <VisionTextSegment>[
        VisionTextSegment(
            x1: 0, y1: 0, x2: 500, y2: 100, text: '原文', translation: '译文'),
      ];
    } finally {
      concurrentRecognize--;
    }
  }

  @override
  Future<List<String>> translateBatch({
    required AiEndpointConfig config,
    required String targetLang,
    required List<String> texts,
    List<TranslationContextPair> history = const <TranslationContextPair>[],
    bool lightweight = false,
    String? systemPrompt,
  }) async {
    translateCalls++;
    lastHistory = history;
    lastSystemPrompt = systemPrompt;
    if (translateCalls <= failTranslateTimes) {
      throw Exception('SocketException:connection interrupted');
    }
    return <String>[for (final t in texts) '[$t]'];
  }

  /// F2 测试观测：最近一次请求注入的对话历史与 system prompt。
  List<TranslationContextPair> lastHistory = const <TranslationContextPair>[];
  String? lastSystemPrompt;
}

class _FakeBackend {
  String? subText;
  String trackListJson = '[]';
  Future<String?> getProperty(String name) async {
    if (name == 'sub-text') return subText;
    if (name == 'track-list') return trackListJson;
    return null;
  }
}

class _FakePlayer {
  _FakePlayer(this.frame);
  final Uint8List frame;
  Future<Uint8List?> screenshot() async => frame;
}

class _FakePlayerController {
  _FakePlayerController(Uint8List frame)
      : player = _FakePlayer(frame),
        backend = _FakeBackend();
  final _FakePlayer player;
  final _FakeBackend backend;
  final StreamController<int> tracks = StreamController<int>.broadcast();
  Stream<int> get tracksStream => tracks.stream;
}

/// 记录请求体并按批量协议回声译文的假 HTTP 适配器（B3 用）。
class _EchoAdapter implements HttpClientAdapter {
  final List<int> markerCounts = <int>[];
  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final dynamic data = options.data;
    // F2 起批量正文前可能注入历史对话，取最后一条 user 消息作为批量输入。
    final String userContent = (data['messages'] as List<dynamic>)
        .cast<Map<dynamic, dynamic>>()
        .lastWhere((m) => m['role'] == 'user')['content'] as String;
    final matches =
        RegExp(r'<<<\s*(\d+)\s*>>>').allMatches(userContent).toList();
    markerCounts.add(matches.length);
    final buf = StringBuffer();
    for (var i = 0; i < matches.length; i++) {
      buf.writeln('<<<${i + 1}>>>');
      buf.writeln('译${i + 1}');
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

/// 生成纯色 PNG（flutter_test 环境支持 dart:ui 光栅化）。
Future<Uint8List> _png(int w, int h) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(
      recorder, Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()));
  canvas.drawPaint(Paint()..color = const Color(0xFF3399CC));
  final picture = recorder.endRecording();
  final image = await picture.toImage(w, h);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

/// 等待条件成立（超时抛错）。
Future<void> _waitFor(
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('等待条件超时');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ─────────────────────────── B7 ───────────────────────────

  group('B7 错误归一化', () {
    test('连接类异常 → 网络连接失败', () {
      final e = TranslationException.from(Exception('SocketException: failed'));
      expect(e.message, '网络连接失败，请检查网络后重试');
    });

    test('超时类异常 → 请求超时', () {
      final e = TranslationException.from(
          Exception('DioException [connection timeout]: TimedOut'));
      expect(e.message, '请求超时，请稍后重试');
    });

    test('其他异常 → 翻译失败前缀 + 截断', () {
      final e = TranslationException.from(Exception('something odd'));
      expect(e.message, startsWith('翻译失败：'));
      final long = TranslationException.from(Exception('x' * 300));
      expect(long.message.length, lessThan(200));
    });

    test('已是 TranslationException 时原样透传', () {
      const e = TranslationException('未配置云端 AI 接口');
      expect(TranslationException.from(e).message, '未配置云端 AI 接口');
      expect(e.toString(), '未配置云端 AI 接口');
    });
  });

  // ─────────────────────────── B6 ───────────────────────────

  group('B6 图片缩放工具', () {
    test('decodeSize 返回自然尺寸', () async {
      final size = await AiImageResizer.decodeSize(await _png(300, 200));
      expect(size.width, 300);
      expect(size.height, 200);
    });

    test('resizeToLimit 长边下采样', () async {
      final out =
          await AiImageResizer.resizeToLimit(await _png(300, 200), maxSide: 100);
      expect(out, isNotNull);
      final size = await AiImageResizer.decodeSize(out!);
      expect(size.width, 100);
      expect(size.height, 67); // round(200 × 100/300)
    });

    test('小图不放大（返回原图尺寸）', () async {
      final src = await _png(50, 40);
      final out = await AiImageResizer.resizeToLimit(src, maxSide: 100);
      final size = await AiImageResizer.decodeSize(out!);
      expect(size.width, 50);
      expect(size.height, 40);
    });
  });

  // ─────────────────────────── B9（协议测试见 batch_protocol_test.dart）─────

  // ─────────────────────────── B3 ───────────────────────────

  group('B3 小说 one-shot 预算保护', () {
    late _EchoAdapter adapter;
    late Directory tempDir;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, String>{
        'novel_overview_api_base_v1': 'http://test.local',
      });
      adapter = _EchoAdapter();
      // F1 起 translateParagraphs 会读取术语表（Hive），需先初始化。
      tempDir = await Directory.systemTemp.createTemp('nexhub_b3_test');
      Hive.init(tempDir.path);
    });

    tearDown(() async {
      if (Hive.isBoxOpen(GlossaryManager.boxName)) {
        await Hive.deleteBoxFromDisk(GlossaryManager.boxName);
      }
      try {
        await tempDir.delete(recursive: true);
      } on Object {
        // 清理失败忽略。
      }
    });

    test('100 段直接分块，每块 ≤ 块大小且 ≤ one-shot 上限', () async {
      final dio = Dio()..httpClientAdapter = adapter;
      final service = NovelTranslationService(dio: dio);
      final paragraphs =
          List<String>.generate(100, (i) => '段落${i + 1}');
      final result = await service.translateParagraphs(paragraphs);
      expect(result, hasLength(100));
      // 回声按块内序号：第 i 段（0 起）落在第 i~/12 块的 i%12 位 → 译(i%12)+1。
      for (var i = 0; i < 100; i++) {
        expect(result[i], '译${(i % 12) + 1}', reason: '第 ${i + 1} 段');
      }
      // ceil(100/12) = 9 次分块请求；任何请求都不超块大小 / 上限 40。
      expect(adapter.markerCounts, hasLength(9));
      for (final n in adapter.markerCounts) {
        expect(n, lessThanOrEqualTo(12));
        expect(n, lessThanOrEqualTo(40));
      }
    });

    test('小章节保持 one-shot 快速路径', () async {
      final dio = Dio()..httpClientAdapter = adapter;
      final service = NovelTranslationService(dio: dio);
      final result = await service
          .translateParagraphs(List<String>.generate(5, (i) => '段落${i + 1}'));
      expect(result, hasLength(5));
      expect(adapter.markerCounts, <int>[5]);
    });
  });

  // ─────────────────────────── B2 ───────────────────────────

  group('B2 漫画翻译并发信号量', () {
    late Directory tempDir;
    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, String>{
        'novel_overview_api_base_v1': 'http://test.local',
      });
      tempDir = await Directory.systemTemp.createTemp('nexhub_b2_test');
      Hive.init(tempDir.path);
      if (Hive.isBoxOpen(ComicTranslationManager.boxName)) {
        await Hive.box(ComicTranslationManager.boxName).clear();
      } else {
        await Hive.openBox(ComicTranslationManager.boxName);
      }
    });

    tearDown(() async {
      await Hive.deleteBoxFromDisk(ComicTranslationManager.boxName);
      try {
        await tempDir.delete(recursive: true);
      } on Object {
        // 清理失败忽略。
      }
    });

    test('连续 5 页并发翻译，视觉请求峰值 ≤ 2 且全部完成', () async {
      final client = _FakeVisionClient(recognizeDelayMs: 60);
      final png = await _png(32, 32);
      final urls = <String>[];
      for (var i = 0; i < 5; i++) {
        final f = File(p.join(tempDir.path, 'p$i.png'));
        await f.writeAsBytes(png);
        urls.add(f.path);
      }
      final controller = ComicTranslationController(
        comicId: 'comic-b2',
        manager: ComicTranslationManager(),
        client: client,
      );
      await controller.setEnabled(true);
      await Future.wait(<Future<void>>[
        for (var i = 0; i < urls.length; i++)
          controller.ensureTranslated(
            urls[i],
            chapterKey: 'ch1',
            pageIndex: i,
          ),
      ]);
      expect(client.recognizeCalls, 5);
      expect(client.maxConcurrentRecognize, lessThanOrEqualTo(2));
      expect(client.maxConcurrentRecognize, greaterThanOrEqualTo(2)); // 确有并发
      for (final url in urls) {
        expect(controller.stateFor(url).status, ComicPageTranslationStatus.done);
      }
    });
  });

  // ─────────────────────── B1 / B4 / B8 ───────────────────────

  group('B1/B4/B8 视频字幕实时翻译', () {
    late Uint8List frame;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, String>{
        'novel_overview_api_base_v1': 'http://test.local',
      });
      frame = await _png(32, 32);
      Hive.init(
          '${Directory.systemTemp.path}/nexhub_b1_test_${DateTime.now().microsecondsSinceEpoch}');
    });

    test('B1：OCR 请求未返回时新 tick 不重入（间隔已过仍只发一次）', () async {
      final fakeClient = _FakeVisionClient();
      final pc = _FakePlayerController(frame)..backend.subText = '';
      final controller = SubtitleTranslationController(client: fakeClient);
      DateTime now = DateTime(2026, 1, 1, 12, 0, 0);
      controller.clock = () => now;
      await controller.attach(pc);
      // 先开 OCR 兜底再开总开关：此时 _enabled=false，setOcrFallback 不会走
      // force OCR 路径，后续 OCR 全部由 onPositionTick 驱动（无竞态）。
      await controller.setOcrFallback(true);
      await controller.setEnabled(true);
      expect(controller.ocrFallback, isTrue);

      // 第一个 tick：发起 OCR #1（阻塞在 gate）。
      fakeClient.recognizeGate = Completer<void>();
      controller.onPositionTick(Duration.zero);
      await _waitFor(() => fakeClient.recognizeCalls == 1);

      // 模拟 10s 后的新 tick（间隔已过）：上一次 OCR 未返回 → 不得重入。
      now = now.add(const Duration(seconds: 10));
      controller.onPositionTick(const Duration(seconds: 10));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(fakeClient.recognizeCalls, 1);

      // 释放 gate：OCR #1 完成；再过 10s 的新 tick 才允许 OCR #2。
      fakeClient.recognizeGate!.complete();
      await _waitFor(() => controller.state.translatedText != null);
      now = now.add(const Duration(seconds: 10));
      controller.onPositionTick(const Duration(seconds: 20));
      await _waitFor(() => fakeClient.recognizeCalls == 2);
      expect(fakeClient.maxConcurrentRecognize, 1);
    });

    test('B8：有字幕轨零 OCR；换轨为无轨后恢复 OCR', () async {
      final fakeClient = _FakeVisionClient();
      final pc = _FakePlayerController(frame)
        ..backend.subText = ''
        ..backend.trackListJson = '[{"type":"sub","id":"1"}]';
      final controller = SubtitleTranslationController(client: fakeClient);
      DateTime now = DateTime(2026, 1, 2, 12, 0, 0);
      controller.clock = () => now;
      await controller.attach(pc);
      await controller.setEnabled(true);
      await controller.setOcrFallback(true);
      expect(controller.hasSubtitleTrack, isTrue);

      now = now.add(const Duration(seconds: 10));
      controller.onPositionTick(Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(fakeClient.recognizeCalls, 0); // 有轨：句间间隙不 OCR

      // 换轨为无轨（轨道变化事件触发重检测）。
      pc.backend.trackListJson = '[]';
      pc.tracks.add(1);
      await _waitFor(() => controller.hasSubtitleTrack == false);
      now = now.add(const Duration(seconds: 10));
      controller.onPositionTick(const Duration(seconds: 5));
      await _waitFor(() => fakeClient.recognizeCalls == 1);
    });

    test('B4：单句翻译瞬时失败重试（2 次失败后成功）', () async {
      final fakeClient = _FakeVisionClient(failTranslateTimes: 2);
      final pc = _FakePlayerController(frame)..backend.subText = 'こんにちは';
      final controller = SubtitleTranslationController(client: fakeClient);
      await controller.attach(pc);
      await controller.setEnabled(true); // force 轮询触发翻译
      await _waitFor(() => controller.state.translatedText != null);
      expect(controller.state.translatedText, '[こんにちは]');
      expect(fakeClient.translateCalls, 3);
    });
  });

  // ─────────────────────────── B5 ───────────────────────────

  group('B5 翻译缓存容量上限', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('nexhub_b5_test');
      Hive.init(tempDir.path);
    });

    tearDown(() async {
      for (final name in <String>[
        NovelTranslationManager.boxName,
        ComicTranslationManager.boxName,
        'subtitle_translations',
      ]) {
        if (Hive.isBoxOpen(name)) await Hive.box(name).close();
        await Hive.deleteBoxFromDisk(name);
      }
      try {
        await tempDir.delete(recursive: true);
      } on Object {
        // 清理失败忽略。
      }
    });

    test('小说缓存：trimToLimit 按 updatedAt 升序淘汰 + clearAll', () async {
      final manager = NovelTranslationManager();
      await manager.init();
      for (var i = 0; i < 5; i++) {
        await manager.save(NovelChapterTranslation(
          novelId: 'n1',
          chapterId: 'c$i',
          chapterTitle: '章$i',
          lang: 'zh',
          translations: <String>['译$i'],
          updatedAt: i,
        ));
      }
      await manager.trimToLimit(3);
      expect(manager.count(), 3);
      expect(await manager.load('n1', 'c0'), isNull); // 最旧被淘汰
      expect(await manager.load('n1', 'c4'), isNotNull); // 最新保留
      expect(await manager.clearAll(), 3);
      expect(manager.count(), 0);
    });

    test('漫画缓存：trimToLimit 按 updatedAt 升序淘汰', () async {
      final manager = ComicTranslationManager();
      await manager.init();
      for (var i = 0; i < 12; i++) {
        await manager.save(
          comicId: 'n1',
          chapterKey: 'ch1',
          pageIndex: i,
          lang: 'zh',
          translation: ComicPageTranslation(
            imageUrl: 'u$i',
            lang: 'zh',
            segments: const <VisionTextSegment>[],
            updatedAt: i,
          ),
        );
      }
      await manager.trimToLimit(10);
      expect(manager.count(), 10);
      expect(
        await manager.load(
            comicId: 'n1', chapterKey: 'ch1', pageIndex: 0, lang: 'zh'),
        isNull,
      );
      expect(
        await manager.load(
            comicId: 'n1', chapterKey: 'ch1', pageIndex: 11, lang: 'zh'),
        isNotNull,
      );
    });

    test('字幕缓存：trimCache 按时间戳淘汰 + clearCache 清空', () async {
      final controller = SubtitleTranslationController();
      final box = await Hive.openBox<dynamic>('subtitle_translations');
      await box.clear();
      final keys = <String>[];
      for (var i = 0; i < 12; i++) {
        final text = '句$i';
        final key = 'zh|${md5.convert(utf8.encode(text)).toString()}';
        keys.add(key);
        await box.put(key, jsonEncode(<String, dynamic>{'t': '[$text]', 'ts': i}));
      }
      expect(controller.cacheCount(), 12);
      await controller.trimCache(10);
      expect(controller.cacheCount(), 10);
      expect(box.containsKey(keys.first), isFalse); // 最旧被淘汰
      expect(box.containsKey(keys.last), isTrue);
      await controller.clearCache();
      expect(controller.cacheCount(), 0);
      await box.close();
    });
  });
}

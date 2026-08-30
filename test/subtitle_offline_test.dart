/// F6（视频离线管线一期）单元测试：字幕文件解析 / 双语生成 / 任务编排。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:nexhub/core/ai/glossary_manager.dart';
import 'package:nexhub/core/ai/translation_options_store.dart';
import 'package:nexhub/core/ai/vision_translation_client.dart';
import 'package:nexhub/core/player/subtitle_file.dart';
import 'package:nexhub/core/player/subtitle_offline_pipeline.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _srtSample = '''1
00:00:01,000 --> 00:00:02,500
こんにちは

2
00:00:03,000 --> 00:00:04,000
元気ですか？
はい

3
00:00:05,000 --> 00:00:06,000
<i>italic line</i>
''';

const _assSample = '''[Script Info]
Title: test

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H64000000,0,0,0,0,100,100,0,0,1,2,1,2,10,10,10,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,{\\i1}こんにちは{\\i0}
Dialogue: 0,0:00:03.50,0:00:04.50,Default,,0,0,0,,第二行\\N第三行
''';

const _vttSample = '''WEBVTT

00:00:01.000 --> 00:00:02.000
hello

00:00:03.000 --> 00:00:04.000
world
''';

/// 回声假客户端。
class _EchoClient extends VisionTranslationClient {
  int calls = 0;
  final List<int> batchSizes = <int>[];

  @override
  Future<List<String>> translateBatch({
    required AiEndpointConfig config,
    required String targetLang,
    required List<String> texts,
    List<TranslationContextPair> history = const <TranslationContextPair>[],
    bool lightweight = false,
    String? systemPrompt,
  }) async {
    calls++;
    batchSizes.add(texts.length);
    return <String>[for (final t in texts) '译[$t]'];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('F6 字幕文件解析', () {
    test('SRT：多行 cue / 标签剥离 / 序号无关', () {
      final cues = SubtitleFile.parse(_srtSample);
      expect(cues, hasLength(3));
      expect(cues[0].start.inMilliseconds, 1000);
      expect(cues[0].end.inMilliseconds, 2500);
      expect(cues[0].text, 'こんにちは');
      expect(cues[1].text, '元気ですか？\nはい');
      expect(cues[2].text, isNot(contains('<i>')));
    });

    test('ASS：Dialogue 解析 / 内联标记剥离 / 换行拆分', () {
      final cues = SubtitleFile.parse(_assSample);
      expect(cues, hasLength(2));
      expect(cues[0].start.inMilliseconds, 1000);
      expect(cues[0].text, 'こんにちは');
      expect(cues[1].text, '第二行\n第三行');
      expect(cues[1].start.inMilliseconds, 3500);
    });

    test('VTT：句点毫秒分隔', () {
      final cues = SubtitleFile.parse(_vttSample);
      expect(cues, hasLength(2));
      expect(cues[0].start.inMilliseconds, 1000);
      expect(cues[1].text, 'world');
    });
  });

  group('F6 双语字幕生成', () {
    test('双语 SRT：时间轴不变、原译相邻；未译仅原文', () {
      final cues = SubtitleFile.parse(_srtSample);
      cues[0].translation = '你好';
      final out = SubtitleFile.buildBilingualSrt(cues);
      expect(out, contains('00:00:01,000 --> 00:00:02,500'));
      expect(out, contains('こんにちは\n你好'));
      expect(out, contains('元気ですか？\nはい')); // 未译条目仅原文。
      // 序号连续（1..3）。
      expect(RegExp(r'^3$', multiLine: true).hasMatch(out), isTrue);
    });

    test('双语 ASS：Dialogue 含 \N 换行', () {
      final cues = SubtitleFile.parse(_srtSample);
      cues[0].translation = '你好';
      final out = SubtitleFile.buildBilingualAss(cues);
      expect(out, contains('[Events]'));
      expect(out, contains('0:00:01.00,0:00:02.50'));
      expect(out, contains('こんにちは\\N你好'));
    });
  });

  group('F6 离线管线', () {
    late Directory tempDir;
    late Directory subDir;
    late _EchoClient client;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, String>{
        'novel_overview_api_base_v1': 'http://test.local',
        'media_translation_api_base_v1': 'http://test.local',
      });
      tempDir = await Directory.systemTemp.createTemp('nexhub_f6');
      Hive.init(tempDir.path);
      subDir = Directory('${tempDir.path}/subs')..createSync(recursive: true);
      client = _EchoClient();
      // path_provider mock（导出落盘用）。
      const channel =
          MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        return tempDir.path;
      });
    });

    tearDown(() async {
      if (Hive.isBoxOpen(SubtitleOfflinePipeline.boxName)) {
        await Hive.deleteBoxFromDisk(SubtitleOfflinePipeline.boxName);
      }
      if (Hive.isBoxOpen(GlossaryManager.boxName)) {
        await Hive.deleteBoxFromDisk(GlossaryManager.boxName);
      }
      try {
        await tempDir.delete(recursive: true);
      } on Object {
        // 清理失败忽略。
      }
    });

    Future<String> writeSubtitle(String name, String content) async {
      final f = File('${subDir.path}/$name');
      await f.writeAsString(content);
      return f.path;
    }

    test('整片翻译：分块批量、逐块落盘、状态完成', () async {
      final pipeline = SubtitleOfflinePipeline(
        client: client,
        glossary: GlossaryManager(),
        options: TranslationOptionsStore(),
      );
      final subPath = await writeSubtitle('sample.srt', _srtSample);
      final id = await pipeline.start(
        videoPath: '/tmp/video.mkv',
        videoTitle: 'video.mkv',
        subtitlePath: subPath,
        lang: '中文',
        config: const AiEndpointConfig(
            baseUrl: 'http://test.local', apiKey: 'k', model: 'm'),
        chunkSize: 2,
      );
      // 等待后台任务完成（3 个 cue / 每块 2 → 2 次请求）。
      for (var i = 0; i < 100; i++) {
        final job = await pipeline.getJob(id);
        if (job?.status == SubtitleJobStatus.done) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final job = await pipeline.getJob(id);
      expect(job!.status, SubtitleJobStatus.done);
      expect(job.cueCount, 3);
      expect(job.translatedCount, 3);
      expect(client.calls, 2);
      expect(client.batchSizes, <int>[2, 1]);
      expect(job.translations[0], contains('こんにちは'));
    });

    test('导出双语 SRT 与 ASS', () async {
      final pipeline = SubtitleOfflinePipeline(
        client: client,
        glossary: GlossaryManager(),
        options: TranslationOptionsStore(),
      );
      final subPath = await writeSubtitle('sample.srt', _srtSample);
      final id = await pipeline.start(
        videoPath: '/tmp/video.mkv',
        videoTitle: 'video.mkv',
        subtitlePath: subPath,
        lang: '中文',
        config: const AiEndpointConfig(
            baseUrl: 'http://test.local', apiKey: 'k', model: 'm'),
      );
      for (var i = 0; i < 100; i++) {
        final job = await pipeline.getJob(id);
        if (job?.status == SubtitleJobStatus.done) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final job = await pipeline.getJob(id);
      final srtPath = await pipeline.export(job: job!, ass: false);
      final srt = await File(srtPath).readAsString();
      expect(srt, contains('こんにちは\n译[こんにちは]'));
      final assPath = await pipeline.export(job: job, ass: true);
      final ass = await File(assPath).readAsString();
      expect(ass, contains('こんにちは\\N译[こんにちは]'));
    });
  });
}

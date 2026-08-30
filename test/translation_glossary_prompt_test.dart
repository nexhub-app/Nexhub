/// F1（术语表）/ F8（提示词体系）单元测试。
///
/// - GlossaryManager：增删改、全局+作品合并、导入合并、冲突检测；
/// - PromptBuilder：术语段/风格段/CoT/轻量格式/前页摘要分段拼接；
/// - BatchProtocol.decodeLoose：无编号逐行解析（围栏剥除/编号行忽略/条数校验）；
/// - 字幕控制器：术语表注入 system prompt、成功句入会话历史（F2）。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:nexhub/core/ai/batch_protocol.dart';
import 'package:nexhub/core/ai/glossary_manager.dart';
import 'package:nexhub/core/ai/prompt_builder.dart';
import 'package:nexhub/core/ai/translation_options_store.dart';
import 'package:nexhub/core/ai/vision_translation_client.dart';
import 'package:nexhub/core/player/subtitle_translation_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ─────────────────── F1：GlossaryManager ───────────────────

  group('F1 GlossaryManager', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('nexhub_f1_test');
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

    test('saveEntry 新增与更新、removeEntry 删除', () async {
      final m = GlossaryManager();
      final saved = await m.saveEntry(
        'book1',
        '中文',
        const GlossaryEntry(id: '', term: 'サクラ', preferred: '小樱'),
      );
      expect(saved, hasLength(1));
      final updated = await m.saveEntry(
        'book1',
        '中文',
        saved.first.copyWith(preferred: '樱'),
      );
      expect(updated.single.preferred, '樱');
      final loaded = await m.entriesFor('book1', '中文');
      expect(loaded.single.term, 'サクラ');
      expect(loaded.single.preferred, '樱');

      final afterRemove = await m.removeEntry('book1', '中文', loaded.single.id);
      expect(afterRemove, isEmpty);
    });

    test('effectiveEntries：全局 + 作品级合并，同术语作品级覆盖', () async {
      final m = GlossaryManager();
      await m.saveEntry(
        GlossaryManager.globalWorkId,
        '中文',
        const GlossaryEntry(id: 'g1', term: '魔法', preferred: '魔法'),
      );
      await m.saveEntry(
        GlossaryManager.globalWorkId,
        '中文',
        const GlossaryEntry(id: 'g2', term: '剣', preferred: '剑'),
      );
      await m.saveEntry(
        'book1',
        '中文',
        const GlossaryEntry(
            id: 'w1', term: '魔法', preferred: '法术', aliases: <String>['魔导']),
      );
      final merged = await m.effectiveEntries('book1', '中文');
      expect(merged, hasLength(2));
      final magic = merged.firstWhere((e) => e.term == '魔法');
      expect(magic.preferred, '法术');
      expect(magic.aliases, contains('魔导'));
      // 其他作品仍用全局译名。
      final other = await m.effectiveEntries('book2', '中文');
      expect(
        other.firstWhere((e) => e.term == '魔法').preferred,
        '魔法',
      );
    });

    test('importMerge：同术语覆盖、新术语追加；导出可回读', () async {
      final m = GlossaryManager();
      await m.saveEntry(
        GlossaryManager.globalWorkId,
        '中文',
        const GlossaryEntry(id: 'a', term: '魔法', preferred: '魔法'),
      );
      final incoming = GlossaryManager.parseImportJson(GlossaryManager.exportJson(
        const <GlossaryEntry>[
          GlossaryEntry(id: '', term: '魔法', preferred: '法术'),
          GlossaryEntry(id: '', term: '剣', preferred: '剑'),
        ],
      ));
      final merged = await m.importMerge(
          GlossaryManager.globalWorkId, '中文', incoming);
      expect(merged, hasLength(2));
      expect(
        merged.firstWhere((e) => e.term == '魔法').preferred,
        '法术',
      );
    });

    test('detectConflicts：术语命中且译文偏离时告警；别名不告警', () {
      const entries = <GlossaryEntry>[
        GlossaryEntry(id: '1', term: 'サクラ', preferred: '小樱'),
        GlossaryEntry(id: '2', term: 'カカシ', preferred: '卡卡西', aliases: <String>['鹿括西']),
      ];
      final warnings = GlossaryManager.detectConflicts(
        entries,
        <String>['サクラは笑った。', 'カカシは頷いた。'],
        <String>['沙克拉笑了。', '鹿括西点了点头。'],
      );
      expect(warnings, hasLength(1));
      expect(warnings.single, contains('サクラ'));
      // 全部符合（首选或别名）→ 无告警。
      expect(
        GlossaryManager.detectConflicts(
          entries,
          <String>['サクラとカカシ'],
          <String>['小樱和卡卡西'],
        ),
        isEmpty,
      );
      // 原文不含术语 → 不告警。
      expect(
        GlossaryManager.detectConflicts(
          entries,
          <String>['無関係な文'],
          <String>['无关的句子'],
        ),
        isEmpty,
      );
    });
  });

  // ─────────────────── F8：PromptBuilder ───────────────────

  group('F8 PromptBuilder', () {
    test('小说提示词：段数声明 + 编号格式 + 术语段 + 风格段 + CoT', () {
      final p = PromptBuilder.novelSystemPrompt(
        lang: '中文',
        paragraphCount: 3,
        glossary: const <GlossaryEntry>[
          GlossaryEntry(id: '1', term: 'サクラ', preferred: '小樱'),
        ],
        style: TranslationStyle.colloquial,
        cot: true,
      );
      expect(p, contains('共 3 段'));
      expect(p, contains('<<<'));
      expect(p, contains('サクラ→小樱'));
      expect(p, contains('口语化'));
      expect(p, contains('思考过程'));
    });

    test('字幕提示词：轻量格式不要求编号；默认要求编号', () {
      final light = PromptBuilder.subtitleSystemPrompt(
          lang: '中文', lightweight: true);
      expect(light, contains('每行一条'));
      expect(light, isNot(contains('每段译文前单独一行')));
      final numbered =
          PromptBuilder.subtitleSystemPrompt(lang: '中文', lightweight: false);
      expect(numbered, contains('每段译文前单独一行'));
    });

    test('漫画提示词：基础段 + 前页摘要（F2）', () {
      final p = PromptBuilder.mangaSystemPrompt(
        lang: '中文',
        prevPageSummary: '主角遇到怪物；逃进洞穴',
      );
      expect(p, contains('漫画翻译引擎'));
      expect(p, contains('前一页内容摘要'));
      expect(p, contains('逃进洞穴'));
      final without = PromptBuilder.mangaSystemPrompt(lang: '中文');
      expect(without, isNot(contains('前一页内容摘要')));
    });

    test('术语条目为空/全空时不注入术语段', () {
      expect(PromptBuilder.glossarySection(const <GlossaryEntry>[]), '');
      expect(
        PromptBuilder.glossarySection(const <GlossaryEntry>[
          GlossaryEntry(id: '1', term: '', preferred: ''),
        ]),
        '',
      );
    });
  });

  // ─────────────────── F8：BatchProtocol.decodeLoose ───────────────────

  group('F8 批量协议轻量解析', () {
    test('纯文本逐行对位', () {
      expect(
        BatchProtocol.decodeLoose('你好\n世界\n再见', 3),
        <String>['你好', '世界', '再见'],
      );
    });

    test('剥围栏与编号标记行、空行与列表符', () {
      final raw = '```text\n<<<1>>>\n- 甲\n\n<<<2>>>\n* 乙\n```';
      expect(BatchProtocol.decodeLoose(raw, 2), <String>['甲', '乙']);
    });

    test('条数不齐返回 null', () {
      expect(BatchProtocol.decodeLoose('只有一行', 2), isNull);
      expect(BatchProtocol.decodeLoose('', 1), isNull);
    });
  });

  // ─────────────────── F8：TranslationOptionsStore ───────────────────

  group('F8 TranslationOptionsStore', () {
    test('风格 / CoT / 轻量 / 导出排版 读写回环', () async {
      SharedPreferences.setMockInitialValues(<String, String>{});
      final s = TranslationOptionsStore();
      expect(await s.getStyle(), TranslationStyle.standard);
      await s.setStyle(TranslationStyle.elegant);
      expect(await s.getStyle(), TranslationStyle.elegant);
      expect(await s.getCotEnabled(), isFalse);
      await s.setCotEnabled(true);
      expect(await s.getCotEnabled(), isTrue);
      // 字幕轻量默认开。
      expect(await s.getSubtitleLightweight(), isTrue);
      await s.setSubtitleLightweight(false);
      expect(await s.getSubtitleLightweight(), isFalse);
      expect(await s.getNovelExportLayout(), 'translationFirst');
      await s.setNovelExportLayout('bilingual');
      expect(await s.getNovelExportLayout(), 'bilingual');
      // 非法值回落默认。
      await s.setNovelExportLayout('bad');
      expect(await s.getNovelExportLayout(), 'translationFirst');
    });

    test('作品级风格覆盖优先于全局', () async {
      SharedPreferences.setMockInitialValues(<String, String>{});
      final dir = await Directory.systemTemp.createTemp('nexhub_f8_style');
      Hive.init(dir.path);
      final s = TranslationOptionsStore();
      await s.setStyle(TranslationStyle.colloquial);
      expect(await s.effectiveStyle('book1'), TranslationStyle.colloquial);
      await s.setStyleOverride('book1', TranslationStyle.internet);
      expect(await s.effectiveStyle('book1'), TranslationStyle.internet);
      expect(await s.effectiveStyle('book2'), TranslationStyle.colloquial);
      await s.setStyleOverride('book1', null);
      expect(await s.effectiveStyle('book1'), TranslationStyle.colloquial);
      if (Hive.isBoxOpen('translation_style_overrides')) {
        await Hive.deleteBoxFromDisk('translation_style_overrides');
      }
      try {
        await dir.delete(recursive: true);
      } on Object {
        // 清理失败忽略。
      }
    });
  });

  // ─────────────── F1+F2：字幕控制器注入链路 ───────────────

  group('F1/F2 字幕翻译注入', () {
    test('system prompt 注入术语表与风格；成功句进入会话历史', () async {
      SharedPreferences.setMockInitialValues(<String, String>{
        'novel_overview_api_base_v1': 'http://test.local',
        'media_translation_api_base_v1': 'http://test.local',
        'media_translation_lang_v1': '中文',
        'translation_style_v1': 'colloquial',
      });
      final dir = await Directory.systemTemp.createTemp('nexhub_f1_sub');
      Hive.init(dir.path);
      final glossary = GlossaryManager();
      await glossary.saveEntry(
        GlossaryManager.globalWorkId,
        '中文',
        const GlossaryEntry(id: 'g1', term: 'サクラ', preferred: '小樱'),
      );
      final client = _RecordingFakeClient();
      final controller = SubtitleTranslationController(
        client: client,
        glossary: glossary,
      );
      final pc = _FakePlayerController();
      pc.backend.subText = 'サクラは走った';
      DateTime now = DateTime(2026, 1, 1, 12, 0, 0);
      controller.clock = () => now;
      await controller.attach(pc);
      // 开启即强制轮询一次 → 第一句翻译。
      await controller.setEnabled(true);
      await _drainMicrotasks();
      expect(client.translateCalls, 1);
      // 前进超过轮询间隔 → 第二句翻译（第一句应作为历史注入）。
      now = now.add(const Duration(seconds: 1));
      pc.backend.subText = '次の日に泣いた';
      controller.onPositionTick(const Duration(seconds: 1));
      await _drainMicrotasks();

      expect(client.translateCalls, 2);
      // F1：system prompt 含术语。
      expect(client.lastSystemPrompt, contains('サクラ→小樱'));
      // F8：风格注入。
      expect(client.lastSystemPrompt, contains('口语化'));
      // F2：第二句请求时历史含第一句。
      expect(client.lastHistory, hasLength(1));
      expect(client.lastHistory.single.source, 'サクラは走った');
      expect(client.lastHistory.single.translation, '[サクラは走った]');

      for (final box in const <String>[
        'subtitle_translations',
        GlossaryManager.boxName,
      ]) {
        if (Hive.isBoxOpen(box)) {
          await Hive.deleteBoxFromDisk(box);
        }
      }
      try {
        await dir.delete(recursive: true);
      } on Object {
        // 清理失败忽略。
      }
    });
  });
}

/// 记录请求参数的假客户端（回声译文）。
class _RecordingFakeClient extends VisionTranslationClient {
  int translateCalls = 0;
  List<TranslationContextPair> lastHistory = const <TranslationContextPair>[];
  String? lastSystemPrompt;

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
    return <String>[for (final t in texts) '[$t]'];
  }
}

class _FakeBackend {
  String? subText;
  Future<String?> getProperty(String name) async {
    if (name == 'sub-text') return subText;
    if (name == 'track-list') return '[]';
    return null;
  }
}

class _FakePlayerController {
  final _FakeBackend backend = _FakeBackend();
  final StreamController<int> tracks = StreamController<int>.broadcast();
  Stream<int> get tracksStream => tracks.stream;
}

/// 等待未 await 的轮询/翻译链路完成。
Future<void> _drainMicrotasks() async {
  await Future<void>.delayed(const Duration(milliseconds: 20));
}

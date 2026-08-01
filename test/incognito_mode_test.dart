/// 按源无痕模式（per-source incognito）单元测试。
///
/// 覆盖：
/// - `ConfigLoader.isIncognito` / `setIncognito` 往返与持久化。
/// - `isIncognito` 回退到 `PluginConfig.stealthMode`。
/// - `isIncognitoBySourceId` 在无 PluginConfig 时的行为。
/// - `HistoryManager.addHistory` 在源无痕时跳过写入。
/// - `PluginConfig.stealthMode` 默认值为 false。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:nexhub/core/comic/models/reader_preferences.dart';
import 'package:nexhub/core/history/history_manager.dart';
import 'package:nexhub/core/models/media_item.dart';
import 'package:nexhub/core/models/plugin_config.dart';
import 'package:nexhub/core/services/config_loader.dart';

void main() {
  setUpAll(() async {
    final dir = Directory.systemTemp.createTempSync('incognito_mode_test_');
    try {
      Hive.init(dir.path);
    } catch (_) {}
    await ConfigLoader.instance.init();
  });

  // 每个测试使用唯一 sourceId，避免单例缓存跨测试污染。

  group('ConfigLoader isIncognito / setIncognito', () {
    test('默认非无痕（无覆盖且 stealthMode 缺省 false）', () {
      const source = PluginConfig(
        id: 'inc_default_src',
        name: 'Default',
        type: SourceType.animeSource,
        site: SiteConfig(domain: 'x.com', baseUrl: 'https://x.com'),
        parser: ParserConfig(type: 'builtin'),
      );
      expect(ConfigLoader.instance.isIncognito(source), isFalse);
    });

    test('setIncognito(true) 后 isIncognito 返回 true', () async {
      const sourceId = 'inc_set_true_src';
      const source = PluginConfig(
        id: sourceId,
        name: 'SetTrue',
        type: SourceType.animeSource,
        site: SiteConfig(domain: 'x.com', baseUrl: 'https://x.com'),
        parser: ParserConfig(type: 'builtin'),
      );
      expect(ConfigLoader.instance.isIncognito(source), isFalse);

      await ConfigLoader.instance.setIncognito(sourceId, true);
      expect(ConfigLoader.instance.isIncognito(source), isTrue);
    });

    test('setIncognito 往返：true -> false 切换生效', () async {
      const sourceId = 'inc_roundtrip_src';
      const source = PluginConfig(
        id: sourceId,
        name: 'RoundTrip',
        type: SourceType.animeSource,
        site: SiteConfig(domain: 'x.com', baseUrl: 'https://x.com'),
        parser: ParserConfig(type: 'builtin'),
      );
      await ConfigLoader.instance.setIncognito(sourceId, true);
      expect(ConfigLoader.instance.isIncognito(source), isTrue);

      await ConfigLoader.instance.setIncognito(sourceId, false);
      expect(ConfigLoader.instance.isIncognito(source), isFalse);
    });

    test('持久化：覆盖确实写入 Hive box source_stealth', () async {
      const sourceId = 'inc_persist_src';
      await ConfigLoader.instance.setIncognito(sourceId, true);

      final box = Hive.box<dynamic>(ConfigLoader.sourceStealthBoxName);
      expect(box.get(sourceId), isTrue);
    });

    test('isIncognito 回退到 source.stealthMode（无运行时覆盖）', () {
      const source = PluginConfig(
        id: 'inc_stealth_fallback_src',
        name: 'Stealth',
        type: SourceType.animeSource,
        site: SiteConfig(domain: 'x.com', baseUrl: 'https://x.com'),
        parser: ParserConfig(type: 'builtin'),
        stealthMode: true,
      );
      // 未设置运行时覆盖时应回退到 stealthMode=true。
      expect(ConfigLoader.instance.isIncognito(source), isTrue);
    });

    test('运行时覆盖优先于 source.stealthMode', () async {
      const sourceId = 'inc_override_wins_src';
      const source = PluginConfig(
        id: sourceId,
        name: 'Override',
        type: SourceType.animeSource,
        site: SiteConfig(domain: 'x.com', baseUrl: 'https://x.com'),
        parser: ParserConfig(type: 'builtin'),
        stealthMode: true,
      );
      // stealthMode=true，但运行时覆盖设为 false → 应返回 false。
      await ConfigLoader.instance.setIncognito(sourceId, false);
      expect(ConfigLoader.instance.isIncognito(source), isFalse);
    });

    test('isIncognitoBySourceId：有覆盖时返回覆盖值', () async {
      const sourceId = 'inc_byid_src';
      await ConfigLoader.instance.setIncognito(sourceId, true);
      expect(ConfigLoader.instance.isIncognitoBySourceId(sourceId), isTrue);
    });

    test('isIncognitoBySourceId：无覆盖时返回 false', () {
      expect(
        ConfigLoader.instance.isIncognitoBySourceId('inc_byid_missing_src'),
        isFalse,
      );
    });

    test('isIncognitoBySourceId：空/null sourceId 返回 false', () {
      expect(ConfigLoader.instance.isIncognitoBySourceId(null), isFalse);
      expect(ConfigLoader.instance.isIncognitoBySourceId(''), isFalse);
    });
  });

  group('PluginConfig.stealthMode default', () {
    test('fromJson 缺省 stealthMode 时为 false', () {
      final source = PluginConfig.fromJson(const <String, dynamic>{
        'id': 'inc_default_json',
        'name': 'Json',
        'type': 'animeSource',
        'site': {'domain': 'x.com', 'baseUrl': 'https://x.com'},
        'parser': {'type': 'builtin'},
      });
      expect(source.stealthMode, isFalse);
    });

    test('fromJson 显式 stealthMode=true 时保留', () {
      final source = PluginConfig.fromJson(const <String, dynamic>{
        'id': 'inc_explicit_json',
        'name': 'Json',
        'type': 'animeSource',
        'site': {'domain': 'x.com', 'baseUrl': 'https://x.com'},
        'parser': {'type': 'builtin'},
        'stealthMode': true,
      });
      expect(source.stealthMode, isTrue);
    });

    test('toJson 仍输出 stealthMode 字段', () {
      const source = PluginConfig(
        id: 'inc_tojson',
        name: 'ToJson',
        type: SourceType.animeSource,
        site: SiteConfig(domain: 'x.com', baseUrl: 'https://x.com'),
        parser: ParserConfig(type: 'builtin'),
      );
      expect(source.toJson()['stealthMode'], isFalse);
    });
  });

  group('HistoryManager incognito gating', () {
    late InMemoryBackend backend;
    late HistoryManager manager;

    setUp(() {
      backend = InMemoryBackend();
      manager = HistoryManager(backend: backend, maxPerModule: 50);
    });

    test('源已开启无痕时 addHistory 跳过写入', () async {
      const sourceId = 'inc_history_skip_src';
      await ConfigLoader.instance.setIncognito(sourceId, true);

      await manager.addHistory(const MediaItem(
        id: 'novel_1',
        title: 'Novel',
        sourceType: SourceType.novelSource,
        sourceId: sourceId,
      ));

      expect(manager.historyFor(SourceType.novelSource), isEmpty);
    });

    test('源未开启无痕时 addHistory 正常写入', () async {
      const sourceId = 'inc_history_record_src';
      // 确保该源无覆盖（默认非无痕）。
      await ConfigLoader.instance.setIncognito(sourceId, false);

      await manager.addHistory(const MediaItem(
        id: 'novel_2',
        title: 'Novel',
        sourceType: SourceType.novelSource,
        sourceId: sourceId,
      ));

      expect(manager.historyFor(SourceType.novelSource).length, 1);
    });

    test('sourceId 为 null 时正常记录（不跳过）', () async {
      await manager.addHistory(const MediaItem(
        id: 'novel_3',
        title: 'NoSource',
        sourceType: SourceType.novelSource,
      ));

      expect(manager.historyFor(SourceType.novelSource).length, 1);
    });

    test('sourceId 为空字符串时正常记录（不跳过）', () async {
      await manager.addHistory(const MediaItem(
        id: 'novel_4',
        title: 'EmptySource',
        sourceType: SourceType.novelSource,
        sourceId: '',
      ));

      expect(manager.historyFor(SourceType.novelSource).length, 1);
    });
  });
}

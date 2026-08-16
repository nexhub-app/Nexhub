/// Tests for [HistoryEntry] field passthrough to [MediaItem] and JSON
/// backward compatibility (F3 defect 3: history gray screen root cause).
///
/// Verifies that `detailUrl` / `coverUrl` / `sourceId` survive the
/// `HistoryEntry -> MediaItem` conversion so [ContentDetailScreen] can
/// open the detail page without re-fetching, and that old persisted JSON
/// (missing the newer fields) deserializes without throwing.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:nexhub/core/comic/models/reader_preferences.dart';
import 'package:nexhub/core/history/history_manager.dart';
import 'package:nexhub/core/models/media_item.dart';
import 'package:nexhub/core/models/plugin_config.dart';

void main() {
  group('HistoryEntry -> MediaItem field passthrough', () {
    test('toMediaItem preserves detailUrl, coverUrl and sourceId', () {
      const entry = HistoryEntry(
        id: 'anime-1',
        title: 'Test Anime',
        coverUrl: 'https://example.com/cover.jpg',
        sourceId: 'src-1',
        sourceType: SourceType.animeSource,
        detailUrl: 'https://example.com/detail/anime-1',
        viewedAt: 1000,
      );
      final item = entry.toMediaItem();

      expect(item.id, 'anime-1');
      expect(item.title, 'Test Anime');
      expect(item.detailUrl, 'https://example.com/detail/anime-1');
      expect(item.coverUrl, 'https://example.com/cover.jpg');
      expect(item.sourceId, 'src-1');
      expect(item.sourceType, SourceType.animeSource);
    });

    test('toMediaItem preserves category as tags and status', () {
      const entry = HistoryEntry(
        id: 'novel-1',
        title: 'Test Novel',
        sourceType: SourceType.novelSource,
        viewedAt: 2000,
        category: 'Fantasy',
        status: 'Ongoing',
      );
      final item = entry.toMediaItem();

      expect(item.tags, <String>['Fantasy']);
      expect(item.status, 'Ongoing');
    });

    test('toMediaItem with null optional fields yields nulls', () {
      const entry = HistoryEntry(
        id: 'manga-1',
        title: 'Test Manga',
        sourceType: SourceType.mangaSource,
        viewedAt: 3000,
      );
      final item = entry.toMediaItem();

      expect(item.detailUrl, isNull);
      expect(item.coverUrl, isNull);
      expect(item.sourceId, isNull);
      expect(item.tags, isNull);
      expect(item.status, isNull);
    });

    test('fromMediaItem then toMediaItem round-trips core fields', () {
      const original = MediaItem(
        id: 'anime-2',
        title: 'Round Trip',
        coverUrl: 'https://example.com/c.jpg',
        sourceId: 'src-2',
        sourceType: SourceType.animeSource,
        detailUrl: 'https://example.com/d/anime-2',
        tags: <String>['Action'],
        status: 'Completed',
      );
      final entry = HistoryEntry.fromMediaItem(original, lastChapter: 'EP1');
      final back = entry.toMediaItem();

      expect(back.id, original.id);
      expect(back.title, original.title);
      expect(back.detailUrl, original.detailUrl);
      expect(back.coverUrl, original.coverUrl);
      expect(back.sourceId, original.sourceId);
      expect(back.sourceType, original.sourceType);
      expect(back.status, original.status);
    });
  });

  group('HistoryEntry.fromJson backward compat', () {
    test('old JSON without detailUrl/coverUrl yields null fields', () {
      final entry = HistoryEntry.fromJson(const <String, dynamic>{
        'id': 'old-1',
        'title': 'Old Entry',
        'sourceType': 'animeSource',
        'sourceId': 'src-old',
        'viewedAt': 5000,
      });

      expect(entry.id, 'old-1');
      expect(entry.title, 'Old Entry');
      expect(entry.sourceType, SourceType.animeSource);
      expect(entry.sourceId, 'src-old');
      expect(entry.detailUrl, isNull);
      expect(entry.coverUrl, isNull);
      expect(entry.viewedAt, 5000);
    });

    test('old JSON without sourceId yields null sourceId', () {
      final entry = HistoryEntry.fromJson(const <String, dynamic>{
        'id': 'old-2',
        'title': 'No Source',
        'sourceType': 'mangaSource',
        'viewedAt': 6000,
      });

      expect(entry.sourceId, isNull);
      expect(entry.detailUrl, isNull);
      expect(entry.coverUrl, isNull);
    });

    test('missing sourceType falls back to animeSource', () {
      final entry = HistoryEntry.fromJson(const <String, dynamic>{
        'id': 'old-3',
        'title': 'No Type',
        'viewedAt': 7000,
      });

      expect(entry.sourceType, SourceType.animeSource);
    });

    test('does not throw on minimal JSON', () {
      expect(
        () => HistoryEntry.fromJson(const <String, dynamic>{}),
        returnsNormally,
      );
    });
  });

  group('HistoryEntry.toJson round-trip', () {
    test('all fields survive serialize then deserialize', () {
      const original = HistoryEntry(
        id: 'rt-1',
        title: 'Round Trip Full',
        coverUrl: 'https://example.com/cover.png',
        sourceId: 'src-rt',
        sourceType: SourceType.novelSource,
        detailUrl: 'https://example.com/detail/rt-1',
        viewedAt: 9000,
        lastChapter: 'Chapter 5',
        category: 'Sci-Fi',
        status: 'Ongoing',
      );
      final json = original.toJson();
      final restored = HistoryEntry.fromJson(json);

      expect(restored.id, original.id);
      expect(restored.title, original.title);
      expect(restored.coverUrl, original.coverUrl);
      expect(restored.sourceId, original.sourceId);
      expect(restored.sourceType, original.sourceType);
      expect(restored.detailUrl, original.detailUrl);
      expect(restored.viewedAt, original.viewedAt);
      expect(restored.lastChapter, original.lastChapter);
      expect(restored.category, original.category);
      expect(restored.status, original.status);
    });

    test('toJson includes detailUrl and coverUrl keys', () {
      const entry = HistoryEntry(
        id: 'keys-1',
        title: 'Keys',
        coverUrl: 'https://example.com/k.jpg',
        sourceId: 'src-k',
        sourceType: SourceType.animeSource,
        detailUrl: 'https://example.com/d/k',
        viewedAt: 10000,
      );
      final json = entry.toJson();

      expect(json.containsKey('detailUrl'), isTrue);
      expect(json.containsKey('coverUrl'), isTrue);
      expect(json['detailUrl'], 'https://example.com/d/k');
      expect(json['coverUrl'], 'https://example.com/k.jpg');
    });

    test('null optional fields survive round-trip as null', () {
      const original = HistoryEntry(
        id: 'nulls-1',
        title: 'Nulls',
        sourceType: SourceType.mangaSource,
        viewedAt: 11000,
      );
      final restored = HistoryEntry.fromJson(original.toJson());

      expect(restored.detailUrl, isNull);
      expect(restored.coverUrl, isNull);
      expect(restored.sourceId, isNull);
      expect(restored.lastChapter, isNull);
      expect(restored.category, isNull);
      expect(restored.status, isNull);
    });
  });

  group('HistoryEntry.hidden round-trip', () {
    test('toJson/fromJson 保留 hidden=true', () {
      const entry = HistoryEntry(
        id: 'hid-1',
        title: 'Hidden',
        sourceType: SourceType.mangaSource,
        viewedAt: 1,
        hidden: true,
      );
      final restored = HistoryEntry.fromJson(entry.toJson());

      expect(restored.hidden, isTrue);
    });

    test('toJson 默认输出 hidden=false', () {
      const entry = HistoryEntry(
        id: 'hid-0',
        title: 'Visible',
        sourceType: SourceType.mangaSource,
        viewedAt: 2,
      );
      final json = entry.toJson();

      expect(json['hidden'], isFalse);
    });

    test('旧数据缺 hidden 字段按 false 解析（向后兼容）', () {
      final entry = HistoryEntry.fromJson(const <String, dynamic>{
        'id': 'old-hidden',
        'title': 'Old',
        'sourceType': 'mangaSource',
        'viewedAt': 3,
      });

      expect(entry.hidden, isFalse);
    });

    test('copyWith 可翻转 hidden', () {
      const entry = HistoryEntry(
        id: 'cw-1',
        title: 'CW',
        sourceType: SourceType.animeSource,
        viewedAt: 4,
      );
      expect(entry.hidden, isFalse);

      final hidden = entry.copyWith(hidden: true);
      expect(hidden.hidden, isTrue);

      final restored = hidden.copyWith(hidden: false);
      expect(restored.hidden, isFalse);

      // 未指定 hidden 时保留原值。
      final unchanged = hidden.copyWith();
      expect(unchanged.hidden, isTrue);
    });
  });

  group('HistoryManager hidden（REQ-C8 软删除）', () {
    HistoryManager newManager() => HistoryManager(backend: InMemoryBackend());

    Future<void> add(
      HistoryManager m,
      String id,
      String title,
      SourceType type,
    ) =>
        m.addHistory(
          MediaItem(id: id, title: title, sourceType: type),
          sourceType: type,
        );

    test('hideAll 后 historyFor 过滤 hidden，但条目仍保留（可 findById）', () async {
      final m = newManager();
      await add(m, 'h-1', 'Hidden One', SourceType.mangaSource);
      await add(m, 'h-2', 'Visible Two', SourceType.mangaSource);
      expect(m.historyFor(SourceType.mangaSource), hasLength(2));

      await m.hideAll(SourceType.mangaSource);

      // 列表不再显示已隐藏条目。
      expect(m.historyFor(SourceType.mangaSource), isEmpty);
      // 条目本身与进度仍保留（内部缓存未被物理删除）。
      final HistoryEntry? kept = m.findById('h-1');
      expect(kept, isNotNull);
      expect(kept!.hidden, isTrue);
      expect(kept.title, 'Hidden One');
    });

    test('clearHistory 同为软删除（保留条目）', () async {
      final m = newManager();
      await add(m, 'c-1', 'Cleared', SourceType.novelSource);

      await m.clearHistory(SourceType.novelSource);

      expect(m.historyFor(SourceType.novelSource), isEmpty);
      final HistoryEntry? kept = m.findById('c-1');
      expect(kept, isNotNull);
      expect(kept!.hidden, isTrue);
    });

    test('restore 复原 hidden=false，条目重新出现在列表', () async {
      final m = newManager();
      await add(m, 'r-1', 'Restored', SourceType.animeSource);
      await m.hideAll(SourceType.animeSource);
      expect(m.historyFor(SourceType.animeSource), isEmpty);

      await m.restore('r-1', sourceType: SourceType.animeSource);

      final list = m.historyFor(SourceType.animeSource);
      expect(list, hasLength(1));
      expect(list.single.id, 'r-1');
      expect(list.single.hidden, isFalse);
    });

    test('markHidden 单条软删除，不影响其他条目', () async {
      final m = newManager();
      await add(m, 's-1', 'Single Hidden', SourceType.mangaSource);
      await add(m, 's-2', 'Kept', SourceType.mangaSource);

      await m.markHidden('s-1', sourceType: SourceType.mangaSource);

      final list = m.historyFor(SourceType.mangaSource);
      expect(list, hasLength(1));
      expect(list.single.id, 's-2');
      expect(m.findById('s-1')!.hidden, isTrue);
    });

    test('addHistory 重读自动复原（hidden 条目重新进入后可见）', () async {
      final m = newManager();
      await add(m, 'a-1', 'Auto Restore', SourceType.mangaSource);
      await m.hideAll(SourceType.mangaSource);
      expect(m.historyFor(SourceType.mangaSource), isEmpty);

      // 模拟用户重新进入该作品：详情/阅读器调用 addHistory 记录浏览。
      await add(m, 'a-1', 'Auto Restore', SourceType.mangaSource);

      final list = m.historyFor(SourceType.mangaSource);
      expect(list, hasLength(1));
      expect(list.single.id, 'a-1');
      expect(list.single.hidden, isFalse);
    });

    test('removeHistory 仍为物理删除（findById 不可再取到）', () async {
      final m = newManager();
      await add(m, 'd-1', 'Physical Delete', SourceType.mangaSource);

      await m.removeHistory('d-1', sourceType: SourceType.mangaSource);

      expect(m.findById('d-1'), isNull);
      expect(m.historyFor(SourceType.mangaSource), isEmpty);
    });

    test('clearAll 为物理清空（全部条目移除）', () async {
      final m = newManager();
      await add(m, 'p-1', 'Purge One', SourceType.mangaSource);
      await add(m, 'p-2', 'Purge Two', SourceType.novelSource);

      await m.clearAll();

      expect(m.findById('p-1'), isNull);
      expect(m.findById('p-2'), isNull);
      expect(m.historyFor(SourceType.mangaSource), isEmpty);
      expect(m.historyFor(SourceType.novelSource), isEmpty);
    });
  });
}

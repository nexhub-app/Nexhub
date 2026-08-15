/// Tests for favorite groups (收藏分组功能).
///
/// Covers: group CRUD / reorder / duplicate-name rejection / delete cascade /
/// persistence across re-init; setEntryGroups; toggleFavorite re-favorite
/// keeps groupIds; FavoriteEntry JSON round-trip with groupIds and legacy
/// JSON compatibility; export/import round-trip.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/comic/models/reader_preferences.dart';
import 'package:nexhub/core/favorites/favorite_group.dart';
import 'package:nexhub/core/favorites/favorites_manager.dart';
import 'package:nexhub/core/models/media_item.dart';
import 'package:nexhub/core/models/plugin_config.dart';

// 三端类型简写：分类夹按类型隔离，测试中高频使用。
const SourceType anime = SourceType.animeSource;
const SourceType manga = SourceType.mangaSource;
const SourceType novel = SourceType.novelSource;

void main() {
  group('FavoriteGroup model', () {
    test('toJson/fromJson round-trip', () {
      const original = FavoriteGroup(
        id: 'grp_1',
        name: '追番中',
        sourceType: SourceType.mangaSource,
        sortOrder: 2,
        createdAt: 1000,
        hidden: true,
      );
      final roundTrip = FavoriteGroup.fromJson(original.toJson());
      expect(roundTrip.id, original.id);
      expect(roundTrip.name, original.name);
      expect(roundTrip.sourceType, SourceType.mangaSource);
      expect(roundTrip.sortOrder, original.sortOrder);
      expect(roundTrip.createdAt, original.createdAt);
      expect(roundTrip.hidden, isTrue);
    });

    test('fromJson tolerates missing fields', () {
      final group = FavoriteGroup.fromJson(const <String, dynamic>{});
      expect(group.id, '');
      expect(group.name, '');
      expect(group.sortOrder, 0);
      expect(group.createdAt, 0);
      // 缺省：归影视、不隐藏
      expect(group.sourceType, SourceType.animeSource);
      expect(group.hidden, isFalse);
    });

    test('newId generates distinct ids', () {
      final ids = <String>{
        for (int i = 0; i < 20; i++) FavoriteGroup.newId(),
      };
      expect(ids.length, 20);
    });
  });

  group('FavoriteEntry groupIds expansion', () {
    test('toJson includes groupIds', () {
      const entry = FavoriteEntry(
        id: '1',
        title: 'Test',
        sourceType: SourceType.animeSource,
        favoritedAt: 1000,
        groupIds: <String>['g1', 'g2'],
      );
      expect(entry.toJson()['groupIds'], <String>['g1', 'g2']);
    });

    test('fromJson reads groupIds', () {
      final entry = FavoriteEntry.fromJson(const <String, dynamic>{
        'id': '1',
        'title': 'Test',
        'sourceType': 'anime',
        'favoritedAt': 1000,
        'groupIds': <dynamic>['g1'],
      });
      expect(entry.groupIds, <String>['g1']);
    });

    test('fromJson backward compat: missing groupIds yields empty list', () {
      final entry = FavoriteEntry.fromJson(const <String, dynamic>{
        'id': '1',
        'title': 'Test',
        'sourceType': 'anime',
        'favoritedAt': 1000,
      });
      expect(entry.groupIds, isEmpty);
    });

    test('toJson/fromJson round-trip preserves groupIds', () {
      const original = FavoriteEntry(
        id: '1',
        title: 'Test',
        sourceType: SourceType.animeSource,
        favoritedAt: 1000,
        groupIds: <String>['g1', 'g2'],
      );
      final roundTrip = FavoriteEntry.fromJson(original.toJson());
      expect(roundTrip.groupIds, original.groupIds);
    });

    test('withLastRead / withCoverUrl carry groupIds through', () {
      const entry = FavoriteEntry(
        id: '1',
        title: 'Test',
        sourceType: SourceType.animeSource,
        favoritedAt: 1000,
        groupIds: <String>['g1'],
      );
      expect(entry.withLastRead(2000).groupIds, <String>['g1']);
      expect(entry.withCoverUrl('http://x/c.jpg').groupIds, <String>['g1']);
    });

    test('withGroupIds replaces groupIds', () {
      const entry = FavoriteEntry(
        id: '1',
        title: 'Test',
        sourceType: SourceType.animeSource,
        favoritedAt: 1000,
        groupIds: <String>['g1'],
      );
      expect(entry.withGroupIds(const <String>['g2', 'g3']).groupIds,
          <String>['g2', 'g3']);
    });
  });

  group('FavoritesManager groups', () {
    late InMemoryBackend backend;
    late FavoritesManager manager;

    setUp(() {
      backend = InMemoryBackend();
      manager = FavoritesManager(backend: backend);
    });

    test('createGroup adds group with incremental sortOrder', () async {
      final g1 = await manager.createGroup('追番中', type: anime);
      final g2 = await manager.createGroup('补番', type: anime);
      expect(g1, isNotNull);
      expect(g2, isNotNull);
      expect(manager.groupsFor(anime).length, 2);
      expect(manager.groupsFor(anime).first.name, '追番中');
      expect(manager.groupsFor(anime).last.name, '补番');
      expect(g2!.sortOrder, greaterThan(g1!.sortOrder));
    });

    test('createGroup rejects duplicate name (trimmed)', () async {
      await manager.createGroup('追番中', type: anime);
      final dup = await manager.createGroup(' 追番中 ', type: anime);
      expect(dup, isNull);
      expect(manager.groupsFor(anime).length, 1);
    });

    test('createGroup rejects empty name', () async {
      expect(await manager.createGroup('   ', type: anime), isNull);
      expect(manager.groupsFor(anime), isEmpty);
    });

    test('same name allowed across different source types', () async {
      final a = await manager.createGroup('在追', type: anime);
      final m = await manager.createGroup('在追', type: manga);
      final n = await manager.createGroup('在追', type: novel);
      expect(a, isNotNull);
      expect(m, isNotNull);
      expect(n, isNotNull);
      // 三端各自只看见自己的分类夹
      expect(manager.groupsFor(anime).length, 1);
      expect(manager.groupsFor(manga).length, 1);
      expect(manager.groupsFor(novel).length, 1);
      expect(manager.groupsFor(anime).first.id, a!.id);
      expect(manager.groupsFor(manga).first.id, m!.id);
    });

    test('renameGroup renames and rejects duplicates within same type',
        () async {
      final g1 = await manager.createGroup('A', type: anime);
      await manager.createGroup('B', type: anime);
      // 另一模块的同名分组不参与重名判定
      await manager.createGroup('C', type: manga);
      expect(await manager.renameGroup(g1!.id, 'C'), isTrue);
      expect(manager.groupById(g1.id)!.name, 'C');
      // Rename to existing other name rejected
      expect(await manager.renameGroup(g1.id, 'B'), isFalse);
      // Nonexistent group rejected
      expect(await manager.renameGroup('nope', 'X'), isFalse);
    });

    test('deleteGroup cascades removal from entry groupIds', () async {
      final g1 = await manager.createGroup('A', type: anime);
      final g2 = await manager.createGroup('B', type: anime);
      await manager.toggleFavorite(const MediaItem(
        id: 'a1',
        title: 'Anime',
        sourceType: SourceType.animeSource,
      ));
      await manager.setEntryGroups(
          'a1', SourceType.animeSource, <String>[g1!.id, g2!.id]);

      await manager.deleteGroup(g1.id);
      expect(manager.groupsFor(anime).length, 1);
      final entry = manager.favoritesFor(SourceType.animeSource).first;
      // Entry survives, only the association is removed
      expect(entry.groupIds, <String>[g2.id]);
    });

    test('reorderGroups reorders by given id order', () async {
      final a = await manager.createGroup('A', type: anime);
      final b = await manager.createGroup('B', type: anime);
      final c = await manager.createGroup('C', type: anime);
      await manager.reorderGroups(<String>[c!.id, a!.id, b!.id], type: anime);
      expect(manager.groupsFor(anime).map((g) => g.name).toList(),
          <String>['C', 'A', 'B']);
    });

    test('reorderGroups does not disturb other source types', () async {
      final a1 = await manager.createGroup('A', type: anime);
      final a2 = await manager.createGroup('B', type: anime);
      await manager.createGroup('M1', type: manga);
      await manager.createGroup('M2', type: manga);
      await manager.reorderGroups(<String>[a2!.id, a1!.id], type: anime);
      expect(manager.groupsFor(anime).map((g) => g.name).toList(),
          <String>['B', 'A']);
      expect(manager.groupsFor(manga).map((g) => g.name).toList(),
          <String>['M1', 'M2']);
    });

    test('setGroupHidden hides from groupsFor but keeps it manageable',
        () async {
      final g1 = await manager.createGroup('A', type: anime);
      await manager.createGroup('B', type: anime);
      await manager.setGroupHidden(g1!.id, true);
      expect(manager.groupsFor(anime).map((g) => g.name).toList(),
          <String>['B']);
      // 管理面板视角仍可见，用于恢复
      expect(manager.groupsFor(anime, includeHidden: true).length, 2);
      expect(manager.groupById(g1.id)!.hidden, isTrue);

      await manager.setGroupHidden(g1.id, false);
      expect(manager.groupsFor(anime).length, 2);
    });

    test('hidden flag persists across re-init', () async {
      final g1 = await manager.createGroup('A', type: anime);
      await manager.setGroupHidden(g1!.id, true);

      final manager2 = FavoritesManager(backend: backend);
      await manager2.init();
      expect(manager2.groupsFor(anime), isEmpty);
      expect(manager2.groupsFor(anime, includeHidden: true).length, 1);
      expect(manager2.groupById(g1.id)!.hidden, isTrue);
    });

    test('groups persist across re-init with sourceType', () async {
      await manager.createGroup('A', type: anime);
      await manager.createGroup('B', type: anime);
      await manager.createGroup('N', type: novel);
      await manager.reorderGroups(<String>[
        manager.groupsFor(anime).last.id,
        manager.groupsFor(anime).first.id,
      ], type: anime);

      final manager2 = FavoritesManager(backend: backend);
      await manager2.init();
      expect(manager2.groupsFor(anime).length, 2);
      expect(manager2.groupsFor(anime).map((g) => g.name).toList(),
          <String>['B', 'A']);
      expect(manager2.groupsFor(novel).map((g) => g.name).toList(),
          <String>['N']);
    });

    test('setEntryGroups assigns and filters invalid ids', () async {
      final g1 = await manager.createGroup('A', type: anime);
      await manager.toggleFavorite(const MediaItem(
        id: 'a1',
        title: 'Anime',
        sourceType: SourceType.animeSource,
      ));
      final ok = await manager.setEntryGroups(
          'a1', SourceType.animeSource, <String>[g1!.id, 'ghost']);
      expect(ok, isTrue);
      expect(manager.favoritesFor(SourceType.animeSource).first.groupIds,
          <String>[g1.id]);
      // Unknown entry returns false
      expect(
          await manager.setEntryGroups(
              'nope', SourceType.animeSource, <String>[g1.id]),
          isFalse);
    });

    test('setEntryGroups rejects group ids from another source type',
        () async {
      final animeGroup = await manager.createGroup('A', type: anime);
      await manager.toggleFavorite(const MediaItem(
        id: 'n1',
        title: 'Novel',
        sourceType: SourceType.novelSource,
      ));
      // 小说条目挂不上影视分类夹 → 被过滤
      final ok = await manager.setEntryGroups(
          'n1', SourceType.novelSource, <String>[animeGroup!.id]);
      expect(ok, isTrue);
      expect(manager.favoritesFor(SourceType.novelSource).first.groupIds,
          isEmpty);
    });

    test('entry groupIds persist across re-init', () async {
      final g1 = await manager.createGroup('A', type: anime);
      await manager.toggleFavorite(const MediaItem(
        id: 'a1',
        title: 'Anime',
        sourceType: SourceType.animeSource,
      ));
      await manager.setEntryGroups(
          'a1', SourceType.animeSource, <String>[g1!.id]);

      final manager2 = FavoritesManager(backend: backend);
      await manager2.init();
      expect(manager2.favoritesFor(SourceType.animeSource).first.groupIds,
          <String>[g1.id]);
    });

    test('toggleFavorite re-favorite keeps groupIds', () async {
      final g1 = await manager.createGroup('A', type: anime);
      const item = MediaItem(
        id: 'a1',
        title: 'Anime',
        sourceType: SourceType.animeSource,
      );
      await manager.toggleFavorite(item);
      await manager.setEntryGroups(
          'a1', SourceType.animeSource, <String>[g1!.id]);

      // Unfavorite then re-favorite in the same session
      await manager.toggleFavorite(item);
      expect(manager.isFavorite('a1', SourceType.animeSource), isFalse);
      await manager.toggleFavorite(item);
      expect(manager.favoritesFor(SourceType.animeSource).first.groupIds,
          <String>[g1.id]);
    });

    test('entryCountInGroup counts only same source type', () async {
      final g1 = await manager.createGroup('A', type: anime);
      await manager.toggleFavorite(const MediaItem(
        id: 'a1',
        title: 'Anime',
        sourceType: SourceType.animeSource,
      ));
      await manager.toggleFavorite(const MediaItem(
        id: 'a2',
        title: 'Anime 2',
        sourceType: SourceType.animeSource,
      ));
      await manager.toggleFavorite(const MediaItem(
        id: 'n1',
        title: 'Novel',
        sourceType: SourceType.novelSource,
      ));
      await manager.setEntryGroups(
          'a1', SourceType.animeSource, <String>[g1!.id]);
      await manager.setEntryGroups(
          'a2', SourceType.animeSource, <String>[g1.id]);
      // 小说条目挂不上影视分类夹，不计入
      await manager.setEntryGroups(
          'n1', SourceType.novelSource, <String>[g1.id]);
      expect(manager.entryCountInGroup(g1.id, type: anime), 2);
      expect(manager.entryCountInGroup(g1.id, type: novel), 0);
    });

    test('visibleFavoritesFor excludes items only in hidden groups', () async {
      final gVisible = (await manager.createGroup('在追', type: anime))!;
      final gHidden = (await manager.createGroup('封存', type: anime))!;
      await manager.setGroupHidden(gHidden.id, true);

      // a1：仅可见分类；a2：仅隐藏分类；a3：同时命中可见+隐藏；a4：未分组。
      await manager.toggleFavorite(const MediaItem(
          id: 'a1', title: 'A1', sourceType: SourceType.animeSource));
      await manager.toggleFavorite(const MediaItem(
          id: 'a2', title: 'A2', sourceType: SourceType.animeSource));
      await manager.toggleFavorite(const MediaItem(
          id: 'a3', title: 'A3', sourceType: SourceType.animeSource));
      await manager.toggleFavorite(const MediaItem(
          id: 'a4', title: 'A4', sourceType: SourceType.animeSource));
      await manager.setEntryGroups(
          'a1', SourceType.animeSource, <String>[gVisible.id]);
      await manager.setEntryGroups(
          'a2', SourceType.animeSource, <String>[gHidden.id]);
      await manager.setEntryGroups('a3', SourceType.animeSource,
          <String>[gVisible.id, gHidden.id]);

      // favoritesFor 仍返回全部 4 条（同步/指派/绑定需用完整列表）。
      expect(manager.favoritesFor(anime).length, 4);

      // visibleFavoritesFor（收藏书架「全部」视图）排除仅属隐藏分类的 a2。
      final visible =
          manager.visibleFavoritesFor(anime).map((e) => e.id).toSet();
      expect(visible, <String>{'a1', 'a3', 'a4'});
      expect(visible.contains('a2'), isFalse);
    });

    test('exportGroups/importGroups round-trip (merge, dedup)', () async {
      await manager.createGroup('A', type: anime);
      await manager.createGroup('B', type: anime);
      final exported = manager.exportGroups();
      expect(exported.length, 2);

      final backend2 = InMemoryBackend();
      final manager2 = FavoritesManager(backend: backend2);
      // duplicate name in the same type — should be skipped
      await manager2.createGroup('B', type: anime);
      await manager2.importGroups(exported);
      expect(manager2.groupsFor(anime).length, 2);
      expect(manager2.groupsFor(anime).map((g) => g.name).toSet(),
          <String>{'A', 'B'});
    });

    test('importGroups keeps same-name groups of different types', () async {
      await manager.createGroup('在追', type: anime);
      final exported = manager.exportGroups();

      final backend2 = InMemoryBackend();
      final manager2 = FavoritesManager(backend: backend2);
      await manager2.createGroup('在追', type: manga);
      await manager2.importGroups(exported);
      expect(manager2.groupsFor(anime).length, 1);
      expect(manager2.groupsFor(manga).length, 1);
    });
  });

  group('Legacy group migration (no sourceType)', () {
    /// 构造一份「旧版」存储：分组无 sourceType 字段。
    Future<FavoritesManager> bootWithLegacy({
      required List<Map<String, dynamic>> groups,
      required List<Map<String, dynamic>> entries,
    }) async {
      final backend = InMemoryBackend();
      await backend.set('favorite_groups_v1', jsonEncode(groups));
      await backend.set('favorites_v1', jsonEncode(entries));
      final manager = FavoritesManager(backend: backend);
      await manager.init();
      return manager;
    }

    Map<String, dynamic> legacyGroup(String id, String name) =>
        <String, dynamic>{
          'id': id,
          'name': name,
          'sortOrder': 0,
          'createdAt': 1000,
        };

    // 注意：SourceType.parse 只认 animeSource / mangaSource / novelSource
    // 全名，简写（'anime'）会静默回落到 animeSource。
    Map<String, dynamic> entryJson(
            String id, SourceType type, List<String> groupIds) =>
        <String, dynamic>{
          'id': id,
          'title': id,
          'sourceType': type.apiName,
          'favoritedAt': 1000,
          'groupIds': groupIds,
        };

    test('group is assigned to the dominant type of its entries', () async {
      final manager = await bootWithLegacy(
        groups: <Map<String, dynamic>>[legacyGroup('g1', '在看')],
        entries: <Map<String, dynamic>>[
          entryJson('n1', novel, <String>['g1']),
          entryJson('n2', novel, <String>['g1']),
          entryJson('a1', anime, <String>['g1']),
        ],
      );
      expect(manager.groupById('g1')!.sourceType, SourceType.novelSource);
      expect(manager.groupsFor(novel).length, 1);
      expect(manager.groupsFor(anime), isEmpty);
    });

    test('empty legacy group falls back to anime', () async {
      final manager = await bootWithLegacy(
        groups: <Map<String, dynamic>>[legacyGroup('g1', '空夹')],
        entries: const <Map<String, dynamic>>[],
      );
      expect(manager.groupById('g1')!.sourceType, SourceType.animeSource);
      expect(manager.groupsFor(anime).length, 1);
    });

    test('migrated groups are not hidden by default', () async {
      final manager = await bootWithLegacy(
        groups: <Map<String, dynamic>>[legacyGroup('g1', '在看')],
        entries: <Map<String, dynamic>>[
          entryJson('m1', manga, <String>['g1']),
        ],
      );
      expect(manager.groupById('g1')!.hidden, isFalse);
      expect(manager.groupsFor(manga).length, 1);
    });
  });
}

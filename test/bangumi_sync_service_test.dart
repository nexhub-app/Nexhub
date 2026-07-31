/// BangumiSyncService 单元测试：fake client 驱动，验证状态判定
/// （想看/在看/看过）、episode 映射与增量标集、不降级覆盖、forcedType、
/// 评分短评推送（PATCH 部分更新）、空缺回拉、书籍 ep_status、
/// 标签合并、私有开关、从 Bangumi 导入、失败不中断与 401 终止、类型开关、
/// 单条同步 syncOne。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:nexhub/core/comic/comic_progress_manager.dart';
import 'package:nexhub/core/comic/models/reader_preferences.dart';
import 'package:nexhub/core/favorites/favorites_manager.dart';
import 'package:nexhub/core/history/media_watched_manager.dart';
import 'package:nexhub/core/models/plugin_config.dart';
import 'package:nexhub/core/novel/novel_progress_manager.dart';
import 'package:nexhub/core/services/bangumi/bangumi_auth.dart';
import 'package:nexhub/core/services/bangumi/bangumi_client.dart';
import 'package:nexhub/core/services/bangumi/bangumi_models.dart';
import 'package:nexhub/core/services/bangumi/bangumi_sync_service.dart';
import 'package:nexhub/core/services/bangumi/subject_link_store.dart';

/// 全接口 fake client：内存表驱动，记录调用序列。
class _FakeClient extends BangumiClient {
  final Map<int, List<BangumiEpisode>> episodesBySubject = {};
  final Map<int, BangumiUserCollection> remoteCollections = {};

  /// 远端章节收藏表（subjectId → episodeId → 章节收藏类型）。
  final Map<int, Map<int, int>> remoteEpisodeCollections = {};

  /// 用户收藏列表（subjectType → 列表），供导入测试。
  final Map<int, List<BangumiUserCollection>> userCollectionsByType = {};

  /// fetchEpisodes 抛错的 subjectId → 异常。
  final Map<int, BangumiApiException> failEpisodesFor = {};

  /// 调用序列（形如 `postCollection:42:3`）。
  final List<String> calls = [];
  final List<CollectionPayload> pushedPayloads = [];
  final Map<int, List<int>> markedEpisodes = {};

  @override
  Future<BangumiMe> fetchMe() async {
    calls.add('me');
    return const BangumiMe(username: 'tester', nickname: 'Tester');
  }

  @override
  Future<List<BangumiSubject>> searchSubjects(
    String keyword, {
    required List<int> types,
    int limit = 10,
  }) async {
    calls.add('search:$keyword');
    return const <BangumiSubject>[];
  }

  @override
  Future<List<BangumiEpisode>> fetchEpisodes(int subjectId) async {
    final error = failEpisodesFor[subjectId];
    if (error != null) throw error;
    calls.add('episodes:$subjectId');
    return episodesBySubject[subjectId] ?? const <BangumiEpisode>[];
  }

  @override
  Future<BangumiUserCollection?> fetchUserCollection(int subjectId) async {
    calls.add('getCollection:$subjectId');
    return remoteCollections[subjectId];
  }

  @override
  Future<void> updateCollection(
      int subjectId, CollectionPayload payload) async {
    calls.add('postCollection:$subjectId:${payload.type}');
    pushedPayloads.add(payload);
  }

  @override
  Future<void> patchCollection(
      int subjectId, CollectionPayload payload) async {
    calls.add('patchCollection:$subjectId:${payload.type}');
    pushedPayloads.add(payload);
  }

  @override
  Future<Map<int, int>> fetchCollectedEpisodes(int subjectId) async {
    calls.add('collectedEpisodes:$subjectId');
    return remoteEpisodeCollections[subjectId] ?? const <int, int>{};
  }

  @override
  Future<List<BangumiUserCollection>> fetchUserCollections(
    String username, {
    required int subjectType,
    int? collectionType,
  }) async {
    calls.add('userCollections:$username:$subjectType'
        '${collectionType != null ? ':$collectionType' : ''}');
    final all = userCollectionsByType[subjectType] ??
        const <BangumiUserCollection>[];
    if (collectionType == null) return all;
    return all.where((c) => c.type == collectionType).toList();
  }

  @override
  Future<void> markEpisodesWatched(int subjectId, List<int> episodeIds) async {
    if (episodeIds.isEmpty) return;
    calls.add('markEpisodes:$subjectId');
    markedEpisodes[subjectId] = episodeIds;
  }
}

/// 可控登录态的 fake auth（不触碰 secure storage）。
class _FakeAuth extends BangumiAuth {
  _FakeAuth({required super.client});

  bool loggedIn = true;

  @override
  bool get isLoggedIn => loggedIn;
}

/// 三集本篇（id 101/102/103）。
List<BangumiEpisode> _threeEpisodes() => const <BangumiEpisode>[
      BangumiEpisode(id: 101, sort: 1, type: 0),
      BangumiEpisode(id: 102, sort: 2, type: 0),
      BangumiEpisode(id: 103, sort: 3, type: 0),
    ];

FavoriteEntry _entry(
  String id,
  SourceType type, {
  int lastRead = 0,
  int myRating = 0,
  String? myComment,
}) =>
    FavoriteEntry(
      id: id,
      title: 'title-$id',
      sourceType: type,
      favoritedAt: 1,
      lastRead: lastRead,
      myRating: myRating,
      myComment: myComment,
    );

void main() {
  late Box<dynamic> linkBox;
  late Box<dynamic> watchedBox;

  setUpAll(() async {
    final dir = await Directory.systemTemp.createTemp('bangumi_sync_test_');
    try {
      Hive.init(dir.path);
    } catch (_) {}
    linkBox = await Hive.openBox('bangumi_sync_links_test');
    watchedBox = await Hive.openBox('bangumi_sync_watched_test');
  });

  setUp(() async {
    await linkBox.clear();
    await watchedBox.clear();
  });

  tearDownAll(() async {
    await Hive.deleteFromDisk();
  });

  /// 组装被测服务与全部 fake 依赖。
  Future<
      ({
        BangumiSyncService service,
        _FakeClient client,
        _FakeAuth auth,
        SubjectLinkStore linkStore,
        FavoritesManager favorites,
        MediaWatchedManager watched,
        ComicProgressManager comicProgress,
        NovelProgressManager novelProgress,
      })> build({List<FavoriteEntry> entries = const []}) async {
    final client = _FakeClient();
    final auth = _FakeAuth(client: client);
    final linkStore = SubjectLinkStore(client: client, box: linkBox);
    final favorites = FavoritesManager(backend: InMemoryBackend());
    await favorites.importFromList(
        entries.map((e) => e.toJson()).toList(growable: false));
    final watched = MediaWatchedManager(box: watchedBox);
    await watched.init();
    final comicProgress = ComicProgressManager(backend: InMemoryBackend());
    final novelProgress = NovelProgressManager(backend: InMemoryBackend());
    final service = BangumiSyncService(
      client: client,
      auth: auth,
      linkStore: linkStore,
      favorites: favorites,
      watched: watched,
      comicProgress: comicProgress,
      novelProgress: novelProgress,
      backend: InMemoryBackend(),
    );
    await service.init();
    return (
      service: service,
      client: client,
      auth: auth,
      linkStore: linkStore,
      favorites: favorites,
      watched: watched,
      comicProgress: comicProgress,
      novelProgress: novelProgress,
    );
  }

  test('未登录 syncAll 抛 StateError', () async {
    final ctx = await build();
    ctx.auth.loggedIn = false;
    expect(ctx.service.syncAll(), throwsStateError);
  });

  test('动漫无已看集 → 想看（wish）', () async {
    final ctx = await build(entries: [_entry('a1', SourceType.animeSource)]);
    await ctx.linkStore.put('a1', const SubjectLink(subjectId: 42));

    final log = await ctx.service.syncAll();
    expect(log.single.status, SyncLogStatus.success);
    expect(ctx.client.pushedPayloads.single.type, BangumiCollectionType.wish);
    // 无已看集时不应拉剧集、不应标记。
    expect(ctx.client.calls.where((c) => c.startsWith('episodes:')), isEmpty);
    expect(ctx.client.markedEpisodes, isEmpty);
  });

  test('动漫部分已看 → 在看（doing）+ episode 映射 + 先收藏后标集', () async {
    final ctx = await build(entries: [_entry('a1', SourceType.animeSource)]);
    await ctx.linkStore.put('a1', const SubjectLink(subjectId: 42));
    ctx.client.episodesBySubject[42] = _threeEpisodes();
    // 本地已看第 1、2 集（episodeIndex 0/1）→ episode id 101/102。
    await ctx.watched.markWatched('a1', 0);
    await ctx.watched.markWatched('a1', 1);

    final log = await ctx.service.syncAll();
    expect(log.single.status, SyncLogStatus.success);
    expect(ctx.client.pushedPayloads.single.type, BangumiCollectionType.doing);
    expect(ctx.client.markedEpisodes[42], <int>[101, 102]);
    // 顺序：先建收藏（POST）再批量标集（PATCH）。
    expect(
      ctx.client.calls.indexOf('postCollection:42:3'),
      lessThan(ctx.client.calls.indexOf('markEpisodes:42')),
    );
  });

  test('动漫全部已看 → 看过（collect）', () async {
    final ctx = await build(entries: [_entry('a1', SourceType.animeSource)]);
    await ctx.linkStore.put('a1', const SubjectLink(subjectId: 42));
    ctx.client.episodesBySubject[42] = _threeEpisodes();
    for (int i = 0; i < 3; i++) {
      await ctx.watched.markWatched('a1', i);
    }

    await ctx.service.syncAll();
    expect(
        ctx.client.pushedPayloads.single.type, BangumiCollectionType.collect);
    expect(ctx.client.markedEpisodes[42], <int>[101, 102, 103]);
  });

  test('越界已看集跳过（源集数多于 Bangumi 本篇）', () async {
    final ctx = await build(entries: [_entry('a1', SourceType.animeSource)]);
    await ctx.linkStore.put('a1', const SubjectLink(subjectId: 42));
    ctx.client.episodesBySubject[42] = _threeEpisodes();
    await ctx.watched.markWatched('a1', 0);
    await ctx.watched.markWatched('a1', 5); // 越界

    await ctx.service.syncAll();
    expect(ctx.client.markedEpisodes[42], <int>[101]);
    expect(ctx.client.pushedPayloads.single.type, BangumiCollectionType.doing);
  });

  test('漫画 lastRead>0 → 在看；未读 → 想看', () async {
    final ctx = await build(entries: [
      _entry('m1', SourceType.mangaSource, lastRead: 123),
      _entry('m2', SourceType.mangaSource),
    ]);
    await ctx.linkStore.put('m1', const SubjectLink(subjectId: 10));
    await ctx.linkStore.put('m2', const SubjectLink(subjectId: 11));

    await ctx.service.syncAll();
    final types = <int, int>{
      for (final call in ctx.client.calls)
        if (call.startsWith('postCollection:'))
          int.parse(call.split(':')[1]): int.parse(call.split(':')[2]),
    };
    expect(types[10], BangumiCollectionType.doing);
    expect(types[11], BangumiCollectionType.wish);
  });

  test('不降级：远端看过、本地在看且无评分变化 → 跳过不 POST', () async {
    final ctx = await build(
        entries: [_entry('m1', SourceType.mangaSource, lastRead: 123)]);
    await ctx.linkStore.put('m1', const SubjectLink(subjectId: 10));
    ctx.client.remoteCollections[10] = const BangumiUserCollection(
        subjectId: 10, type: BangumiCollectionType.collect);

    final log = await ctx.service.syncAll();
    expect(log.single.status, SyncLogStatus.skipped);
    expect(ctx.client.pushedPayloads, isEmpty);
  });

  test('评分/短评变化时推送：已收藏走 PATCH 且不携带未变化的状态', () async {
    final ctx = await build(entries: [
      _entry('m1', SourceType.mangaSource,
          lastRead: 123, myRating: 8, myComment: 'great'),
    ]);
    await ctx.linkStore.put('m1', const SubjectLink(subjectId: 10));
    ctx.client.remoteCollections[10] = const BangumiUserCollection(
        subjectId: 10, type: BangumiCollectionType.collect);

    final log = await ctx.service.syncAll();
    expect(log.single.status, SyncLogStatus.success);
    final payload = ctx.client.pushedPayloads.single;
    // 状态不降级且未变化：PATCH 不携带 type，仅带评分短评。
    expect(payload.type, isNull);
    expect(payload.rate, 8);
    expect(payload.comment, 'great');
    expect(ctx.client.calls.where((c) => c.startsWith('postCollection:')),
        isEmpty);
  });

  test('forcedType 手动覆盖 → 强制推送选定状态', () async {
    final ctx = await build(entries: [_entry('m1', SourceType.mangaSource)]);
    await ctx.linkStore.put(
        'm1',
        const SubjectLink(
            subjectId: 10, forcedType: BangumiCollectionType.collect));
    ctx.client.remoteCollections[10] = const BangumiUserCollection(
        subjectId: 10, type: BangumiCollectionType.doing);

    await ctx.service.syncAll();
    expect(
        ctx.client.pushedPayloads.single.type, BangumiCollectionType.collect);
  });

  test('forcedType 抛弃覆盖 → 远端看过也改为抛弃', () async {
    final ctx = await build(entries: [_entry('m1', SourceType.mangaSource)]);
    await ctx.linkStore.put(
        'm1',
        const SubjectLink(
            subjectId: 10, forcedType: BangumiCollectionType.dropped));
    ctx.client.remoteCollections[10] = const BangumiUserCollection(
        subjectId: 10, type: BangumiCollectionType.collect);

    await ctx.service.syncAll();
    expect(
        ctx.client.pushedPayloads.single.type, BangumiCollectionType.dropped);
  });

  test('无绑定且搜索无结果 → 待手动绑定（pendingBind）', () async {
    final ctx = await build(entries: [_entry('x1', SourceType.novelSource)]);

    final log = await ctx.service.syncAll();
    expect(log.single.status, SyncLogStatus.pendingBind);
    expect(ctx.client.pushedPayloads, isEmpty);
  });

  test('单条失败（5xx）不中断后续条目', () async {
    final ctx = await build(entries: [
      _entry('a1', SourceType.animeSource),
      _entry('a2', SourceType.animeSource),
    ]);
    await ctx.linkStore.put('a1', const SubjectLink(subjectId: 1));
    await ctx.linkStore.put('a2', const SubjectLink(subjectId: 2));
    // a1/a2 均有已看集，其一拉剧集报 500。
    await ctx.watched.markWatched('a1', 0);
    await ctx.watched.markWatched('a2', 0);
    ctx.client.episodesBySubject[1] = _threeEpisodes();
    ctx.client.episodesBySubject[2] = _threeEpisodes();
    ctx.client.failEpisodesFor[1] =
        const BangumiApiException(500, 'server error');

    final log = await ctx.service.syncAll();
    expect(log, hasLength(2));
    expect(log.map((e) => e.status).toSet(),
        {SyncLogStatus.failed, SyncLogStatus.success});
    expect(ctx.service.lastSyncAt, isNotNull);
  });

  test('401 终止本轮同步', () async {
    final ctx = await build(entries: [
      _entry('a1', SourceType.animeSource),
      _entry('m1', SourceType.mangaSource),
    ]);
    await ctx.linkStore.put('a1', const SubjectLink(subjectId: 1));
    await ctx.linkStore.put('m1', const SubjectLink(subjectId: 10));
    await ctx.watched.markWatched('a1', 0);
    ctx.client.failEpisodesFor[1] =
        const BangumiApiException(401, 'unauthorized');

    final log = await ctx.service.syncAll();
    // 动漫条目 401 后终止，漫画条目不再处理。
    expect(log, hasLength(1));
    expect(log.single.status, SyncLogStatus.failed);
  });

  test('类型开关关闭时跳过该类条目', () async {
    final ctx = await build(entries: [
      _entry('m1', SourceType.mangaSource, lastRead: 1),
      _entry('n1', SourceType.novelSource, lastRead: 1),
    ]);
    await ctx.linkStore.put('m1', const SubjectLink(subjectId: 10));
    await ctx.linkStore.put('n1', const SubjectLink(subjectId: 20));
    await ctx.service.setTypeEnabled(SourceType.mangaSource, false);

    final log = await ctx.service.syncAll();
    expect(log, hasLength(1));
    expect(log.single.title, 'title-n1');
  });

  test('空缺回拉：本地未评分/无短评时写回远端值', () async {
    final ctx = await build(
        entries: [_entry('m1', SourceType.mangaSource, lastRead: 123)]);
    await ctx.linkStore.put('m1', const SubjectLink(subjectId: 10));
    ctx.client.remoteCollections[10] = const BangumiUserCollection(
        subjectId: 10,
        type: BangumiCollectionType.doing,
        rate: 7,
        comment: 'nice');

    final log = await ctx.service.syncAll();
    // 回拉后本地与远端一致，无需推送。
    expect(log.single.status, SyncLogStatus.skipped);
    expect(ctx.client.pushedPayloads, isEmpty);
    final entry = ctx.favorites.favoritesFor(SourceType.mangaSource).single;
    expect(entry.myRating, 7);
    expect(entry.myComment, 'nice');
  });

  test('空缺回拉不覆盖本地已有评分（本地为准）', () async {
    final ctx = await build(entries: [
      _entry('m1', SourceType.mangaSource, lastRead: 123, myRating: 5),
    ]);
    await ctx.linkStore.put('m1', const SubjectLink(subjectId: 10));
    ctx.client.remoteCollections[10] = const BangumiUserCollection(
        subjectId: 10, type: BangumiCollectionType.doing, rate: 9);

    await ctx.service.syncAll();
    final entry = ctx.favorites.favoritesFor(SourceType.mangaSource).single;
    expect(entry.myRating, 5);
    // 本地评分与远端不同 → PATCH 推本地值。
    expect(ctx.client.pushedPayloads.single.rate, 5);
  });

  test('增量标集：远端已看集不重复标记，只推差集', () async {
    final ctx = await build(entries: [_entry('a1', SourceType.animeSource)]);
    await ctx.linkStore.put('a1', const SubjectLink(subjectId: 42));
    ctx.client.episodesBySubject[42] = _threeEpisodes();
    ctx.client.remoteCollections[42] = const BangumiUserCollection(
        subjectId: 42, type: BangumiCollectionType.doing);
    // 远端已标第 1 集看过。
    ctx.client.remoteEpisodeCollections[42] = <int, int>{101: 2};
    await ctx.watched.markWatched('a1', 0);
    await ctx.watched.markWatched('a1', 1);

    final log = await ctx.service.syncAll();
    expect(log.single.status, SyncLogStatus.success);
    expect(ctx.client.markedEpisodes[42], <int>[102]);
    // 状态未变化时不推收藏。
    expect(ctx.client.pushedPayloads, isEmpty);
  });

  test('远端集全部已标且无其它变化 → 跳过', () async {
    final ctx = await build(entries: [_entry('a1', SourceType.animeSource)]);
    await ctx.linkStore.put('a1', const SubjectLink(subjectId: 42));
    ctx.client.episodesBySubject[42] = _threeEpisodes();
    ctx.client.remoteCollections[42] = const BangumiUserCollection(
        subjectId: 42, type: BangumiCollectionType.doing);
    ctx.client.remoteEpisodeCollections[42] = <int, int>{101: 2, 102: 2};
    await ctx.watched.markWatched('a1', 0);
    await ctx.watched.markWatched('a1', 1);

    final log = await ctx.service.syncAll();
    expect(log.single.status, SyncLogStatus.skipped);
    expect(ctx.client.markedEpisodes, isEmpty);
    expect(ctx.client.pushedPayloads, isEmpty);
  });

  test('书籍阅读进度 → ep_status；读完末章 → 看过', () async {
    final ctx = await build(entries: [
      _entry('m1', SourceType.mangaSource, lastRead: 123),
      _entry('m2', SourceType.mangaSource, lastRead: 123),
      _entry('n1', SourceType.novelSource, lastRead: 123),
    ]);
    await ctx.linkStore.put('m1', const SubjectLink(subjectId: 10));
    await ctx.linkStore.put('m2', const SubjectLink(subjectId: 11));
    await ctx.linkStore.put('n1', const SubjectLink(subjectId: 20));
    // m1 读到第 5 章（共 10 章）；m2 读完末章；n1 总章数未知。
    await ctx.comicProgress.save('m1', 'c5', 0, 4, totalChapters: 10);
    await ctx.comicProgress.save('m2', 'c10', 0, 9, totalChapters: 10);
    await ctx.novelProgress.save('n1', 'c3', 0, 2);

    await ctx.service.syncAll();
    final postCalls = ctx.client.calls
        .where((c) => c.startsWith('postCollection:'))
        .toList();
    final bySubject = <int, CollectionPayload>{
      for (int i = 0; i < postCalls.length; i++)
        int.parse(postCalls[i].split(':')[1]): ctx.client.pushedPayloads[i],
    };
    expect(bySubject[10]!.type, BangumiCollectionType.doing);
    expect(bySubject[10]!.epStatus, 5);
    expect(bySubject[11]!.type, BangumiCollectionType.collect);
    expect(bySubject[11]!.epStatus, 10);
    expect(bySubject[20]!.type, BangumiCollectionType.doing);
    expect(bySubject[20]!.epStatus, 3);
  });

  test('ep_status 只增不减：远端更靠前时不推送', () async {
    final ctx = await build(
        entries: [_entry('m1', SourceType.mangaSource, lastRead: 123)]);
    await ctx.linkStore.put('m1', const SubjectLink(subjectId: 10));
    await ctx.comicProgress.save('m1', 'c5', 0, 4, totalChapters: 10);
    ctx.client.remoteCollections[10] = const BangumiUserCollection(
        subjectId: 10, type: BangumiCollectionType.doing, epStatus: 8);

    final log = await ctx.service.syncAll();
    expect(log.single.status, SyncLogStatus.skipped);
    expect(ctx.client.pushedPayloads, isEmpty);
  });

  test('标签合并推送：远端 ∪ 本地分组名', () async {
    final ctx = await build(
        entries: [_entry('m1', SourceType.mangaSource, lastRead: 123)]);
    await ctx.service.setTagsEnabled(true);
    await ctx.linkStore.put('m1', const SubjectLink(subjectId: 10));
    final group = await ctx.favorites
        .createGroup('MyGroup', type: SourceType.mangaSource);
    await ctx.favorites
        .setEntryGroups('m1', SourceType.mangaSource, [group!.id]);
    ctx.client.remoteCollections[10] = const BangumiUserCollection(
        subjectId: 10,
        type: BangumiCollectionType.doing,
        tags: <String>['old']);

    final log = await ctx.service.syncAll();
    expect(log.single.status, SyncLogStatus.success);
    final payload = ctx.client.pushedPayloads.single;
    expect(payload.tags, containsAll(<String>['old', 'MyGroup']));
    // 仅标签变化：PATCH 不携带 type。
    expect(payload.type, isNull);
  });

  test('分组名已含于远端标签时不重复推送', () async {
    final ctx = await build(
        entries: [_entry('m1', SourceType.mangaSource, lastRead: 123)]);
    await ctx.service.setTagsEnabled(true);
    await ctx.linkStore.put('m1', const SubjectLink(subjectId: 10));
    final group = await ctx.favorites
        .createGroup('MyGroup', type: SourceType.mangaSource);
    await ctx.favorites
        .setEntryGroups('m1', SourceType.mangaSource, [group!.id]);
    ctx.client.remoteCollections[10] = const BangumiUserCollection(
        subjectId: 10,
        type: BangumiCollectionType.doing,
        tags: <String>['MyGroup']);

    final log = await ctx.service.syncAll();
    expect(log.single.status, SyncLogStatus.skipped);
    expect(ctx.client.pushedPayloads, isEmpty);
  });

  test('私有开关：仅新建收藏携带 private，PATCH 不带', () async {
    final ctx = await build(entries: [
      _entry('m1', SourceType.mangaSource, lastRead: 123),
      _entry('m2', SourceType.mangaSource, lastRead: 123, myRating: 8),
    ]);
    await ctx.service.setPrivateEnabled(true);
    await ctx.linkStore.put('m1', const SubjectLink(subjectId: 10));
    await ctx.linkStore.put('m2', const SubjectLink(subjectId: 11));
    // m2 已收藏 → 评分变化走 PATCH。
    ctx.client.remoteCollections[11] = const BangumiUserCollection(
        subjectId: 11, type: BangumiCollectionType.doing);

    await ctx.service.syncAll();
    final pushCalls = ctx.client.calls
        .where((c) =>
            c.startsWith('postCollection:') ||
            c.startsWith('patchCollection:'))
        .toList();
    final bySubject = <int, CollectionPayload>{
      for (int i = 0; i < pushCalls.length; i++)
        int.parse(pushCalls[i].split(':')[1]): ctx.client.pushedPayloads[i],
    };
    expect(bySubject[10]!.private, isTrue);
    expect(bySubject[11]!.private, isNull);
  });

  test('importFromBangumi：标题高置信匹配建绑定并回拉评分', () async {
    final ctx = await build(entries: [
      _entry('b1', SourceType.mangaSource), // 已绑定 → 不入日志
      _entry('m1', SourceType.mangaSource), // 高置信匹配
      _entry('zzz', SourceType.novelSource), // 无匹配 → skipped
    ]);
    await ctx.linkStore.put('b1', const SubjectLink(subjectId: 1));
    ctx.client.userCollectionsByType[BangumiSubjectType.book] =
        const <BangumiUserCollection>[
      BangumiUserCollection(
          subjectId: 400602,
          type: BangumiCollectionType.collect,
          rate: 9,
          subjectName: 'other',
          subjectNameCn: 'title-m1'),
    ];

    final log = await ctx.service.importFromBangumi();
    expect(log, hasLength(2));
    final byTitle = <String, SyncLogItem>{
      for (final item in log) item.title: item,
    };
    expect(byTitle['title-m1']!.status, SyncLogStatus.success);
    expect(byTitle['title-m1']!.detail, '#400602');
    expect(byTitle['title-zzz']!.status, SyncLogStatus.skipped);
    expect((await ctx.linkStore.get('m1'))!.subjectId, 400602);
    expect(await ctx.linkStore.get('zzz'), isNull);
    // 顺带空缺回拉评分。
    final entry = ctx.favorites
        .favoritesFor(SourceType.mangaSource)
        .firstWhere((e) => e.id == 'm1');
    expect(entry.myRating, 9);
    // 用户名以 /v0/me 实时结果为准；book 列表只拉一次（漫画/小说共用缓存）。
    expect(ctx.client.calls, contains('userCollections:tester:1'));
    expect(
      ctx.client.calls.where((c) => c.startsWith('userCollections:')).length,
      1,
    );
  });

  test('未登录 syncOne 抛 StateError', () async {
    final ctx = await build(entries: [_entry('a1', SourceType.animeSource)]);
    ctx.auth.loggedIn = false;
    expect(
      ctx.service.syncOne('a1', SourceType.animeSource),
      throwsStateError,
    );
  });

  test('syncOne 未收藏条目 → 返回 null 不推送', () async {
    final ctx = await build(entries: [_entry('a1', SourceType.animeSource)]);
    final item = await ctx.service.syncOne('nope', SourceType.animeSource);
    expect(item, isNull);
    expect(ctx.client.pushedPayloads, isEmpty);
  });

  test('syncOne 已绑定 → 仅推送该条目（其余收藏不动）', () async {
    final ctx = await build(entries: [
      _entry('a1', SourceType.animeSource),
      _entry('a2', SourceType.animeSource),
    ]);
    await ctx.linkStore.put('a1', const SubjectLink(subjectId: 42));
    await ctx.linkStore.put('a2', const SubjectLink(subjectId: 43));

    final item = await ctx.service.syncOne('a1', SourceType.animeSource);
    expect(item!.status, SyncLogStatus.success);
    expect(item.title, 'title-a1');
    // 仅 a1 推送（无已看集 → 想看），a2 不处理。
    expect(ctx.client.pushedPayloads.single.type, BangumiCollectionType.wish);
    expect(ctx.client.calls.where((c) => c.contains(':43')), isEmpty);
    expect(ctx.service.isSyncing, isFalse);
  });

  test('syncOne 无绑定且搜索无结果 → pendingBind；失败不抛出', () async {
    final ctx = await build(entries: [_entry('x1', SourceType.animeSource)]);

    final pending = await ctx.service.syncOne('x1', SourceType.animeSource);
    expect(pending!.status, SyncLogStatus.pendingBind);
    expect(ctx.client.pushedPayloads, isEmpty);

    // 绑定后拉剧集报 500 → 封装为 failed 日志项而非抛出。
    await ctx.linkStore.put('x1', const SubjectLink(subjectId: 7));
    await ctx.watched.markWatched('x1', 0);
    ctx.client.failEpisodesFor[7] =
        const BangumiApiException(500, 'server error');
    final failed = await ctx.service.syncOne('x1', SourceType.animeSource);
    expect(failed!.status, SyncLogStatus.failed);
    expect(ctx.service.isSyncing, isFalse);
  });
}

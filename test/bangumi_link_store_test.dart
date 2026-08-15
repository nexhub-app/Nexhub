/// SubjectLinkStore 单元测试：相似度打分 / 缓存读写 / forcedType 序列化
/// （含旧字段 forceCollect 迁移）/ 三级解析（缓存命中、高置信自动采用、低置信候选）。
///
/// 不依赖 path_provider，直接 `Hive.init(临时目录)`（与 cookie_store_test 同法）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:nexhub/core/models/plugin_config.dart';
import 'package:nexhub/core/services/bangumi/bangumi_client.dart';
import 'package:nexhub/core/services/bangumi/bangumi_models.dart';
import 'package:nexhub/core/services/bangumi/subject_link_store.dart';

/// 只覆写搜索的 fake client（不发真实网络请求）。
class _FakeSearchClient extends BangumiClient {
  _FakeSearchClient();

  List<BangumiSubject> results = const <BangumiSubject>[];
  String? lastKeyword;
  List<int>? lastTypes;

  @override
  Future<List<BangumiSubject>> searchSubjects(
    String keyword, {
    required List<int> types,
    int limit = 10,
  }) async {
    lastKeyword = keyword;
    lastTypes = types;
    return results;
  }
}

void main() {
  late Box<dynamic> box;

  setUpAll(() async {
    final dir = await Directory.systemTemp.createTemp('bangumi_link_test_');
    try {
      Hive.init(dir.path);
    } catch (_) {}
    box = await Hive.openBox('bangumi_link_test');
  });

  setUp(() async {
    await box.clear();
  });

  tearDownAll(() async {
    await Hive.deleteFromDisk();
  });

  group('bangumiTitleSimilarity', () {
    test('完全相等 = 1', () {
      expect(bangumiTitleSimilarity('Frieren', 'Frieren'), 1);
    });

    test('大小写与空白归一化后相等 = 1', () {
      expect(bangumiTitleSimilarity('Sousou no Frieren', 'sousouno frieren'), 1);
    });

    test('中文名完全匹配 = 1', () {
      expect(bangumiTitleSimilarity('葬送的芙莉莲', '葬送的芙莉莲'), 1);
    });

    test('轻微差异 >= 0.85（高置信）', () {
      // 8 字中 1 字不同 → 1 - 1/8 = 0.875。
      expect(
        bangumiTitleSimilarity('葬送的芙莉莲第二季', '葬送的芙莉连第二季'),
        greaterThanOrEqualTo(0.85),
      );
    });

    test('明显不同标题 < 0.85（低置信）', () {
      expect(bangumiTitleSimilarity('葬送的芙莉莲', '孤独摇滚'), lessThan(0.85));
    });

    test('空串 = 0', () {
      expect(bangumiTitleSimilarity('', 'abc'), 0);
      expect(bangumiTitleSimilarity('abc', ''), 0);
    });
  });

  group('SubjectLink 序列化', () {
    test('toJson/fromJson 往返（含 forcedType）', () {
      const link = SubjectLink(
          subjectId: 400602, forcedType: BangumiCollectionType.dropped);
      final restored = SubjectLink.fromJson(link.toJson());
      expect(restored.subjectId, 400602);
      expect(restored.forcedType, BangumiCollectionType.dropped);
    });

    test('缺省 forcedType = null，容错缺字段', () {
      final restored = SubjectLink.fromJson(<String, dynamic>{'subjectId': 1});
      expect(restored.subjectId, 1);
      expect(restored.forcedType, isNull);
    });

    test('旧版 forceCollect: true 迁移为 forcedType = collect', () {
      final restored = SubjectLink.fromJson(
          <String, dynamic>{'subjectId': 2, 'forceCollect': true});
      expect(restored.subjectId, 2);
      expect(restored.forcedType, BangumiCollectionType.collect);
    });
  });

  group('SubjectLinkStore 缓存读写', () {
    test('put/get/remove 往返', () async {
      final store = SubjectLinkStore(client: _FakeSearchClient(), box: box);
      await store.put('c1', const SubjectLink(subjectId: 42));
      final link = await store.get('c1');
      expect(link, isNotNull);
      expect(link!.subjectId, 42);
      expect(link.forcedType, isNull);

      await store.put(
          'c1',
          const SubjectLink(
              subjectId: 42, forcedType: BangumiCollectionType.collect));
      expect(
          (await store.get('c1'))!.forcedType, BangumiCollectionType.collect);

      await store.remove('c1');
      expect(await store.get('c1'), isNull);
    });

    test('损坏数据返回 null', () async {
      final store = SubjectLinkStore(client: _FakeSearchClient(), box: box);
      await box.put('bad', 'not-json');
      expect(await store.get('bad'), isNull);
    });
  });

  group('searchTypesFor', () {
    test('animeSource 同时匹配动画与三次元', () {
      expect(
        SubjectLinkStore.searchTypesFor(SourceType.animeSource),
        <int>[BangumiSubjectType.anime, BangumiSubjectType.real],
      );
    });

    test('漫画 / 小说匹配 book', () {
      expect(
        SubjectLinkStore.searchTypesFor(SourceType.mangaSource),
        <int>[BangumiSubjectType.book],
      );
      expect(
        SubjectLinkStore.searchTypesFor(SourceType.novelSource),
        <int>[BangumiSubjectType.book],
      );
    });
  });

  group('resolve 三级解析', () {
    test('缓存命中直接返回，不触发搜索', () async {
      final client = _FakeSearchClient();
      final store = SubjectLinkStore(client: client, box: box);
      await store.put('c1', const SubjectLink(subjectId: 7));

      final result = await store.resolve('c1', 'whatever', SourceType.animeSource);
      expect(result.resolved, isTrue);
      expect(result.link!.subjectId, 7);
      expect(client.lastKeyword, isNull);
    });

    test('高置信（中文名完全匹配）自动采用并写缓存', () async {
      final client = _FakeSearchClient()
        ..results = const <BangumiSubject>[
          BangumiSubject(id: 1, name: 'other', nameCn: '别的动画', type: 2),
          BangumiSubject(
              id: 400602, name: 'Sousou no Frieren', nameCn: '葬送的芙莉莲', type: 2),
        ];
      final store = SubjectLinkStore(client: client, box: box);

      final result =
          await store.resolve('c2', '葬送的芙莉莲', SourceType.animeSource);
      expect(result.resolved, isTrue);
      expect(result.link!.subjectId, 400602);
      expect(client.lastTypes, <int>[2, 6]);
      // 已写入缓存。
      expect((await store.get('c2'))!.subjectId, 400602);
    });

    test('低置信返回候选列表且不写缓存', () async {
      final client = _FakeSearchClient()
        ..results = const <BangumiSubject>[
          BangumiSubject(id: 1, name: 'A', nameCn: '完全不相关的标题', type: 2),
          BangumiSubject(id: 2, name: 'B', nameCn: '另一个不相关', type: 2),
        ];
      final store = SubjectLinkStore(client: client, box: box);

      final result = await store.resolve('c3', '葬送的芙莉莲', SourceType.animeSource);
      expect(result.resolved, isFalse);
      expect(result.candidates, hasLength(2));
      expect(await store.get('c3'), isNull);
    });

    test('无搜索结果返回空结果', () async {
      final client = _FakeSearchClient()..results = const <BangumiSubject>[];
      final store = SubjectLinkStore(client: client, box: box);

      final result = await store.resolve('c4', '某标题', SourceType.mangaSource);
      expect(result.resolved, isFalse);
      expect(result.candidates, isEmpty);
      expect(client.lastTypes, <int>[1]);
    });
  });
}

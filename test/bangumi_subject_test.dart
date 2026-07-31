/// Bangumi 条目详情与用户收藏过滤单元测试。
///
/// 覆盖：
/// - [BangumiSubjectRating] / [BangumiSubjectDetail] 的 JSON 解析（评分、
///   分布、标签、封面回退、中文名回退）；
/// - [BangumiClient.fetchSubject] 走 `/v0/subjects/{id}` 并正确解析；
/// - [BangumiClient.fetchUserCollections] 在传入 collectionType 时携带 `type`
///   查询参数，未传入时省略。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/services/bangumi/bangumi_client.dart';
import 'package:nexhub/core/services/bangumi/bangumi_models.dart';

/// 可编程 Dio 适配器：按路径返回预设 JSON，并记录每次请求。
class _FakeAdapter implements HttpClientAdapter {
  /// path → JSON body 映射（精确匹配 RequestOptions.path）。
  final Map<String, Map<String, dynamic>> responses;

  /// 记录所有到达的请求，供断言查询参数。
  final List<RequestOptions> requests = <RequestOptions>[];

  _FakeAdapter(this.responses);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final body = responses[options.path] ?? <String, dynamic>{};
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  group('BangumiSubjectRating.fromJson', () {
    test('解析平均分/人数/排名/分布', () {
      final rating = BangumiSubjectRating.fromJson(<String, dynamic>{
        'score': 8.6,
        'total': 1234,
        'rank': 42,
        'count': <String, dynamic>{'9': 100, '10': 200},
      });
      expect(rating.score, 8.6);
      expect(rating.total, 1234);
      expect(rating.rank, 42);
      expect(rating.count[9], 100);
      expect(rating.count[10], 200);
      expect(rating.hasScore, isTrue);
    });

    test('无评分时 hasScore 为 false', () {
      final rating = BangumiSubjectRating.fromJson(const <String, dynamic>{});
      expect(rating.hasScore, isFalse);
      expect(rating.count, isEmpty);
    });
  });

  group('BangumiSubjectDetail.fromJson', () {
    test('解析名称/中文名/简介/标签/封面/评分', () {
      final detail = BangumiSubjectDetail.fromJson(<String, dynamic>{
        'id': 3559,
        'name': 'とある科学の超電磁砲',
        'name_cn': '某科学的超电磁炮',
        'type': 2,
        'summary': '一段介绍',
        'images': <String, dynamic>{
          'common': 'https://img.example/common.jpg',
          'medium': 'https://img.example/medium.jpg',
        },
        'tags': <dynamic>[
          <String, dynamic>{'name': '科幻', 'count': 500},
          <String, dynamic>{'name': '超能力', 'count': 300},
        ],
        'rating': <String, dynamic>{'score': 8.2, 'total': 9000, 'rank': 100},
      });
      expect(detail.id, 3559);
      expect(detail.displayName, '某科学的超电磁炮');
      expect(detail.summary, '一段介绍');
      expect(detail.image, 'https://img.example/common.jpg');
      expect(detail.tags, <String>['科幻', '超能力']);
      expect(detail.rating.score, 8.2);
      expect(detail.rating.hasScore, isTrue);
    });

    test('缺中文名时 displayName 回退原名；无 common 时封面回退 medium', () {
      final detail = BangumiSubjectDetail.fromJson(<String, dynamic>{
        'id': 1,
        'name': 'Original',
        'name_cn': '',
        'type': 2,
        'images': <String, dynamic>{'medium': 'https://img.example/m.jpg'},
      });
      expect(detail.displayName, 'Original');
      expect(detail.image, 'https://img.example/m.jpg');
      expect(detail.rating.hasScore, isFalse);
      expect(detail.tags, isEmpty);
    });
  });

  group('BangumiClient.fetchSubject', () {
    test('请求 /v0/subjects/{id} 并解析详情', () async {
      final adapter = _FakeAdapter(<String, Map<String, dynamic>>{
        '/v0/subjects/3559': <String, dynamic>{
          'id': 3559,
          'name': 'Railgun',
          'name_cn': '超电磁炮',
          'type': 2,
          'summary': 'sum',
          'rating': <String, dynamic>{'score': 8.2, 'total': 9000, 'rank': 100},
          'tags': <dynamic>[
            <String, dynamic>{'name': '科幻'}
          ],
        },
      });
      final client = BangumiClient(dio: Dio()..httpClientAdapter = adapter);

      final detail = await client.fetchSubject(3559);
      expect(detail.id, 3559);
      expect(detail.displayName, '超电磁炮');
      expect(detail.rating.score, 8.2);
      expect(detail.tags, <String>['科幻']);
      expect(adapter.requests.single.path, '/v0/subjects/3559');
    });
  });

  group('BangumiClient.fetchUserCollections collectionType 过滤', () {
    test('传入 collectionType 时携带 type 查询参数', () async {
      final adapter = _FakeAdapter(<String, Map<String, dynamic>>{
        '/v0/users/tester/collections': <String, dynamic>{
          'data': <dynamic>[
            <String, dynamic>{
              'subject_id': 10,
              'type': BangumiCollectionType.doing,
            },
          ],
          'total': 1,
        },
      });
      final client = BangumiClient(dio: Dio()..httpClientAdapter = adapter);

      final items = await client.fetchUserCollections(
        'tester',
        subjectType: BangumiSubjectType.anime,
        collectionType: BangumiCollectionType.doing,
      );
      expect(items.single.subjectId, 10);
      final query = adapter.requests.first.queryParameters;
      expect(query['subject_type'], BangumiSubjectType.anime);
      expect(query['type'], BangumiCollectionType.doing);
    });

    test('未传 collectionType 时省略 type 查询参数', () async {
      final adapter = _FakeAdapter(<String, Map<String, dynamic>>{
        '/v0/users/tester/collections': <String, dynamic>{
          'data': <dynamic>[],
          'total': 0,
        },
      });
      final client = BangumiClient(dio: Dio()..httpClientAdapter = adapter);

      await client.fetchUserCollections(
        'tester',
        subjectType: BangumiSubjectType.anime,
      );
      final query = adapter.requests.first.queryParameters;
      expect(query.containsKey('type'), isFalse);
      expect(query['subject_type'], BangumiSubjectType.anime);
    });
  });

  group('BangumiUserCollection.fromJson 嵌套 subject 解析', () {
    test('解析封面 / 站点评分 / 名称 / displayName', () {
      final c = BangumiUserCollection.fromJson(<String, dynamic>{
        'subject_id': 3559,
        'type': BangumiCollectionType.collect,
        'rate': 9,
        'comment': '好评',
        'subject': <String, dynamic>{
          'name': 'Railgun',
          'name_cn': '超电磁炮',
          'score': 8.2,
          'images': <String, dynamic>{
            'common': 'https://img.example/common.jpg',
            'grid': 'https://img.example/grid.jpg',
          },
        },
      });
      expect(c.subjectId, 3559);
      expect(c.rate, 9);
      expect(c.subjectImage, 'https://img.example/common.jpg');
      expect(c.subjectScore, 8.2);
      expect(c.displayName, '超电磁炮');
    });

    test('subject.score 缺省时回退 subject.rating.score', () {
      final c = BangumiUserCollection.fromJson(<String, dynamic>{
        'subject_id': 1,
        'type': BangumiCollectionType.doing,
        'subject': <String, dynamic>{
          'name': 'Original',
          'name_cn': '',
          'rating': <String, dynamic>{'score': 7.5},
          'images': <String, dynamic>{'medium': 'https://img.example/m.jpg'},
        },
      });
      expect(c.subjectScore, 7.5);
      expect(c.subjectImage, 'https://img.example/m.jpg');
      // 缺中文名时 displayName 回退原名。
      expect(c.displayName, 'Original');
    });

    test('无 subject 时封面为空、评分为 0、displayName 回退 #id', () {
      final c = BangumiUserCollection.fromJson(<String, dynamic>{
        'subject_id': 42,
        'type': BangumiCollectionType.wish,
      });
      expect(c.subjectImage, isNull);
      expect(c.subjectScore, 0);
      expect(c.displayName, '#42');
    });
  });
}

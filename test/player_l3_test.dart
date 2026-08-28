/// 播放器 L3 剩余项单元测试。
///
/// 覆盖：
/// -  缓存策略降级：[DemuxerCacheProfile] 两档预算数值；
/// -  弹幕发送上传：[DandanplayService.sendComment] 请求路径 / 体 /
///   Bearer 头与成功解析，[DandanplayService.login] 凭据校验与 token 提取。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nexhub/core/danmaku/dandanplay_service.dart';
import 'package:nexhub/core/player/demuxer_cache_policy.dart';
import 'package:nexhub/core/settings/danmaku_config.dart';

/// 可编程 Dio 适配器：按路径返回预设 JSON，并记录每次请求。
class _FakeAdapter implements HttpClientAdapter {
  final Map<String, Map<String, dynamic>> responses;
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
  group(' DemuxerCacheProfile', () {
    test('标准档 1500MiB 前向 / 750MiB 后向', () {
      expect(DemuxerCacheProfile.standard.maxBytes, 1500 * 1024 * 1024);
      expect(DemuxerCacheProfile.standard.maxBackBytes, 750 * 1024 * 1024);
    });

    test('低内存档 2MiB 前向 / 1MiB 后向', () {
      expect(DemuxerCacheProfile.low.maxBytes, 2 * 1024 * 1024);
      expect(DemuxerCacheProfile.low.maxBackBytes, 1024 * 1024);
    });
  });

  group(' DandanplayService.sendComment', () {
    late _FakeAdapter adapter;
    late DandanplayService service;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = DanmakuConfigStore();
      await store.save(const DanmakuConfig(
          appId: 'app-id', appSecret: 'app-secret', enabled: true));
      adapter = _FakeAdapter(<String, Map<String, dynamic>>{
        '/api/v2/comment/80699': <String, dynamic>{
          'success': true,
          'cid': 12345,
        },
      });
      service = DandanplayService(
        configStore: store,
        dio: Dio(BaseOptions(baseUrl: 'https://api.dandanplay.net'))
          ..httpClientAdapter = adapter,
      );
    });

    test('POST 到 /api/v2/comment/{episodeId} 并携带 Bearer 与弹幕体',
        () async {
      final cid = await service.sendComment(
        episodeId: '80699',
        time: 61.5,
        mode: 1,
        color: 0xFF3355 & 0xFFFFFF,
        comment: '测试弹幕',
        bearerToken: 'tok_abc',
      );
      expect(cid, '12345');
      expect(adapter.requests, hasLength(1));
      final req = adapter.requests.single;
      expect(req.method, 'POST');
      expect(req.path, '/api/v2/comment/80699');
      expect(req.headers['Authorization'], 'Bearer tok_abc');
      // 应用级签名头必须齐备。
      expect(req.headers.containsKey('X-AppId'), isTrue);
      expect(req.headers.containsKey('X-Timestamp'), isTrue);
      expect(req.headers.containsKey('X-Signature'), isTrue);
      final body = req.data as Map<String, dynamic>;
      expect(body['time'], closeTo(61.5, 0.001));
      expect(body['mode'], 1);
      expect(body['color'], 0xFF3355);
      expect(body['comment'], '测试弹幕');
    });

    test('success=false 时抛出异常', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = DanmakuConfigStore();
      await store.save(const DanmakuConfig(
          appId: 'app-id', appSecret: 'app-secret', enabled: true));
      final failing = DandanplayService(
        configStore: store,
        dio: Dio(BaseOptions(baseUrl: 'https://api.dandanplay.net'))
          ..httpClientAdapter = _FakeAdapter(<String, Map<String, dynamic>>{
            '/api/v2/comment/80699': <String, dynamic>{
              'success': false,
              'errorMessage': 'need login',
            },
          }),
      );
      await expectLater(
        failing.sendComment(
          episodeId: '80699',
          time: 10,
          mode: 1,
          color: 0xFFFFFF,
          comment: 'x',
          bearerToken: 'expired',
        ),
        throwsStateError,
      );
    });

    test('color 超出 24bit 时被掩码截断', () async {
      await service.sendComment(
        episodeId: '80699',
        time: 1,
        mode: 4,
        color: 0xFF112233, // 带 alpha 位
        comment: 'c',
        bearerToken: 't',
      );
      final body =
          adapter.requests.single.data as Map<String, dynamic>;
      expect(body['color'], 0x112233);
    });
  });

  group(' DandanplayService.login', () {
    test('未配置凭据时抛 StateError', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = DanmakuConfigStore();
      await store.save(const DanmakuConfig(
          appId: '', appSecret: '', enabled: true));
      final service = DandanplayService(
        configStore: store,
        dio: Dio(BaseOptions(baseUrl: 'https://api.dandanplay.net'))
          ..httpClientAdapter = _FakeAdapter(const <String,
              Map<String, dynamic>>{}),
      );
      await expectLater(
        service.login('user', 'pass'),
        throwsStateError,
      );
    });

    test('已配置凭据时提取 token 与用户信息', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = DanmakuConfigStore();
      await store.save(const DanmakuConfig(
          appId: 'app-id', appSecret: 'app-secret', enabled: true));
      final adapter = _FakeAdapter(<String, Map<String, dynamic>>{
        '/api/v2/login': <String, dynamic>{
          'success': true,
          'token': 'user_token_1',
          'user': <String, dynamic>{
            'userName': 'u1',
            'screenName': '昵称一',
          },
        },
      });
      final service = DandanplayService(
        configStore: store,
        dio: Dio(BaseOptions(baseUrl: 'https://api.dandanplay.net'))
          ..httpClientAdapter = adapter,
      );
      final result = await service.login('u1', 'pw');
      expect(result.token, 'user_token_1');
      expect(result.userName, 'u1');
      expect(result.screenName, '昵称一');
      final req = adapter.requests.single;
      expect(req.path, '/api/v2/login');
      final body = req.data as Map<String, dynamic>;
      expect(body['userName'], 'u1');
      expect(body['appId'], 'app-id');
      expect((body['hash'] as String).length, 32); // md5 hex
    });
  });
}

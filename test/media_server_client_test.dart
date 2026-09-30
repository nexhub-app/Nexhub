/// 媒体服务器客户端单测（离线）：dio 假适配器覆盖方言端点路径、鉴权头、
/// 响应解析、直连协商决策树、401 → isUnauthorized 映射与会话上报。
///
/// 夹具 JSON 按官方 API 文档形态手写，真机实测后如有出入回填修正
/// （TODO 文档 §八 M2）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/services/media_server/emby_client.dart';
import 'package:nexhub/core/services/media_server/jellyfin_client.dart';
import 'package:nexhub/core/services/media_server/media_server_client.dart';
import 'package:nexhub/core/services/media_server/media_server_models.dart';

/// 假适配器：不触网，按 handler 回放响应并记录请求。
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);

  // 非 final：用例间翻转响应（如登录成功后再让探测失败）。
  Future<ResponseBody> Function(RequestOptions opts) handler;
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object body, [int status = 200]) =>
    ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );

void main() {
  late Dio dio;
  late _FakeAdapter adapter;
  late MediaServerClientBase client;

  const jellyInfo = MediaServerInfo(
    id: 'srv1',
    type: ServerType.jellyfin,
    name: 'JF',
    baseUrl: 'http://jf:8096',
    userId: 'u1',
  );

  setUp(() {
    adapter = _FakeAdapter((opts) async => _json(<String, dynamic>{}));
    dio = Dio(BaseOptions(baseUrl: jellyInfo.baseUrl))
      ..httpClientAdapter = adapter;
    client = MediaServerClientBase.createServerClient(
      jellyInfo,
      deviceId: 'dev1',
      token: 'tok',
      deviceName: 'test-dev',
      dio: dio,
    );
  });

  group('工厂与方言', () {
    test('按类型返回对应方言客户端', () {
      expect(client, isA<JellyfinClient>());
      final emby = MediaServerClientBase.createServerClient(
        jellyInfo.copyWith(type: ServerType.emby),
        deviceId: 'dev1',
      );
      expect(emby, isA<EmbyClient>());
    });

    test('Authorization 头：scheme、字段与 Token 拼装', () {
      expect(
        client.authorizationHeader(),
        'MediaBrowser Client="NexHub", Device="test-dev", '
        'DeviceId="dev1", Version="1.0.0", Token="tok"',
      );
    });

    test('Emby 方言 scheme 与鉴权头', () {
      final emby = MediaServerClientBase.createServerClient(
        jellyInfo.copyWith(type: ServerType.emby),
        deviceId: 'dev1',
        token: 'tok',
        deviceName: 'test-dev',
      );
      expect(emby.authScheme, 'Emby');
      expect(
        emby.authorizationHeader(),
        startsWith('Emby Client="NexHub"'),
      );
    });

    test('authHeaders 含 X-Emby-Token 双保险', () {
      final headers = client.authHeaders();
      expect(headers['Authorization'], contains('MediaBrowser'));
      expect(headers['X-Emby-Token'], 'tok');
    });
  });

  group('探测与登录（预 token）', () {
    test('probe：识别 Jellyfin 并取 ServerName/Version', () async {
      adapter.handler = (opts) async {
        expect(opts.path, '/System/Info/Public');
        return _json(<String, dynamic>{
          'ProductName': 'Jellyfin Server',
          'ServerName': 'NAS',
          'Version': '10.9.2',
        });
      };
      final r = await MediaServerClientBase.probe('http://jf:8096', dio: dio);
      expect(r.type, ServerType.jellyfin);
      expect(r.serverName, 'NAS');
      expect(r.version, '10.9.2');
    });

    test('probe：识别 Emby', () async {
      adapter.handler = (opts) async => _json(<String, dynamic>{
            'ProductName': 'Emby Server',
            'ServerName': 'E',
          });
      final r = await MediaServerClientBase.probe('http://jf:8096', dio: dio);
      expect(r.type, ServerType.emby);
    });

    test('probe：未知产品抛异常', () async {
      adapter.handler = (opts) async =>
          _json(<String, dynamic>{'ProductName': 'Kodi'});
      await expectLater(
        MediaServerClientBase.probe('http://jf:8096', dio: dio),
        throwsA(isA<MediaServerApiException>()),
      );
    });

    test('authenticateByName：路径 / 请求体 / 预 token 头 / 解析', () async {
      // 独立 dio：不走 setUp 里带 token 的客户端拦截器，验证预 token 请求形态。
      final authAdapter = _FakeAdapter((opts) async {
        expect(opts.path, '/Users/AuthenticateByName');
        expect(opts.data, <String, dynamic>{'Username': 'alice', 'Pw': 'pw'});
        expect(opts.headers['Authorization'], startsWith('MediaBrowser '));
        expect(opts.headers.containsKey('X-Emby-Token'), isFalse);
        return _json(<String, dynamic>{
          'AccessToken': 'at-1',
          'User': <String, dynamic>{'Id': 'uid-9', 'Name': 'alice'},
        });
      });
      final authDio = Dio(BaseOptions(baseUrl: jellyInfo.baseUrl))
        ..httpClientAdapter = authAdapter;
      final r = await MediaServerClientBase.authenticateByName(
        baseUrl: 'http://jf:8096',
        type: ServerType.jellyfin,
        username: 'alice',
        password: 'pw',
        deviceId: 'dev1',
        deviceName: 'test-dev',
        dio: authDio,
      );
      expect(r.accessToken, 'at-1');
      expect(r.userId, 'uid-9');
      expect(r.username, 'alice');
    });

    test('authenticateByName：401 → isUnauthorized', () async {
      adapter.handler = (opts) async => _json(<String, dynamic>{}, 401);
      await expectLater(
        MediaServerClientBase.authenticateByName(
          baseUrl: 'http://jf:8096',
          type: ServerType.jellyfin,
          username: 'alice',
          password: 'bad',
          deviceId: 'dev1',
          dio: dio,
        ),
        throwsA(
          isA<MediaServerApiException>()
              .having((e) => e.isUnauthorized, 'isUnauthorized', isTrue),
        ),
      );
    });
  });

  group('浏览端点（方言路径）', () {
    test('Jellyfin：/UserViews + userId query；请求头带 token', () async {
      adapter.handler = (opts) async {
        expect(opts.path, '/UserViews');
        expect(opts.queryParameters['userId'], 'u1');
        expect(opts.headers['Authorization'], contains('Token="tok"'));
        return _json(<String, dynamic>{
          'Items': [
            {'Id': 'lib1', 'Name': '电影', 'CollectionType': 'movies'},
            {'Id': 'lib2', 'Name': '剧集', 'CollectionType': 'tvshows'},
          ],
        });
      };
      final libs = await client.fetchLibraries();
      expect(libs, hasLength(2));
      expect(libs.first.id, 'lib1');
      expect(libs.first.collectionType, 'movies');
    });

    test('Emby：/Users/{u}/Views 且 query 不带 userId', () async {
      final emby = MediaServerClientBase.createServerClient(
        jellyInfo.copyWith(type: ServerType.emby),
        deviceId: 'dev1',
        token: 'tok',
        dio: dio,
      );
      adapter.handler = (opts) async {
        expect(opts.path, '/Users/u1/Views');
        expect(opts.queryParameters.containsKey('userId'), isFalse);
        expect(opts.headers['Authorization'], startsWith('Emby '));
        return _json(<String, dynamic>{
          'Items': [
            {'Id': 'lib1', 'Name': 'Movies', 'CollectionType': 'movies'},
          ],
        });
      };
      final libs = await emby.fetchLibraries();
      expect(libs, hasLength(1));
    });

    test('Jellyfin Latest：/Items/Latest 裸数组解析', () async {
      adapter.handler = (opts) async {
        expect(opts.path, '/Items/Latest');
        expect(opts.queryParameters['Limit'], 20);
        return _json(<Object?>[
          {
            'Id': 'm1',
            'Name': 'Movie A',
            'Type': 'Movie',
            'ProductionYear': 2020,
          },
        ]);
      };
      final items = await client.fetchLatest();
      expect(items, hasLength(1));
      expect(items.single.type, 'Movie');
    });

    test('Emby Resume：老式路径 + 分页参数 + TotalRecordCount', () async {
      final emby = MediaServerClientBase.createServerClient(
        jellyInfo.copyWith(type: ServerType.emby),
        deviceId: 'dev1',
        dio: dio,
      );
      adapter.handler = (opts) async {
        expect(opts.path, '/Users/u1/Items/Resume');
        expect(opts.queryParameters['StartIndex'], 0);
        expect(opts.queryParameters['Limit'], 30);
        return _json(<String, dynamic>{
          'TotalRecordCount': 1,
          'Items': [
            {
              'Id': 'e1',
              'Name': 'S1E1',
              'Type': 'Episode',
              'SeriesName': 'Show',
              'UserData': {
                'Played': false,
                'PlaybackPositionTicks': 600000000,
              },
            },
          ],
        });
      };
      final page = await emby.fetchResume();
      expect(page.total, 1);
      expect(page.items.single.userData?.playbackPositionTicks, 600000000);
    });

    test('fetchItems：库内浏览带 ParentId 与分页', () async {
      adapter.handler = (opts) async {
        expect(opts.path, '/Items');
        expect(opts.queryParameters['ParentId'], 'lib1');
        expect(opts.queryParameters['SearchTerm'], isNull);
        expect(opts.queryParameters['IncludeItemTypes'], 'Movie');
        expect(opts.queryParameters['StartIndex'], 30);
        return _json(<String, dynamic>{'TotalRecordCount': 0, 'Items': []});
      };
      await client.fetchItems(
        parentId: 'lib1',
        includeTypes: const <String>['Movie'],
        startIndex: 30,
      );
    });

    test('fetchItems：搜索带 SearchTerm', () async {
      adapter.handler = (opts) async {
        expect(opts.queryParameters['SearchTerm'], 'foo');
        expect(opts.queryParameters.containsKey('ParentId'), isFalse);
        return _json(<String, dynamic>{'Items': []});
      };
      await client.fetchItems(searchTerm: 'foo');
    });

    test('详情 / 季 / 集 端点', () async {
      adapter.handler = (opts) async {
        if (opts.path == '/Users/u1/Items/it1') {
          return _json(<String, dynamic>{'Id': 'it1', 'Name': 'X', 'Type': 'Series'});
        }
        if (opts.path == '/Shows/it1/Seasons') {
          return _json(<String, dynamic>{
            'Items': [
              {'Id': 's1', 'Name': 'Season 1', 'Type': 'Season', 'IndexNumber': 1},
            ],
          });
        }
        if (opts.path == '/Shows/it1/Episodes') {
          expect(opts.queryParameters['SeasonId'], 's1');
          return _json(<String, dynamic>{
            'Items': [
              {'Id': 'e1', 'Name': 'Pilot', 'Type': 'Episode'},
            ],
          });
        }
        fail('unexpected path ${opts.path}');
      };
      final item = await client.fetchItem('it1');
      expect(item.type, 'Series');
      final seasons = await client.fetchSeasons('it1');
      expect(seasons.single.id, 's1');
      final eps = await client.fetchEpisodes('it1', seasonId: 's1');
      expect(eps.single.id, 'e1');
    });
  });

  group('PlaybackInfo 直连协商', () {
    test('DirectPlay → 拼 stream?static=true 直连 URL', () async {
      adapter.handler = (opts) async {
        expect(opts.path, '/Items/it1/PlaybackInfo');
        return _json(<String, dynamic>{
          'PlaySessionId': 'ps1',
          'MediaSources': [
            {
              'Id': 'ms1',
              'SupportsDirectPlay': true,
              'Container': 'mp4',
              'RunTimeTicks': 72000000000,
            },
          ],
        });
      };
      final r = await client.createPlaybackInfo('it1');
      expect(r.requiresTranscode, isFalse);
      // 播放地址自鉴权：追加 api_key（mpv 跟随 302 重定向不转发请求头）。
      expect(
        r.playUrl,
        'http://jf:8096/Videos/it1/stream'
        '?static=true&MediaSourceId=ms1&PlaySessionId=ps1&api_key=tok',
      );
      expect(r.headers['Authorization'], contains('Token="tok"'));
      expect(r.runTimeTicks, 72000000000);
      expect(r.container, 'mp4');
    });

    test('DirectStream → DirectStreamUrl 拼 baseUrl', () async {
      adapter.handler = (opts) async => _json(<String, dynamic>{
            'PlaySessionId': 'ps1',
            'MediaSources': [
              {
                'Id': 'ms1',
                'SupportsDirectPlay': false,
                'SupportsDirectStream': true,
                'DirectStreamUrl': '/Videos/it1/original.mp4',
              },
            ],
          });
      final r = await client.createPlaybackInfo('it1');
      expect(r.requiresTranscode, isFalse);
      expect(r.playUrl, 'http://jf:8096/Videos/it1/original.mp4?api_key=tok');
    });

    test('仅转码可用 → 走 TranscodingUrl（HLS）并标记 transcode', () async {
      adapter.handler = (opts) async {
        expect(opts.data['DeviceProfile'], isA<Map>());
        return _json(<String, dynamic>{
          'PlaySessionId': 'ps1',
          'MediaSources': [
            {
              'Id': 'ms1',
              'SupportsDirectPlay': false,
              'SupportsDirectStream': false,
              'SupportsTranscoding': true,
              'TranscodingUrl':
                  '/Videos/it1/master.m3u8?MediaSourceId=ms1&PlaySessionId=ps1',
            },
          ],
        });
      };
      final r = await client.createPlaybackInfo('it1');
      expect(r.requiresTranscode, isTrue);
      expect(r.playMethod, MediaServerPlayMethod.transcode);
      expect(
        r.playUrl,
        'http://jf:8096/Videos/it1/master.m3u8'
        '?MediaSourceId=ms1&PlaySessionId=ps1&api_key=tok',
      );
    });

    test('码率档位透传 MaxStreamingBitrate', () async {
      adapter.handler = (opts) async {
        expect(opts.data['MaxStreamingBitrate'], 8000000);
        return _json(<String, dynamic>{
          'PlaySessionId': 'ps1',
          'MediaSources': [
            {'Id': 'ms1', 'SupportsDirectPlay': true},
          ],
        });
      };
      await client.createPlaybackInfo('it1', maxStreamingBitrate: 8000000);
    });

    test('音轨解析（MediaStreams type=Audio）', () async {
      adapter.handler = (opts) async => _json(<String, dynamic>{
            'PlaySessionId': 'ps1',
            'MediaSources': [
              {
                'Id': 'ms1',
                'SupportsDirectPlay': true,
                'MediaStreams': [
                  {'Type': 'Video', 'Codec': 'h264', 'Index': 0},
                  {
                    'Type': 'Audio',
                    'Codec': 'aac',
                    'Index': 1,
                    'DisplayTitle': '日语 AAC 5.1',
                    'Language': 'jpn',
                    'IsDefault': true,
                  },
                  {'Type': 'Audio', 'Codec': 'flac', 'Index': 2},
                ],
              },
            ],
          });
      final r = await client.createPlaybackInfo('it1');
      expect(r.audioStreams, hasLength(2));
      expect(r.audioStreams.first.index, 1);
      expect(r.audioStreams.first.label(), '日语 AAC 5.1');
      expect(r.audioStreams.last.label(), 'FLAC');
      expect(r.audioStreams.first.isDefault, isTrue);
    });

    test('无媒体源 → 抛异常', () async {
      adapter.handler = (opts) async =>
          _json(<String, dynamic>{'PlaySessionId': 'ps1', 'MediaSources': []});
      await expectLater(
        client.createPlaybackInfo('it1'),
        throwsA(isA<MediaServerApiException>()),
      );
    });
  });

  group('会话上报与已看标记', () {
    test('Playing 三段式端点与请求体', () async {
      adapter.handler = (opts) async => _json(<String, dynamic>{});
      await client.reportPlayingStart(
        itemId: 'it1',
        playSessionId: 'ps1',
        positionTicks: 0,
      );
      await client.reportPlayingProgress(
        itemId: 'it1',
        positionTicks: 600000000,
        isPaused: false,
        playSessionId: 'ps1',
      );
      await client.reportPlayingStopped(
        itemId: 'it1',
        playSessionId: 'ps1',
        positionTicks: 900000000,
      );
      expect(adapter.requests[0].path, '/Sessions/Playing');
      expect(adapter.requests[1].path, '/Sessions/Playing/Progress');
      expect(adapter.requests[1].data['PositionTicks'], 600000000);
      expect(adapter.requests[1].data['IsPaused'], false);
      expect(adapter.requests[2].path, '/Sessions/Playing/Stopped');
    });

    test('已看标记：POST / DELETE', () async {
      adapter.handler = (opts) async => _json(<String, dynamic>{});
      await client.markPlayed('it1');
      await client.markUnplayed('it1');
      expect(adapter.requests[0].method, 'POST');
      expect(adapter.requests[0].path, '/Users/u1/PlayedItems/it1');
      expect(adapter.requests[1].method, 'DELETE');
    });
  });

  group('错误映射', () {
    test('列表请求 401 → isUnauthorized', () async {
      adapter.handler = (opts) async => _json(<String, dynamic>{}, 401);
      await expectLater(
        client.fetchLibraries(),
        throwsA(
          isA<MediaServerApiException>()
              .having((e) => e.isUnauthorized, 'isUnauthorized', isTrue)
              .having((e) => e.statusCode, 'statusCode', 401),
        ),
      );
    });

    test('连接超时 → timeout 异常', () async {
      adapter.handler = (opts) async {
        throw DioException(
          requestOptions: opts,
          type: DioExceptionType.connectionTimeout,
        );
      };
      await expectLater(
        client.fetchLibraries(),
        throwsA(
          isA<MediaServerApiException>().having(
            (e) => e.message,
            'message',
            contains('timeout'),
          ),
        ),
      );
    });
  });
}

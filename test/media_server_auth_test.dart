/// MediaServerAuth 单测：添加 / 登录 / 删除 / 状态判定 / deviceId 复用，
/// 以及「添加 → 重建实例（模拟杀进程重进）→ 档案仍在」的持久化往返。
///
/// 网络（探测 / 登录）注入假实现；token 存储与偏好后端均为内存实现，
/// 不触碰平台插件。Hive 用临时目录（同 SubjectLinkStore 测试做法）。
library;

import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:nexhub/core/comic/models/reader_preferences.dart';
import 'package:nexhub/core/services/media_server/media_server_auth.dart';
import 'package:nexhub/core/services/media_server/media_server_models.dart';

/// 内存版 token 存储（覆写全签名，避免触平台通道）。
class _FakeTokenStorage extends FlutterSecureStorage {
  final Map<String, String?> store = <String, String?>{};

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      store[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    store[key] = value;
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    store.remove(key);
  }
}

void main() {
  late Box<dynamic> box;
  late _FakeTokenStorage tokenStorage;
  late InMemoryBackend prefs;

  setUpAll(() async {
    final dir = await Directory.systemTemp.createTemp('media_server_auth_');
    try {
      Hive.init(dir.path);
    } catch (_) {}
    box = await Hive.openBox('media_servers');
  });

  setUp(() async {
    await box.clear();
    tokenStorage = _FakeTokenStorage();
    prefs = InMemoryBackend();
  });

  tearDownAll(() async {
    await Hive.deleteFromDisk();
  });

  /// 探测假实现：返回 Jellyfin 类型 + 服务器名。
  MediaServerProbe fakeProbe({
    String serverName = 'NAS 媒体库',
    Object? throwOn,
  }) {
    return (String baseUrl) async {
      if (throwOn != null) throw throwOn;
      return MediaServerProbeResult(
        type: ServerType.jellyfin,
        serverName: serverName,
        version: '10.9.2',
      );
    };
  }

  /// 登录假实现：返回固定成功载荷。
  MediaServerAuthenticator fakeLogin({
    Object? throwOn,
  }) {
    return (
      String baseUrl,
      ServerType type, {
      required String username,
      required String password,
      required String deviceId,
    }) async {
      if (throwOn != null) throw throwOn;
      return MediaServerLoginResult(
        accessToken: 'token-$username',
        userId: 'user-$username',
        username: username,
      );
    };
  }

  MediaServerAuth buildAuth({MediaServerProbe? probe, MediaServerAuthenticator? login}) {
    return MediaServerAuth(
      storage: tokenStorage,
      box: box,
      prefs: prefs,
      probe: probe ?? fakeProbe(),
      authenticate: login ?? fakeLogin(),
    );
  }

  group('addServer', () {
    test('探测后预填别名并持久化', () async {
      final auth = buildAuth();
      final info = await auth.addServer('http://192.168.1.10:8096/');
      expect(info.type, ServerType.jellyfin);
      expect(info.baseUrl, 'http://192.168.1.10:8096');
      expect(info.name, 'NAS 媒体库');
      expect(info.loggedIn, isFalse);
      expect(auth.servers, hasLength(1));
    });

    test('ServerName 缺省回退地址', () async {
      final auth = MediaServerAuth(
        storage: tokenStorage,
        box: box,
        prefs: prefs,
        probe: fakeProbe(serverName: ''),
        authenticate: fakeLogin(),
      );
      final info = await auth.addServer('http://nas:8096');
      expect(info.name, 'http://nas:8096');
    });

    test('重复地址拒绝', () async {
      final auth = buildAuth();
      await auth.addServer('http://nas:8096');
      expect(
        () => auth.addServer('http://nas:8096'),
        throwsStateError,
      );
    });

    test('空地址报参数错误', () async {
      final auth = buildAuth();
      expect(() => auth.addServer('   '), throwsArgumentError);
    });

    test('探测失败原样上抛且不落库', () async {
      final auth = MediaServerAuth(
        storage: tokenStorage,
        box: box,
        prefs: prefs,
        probe: fakeProbe(throwOn: const MediaServerApiException(null, 'timeout')),
        authenticate: fakeLogin(),
      );
      await expectLater(
        auth.addServer('http://nas:8096'),
        throwsA(isA<MediaServerApiException>()),
      );
      expect(auth.servers, isEmpty);
    });
  });

  group('login', () {
    test('token 进安全存储，userId/username 回写持久化', () async {
      final auth = buildAuth();
      final info = await auth.addServer('http://nas:8096');
      await auth.login(info.id, 'alice', 'secret');

      expect(tokenStorage.store['media_server_token_${info.id}'], 'token-alice');
      expect(auth.servers.single.loggedIn, isTrue);
      expect(auth.servers.single.userId, 'user-alice');
      expect(auth.servers.single.username, 'alice');
    });

    test('未知服务器 id 报错', () async {
      final auth = buildAuth();
      expect(
        () => auth.login('nope', 'a', 'b'),
        throwsStateError,
      );
    });

    test('凭证错误上抛且不落 token', () async {
      final auth = MediaServerAuth(
        storage: tokenStorage,
        box: box,
        prefs: prefs,
        probe: fakeProbe(),
        authenticate: fakeLogin(
          throwOn: const MediaServerApiException(401, 'bad credentials'),
        ),
      );
      final info = await auth.addServer('http://nas:8096');
      await expectLater(
        auth.login(info.id, 'alice', 'wrong'),
        throwsA(isA<MediaServerApiException>()),
      );
      expect(tokenStorage.store['media_server_token_${info.id}'], isNull);
      expect(auth.servers.single.loggedIn, isFalse);
    });
  });

  group('removeServer', () {
    test('清档案并清 token', () async {
      final auth = buildAuth();
      final info = await auth.addServer('http://nas:8096');
      await auth.login(info.id, 'alice', 'secret');
      await auth.removeServer(info.id);

      expect(auth.servers, isEmpty);
      expect(box.get(info.id), isNull);
      expect(tokenStorage.store['media_server_token_${info.id}'], isNull);
    });
  });

  group('statusOf', () {
    test('未登录 → needRelogin', () async {
      final auth = buildAuth();
      final info = await auth.addServer('http://nas:8096');
      expect(await auth.statusOf(info.id), MediaServerStatus.needRelogin);
    });

    test('已登录且探测成功 → ok', () async {
      final auth = buildAuth();
      final info = await auth.addServer('http://nas:8096');
      await auth.login(info.id, 'alice', 'secret');
      expect(await auth.statusOf(info.id), MediaServerStatus.ok);
    });

    test('已登录但探测网络失败 → offline', () async {
      var failProbe = false;
      final auth = MediaServerAuth(
        storage: tokenStorage,
        box: box,
        prefs: prefs,
        probe: (String baseUrl) async {
          if (failProbe) {
            throw const MediaServerApiException(503, 'down');
          }
          return const MediaServerProbeResult(type: ServerType.jellyfin);
        },
        authenticate: fakeLogin(),
      );
      final info = await auth.addServer('http://nas:8096');
      await auth.login(info.id, 'alice', 'secret');
      failProbe = true;
      expect(await auth.statusOf(info.id), MediaServerStatus.offline);
    });

    test('已登录但探测 401 → needRelogin', () async {
      var failProbe = false;
      final auth = MediaServerAuth(
        storage: tokenStorage,
        box: box,
        prefs: prefs,
        probe: (String baseUrl) async {
          if (failProbe) {
            throw const MediaServerApiException(401, 'stale token');
          }
          return const MediaServerProbeResult(type: ServerType.jellyfin);
        },
        authenticate: fakeLogin(),
      );
      final info = await auth.addServer('http://nas:8096');
      await auth.login(info.id, 'alice', 'secret');
      failProbe = true;
      expect(await auth.statusOf(info.id), MediaServerStatus.needRelogin);
    });
  });

  group('deviceId', () {
    test('首次生成并持久化，重建实例后复用', () async {
      final auth = buildAuth();
      final id1 = await auth.deviceId();
      expect(id1, isNotEmpty);

      final auth2 = buildAuth();
      final id2 = await auth2.deviceId();
      expect(id2, id1);
    });
  });

  group('持久化往返（模拟杀进程重进）', () {
    test('新实例 init 后档案与登录态完整恢复', () async {
      final auth = buildAuth();
      final info = await auth.addServer('http://nas:8096');
      await auth.login(info.id, 'alice', 'secret');

      // 模拟进程重启：同一 box / 同一存储，新建管理器实例。
      final auth2 = buildAuth();
      await auth2.init();
      expect(auth2.servers, hasLength(1));
      expect(auth2.servers.single.id, info.id);
      expect(auth2.servers.single.baseUrl, 'http://nas:8096');
      expect(auth2.servers.single.loggedIn, isTrue);
      expect(
        await auth2.tokenOf(info.id),
        'token-alice',
      );
    });
  });
}

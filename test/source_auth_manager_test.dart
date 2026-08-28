import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/auth/source_auth_manager.dart';
import 'package:nexhub/core/models/plugin_config.dart';
import 'package:nexhub/core/scraper/verification_detector.dart';

PluginConfig buildSource({Map<String, dynamic>? login}) =>
    PluginConfig.fromJson(<String, dynamic>{
      'id': 'pms_example',
      'name': 'example',
      'type': 'animeSource',
      'site': {'baseUrl': 'https://example.com'},
      'parser': {'type': 'builtin'},
      'routes': {
        'latest': {'url': '/latest?page={page}'},
      },
      'comments': {
        'routes': {
          'list': {'url': '/comments/{id}'},
        },
        if (login != null) 'login': login,
      },
    });

void main() {
  group('SourceAuthManager checkCookie 快速判定', () {
    test('Cookie 头出现 checkCookie 键名判已登录', () {
      final cookies = <String, String>{
        'example.com': 'sess=abc; user_token=xyz; theme=dark',
      };
      final manager = SourceAuthManager(
        cookieHeader: (host) => cookies[host],
        cookieVersions: const Stream<int>.empty(),
        clearCookies: (_) {},
        probe: (url, {referer}) async => '',
      );
      final source = buildSource(login: <String, dynamic>{
        'url': 'https://example.com/login',
        'checkCookie': 'user_token',
      });
      expect(manager.isLoggedIn(source), isTrue);
      manager.dispose();
    });

    test('键名未命中 / 仅值里出现该串 判未登录', () {
      final cookies = <String, String>{
        // 值里含 "user_token=" 字样但键名不匹配，不得误判。
        'example.com': 'sess=user_tokenX; other=user_token',
      };
      final manager = SourceAuthManager(
        cookieHeader: (host) => cookies[host],
        cookieVersions: const Stream<int>.empty(),
        clearCookies: (_) {},
        probe: (url, {referer}) async => '',
      );
      final source = buildSource(login: <String, dynamic>{
        'checkCookie': 'user_token',
      });
      expect(manager.isLoggedIn(source), isFalse);
      manager.dispose();
    });

    test('登录页 host 与站点 host 不同时也参与匹配', () {
      final cookies = <String, String>{
        'passport.example.net': 'user_token=1',
      };
      final manager = SourceAuthManager(
        cookieHeader: (host) => cookies[host],
        cookieVersions: const Stream<int>.empty(),
        clearCookies: (_) {},
        probe: (url, {referer}) async => '',
      );
      final source = buildSource(login: <String, dynamic>{
        'url': 'https://passport.example.net/login',
        'checkCookie': 'user_token',
      });
      expect(manager.isLoggedIn(source), isTrue);
      manager.dispose();
    });

    test('未声明 comments.login 恒未登录', () {
      final manager = SourceAuthManager(
        cookieHeader: (_) => 'user_token=1',
        cookieVersions: const Stream<int>.empty(),
        clearCookies: (_) {},
        probe: (url, {referer}) async => '',
      );
      expect(manager.isLoggedIn(buildSource()), isFalse);
      manager.dispose();
    });
  });

  group('SourceAuthManager cookieVersion 重评估', () {
    test('Cookie 变化触发已关注源重新评估并广播', () async {
      final cookies = <String, String>{};
      final versions = StreamController<int>();
      final manager = SourceAuthManager(
        cookieHeader: (host) => cookies[host],
        cookieVersions: versions.stream,
        clearCookies: (_) {},
        probe: (url, {referer}) async => '',
      );
      var notified = 0;
      manager.addListener(() => notified++);
      final source = buildSource(login: <String, dynamic>{
        'checkCookie': 'user_token',
      });

      expect(manager.isLoggedIn(source), isFalse); // 关注 + 缓存 false

      // WebView 登录回灌 Cookie → 版本广播 → 重评估为已登录。
      cookies['example.com'] = 'user_token=xyz';
      versions.add(1);
      await Future<void>.delayed(Duration.zero);
      expect(manager.isLoggedIn(source), isTrue);
      expect(notified, 1);

      // Cookie 被清除 → 回到未登录。
      cookies.clear();
      versions.add(2);
      await Future<void>.delayed(Duration.zero);
      expect(manager.isLoggedIn(source), isFalse);
      expect(notified, 2);

      // 无变化的广播不重复通知。
      versions.add(3);
      await Future<void>.delayed(Duration.zero);
      expect(notified, 2);

      manager.dispose();
      await versions.close();
    });
  });

  group('SourceAuthManager refreshLoginState / checkUrl 探测', () {
    test('checkUrl + loggedInSelector 命中确认登录', () async {
      final probed = <String>[];
      final manager = SourceAuthManager(
        cookieHeader: (_) => 'user_token=1',
        cookieVersions: const Stream<int>.empty(),
        clearCookies: (_) {},
        probe: (url, {referer}) async {
          probed.add(url);
          return '{"data": {"username": "yukai"}}';
        },
      );
      final source = buildSource(login: <String, dynamic>{
        'checkCookie': 'user_token',
        'checkUrl': '/api/user/me',
        'loggedInSelector': r'$.data.username',
      });

      expect(await manager.refreshLoginState(source), isTrue);
      expect(probed.single, 'https://example.com/api/user/me');
      expect(manager.isLoggedIn(source), isTrue);
      manager.dispose();
    });

    test('探测选择器未命中 → 会话失效判未登录', () async {
      final manager = SourceAuthManager(
        cookieHeader: (_) => 'user_token=stale',
        cookieVersions: const Stream<int>.empty(),
        clearCookies: (_) {},
        probe: (url, {referer, headers}) async => '{"data": {}}',
      );
      final source = buildSource(login: <String, dynamic>{
        'checkCookie': 'user_token',
        'checkUrl': '/api/user/me',
        'loggedInSelector': r'$.data.username',
      });
      expect(await manager.refreshLoginState(source), isFalse);
      expect(manager.isLoggedIn(source), isFalse);
      manager.dispose();
    });

    test('探测请求 401 判未登录', () async {
      final manager = SourceAuthManager(
        cookieHeader: (_) => 'user_token=stale',
        cookieVersions: const Stream<int>.empty(),
        clearCookies: (_) {},
        probe: (url, {referer, headers}) =>
            Future<String>.error(const HttpStatusException(url: 'u', statusCode: 401)),
      );
      final source = buildSource(login: <String, dynamic>{
        'checkCookie': 'user_token',
        'checkUrl': '/api/user/me',
      });
      expect(await manager.refreshLoginState(source), isFalse);
      manager.dispose();
    });

    test('Cookie 快速路径未命中时跳过探测直接 false', () async {
      var probes = 0;
      final manager = SourceAuthManager(
        cookieHeader: (_) => null,
        cookieVersions: const Stream<int>.empty(),
        clearCookies: (_) {},
        probe: (url, {referer}) async {
          probes++;
          return '{"data": {"username": "x"}}';
        },
      );
      final source = buildSource(login: <String, dynamic>{
        'checkCookie': 'user_token',
        'checkUrl': '/api/user/me',
        'loggedInSelector': r'$.data.username',
      });
      expect(await manager.refreshLoginState(source), isFalse);
      expect(probes, 0);
      manager.dispose();
    });

    test('未声明 checkCookie 时以探测结果为准', () async {
      final manager = SourceAuthManager(
        cookieHeader: (_) => null,
        cookieVersions: const Stream<int>.empty(),
        clearCookies: (_) {},
        probe: (url, {referer}) async => '{"data": {"username": "x"}}',
      );
      final source = buildSource(login: <String, dynamic>{
        'checkUrl': '/api/user/me',
        'loggedInSelector': r'$.data.username',
      });
      expect(await manager.refreshLoginState(source), isTrue);
      manager.dispose();
    });
  });

  group('SourceAuthManager logout', () {
    test('logout 清除相关 host Cookie 并置未登录', () async {
      final cookies = <String, String>{
        'example.com': 'user_token=1',
        'passport.example.net': 'user_token=1',
        'other.com': 'keep=1',
      };
      final cleared = <String>[];
      final manager = SourceAuthManager(
        cookieHeader: (host) => cookies[host],
        cookieVersions: const Stream<int>.empty(),
        clearCookies: (host) {
          cleared.add(host);
          cookies.remove(host);
        },
        probe: (url, {referer}) async => '',
      );
      final source = buildSource(login: <String, dynamic>{
        'url': 'https://passport.example.net/login',
        'checkCookie': 'user_token',
      });
      var notified = 0;
      manager.addListener(() => notified++);

      expect(manager.isLoggedIn(source), isTrue);
      await manager.logout(source);

      expect(cleared, containsAll(['example.com', 'passport.example.net']));
      expect(cleared, isNot(contains('other.com'))); // 仅清该源相关域
      expect(manager.isLoggedIn(source), isFalse);
      expect(notified, 1);
      manager.dispose();
    });
  });
}

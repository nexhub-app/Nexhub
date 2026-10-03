// 引擎 A（用户拍板 1.A）：无 body 的纯硬 403 在验证提示前退避重试。
//
// HttpFetcher 是单例+私有构造，测试通过 loopback HttpServer 发起真实 HTTP：
// TestWidgetsFlutterBinding 默认装「假 HttpClient」挡真实联网，
// `HttpOverrides.global = null` 恢复（同 debug_source_probe_test 范式）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/scraper/http_fetcher.dart';
import 'package:nexhub/core/scraper/verification_detector.dart';
import 'package:nexhub/core/services/config_loader.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(<String, Object>{});

  setUpAll(() {
    // 恢复真实网络：flutter test 的绑定默认全局假 HttpClient（一律 400）。
    HttpOverrides.global = null;
    // 关掉隐身延迟，测试不必等 300~1100ms 随节拍（退避时长由 403 分支自证）。
    ConfigLoader.instance.setStealthMode(false);
  });

  setUp(() {
    // 单例跨测试污染清理：所有用例的 host 都是 127.0.0.1（端口不属于 host），
    // 上一个测试抛 VerificationRequiredException 前会写入 20s 验证冷却并残留。
    // 写入「已过期」冷却，_throttleHost 会在到期清理路径上立即移除它
    // （HttpFetcher 无公开清空 API，setVerifyCooldown 是测试可见接口）。
    HttpFetcher.instance.setVerifyCooldown(
      '127.0.0.1',
      DateTime.now().subtract(const Duration(seconds: 1)),
    );
  });

  /// 起一个按脚本应答的 loopback 服务器，返回 (url, 关闭钩子)。
  /// 脚本耗尽后持续重复最后一步（持续失败场景无需枚举无数条）。
  Future<(String, Future<void> Function())> startServer(
    List<({int status, String body})> script,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var i = 0;
    server.listen((req) async {
      final idx = i < script.length ? i : script.length - 1;
      i++;
      final step = script[idx];
      req.response.statusCode = step.status;
      req.response.headers.set('content-type', 'text/html; charset=utf-8');
      // 用 add 写真字节；write() 会对参数 toString()，把空字节列表写成 "[]"，
      // 使「无 body 403」变成非空幻影体，破坏重试语义。
      req.response.add(utf8.encode(step.body));
      await req.response.close();
    });
    return (
      'http://127.0.0.1:${server.port}/probe',
      () async {
        await server.close(force: true);
      }
    );
  }

  test('纯 403（无 body）：退避重试后放行，不再抛验证异常', () async {
    final (url, close) = await startServer(const [
      (status: 403, body: ''),
      (status: 403, body: ''),
      (status: 200, body: '<html><body>ok</body></html>'),
    ]);
    try {
      final sw = Stopwatch()..start();
      final body = await HttpFetcher.instance.getHtml(url);
      sw.stop();
      expect(body, contains('ok'));
      // 两次递增退避（1500+ 与 3000+ 毫秒）至少应耗 ~4s。
      expect(sw.elapsed.inMilliseconds, greaterThan(3500));
      expect(sw.elapsed.inMilliseconds, lessThan(15000));
      // 冷却清理：重试成功后同站紧随请求不被 20s 验证冷却拖住。
      final sw2 = Stopwatch()..start();
      await HttpFetcher.instance.getHtml(url);
      sw2.stop();
      expect(sw2.elapsed.inMilliseconds, lessThan(3000));
    } finally {
      await close();
    }
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('403 持续失败：重试耗尽后仍抛 VerificationRequiredException', () async {
    final (url, close) = await startServer(
      List.filled(6, const (status: 403, body: '')),
    );
    try {
      final sw = Stopwatch()..start();
      await expectLater(
        HttpFetcher.instance.getHtml(url),
        throwsA(
          isA<VerificationRequiredException>()
              .having((e) => e.statusCode, 'statusCode', 403)
              .having((e) => e.body, 'body', ''),
        ),
      );
      sw.stop();
      // 3 次尝试 + 2 次退避 ≈ 4.5s+jitter。
      expect(sw.elapsed.inMilliseconds, greaterThan(3500));
    } finally {
      await close();
    }
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('403 带挑战体（turnstile）：不重试，立即抛验证异常', () async {
    final (url, close) = await startServer(const [
      (status: 403, body: '<form>turnstile</form>'),
      (status: 200, body: 'SHOULD_NOT_SERVE'),
    ]);
    try {
      final sw = Stopwatch()..start();
      await expectLater(
        HttpFetcher.instance.getHtml(url),
        throwsA(
          isA<VerificationRequiredException>()
              .having((e) => e.statusCode, 'statusCode', 403),
        ),
      );
      sw.stop();
      // 无退避：应远快于 403 重试路径（节流下限 ~800ms）。
      expect(sw.elapsed.inMilliseconds, lessThan(3000));
    } finally {
      await close();
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('401：不重试，立即抛验证异常', () async {
    final (url, close) = await startServer(const [
      (status: 401, body: ''),
      (status: 200, body: 'SHOULD_NOT_SERVE'),
    ]);
    try {
      await expectLater(
        HttpFetcher.instance.getHtml(url),
        throwsA(
          isA<VerificationRequiredException>()
              .having((e) => e.statusCode, 'statusCode', 401),
        ),
      );
    } finally {
      await close();
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('首次即 200：零退避直通（回归保护）', () async {
    final (url, close) = await startServer(const [
      (status: 200, body: '<html><body>fast</body></html>'),
    ]);
    try {
      final sw = Stopwatch()..start();
      final body = await HttpFetcher.instance.getHtml(url);
      sw.stop();
      expect(body, contains('fast'));
      expect(sw.elapsed.inMilliseconds, lessThan(3000));
    } finally {
      await close();
    }
  }, timeout: const Timeout(Duration(seconds: 30)));
}

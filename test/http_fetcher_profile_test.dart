// HttpFetcher 多档案相关的公开行为测试。
//
// 说明：`_dioFor` / `_createDio` 为私有，无法直接断言档案隔离；这里验证
// 公开的 `rebuildAll()` 幂等、不抛异常，且单例稳定（配置变更后连接池重建
// 不影响 UA 等确定性行为）。不发起真实网络请求。
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/scraper/http_fetcher.dart';

void main() {
  group('HttpFetcher.rebuildAll', () {
    test('多次调用幂等，不抛异常', () {
      expect(() => HttpFetcher.instance.rebuildAll(), returnsNormally);
      expect(() => HttpFetcher.instance.rebuildAll(), returnsNormally);
    });

    test('rebuildAll 后 UA 选择仍确定（同 host 恒定）', () {
      const url = 'https://profile-test.example.com/a';
      final before = HttpFetcher.instance.userAgentForUrl(url);
      HttpFetcher.instance.rebuildAll();
      final after = HttpFetcher.instance.userAgentForUrl(url);
      expect(after, before); // 连接池重建不改变每 host 指纹
    });
  });

  group('HttpFetcher 静态覆盖 API 兼容', () {
    tearDown(() {
      // 复位静态状态，避免影响其他测试。
      HttpFetcher.setForceDirect(false);
      HttpFetcher.setProxy(null);
    });

    test('setForceDirect 触发重建不抛异常', () {
      expect(() => HttpFetcher.setForceDirect(true), returnsNormally);
      expect(HttpFetcher.forceDirect, isTrue);
    });

    test('setProxy 触发重建不抛异常', () {
      expect(() => HttpFetcher.setProxy('127.0.0.1:7890'), returnsNormally);
      expect(HttpFetcher.proxy, '127.0.0.1:7890');
    });
  });
}

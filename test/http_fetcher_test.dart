/// HttpFetcher 单元测试：UA 一致性 + 验证冷却对闸门间隔的影响。
///
/// 不发起真实网络请求，仅断言公开行为（[userAgentForUrl] 稳定、[runGate] 受
/// 验证冷却延长）。
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/scraper/http_fetcher.dart';

void main() {
  group('HttpFetcher.userAgentForUrl', () {
    test('同一 host 多次取 UA 完全一致（防验证死循环的关键）', () {
      const url1 = 'https://www.huanmengacg.com/book/1';
      const url2 = 'https://www.huanmengacg.com/book/2';
      final a = HttpFetcher.instance.userAgentForUrl(url1);
      final b = HttpFetcher.instance.userAgentForUrl(url2);
      expect(a, isA<String>());
      expect(a, isNotEmpty);
      // 同一 host 必须恒定，否则反爬把 Cookie 绑定到 UA+IP 会失效 → 验证循环。
      expect(a, equals(b));
    });

    test('返回的是合法 UA 字符串（含 Mozilla/Chrome 标记）', () {
      final ua = HttpFetcher.instance.userAgentForUrl('https://foo.bar/x');
      expect(ua, contains('Mozilla'));
      expect(ua, contains('Chrome'));
    });
  });

  group('HttpFetcher 验证冷却', () {
    test('命中验证冷却时闸门间隔被显著延长', () async {
      const host = 'cooldown.example.com';
      final url = 'https://$host/path';

      // 无冷却的基��（该 host 此前无记录，应几乎无延迟）。
      final base = Stopwatch()..start();
      await HttpFetcher.instance.runGate(url);
      final baseElapsed = base.elapsed;

      // 写入一个近未来（800ms）的验证冷却，再走一次闸门。
      HttpFetcher.instance.setVerifyCooldown(
        host,
        DateTime.now().add(const Duration(milliseconds: 800)),
      );
      final delayed = Stopwatch()..start();
      await HttpFetcher.instance.runGate(url);
      final delayedElapsed = delayed.elapsed;

      // 冷却必须让间隔明显变长（证明负缓存生效，验证期间不会继续高频打站）。
      expect(
        delayedElapsed.inMilliseconds,
        greaterThan(baseElapsed.inMilliseconds + 500),
      );
    });

    test('冷却到期后被清理，不再延长间隔', () async {
      const host = 'cooldown2.example.com';
      final url = 'https://$host/path';
      HttpFetcher.instance.setVerifyCooldown(
        host,
        DateTime.now().subtract(const Duration(seconds: 1)),
      );
      final sw = Stopwatch()..start();
      await HttpFetcher.instance.runGate(url);
      // 已到期的冷却不阻塞（仅受可能的最小间隔约束，远小于 1 秒）。
      expect(sw.elapsed.inMilliseconds, lessThan(1000));
    });
  });
}

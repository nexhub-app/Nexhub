import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/scraper/verification_detector.dart';

void main() {
  group('VerificationDetector', () {
    test('401 / 403 always require verification', () {
      expect(
        VerificationDetector.isVerificationRequired(statusCode: 401, body: 'x'),
        isTrue,
      );
      expect(
        VerificationDetector.isVerificationRequired(statusCode: 403, body: 'x'),
        isTrue,
      );
    });

    test('503 with Cloudflare challenge feature requires verification', () {
      const body = '<html><body>cf-ray: 123</body></html>';
      expect(
        VerificationDetector.isVerificationRequired(statusCode: 503, body: body),
        isTrue,
      );
    });

    test('200 with __cf_chl challenge feature requires verification', () {
      const body = 'please wait <div class="__cf_chl"></div>';
      expect(
        VerificationDetector.isVerificationRequired(statusCode: 200, body: body),
        isTrue,
      );
    });

    test('fsdm02 slider guard page requires verification', () {
      const body = '<script src="/_guard/slide.js"></script>';
      expect(
        VerificationDetector.isVerificationRequired(statusCode: 200, body: body),
        isTrue,
      );
    });

    test('normal 200 page does not require verification', () {
      const body = '<html><body>hello world</body></html>';
      expect(
        VerificationDetector.isVerificationRequired(statusCode: 200, body: body),
        isFalse,
      );
    });

    // ---- 笔趣阁（Cloudflare 反代）回归：正常页含被动标记不得误判 ----

    test(
        'biquge-style normal page (passive CF marker + full of chapter links, '
        '>8KB) must NOT require verification', () {
      // 实测 m.biqubu3.com 正常页（首页 17KB / 书页 8.3KB / 章节页 12.8KB）均含
      // challenge-platform 被动标记；体积超过挑战壳长度闸门（8192）→ 必须
      // 放行，否则从历史进入详情页会被误判进验证循环。
      final links = StringBuffer();
      for (var i = 1; i <= 200; i++) {
        links.writeln('<a href="/book_18093/$i.html">第$i章 章节标题占位内容</a>');
      }
      final body = '<html><head>'
          '<script src="/cdn-cgi/challenge-platform/scripts/jsd/main.js">'
          '</script></head><body><div class="chapterlist">$links</div>'
          '</body></html>';
      // 前置断言：构造页体量与实测正常页一致（超过挑战壳长度闸门）。
      expect(body.trim().length, greaterThan(8192));
      expect(
        VerificationDetector.isVerificationRequired(statusCode: 200, body: body),
        isFalse,
      );
    });

    test('200 short challenge shell with passive CF marker requires '
        'verification', () {
      // 真正的 CF 临时挑战壳：只有几 KB 的等待/重定向壳 + 被动标记 → 判验证。
      const body = '<html><head>'
          '<script src="/cdn-cgi/challenge-platform/h/b/orchestrate/jsch/v1">'
          '</script></head><body>please wait while we check your browser'
          '</body></html>';
      expect(
        VerificationDetector.isVerificationRequired(statusCode: 200, body: body),
        isTrue,
      );
    });

    test('503 without challenge feature does not require verification', () {
      const body = '<html><body>service unavailable</body></html>';
      expect(
        VerificationDetector.isVerificationRequired(statusCode: 503, body: body),
        isFalse,
      );
    });

    // ---- WAF「拦截应答」检测（cycani / girigirilove: 200 + body="closed"）----

    test('200 with body exactly "closed" requires verification (Edge WAF)', () {
      expect(
        VerificationDetector.isVerificationRequired(
            statusCode: 200, body: 'closed'),
        isTrue,
      );
    });

    test('body "closed" with surrounding whitespace/case still matches', () {
      expect(
        VerificationDetector.isVerificationRequired(
            statusCode: 200, body: '  CLOSED\n'),
        isTrue,
      );
    });

    test('normal content containing the word "closed" is NOT verification', () {
      // 关键防误伤：正常页面里出现 closed 一词不能触发验证死循环。
      const body =
          '<html><body><span class="status">已完结 closed</span></body></html>';
      expect(
        VerificationDetector.isVerificationRequired(statusCode: 200, body: body),
        isFalse,
      );
    });

    test('short non-JSON body + Edge WAF Server header requires verification',
        () {
      expect(
        VerificationDetector.isVerificationRequired(
          statusCode: 200,
          body: 'denied',
          headers: {'Server': 'Edge/1.1.18'},
        ),
        isTrue,
      );
    });

    test('valid JSON body + Edge Server header is NOT verification', () {
      // 同一 WAF 放行后返回的正常大 JSON 不能被误判。
      const body =
          '{"code":1,"msg":"数据列表","page":1,"list":[{"vod_id":1,"vod_name":"x"}]}';
      expect(
        VerificationDetector.isVerificationRequired(
          statusCode: 200,
          body: body,
          headers: {'server': 'Edge/1.1.18'},
        ),
        isFalse,
      );
    });
  });
}

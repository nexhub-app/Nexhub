/// PublishPageMirrorExtractor 单元测试。
///
/// 只覆盖纯解析方法 [PublishPageMirrorExtractor.extractFromHtml]，
/// 不触网（[extract] 走 HttpFetcher 真实网络，由 http_fetcher_test 覆盖）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/models/plugin_config.dart';
import 'package:nexhub/core/scraper/publish_page_mirror_extractor.dart';

void main() {
  group('PublishPageMirrorExtractor.extractFromHtml', () {
    final extractor = PublishPageMirrorExtractor();

    test('空 HTML 返回空列表', () {
      expect(extractor.extractFromHtml(''), isEmpty);
      expect(extractor.extractFromHtml('   '), isEmpty);
    });

    test('通用兜底：从 HTML 提取所有 http(s) 绝对链接并按 host 去重', () {
      const html = '''
<html><body>
  <a href="https://mirror1.example.com/">镜像1</a>
  <a href="https://mirror2.example.com/path?q=1">镜像2</a>
  <a href="https://mirror1.example.com/other">同 host 不同路径（应去重）</a>
  <a href="ftp://not-http.example.com/">非 http（应忽略）</a>
  <a href="/relative/path">相对路径（应忽略）</a>
</body></html>
''';
      final result = extractor.extractFromHtml(html);
      expect(result, hasLength(2));
      final baseUrls = result.map((m) => m.baseUrl).toSet();
      expect(baseUrls, contains('https://mirror1.example.com'));
      expect(baseUrls, contains('https://mirror2.example.com'));
      // name/domain 由 host 推导。
      for (final m in result) {
        expect(m.name, m.domain);
        expect(m.baseUrl.startsWith('https://'), isTrue);
      }
    });

    test('排除与发布页同 host 的链接', () {
      const html = '''
<a href="https://publish.example.com/">发布页自身（应排除）</a>
<a href="https://mirror.example.com/">镜像（应保留）</a>
''';
      final result = extractor.extractFromHtml(
        html,
        publishPageUrl: 'https://publish.example.com/',
      );
      expect(result, hasLength(1));
      expect(result.first.baseUrl, 'https://mirror.example.com');
    });

    test('host 比较大小写不敏感', () {
      const html = '''
<a href="https://PUBLISH.example.com/">大写 host 同发布页（应排除）</a>
<a href="https://mirror.example.com/">镜像（应保留）</a>
''';
      final result = extractor.extractFromHtml(
        html,
        publishPageUrl: 'https://publish.example.com/',
      );
      expect(result, hasLength(1));
      expect(result.first.baseUrl, 'https://mirror.example.com');
    });

    test('正则选择器：优先取首个捕获组', () {
      // 模拟发布页用 JS 写入变量：`var url = "https://a.example.com";`
      const html = '''
<script>
  var url1 = "https://a.example.com";
  var url2 = "https://b.example.com";
  var note = "not a url";
</script>
''';
      final result = extractor.extractFromHtml(
        html,
        selector: r'/var \w+ = "(https?:\/\/[^"]+)"/',
      );
      expect(result, hasLength(2));
      final baseUrls = result.map((m) => m.baseUrl).toSet();
      expect(baseUrls, contains('https://a.example.com'));
      expect(baseUrls, contains('https://b.example.com'));
    });

    test('正则编译失败时回退通用提取', () {
      const html = '<a href="https://mirror.example.com/">镜像</a>';
      // 非法正则：未闭合分组
      final result = extractor.extractFromHtml(
        html,
        selector: '/(unclosed',
      );
      expect(result, hasLength(1));
      expect(result.first.baseUrl, 'https://mirror.example.com');
    });

    test('正则未命中时回退通用提取', () {
      const html = '<a href="https://mirror.example.com/">镜像</a>';
      final result = extractor.extractFromHtml(
        html,
        selector: r'/never-matches-\d+/',
      );
      expect(result, hasLength(1));
      expect(result.first.baseUrl, 'https://mirror.example.com');
    });

    test('去除 URL 尾部粘连标点', () {
      const html = '''
<a href="https://a.example.com/path,">逗号</a>
<a href="https://b.example.com/x).">右括号点</a>
''';
      final result = extractor.extractFromHtml(html);
      expect(result, hasLength(2));
      final baseUrls = result.map((m) => m.baseUrl).toSet();
      expect(baseUrls, contains('https://a.example.com'));
      expect(baseUrls, contains('https://b.example.com'));
    });

    test('不含 http(s) 链接的 HTML 返回空列表', () {
      const html = '<html><body>纯文本，无链接</body></html>';
      expect(extractor.extractFromHtml(html), isEmpty);
    });

    test('返回的 MirrorConfig 字段完整且可序列化', () {
      const html = '<a href="https://mirror.example.com/">镜像</a>';
      final result = extractor.extractFromHtml(html);
      expect(result, hasLength(1));
      final m = result.first;
      expect(m.name, 'mirror.example.com');
      expect(m.domain, 'mirror.example.com');
      expect(m.baseUrl, 'https://mirror.example.com');
      // 序列化往返一致性。
      final json = m.toJson();
      expect(MirrorConfig.fromJson(json).baseUrl, m.baseUrl);
    });
  });
}

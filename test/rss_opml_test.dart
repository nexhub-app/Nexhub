/// OPML 导入 / 导出解析测试。
///
/// 重点回归「导入显示无可导入的内容」：标准 OPML 的 type 属性写短词
/// `rss`（不是 MIME），此前被按 MIME 集合校验全部跳过。
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/rss/rss_feed.dart';
import 'package:nexhub/core/rss/rss_opml.dart';

void main() {
  group('RssOpml.parse', () {
    /// 主流阅读器导出的标准形态：type="rss" 短词 + 分组节点。
    const standardOpml = '''<?xml version="1.0" encoding="UTF-8"?>
<opml version="2.0">
  <head><title>My subscriptions</title></head>
  <body>
    <outline text="科技" title="科技">
      <outline type="rss" text="阮一峰" title="阮一峰"
        xmlUrl="https://ruanyifeng.com/feed.xml" htmlUrl="https://ruanyifeng.com"/>
      <outline type="rss" text="Hacker News" xmlUrl="https://hnrss.org/frontpage"/>
    </outline>
    <outline type="rss" text="少数派" xmlUrl="https://sspai.com/feed"/>
  </body>
</opml>''';

    test('标准导出（type="rss"）不再被判为无可导入内容', () {
      final r = RssOpml.parse(standardOpml);
      expect(r.entries, hasLength(3));
      expect(r.skipped, 0);
      expect(r.entries[0].title, '阮一峰');
      expect(r.entries[0].category, '科技');
      expect(r.entries[1].category, '科技');
      expect(r.entries[2].category, isNull);
    });

    test('属性大小写容错（xmlurl / TEXT）', () {
      final r = RssOpml.parse('''<opml version="2.0"><body>
        <outline type="rss" TEXT="小写属性" xmlurl="https://a.example/feed"/>
      </body></opml>''');
      expect(r.entries, hasLength(1));
      expect(r.entries.single.title, '小写属性');
      expect(r.entries.single.xmlUrl, 'https://a.example/feed');
    });

    test('UTF-8 BOM 不导致解析失败', () {
      final r = RssOpml.parse('\uFEFF$standardOpml');
      expect(r.entries, hasLength(3));
    });

    test('按 xmlUrl 去重，缺 xmlUrl 的空节点计入 skipped', () {
      final r = RssOpml.parse('''<opml version="2.0"><body>
        <outline type="rss" text="A" xmlUrl="https://a.example/feed"/>
        <outline type="rss" text="A 重复" xmlUrl="https://a.example/feed"/>
        <outline text="空节点"/>
      </body></opml>''');
      expect(r.entries, hasLength(1));
      expect(r.skipped, 1);
    });

    test('feed 节点自带子级时一并递归', () {
      final r = RssOpml.parse('''<opml version="2.0"><body>
        <outline type="rss" text="父源" xmlUrl="https://p.example/feed">
          <outline type="rss" text="子源" xmlUrl="https://c.example/feed"/>
        </outline>
      </body></opml>''');
      expect(r.entries.map((e) => e.title), containsAll(<String>['父源', '子源']));
    });

    test('空文本 / 无 body 抛 FormatException', () {
      expect(() => RssOpml.parse('   '), throwsFormatException);
      expect(() => RssOpml.parse('<opml version="2.0"></opml>'),
          throwsFormatException);
      expect(() => RssOpml.parse('not xml at all'), throwsFormatException);
    });
  });

  group('RssOpml.build + parse 往返', () {
    test('导出的 OPML 可被自身解析还原（分组保留）', () {
      final feeds = <RssFeed>[
        RssFeed(
          id: '1',
          url: 'https://a.example/feed',
          title: '源A',
          groups: <String>['科技', '日更'],
          addedAt: DateTime.now().millisecondsSinceEpoch,
        ),
        RssFeed(
          id: '2',
          url: 'https://b.example/feed',
          title: '源B',
          addedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      ];
      final xml = RssOpml.build(feeds, docTitle: 'roundtrip');
      final r = RssOpml.parse(xml);
      // 源A 的两次出现（两分组）聚合为一条目，分组取并集。
      expect(r.entries, hasLength(2));
      final a = r.entries.singleWhere((e) => e.xmlUrl == 'https://a.example/feed');
      expect(a.categories, containsAll(<String>['科技', '日更']));
      expect(r.entries.any((e) => e.xmlUrl == 'https://b.example/feed'), isTrue);
    });
  });
}

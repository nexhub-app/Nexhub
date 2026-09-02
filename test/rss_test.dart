import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/comic/models/reader_preferences.dart';
import 'package:nexhub/core/models/plugin_config.dart';
import 'package:nexhub/core/rss/rss_article_store.dart';
import 'package:nexhub/core/rss/rss_feed.dart';
import 'package:nexhub/core/rss/rss_manager.dart';
import 'package:nexhub/core/rss/rss_parser.dart';

void main() {
  group('RssParser', () {
    test('parses RSS 2.0 feed', () {
      const rssXml = '''<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <title>Test Feed</title>
    <description>A test RSS feed</description>
    <link>https://example.com</link>
    <item>
      <title>Article 1</title>
      <link>https://example.com/article-1</link>
      <description>&lt;p&gt;First article&lt;/p&gt;</description>
      <author>author@example.com</author>
      <pubDate>Mon, 01 Jan 2024 00:00:00 GMT</pubDate>
    </item>
    <item>
      <title>Article 2</title>
      <link>https://example.com/article-2</link>
      <description>Second article description</description>
    </item>
  </channel>
</rss>''';

      final feed = RssParser.parse(rssXml);

      expect(feed.title, 'Test Feed');
      expect(feed.description, 'A test RSS feed');
      expect(feed.siteUrl, 'https://example.com');
      expect(feed.items.length, 2);
      expect(feed.items[0].title, 'Article 1');
      expect(feed.items[0].url, 'https://example.com/article-1');
      expect(feed.items[0].author, 'author@example.com');
      expect(feed.items[0].publishedAt, isNotNull);
      expect(feed.items[1].title, 'Article 2');
    });

    test('parses Atom 1.0 feed', () {
      const atomXml = '''<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>Atom Test Feed</title>
  <subtitle>An atom test feed</subtitle>
  <link href="https://example.com" rel="alternate"/>
  <link href="https://example.com/feed.xml" rel="self"/>
  <entry>
    <title>Entry 1</title>
    <link href="https://example.com/entry-1" rel="alternate"/>
    <summary>Summary of entry 1</summary>
    <author><name>Test Author</name></author>
    <published>2024-01-15T10:30:00Z</published>
  </entry>
  <entry>
    <title>Entry 2</title>
    <link href="https://example.com/entry-2"/>
    <updated>2024-02-01T12:00:00Z</updated>
  </entry>
</feed>''';

      final feed = RssParser.parse(atomXml);

      expect(feed.title, 'Atom Test Feed');
      expect(feed.description, 'An atom test feed');
      expect(feed.siteUrl, 'https://example.com');
      expect(feed.items.length, 2);
      expect(feed.items[0].title, 'Entry 1');
      expect(feed.items[0].url, 'https://example.com/entry-1');
      expect(feed.items[0].author, 'Test Author');
      expect(feed.items[0].publishedAt, isNotNull);
      expect(feed.items[1].title, 'Entry 2');
    });

    test('extracts cover from HTML in description', () {
      const rssXml = '''<?xml version="1.0"?>
<rss version="2.0">
  <channel>
    <title>Image Feed</title>
    <item>
      <title>Image Article</title>
      <link>https://example.com/img</link>
      <description>&lt;img src="https://example.com/cover.jpg"/&gt;Some text</description>
    </item>
  </channel>
</rss>''';

      final feed = RssParser.parse(rssXml);
      expect(feed.items.length, 1);
      expect(feed.items[0].coverUrl, 'https://example.com/cover.jpg');
    });

    test('throws on unrecognized format', () {
      expect(
        () => RssParser.parse('<unknown><test>data</test></unknown>'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('RssManager', () {
    late InMemoryBackend backend;
    late RssManager manager;

    setUp(() {
      backend = InMemoryBackend();
      manager = RssManager(backend: backend);
    });

    test('addFeed adds feed', () async {
      final feed = await manager.addFeed(
        url: 'https://example.com/feed.xml',
        title: 'Test Feed',
        moduleType: SourceType.novelSource,
      );

      expect(manager.feeds.length, 1);
      expect(manager.feeds.first.title, 'Test Feed');
      expect(manager.feeds.first.url, 'https://example.com/feed.xml');
      expect(feed.id, isNotEmpty);
    });

    test('addFeed deduplicates by URL', () async {
      await manager.addFeed(url: 'https://example.com/feed.xml', title: 'Feed 1');
      await manager.addFeed(url: 'https://example.com/feed.xml', title: 'Feed 2');

      expect(manager.feeds.length, 1);
      expect(manager.feeds.first.title, 'Feed 1');
    });

    test('feedsFor filters by module type', () async {
      await manager.addFeed(
        url: 'https://example.com/novel.xml',
        title: 'Novel Feed',
        moduleType: SourceType.novelSource,
      );
      await manager.addFeed(
        url: 'https://example.com/comic.xml',
        title: 'Comic Feed',
        moduleType: SourceType.mangaSource,
      );
      await manager.addFeed(
        url: 'https://example.com/global.xml',
        title: 'Global Feed',
      );

      expect(manager.feedsFor(SourceType.novelSource).length, 1);
      expect(manager.feedsFor(SourceType.mangaSource).length, 1);
      expect(manager.globalFeeds.length, 1);
      expect(manager.feeds.length, 3);
    });

    test('removeFeed removes by id', () async {
      final feed = await manager.addFeed(
        url: 'https://example.com/feed.xml',
        title: 'Test',
      );
      await manager.removeFeed(feed.id);
      expect(manager.feeds, isEmpty);
    });

    test('updateFeed updates existing', () async {
      final feed = await manager.addFeed(
        url: 'https://example.com/feed.xml',
        title: 'Old Title',
      );
      await manager.updateFeed(feed.copyWith(title: 'New Title'));
      expect(manager.feeds.first.title, 'New Title');
    });

    test('persistence survives re-init', () async {
      await manager.addFeed(
        url: 'https://example.com/feed.xml',
        title: 'Persisted Feed',
        moduleType: SourceType.novelSource,
      );

      final manager2 = RssManager(backend: backend);
      await manager2.init();
      expect(manager2.feeds.length, 1);
      expect(manager2.feeds.first.title, 'Persisted Feed');
    });

    test('feedIdFromUrl generates consistent IDs', () {
      final id1 = feedIdFromUrl('https://example.com/feed.xml');
      final id2 = feedIdFromUrl('https://example.com/feed.xml');
      final id3 = feedIdFromUrl('https://other.com/feed.xml');

      expect(id1, id2);
      expect(id1, isNot(id3));
    });
  });

  group('RssFeed model', () {
    test('JSON round-trip', () {
      const feed = RssFeed(
        id: 'feed_123',
        title: 'Test',
        url: 'https://example.com/feed.xml',
        description: 'A test feed',
        siteUrl: 'https://example.com',
        moduleType: SourceType.novelSource,
        addedAt: 1700000000000,
      );

      final json = feed.toJson();
      final restored = RssFeed.fromJson(json);

      expect(restored.id, feed.id);
      expect(restored.title, feed.title);
      expect(restored.url, feed.url);
      expect(restored.description, feed.description);
      expect(restored.siteUrl, feed.siteUrl);
      expect(restored.moduleType, feed.moduleType);
      expect(restored.addedAt, feed.addedAt);
    });

    test('copyWith creates modified copy', () {
      const feed = RssFeed(
        id: 'feed_123',
        title: 'Original',
        url: 'https://example.com/feed.xml',
        addedAt: 0,
      );
      final modified = feed.copyWith(title: 'Modified');

      expect(modified.title, 'Modified');
      expect(modified.id, feed.id);
      expect(modified.url, feed.url);
    });
  });

  group('RssArticleStore.extractReadableHtml（启发式正文识别）', () {
    String paragraph(String tag) =>
        '这是文章正文段落（$tag），含有相当长度的中文正文文本，用来让正文容器在启发式评分中胜出，'
        '同时保证与导航/侧栏的链接密度差距足够大。' * 3;

    String pageHtml(String para) => '''<!DOCTYPE html>
<html>
<head><title>站点标题</title><script>var t=1;</script></head>
<body>
  <nav class="main-nav"><a href="/">首页</a><a href="/cat">分类</a></nav>
  <div class="sidebar">侧栏推荐 <a href="/x">链接1</a><a href="/y">链接2</a></div>
  <article class="post-content">
    <h1>文章标题</h1>
    <p>$para</p>
    <img src="/img/a.jpg" alt="a" />
    <p>$para 正文第二段，包含足够长的文本内容用于评分。</p>
  </article>
  <footer class="site-footer">版权所有 © 示例站点</footer>
</body>
</html>''';

    test('选中正文容器并剔除导航/侧栏/页脚', () {
      final html = pageHtml(paragraph('p'));
      final out = RssArticleStore.extractReadableHtml(html);
      expect(out, contains('文章标题'));
      expect(out, contains('img'));
      expect(out, isNot(contains('侧栏推荐')));
      expect(out, isNot(contains('版权所有')));
      expect(out, isNot(contains('<script')));
    });

    test('剔除噪音标签（script/iframe/form）', () {
      final out = RssArticleStore.extractReadableHtml(
        '<body><form><input name="q"/></form><iframe src="https://x"></iframe>'
        '<script>alert(1)</script><p>正文内容保持不变</p></body>',
      );
      expect(out, contains('正文内容保持不变'));
      expect(out, isNot(contains('<script')));
      expect(out, isNot(contains('<iframe')));
      expect(out, isNot(contains('<form')));
    });

    test('极端残缺 HTML 回退正则清洗且不抛异常', () {
      final out = RssArticleStore.extractReadableHtml(
        '<p>未闭合的正文 <b>加粗',
      );
      expect(out, contains('正文'));
    });
  });

  group('RssParser Media RSS 附件', () {
    test('解析 media:content 视频附件（含 media:group 内嵌）', () {
      const rssXml = '''<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/">
  <channel>
    <title>Video Feed</title>
    <link>https://example.com</link>
    <description>videos</description>
    <item>
      <title>V1</title>
      <link>https://example.com/v1</link>
      <media:group>
        <media:content url="https://cdn.example.com/v1.mp4" type="video/mp4" fileSize="1048576"/>
      </media:group>
    </item>
    <item>
      <title>V2</title>
      <link>https://example.com/v2</link>
      <media:content url="https://cdn.example.com/v2.m3u8" type="application/vnd.apple.mpegurl"/>
    </item>
  </channel>
</rss>''';

      final feed = RssParser.parse(rssXml);
      final first = feed.items[0].enclosures;
      expect(first.length, 1);
      expect(first.single.url, 'https://cdn.example.com/v1.mp4');
      expect(first.single.type, 'video/mp4');
      expect(first.single.isVideo, isTrue);
      expect(first.single.isAudio, isFalse);

      final second = feed.items[1].enclosures;
      expect(second.single.url, 'https://cdn.example.com/v2.m3u8');
      expect(second.single.isVideo, isTrue);
    });

    test('media:content 与 enclosure 同址时去重', () {
      const rssXml = '''<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/">
  <channel>
    <title>Dup Feed</title>
    <link>https://example.com</link>
    <description>d</description>
    <item>
      <title>D1</title>
      <link>https://example.com/d1</link>
      <enclosure url="https://cdn.example.com/d1.mp4" type="video/mp4" length="10"/>
      <media:content url="https://cdn.example.com/d1.mp4" type="video/mp4"/>
    </item>
  </channel>
</rss>''';

      final feed = RssParser.parse(rssXml);
      expect(feed.items.single.enclosures.length, 1);
    });
  });

  group('RssEnclosure 分类', () {
    test('MIME 缺失的视频附件按后缀归为视频而非音频', () {
      const v = RssEnclosure(
        url: 'https://cdn.example.com/video.mp4',
        type: null,
      );
      expect(v.isVideo, isTrue);
      expect(v.isAudio, isFalse);
    });

    test('MIME 为 video/* 的视频附件', () {
      const v = RssEnclosure(
        url: 'https://cdn.example.com/x?token=abc',
        type: 'video/mp4',
      );
      expect(v.isVideo, isTrue);
      expect(v.isAudio, isFalse);
    });

    test('MIME 缺失且非视频后缀仍保守归为音频', () {
      const a = RssEnclosure(
        url: 'https://cdn.example.com/ep.mp3',
        type: null,
      );
      expect(a.isAudio, isTrue);
      expect(a.isVideo, isFalse);
    });
  });
}

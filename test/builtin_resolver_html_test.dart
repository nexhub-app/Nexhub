// Unit tests for BuiltinResolver HTML path with nested (per-apiName) selectors.
//
// Mirrors the demo-style selectors shape: each API (latest / detail /
// episodes / ...) is a sub-map under `selectors.<apiName>` with its own
// `list` / `id` / `title` / `cover` / `url` fields expressed as XPath or
// `css@attr` selectors. The flat legacy shape (`{episodes: "div.chapter a"}`)
// must continue to work for backward compatibility.
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/models/media_item.dart';
import 'package:nexhub/core/models/plugin_config.dart';
import 'package:nexhub/core/resolver/builtin_resolver.dart';

PluginConfig _source(Map<String, dynamic> selectors) {
  return PluginConfig.fromJson(<String, dynamic>{
    'id': 'demo_test',
    'name': 'demo_test',
    'type': 'animeSource',
    'responseType': 'html',
    'site': {
      'domain': 'www.example.com',
      'baseUrl': 'https://www.example.com/',
    },
    'parser': {'type': 'xpath'},
    'routes': {
      'latest': '/latest.html',
      'detail': '/detail/{id}.html',
      'episodes': '/detail/{id}.html',
    },
    'selectors': selectors,
  });
}

void main() {
  group('BuiltinResolver HTML - nested selectors (demo-style)', () {
    test('latest list: extracts id/title/cover via per-apiName sub-map',
        () async {
      final source = _source(<String, dynamic>{
        'latest': <String, dynamic>{
          'list': "div[@class='item']",
          'id':
              "substring-before(substring-after(./a/@href, '/voddetail/'), '.html')",
          'title': './a/@title',
          'cover': ".//img/@data-src",
        },
      });
      const html = '''
<html><body>
<div class="list">
  <div class="item">
    <a href="/voddetail/123.html" title="某番剧">
      <img data-src="http://x/cover.jpg"/>
    </a>
  </div>
  <div class="item">
    <a href="/voddetail/456.html" title="另一番">
      <img data-src="http://x/cover2.jpg"/>
    </a>
  </div>
</div>
</body></html>
''';
      final r = await const BuiltinResolver().resolveFromHtml(
        source,
        'latest',
        html,
      );
      expect(r, isA<List>());
      final items = r as List;
      expect(items.length, 2);
      expect(items[0].id, '123');
      expect(items[0].title, '某番剧');
      expect(items[0].coverUrl, 'http://x/cover.jpg');
      expect(items[1].id, '456');
      expect(items[1].title, '另一番');
      expect(items[1].coverUrl, 'http://x/cover2.jpg');
    });

    test('episodes: extracts id/title via XPath, url falls back to <a> href',
        () async {
      final source = _source(<String, dynamic>{
        'episodes': <String, dynamic>{
          'list': "//div[@class='playlist']//li/a",
          'id':
              "substring-before(substring-after(./@href, '/vodplay/'), '.html')",
          'title': './text()',
        },
      });
      const html = '''
<html><body>
<div class="playlist">
  <ul>
    <li><a href="/vodplay/123-1.html">第1集</a></li>
    <li><a href="/vodplay/123-2.html">第2集</a></li>
  </ul>
</div>
</body></html>
''';
      final r = await const BuiltinResolver().resolveFromHtml(
        source,
        'episodes',
        html,
      );
      expect(r, isA<List>());
      final eps = r as List;
      expect(eps.length, 2);
      expect(eps[0].id, '123-1');
      expect(eps[0].title, '第1集');
      // `url` selector is not declared -> falls back to <a> href.
      expect(eps[0].url, '/vodplay/123-1.html');
      expect(eps[1].id, '123-2');
      expect(eps[1].title, '第2集');
      expect(eps[1].url, '/vodplay/123-2.html');
    });

    test('flat legacy shape `{episodes: "div.chapter a"}` still works',
        () async {
      final source = _source(<String, dynamic>{
        'episodes': 'div.chapter a',
      });
      const html = '''
<html><body>
<div class="chapter"><a href="/c1">第1话</a></div>
<div class="chapter"><a href="/c2">第2话</a></div>
</body></html>
''';
      final r = await const BuiltinResolver().resolveFromHtml(
        source,
        'episodes',
        html,
      );
      expect(r, isA<List>());
      final eps = r as List;
      expect(eps.length, 2);
      expect(eps[0].title, '第1话');
      expect(eps[0].url, '/c1');
      expect(eps[1].title, '第2话');
      expect(eps[1].url, '/c2');
    });

    test('detail: extracts title/cover/description via per-apiName sub-map',
        () async {
      final source = _source(<String, dynamic>{
        'detail': <String, dynamic>{
          'title': '//h1/text()',
          'cover': "//div[@class='detail-pic']//img/@src",
          'description': "//div[@class='detail-content']",
        },
      });
      const html = '''
<html><body>
<h1>某番剧</h1>
<div class="detail-pic"><img src="http://x/cover.jpg"/></div>
<div class="detail-content">这是某番剧的简介，内容非空。</div>
</body></html>
''';
      final r = await const BuiltinResolver().resolveFromHtml(
        source,
        'detail',
        html,
      );
      expect(r, isA<MediaItem>());
      final item = r as MediaItem;
      expect(item.title, '某番剧');
      expect(item.coverUrl, 'http://x/cover.jpg');
      expect(item.description, isNotEmpty);
    });
  });

  group('BuiltinResolver - mixed @attr comma selectors & empty-card filter',
      () {
    // 修复回归用例：混合 @attr + CSS 多分支选择器（此前整串交给一次
    // querySelector 导致整体失效）。
    test('detail cover: mixed @attr comma selector picks first non-empty branch',
        () async {
      final source = _source(<String, dynamic>{
        'detail': <String, dynamic>{
          'title': '//h1/text()',
          // 第一分支命中 <video poster>，第二分支为 meta 兜底。
          'cover':
              'video#player@poster, meta[property="og:image"]@content',
        },
      });
      const html = '''
<html><head>
<meta property="og:image" content="http://x/og.jpg"/>
</head><body>
<h1>混合选择器</h1>
<video id="player" poster="http://x/poster.jpg"></video>
</body></html>
''';
      final r = await const BuiltinResolver().resolveFromHtml(
        source,
        'detail',
        html,
      );
      final item = r as MediaItem;
      expect(item.coverUrl, 'http://x/poster.jpg');
    });

    test('detail cover: falls back to second branch when first misses',
        () async {
      final source = _source(<String, dynamic>{
        'detail': <String, dynamic>{
          'title': '//h1/text()',
          'cover':
              'video#player@poster, meta[property="og:image"]@content',
        },
      });
      const html = '''
<html><head>
<meta property="og:image" content="http://x/og.jpg"/>
</head><body>
<h1>混合选择器</h1>
</body></html>
''';
      final r = await const BuiltinResolver().resolveFromHtml(
        source,
        'detail',
        html,
      );
      final item = r as MediaItem;
      expect(item.coverUrl, 'http://x/og.jpg');
    });

    // pms_hanime 场景回归：list 直接选 <a> 卡片，id 用 XPath 从元素
    // 自身取 href；广告外链卡（无 watch 链接）不匹配 list，不会混入。
    test('list=a cards + id=//a/@href: self-href extraction',
        () async {
      final source = _source(<String, dynamic>{
        'category': <String, dynamic>{
          'list': 'a[href*="watch"]',
          'id': '//a/@href',
          'title': '.home-rows-videos-title',
          'cover': 'img@src',
        },
      });
      const html = '''
<html><body>
<div class="home-rows-videos-wrapper">
  <a style="text-decoration: none;" href="https://hanime1.me/watch?v=408116">
    <div class="video-card-inner">
      <img loading="lazy" src="http://x/cover/408116.jpg"/>
      <div class="home-rows-videos-title">第一支影片</div>
    </div>
  </a>
  <a href="https://l.erodalabs.com/s/7duYXu" target="_blank">
    <img src="http://x/ad.jpg"/>
  </a>
  <a style="text-decoration: none;" href="https://hanime1.me/watch?v=408117">
    <div class="video-card-inner">
      <img loading="lazy" src="http://x/cover/408117.jpg"/>
      <div class="home-rows-videos-title">第二支影片</div>
    </div>
  </a>
</div>
</body></html>
''';
      final r = await const BuiltinResolver().resolveFromHtml(
        source,
        'category',
        html,
      );
      expect(r, isA<List>());
      final items = r as List;
      expect(items.length, 2);
      expect(items[0].id, 'https://hanime1.me/watch?v=408116');
      expect(items[0].title, '第一支影片');
      expect(items[0].coverUrl, 'http://x/cover/408116.jpg');
      expect(items[1].id, 'https://hanime1.me/watch?v=408117');
    });

    test('empty-card filter: cards with blank id AND title are dropped',
        () async {
      final source = _source(<String, dynamic>{
        'category': <String, dynamic>{
          'list': 'div.card',
          'id': 'a@href',
          'title': '.t',
        },
      });
      const html = '''
<html><body>
<div class="card"><a href="/v/1"><span class="t">有标题</span></a></div>
<div class="card"><a href="/v/2"><span class="t"></span></a></div>
<div class="card"><span class="t">无链接占位</span></div>
<div class="card"><img src="http://x/pure.jpg"/></div>
</body></html>
''';
      final r = await const BuiltinResolver().resolveFromHtml(
        source,
        'category',
        html,
      );
      final items = r as List;
      // 卡1（id+title 双全）、卡2（有 id）、卡3（有 title）保留；
      // 卡4 无链接无标题（双空）被通用过滤。
      expect(items.length, 3);
      expect(items[0].id, '/v/1');
      expect(items[1].id, '/v/2');
      expect(items[2].title, '无链接占位');
    });

    // 无 CSS 前缀的 @attr/@text 自属性写法（manga_goda/dm5 等 existing
    // 源已在用；旧实现 css 为空时 querySelector('') 会异常或返回空）。
    test('self-attr @href / @text on episode list element', () async {
      final source = _source(<String, dynamic>{
        'episodes': <String, dynamic>{
          'list': 'div.chapter a',
          'url': '@href',
          'title': '@text',
        },
      });
      const html = '''
<html><body>
<div class="chapter"><a href="/c/1">第一章</a></div>
<div class="chapter"><a href="/c/2">第二章</a></div>
</body></html>
''';
      final r = await const BuiltinResolver().resolveFromHtml(
        source,
        'episodes',
        html,
      );
      final eps = r as List;
      expect(eps.length, 2);
      expect(eps[0].title, '第一章');
      expect(eps[0].url, '/c/1');
      expect(eps[1].url, '/c/2');
    });

    test('multi-branch css fallback: first branch wins, second fills gap',
        () async {
      final source = _source(<String, dynamic>{
        'latest': <String, dynamic>{
          'list': 'div.item',
          'id': 'a@href',
          // 新版页面用 .nt，旧版页面用 .title，两版都要能取到。
          'title': '.nt, .title',
        },
      });
      const newHtml = '''
<html><body>
<div class="item"><a href="/v/1"><div class="nt">新版标题</div></a></div>
</body></html>
''';
      const oldHtml = '''
<html><body>
<div class="item"><a href="/v/2"><div class="title">旧版标题</div></a></div>
</body></html>
''';
      final r1 = await const BuiltinResolver().resolveFromHtml(
        source,
        'latest',
        newHtml,
      );
      expect((r1 as List)[0].title, '新版标题');
      final r2 = await const BuiltinResolver().resolveFromHtml(
        source,
        'latest',
        oldHtml,
      );
      expect((r2 as List)[0].title, '旧版标题');
    });
  });
}

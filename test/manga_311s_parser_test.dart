import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/models/plugin_config.dart';

PluginConfig _loadSource() {
  final f = File('plugins/builtin/manga_311s.json');
  final raw = f.readAsStringSync();
  return PluginConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
}

Future<dynamic> _runNode(
  String script,
  String function,
  List<dynamic> args, {
  String baseUrl = 'https://www.311s.com',
}) async {
  final escaped = <String>[];
  for (final a in args) {
    escaped.add(jsonEncode(a));
  }
  final callExpr = '$function(${escaped.join(', ')}, { baseUrl: ${jsonEncode(baseUrl)} })';
  final nodeExpr = '''
$script
var __r = $callExpr;
process.stdout.write(JSON.stringify(__r));
''';
  final result = await Process.run(
    'node',
    <String>['-e', nodeExpr],
    workingDirectory: Directory.current.path,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (result.exitCode != 0) {
    throw Exception('node exit ${result.exitCode}: ${result.stderr}');
  }
  final out = result.stdout.toString();
  if (out.isEmpty) return null;
  try {
    return jsonDecode(out);
  } on FormatException {
    return out;
  }
}

void main() {
  final source = _loadSource();
  final listScript = source.parser.overrides?['search']?.script ?? '';
  final detailScript = source.parser.overrides?['detail']?.script ?? '';
  final chaptersScript = source.parser.overrides?['chapters']?.script ?? '';
  final imagesScript = source.parser.overrides?['images']?.script ?? '';

  group('manga_311s JSON 语法与关键字段验证', () {
    test('JSON.parse 无语法错误; id/name/routes/selectors/四脚本非空', () {
      expect(source.id, 'manga_311s');
      expect(source.name, isNotEmpty);
      expect(source.type.toString().contains('mangaSource'), isTrue);
      expect(source.site.baseUrl, isNotEmpty);
      expect(source.site.mirrors, isNotEmpty);
      expect(listScript, isNotEmpty);
      expect(detailScript, isNotEmpty);
      expect(chaptersScript, isNotEmpty);
      expect(imagesScript, isNotEmpty);
      expect(source.routes.containsKey('latest'), isTrue);
      expect(source.routes.containsKey('detail'), isTrue);
      expect(source.routes.containsKey('chapters'), isTrue);
      expect(source.routes.containsKey('images'), isTrue);
      expect(source.routes.containsKey('search'), isTrue);
      expect(source.selectors?.isNotEmpty ?? true, isTrue);
      expect(source.parser.type, 'hybrid');
    });
  });

  group('parseList (TR-1.x)', () {
    test('test1 TR-1.1: 3 条 div.comic-item 漫画卡片均正确解析', () async {
      const html = '''
<div class="comic-item"><a href="/comic_1.html" class="comic-cover"><img src="/img/1.jpg" alt="漫画1"></a><h3><a href="/comic_1.html" title="漫画1">漫画1</a></h3><p class="comic-author">作者1</p></div>
<div class="comic-item"><a href="/comic_2.html" class="comic-cover"><img src="/img/2.jpg" alt="漫画2"></a><h3><a href="/comic_2.html" title="漫画2">漫画2</a></h3><p class="comic-author">作者2</p></div>
<div class="comic-item"><a href="/comic_3.html" class="comic-cover"><img src="/img/3.jpg" alt="漫画3"></a><h3><a href="/comic_3.html" title="漫画3">漫画3</a></h3><p class="comic-author">作者3</p></div>''';
      final result = await _runNode(listScript, 'parseList', <dynamic>[html]) as List;
      expect(result.length, 3);
      for (final item in result) {
        final m = item as Map;
        expect(m['id'], isNotEmpty, reason: 'id 非空');
        expect(m['title'], isNotEmpty, reason: 'title 非空');
        expect(m['cover'], isNotEmpty, reason: 'cover 非空');
        expect(m['detailUrl'], isNotEmpty, reason: 'detailUrl 非空');
      }
      final titles = result.map((e) => (e as Map)['title'] as String).toList();
      expect(titles, containsAll(<String>['漫画1', '漫画2', '漫画3']));
      final ids = result.map((e) => (e as Map)['id'] as String).toList();
      expect(ids, containsAll(<String>['1', '2', '3']));
    });

    test('test2 TR-1.2: 同一 href 重复出现，去重后仅返回 1 条', () async {
      const html = '''
<div class="comic-item"><a href="/comic_99.html" class="comic-cover"><img src="/img/a.jpg" alt="重复A"></a><h3><a href="/comic_99.html" title="重复A">重复A</a></h3><p class="comic-author">作者</p></div>
<div class="comic-item"><a href="/comic_99.html" class="comic-cover"><img src="/img/b.jpg" alt="重复B"></a><h3><a href="/comic_99.html" title="重复B">重复B</a></h3><p class="comic-author">作者</p></div>''';
      final result = await _runNode(listScript, 'parseList', <dynamic>[html]) as List;
      expect(result.length, 1);
      expect((result.first as Map)['id'], '99');
    });

    test('test3 TR-1.3: 卡片缺图或缺标题被跳过，仅完整卡片返回', () async {
      const html = '''
<div class="comic-item"><a href="/comic_101.html" class="comic-cover"></a><h3><a href="/comic_101.html" title="缺图卡片">缺图卡片</a></h3><p class="comic-author">作者</p></div>
<div class="comic-item"><a href="/comic_102.html" class="comic-cover"><img src="/img/mt.jpg"></a><p class="comic-author">作者</p></div>
<div class="comic-item"><a href="/comic_103.html" class="comic-cover"><img src="/img/ok.jpg" alt="完整卡片"></a><h3><a href="/comic_103.html" title="完整卡片">完整卡片</a></h3><p class="comic-author">作者</p></div>''';
      final result = await _runNode(listScript, 'parseList', <dynamic>[html]) as List;
      expect(result.length, 1);
      final item = result.first as Map;
      expect(item['title'], '完整卡片');
      expect(item['cover'].toString(), contains('ok.jpg'));
      expect(item['id'], '103');
    });
  });

  group('parseDetail (TR-2.x)', () {
    test('test4 TR-2.1: og:image/og:title/meta description 正确提取', () async {
      const html = '''
<html>
<head>
  <meta property="og:image" content="https://www.311s.com/cover_13871.jpg">
  <meta property="og:title" content="311s漫画标题">
  <meta name="description" content="这是311s漫画的详细描述内容">
</head>
<body>
  <p class="comic-author">原作者</p>
</body>
</html>''';
      final result = await _runNode(detailScript, 'parseDetail', <dynamic>[html]) as Map;
      expect(result['title'], '311s漫画标题');
      expect(result['coverUrl'], 'https://www.311s.com/cover_13871.jpg');
      expect(result['description'], '这是311s漫画的详细描述内容');
      expect(result['author'], '原作者');
    });
  });

  group('parseChapters (TR-3.x)', () {
    test('test5 TR-3.1: div.chapter-item + /chapter_XXX_YYY.html 链接解析', () async {
      const html = '''
<div class="chapter-item"><a href="/chapter_13871_4992.html">第2话 2.姐姐2</a></div>
<div class="chapter-item"><a href="/chapter_13871_4993.html">第3话 3.哥哥3</a></div>
<div class="chapter-item"><a href="/chapter_13871_4994.html">第4话 4.妹妹4</a></div>''';
      final result = await _runNode(chaptersScript, 'parseChapters', <dynamic>[html]) as List;
      expect(result.length, 3);
      final titles = result.map((e) => (e as Map)['title'] as String).toList();
      expect(titles, contains('第2话 2.姐姐2'));
      expect(titles, contains('第3话 3.哥哥3'));
      expect(titles, contains('第4话 4.妹妹4'));
      final ids = result.map((e) => (e as Map)['id'] as String).toList();
      expect(ids, containsAll(<String>[
        '/chapter_13871_4992.html',
        '/chapter_13871_4993.html',
        '/chapter_13871_4994.html',
      ]));
    });
  });

  group('parseImages (TR-4.x)', () {
    test('test6 TR-4.1: reader-container 内图片正确提取', () async {
      const html = '''
<div class="reader-container">
  <img src="https://www.311s.com/images/001.jpg">
  <img src="https://www.311s.com/images/002.jpg">
  <img src="https://www.311s.com/images/003.jpg">
</div>
<img class="logo" src="/logo.png">''';
      final result = await _runNode(imagesScript, 'parseImages', <dynamic>[html]) as List;
      expect(result.length, 3);
      expect(result.cast<String>(), contains('https://www.311s.com/images/001.jpg'));
      expect(result.cast<String>(), contains('https://www.311s.com/images/002.jpg'));
      expect(result.cast<String>(), contains('https://www.311s.com/images/003.jpg'));
    });
  });
}
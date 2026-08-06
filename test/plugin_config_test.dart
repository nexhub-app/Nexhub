import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/models/plugin_config.dart';

PluginConfig build(Map<String, dynamic> json) => PluginConfig.fromJson(json);

void main() {
  group('PluginConfig', () {
    test('parses animeSource MacCMS config', () {
      final source = build(<String, dynamic>{
        'id': 'pms_example',
        'name': '示例影视源',
        'type': 'animeSource',
        'responseType': 'json',
        'site': {
          'domain': 'https://example.com',
          'baseUrl': 'https://example.com',
        },
        'parser': {'type': 'builtin'},
        'routes': {
          'latest': {'url': '/api.php/provide/vod/?ac=list&pg={page}'},
          'search': {'url': '/api.php/provide/vod/?ac=list&wd={keyword}'},
        },
      });
      expect(source.id, 'pms_example');
      expect(source.type, SourceType.animeSource);
      expect(source.validate(), isEmpty);
    });

    test('detects source type for mangaSource / novelSource', () {
      expect(
        build(<String, dynamic>{
          'id': 'm', 'name': 'm', 'type': 'mangaSource',
          'site': {'baseUrl': 'https://x.com'}, 'parser': {'type': 'builtin'},
        }).type,
        SourceType.mangaSource,
      );
      expect(
        build(<String, dynamic>{
          'id': 'n', 'name': 'n', 'type': 'novelSource',
          'site': {'baseUrl': 'https://x.com'}, 'parser': {'type': 'builtin'},
        }).type,
        SourceType.novelSource,
      );
    });

    test('validate flags missing id and baseUrl', () {
      final source = build(<String, dynamic>{
        'name': 'bad',
        'type': 'animeSource',
        'site': {'baseUrl': ''},
        'parser': {'type': 'builtin'},
      });
      final errors = source.validate();
      expect(errors, contains('missing: id'));
      expect(errors, contains('missing: site.baseUrl'));
    });

    test('resolveRouteUrl fills baseUrl and vars', () {
      final source = build(<String, dynamic>{
        'id': 'pms_example',
        'name': '示例',
        'type': 'animeSource',
        'site': {'baseUrl': 'https://example.com'},
        'parser': {'type': 'builtin'},
        'routes': {
          'search': {'url': '/api.php/provide/vod/?ac=list&wd={keyword}&pg={page}'},
        },
      });
      final url = source.resolveRouteUrl(
        'search',
        activeBaseUrl: 'https://example.com',
        vars: <String, String>{'keyword': 'naruto', 'page': '2'},
      );
      expect(
        url,
        'https://example.com/api.php/provide/vod/?ac=list&wd=naruto&pg=2',
      );
    });

    test('responseTypeFor falls back to top-level', () {
      final source = build(<String, dynamic>{
        'id': 'p', 'name': 'p', 'type': 'animeSource',
        'responseType': 'json',
        'site': {'baseUrl': 'https://x.com'},
        'parser': {'type': 'builtin'},
        'routes': {'latest': {'url': '/l'}},
      });
      expect(source.responseTypeFor('latest'), 'json');
    });
  });

  group('CommentsConfig', () {
    Map<String, dynamic> baseJson({Map<String, dynamic>? comments}) =>
        <String, dynamic>{
          'id': 'pms_example',
          'name': 'example',
          'type': 'animeSource',
          'site': {'baseUrl': 'https://example.com'},
          'parser': {'type': 'builtin'},
          'routes': {
            'latest': {'url': '/latest?page={page}'},
          },
          if (comments != null) 'comments': comments,
        };

    test('missing comments section yields null (backward compat)', () {
      final source = build(baseJson());
      expect(source.comments, isNull);
      expect(source.validate(), isEmpty);
    });

    test('parses full comments section', () {
      final source = build(baseJson(comments: <String, dynamic>{
        'routes': {
          'list': {'url': '/api/comments?id={id}&page={page}'},
          'replies': {'url': '/api/comments/{commentId}/replies?page={page}'},
          'post': {
            'url': '/api/comments',
            'method': 'POST',
            'params': {'id': '{id}', 'content': '{text}'},
          },
          'like': {'url': '/api/comments/{commentId}/like', 'method': 'POST'},
          'report': {
            'url': '/api/comments/{commentId}/report',
            'method': 'POST',
          },
        },
        'selectors': {
          'items': r'$.data.list',
          'commentId': r'$.id',
          'author': r'$.user.name',
          'content': r'$.content',
          'success': r'$.code',
        },
        'login': {
          'url': 'https://example.com/login',
          'checkCookie': 'user_token',
          'checkUrl': '/api/user/me',
          'loggedInSelector': r'$.data.username',
        },
      }));
      final comments = source.comments!;
      expect(comments.provider, 'source');
      expect(comments.hasList, isTrue);
      expect(comments.hasRoute('post'), isTrue);
      expect(comments.hasRoute('reply'), isFalse);
      expect(comments.routes['post']!.method, 'POST');
      expect(comments.routes['post']!.params, containsPair('content', '{text}'));
      expect(comments.selectors!['items'], r'$.data.list');
      expect(comments.supportsLogin, isTrue);
      expect(comments.login!.checkCookie, 'user_token');
      expect(comments.login!.loggedInSelector, r'$.data.username');
    });

    test('list-only comments: other actions absent, no login', () {
      final source = build(baseJson(comments: <String, dynamic>{
        'routes': {
          'list': {'url': '/comments/{id}'},
        },
      }));
      final comments = source.comments!;
      expect(comments.hasList, isTrue);
      expect(comments.hasRoute('post'), isFalse);
      expect(comments.hasRoute('like'), isFalse);
      expect(comments.hasRoute('report'), isFalse);
      expect(comments.login, isNull);
      expect(comments.supportsLogin, isFalse);
    });

    test('provider field reserved for bangumi (parse only)', () {
      final source = build(baseJson(comments: <String, dynamic>{
        'provider': 'bangumi',
        'routes': {
          'list': {'url': '/comments/{id}'},
        },
      }));
      expect(source.comments!.provider, 'bangumi');
    });

    test('resolveRouteUrl resolves comments.* routes with placeholders', () {
      final source = build(baseJson(comments: <String, dynamic>{
        'routes': {
          'list': {'url': '/api/comments?id={id}&page={page}'},
          'replies': {'url': '/api/comments/{commentId}/replies?page={page}'},
          'post': {'url': '/api/comments?id={id}&content={text}'},
        },
      }));
      expect(
        source.resolveRouteUrl(
          'comments.list',
          activeBaseUrl: 'https://example.com',
          vars: <String, String>{'id': '42', 'page': '3'},
        ),
        'https://example.com/api/comments?id=42&page=3',
      );
      expect(
        source.resolveRouteUrl(
          'comments.replies',
          activeBaseUrl: 'https://example.com',
          vars: <String, String>{'commentId': 'c9', 'page': '1'},
        ),
        'https://example.com/api/comments/c9/replies?page=1',
      );
      // 非 ASCII 自由文本占位符需 URL 编码
      expect(
        source.resolveRouteUrl(
          'comments.post',
          activeBaseUrl: 'https://example.com',
          vars: <String, String>{'id': '42', 'text': '好看'},
        ),
        'https://example.com/api/comments?id=42&content=${Uri.encodeComponent('好看')}',
      );
    });

    test('resolveRouteUrl comments route follows mirror base', () {
      final source = build(baseJson(comments: <String, dynamic>{
        'routes': {
          'list': {'url': 'https://example.com/api/comments?id={id}'},
        },
      }));
      expect(
        source.resolveRouteUrl(
          'comments.list',
          activeBaseUrl: 'https://mirror.example.org',
          vars: <String, String>{'id': '1'},
        ),
        'https://mirror.example.org/api/comments?id=1',
      );
    });

    test('resolveRouteUrl throws for undeclared comments route', () {
      final source = build(baseJson(comments: <String, dynamic>{
        'routes': {
          'list': {'url': '/comments/{id}'},
        },
      }));
      expect(
        () => source.resolveRouteUrl(
          'comments.post',
          activeBaseUrl: 'https://example.com',
        ),
        throwsA(isA<PluginConfigException>()),
      );
    });

    test('responseTypeFor resolves comments route level then top level', () {
      final source = build(<String, dynamic>{
        'id': 'p', 'name': 'p', 'type': 'animeSource',
        'responseType': 'json',
        'site': {'baseUrl': 'https://x.com'},
        'parser': {'type': 'builtin'},
        'routes': {'latest': {'url': '/l'}},
        'comments': {
          'routes': {
            'list': {'url': '/c', 'responseType': 'html'},
            'post': {'url': '/p', 'method': 'POST'},
          },
        },
      });
      expect(source.responseTypeFor('comments.list'), 'html');
      expect(source.responseTypeFor('comments.post'), 'json');
    });

    test('toJson round-trips comments section', () {
      final source = build(baseJson(comments: <String, dynamic>{
        'routes': {
          'list': {'url': '/comments/{id}'},
        },
        'login': {'checkCookie': 'token'},
      }));
      final reparsed = PluginConfig.fromJson(source.toJson());
      expect(reparsed.comments, isNotNull);
      expect(reparsed.comments!.hasList, isTrue);
      expect(reparsed.comments!.login!.checkCookie, 'token');
    });
  });
}

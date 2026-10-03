import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/comments/comment_api_service.dart';
import 'package:nexhub/core/models/plugin_config.dart';
import 'package:nexhub/core/network/model/effective_network_profile.dart';
import 'package:nexhub/core/scraper/verification_detector.dart';

/// 记录一次 fake 请求的方法/URL/头/体。
class FakeRequest {
  FakeRequest(this.method, this.url, {this.headers, this.data});
  final String method;
  final String url;
  final Map<String, String>? headers;
  final Object? data;
}

/// 队列式 fake：按顺序弹出预置响应（String 正常返回，Exception 抛出）。
class FakeCommentClient implements CommentHttpClient {
  final List<FakeRequest> requests = <FakeRequest>[];
  final List<Object> responses = <Object>[];

  void enqueue(Object response) => responses.add(response);

  Future<String> _pop() {
    if (responses.isEmpty) {
      throw StateError('FakeCommentClient: no queued response');
    }
    final next = responses.removeAt(0);
    if (next is Exception) return Future<String>.error(next);
    return Future<String>.value(next as String);
  }

  @override
  Future<String> getText(
    String url, {
    Map<String, String>? headers,
    String? referer,
    EffectiveNetworkProfile? net,
  }) {
    requests.add(FakeRequest('GET', url, headers: headers));
    return _pop();
  }

  @override
  Future<String> postText(
    String url, {
    Map<String, String>? headers,
    Object? data,
    String? referer,
    EffectiveNetworkProfile? net,
  }) {
    requests.add(FakeRequest('POST', url, headers: headers, data: data));
    return _pop();
  }

  @override
  Future<String> postFormText(
    String url, {
    Map<String, String>? headers,
    Map<String, String>? data,
    String? referer,
    EffectiveNetworkProfile? net,
  }) {
    requests.add(FakeRequest('FORM', url, headers: headers, data: data));
    return _pop();
  }
}

PluginConfig buildSource({Map<String, dynamic>? comments}) =>
    PluginConfig.fromJson(<String, dynamic>{
      'id': 'pms_example',
      'name': 'example',
      'type': 'animeSource',
      'site': {'baseUrl': 'https://example.com'},
      'parser': {'type': 'builtin'},
      'routes': {
        'latest': {'url': '/latest?page={page}'},
      },
      if (comments != null) 'comments': comments,
    });

Map<String, dynamic> jsonComments({Map<String, dynamic>? selectors}) =>
    <String, dynamic>{
      'routes': {
        'list': {'url': '/api/comments?id={id}&page={page}'},
        'replies': {'url': '/api/comments/{commentId}/replies?page={page}'},
        'post': {
          'url': '/api/comments',
          'method': 'POST',
          'params': {'id': '{id}', 'content': '{text}'},
        },
        'like': {'url': '/api/comments/{commentId}/like', 'method': 'POST'},
        'report': {'url': '/api/comments/{commentId}/report', 'method': 'POST'},
      },
      'selectors': selectors ??
          <String, dynamic>{
            'items': r'$.data.list',
            'commentId': r'$.id',
            'author': r'$.user.name',
            'avatar': r'$.user.avatar',
            'content': r'$.content',
            'time': r'$.time',
            'likeCount': r'$.likes',
            'replyCount': r'$.replyCount',
            'replies': r'$.children',
            'hasMore': r'$.data.hasMore',
            'success': r'$.code',
            'successValue': '0',
          },
    };

String jsonListBody({bool hasMore = true, List<Map<String, dynamic>>? list}) =>
    jsonEncode(<String, dynamic>{
      'code': 0,
      'data': {
        'hasMore': hasMore,
        'list': list ??
            <Map<String, dynamic>>[
              {
                'id': 101,
                'user': {'name': '甲', 'avatar': 'https://cdn/a.png'},
                'content': '好看',
                'time': '2小时前',
                'likes': '12',
                'replyCount': 1,
                'children': [
                  {
                    'id': 102,
                    'user': {'name': '乙'},
                    'content': '同感',
                  },
                ],
              },
              {
                'id': 103,
                'user': {'name': '丙'},
                'content': '一般',
                'likes': 0,
              },
            ],
      },
    });

void main() {
  group('CommentApiService JSON 解析', () {
    test('fetchComments 解析字段/内联回复/hasMore 选择器', () async {
      final client = FakeCommentClient()..enqueue(jsonListBody());
      final service = CommentApiService(client: client);
      final source = buildSource(comments: jsonComments());

      final page = await service.fetchComments(source, 'v1', page: 2);

      expect(client.requests.single.method, 'GET');
      expect(client.requests.single.url,
          'https://example.com/api/comments?id=v1&page=2');
      expect(page.comments, hasLength(2));
      final first = page.comments.first;
      expect(first.id, '101');
      expect(first.author, '甲');
      expect(first.avatarUrl, 'https://cdn/a.png');
      expect(first.content, '好看');
      expect(first.timeText, '2小时前');
      expect(first.likeCount, 12); // 字符串数字容错
      expect(first.replyCount, 1);
      expect(first.replies, hasLength(1));
      expect(first.replies.single.author, '乙');
      expect(page.comments[1].avatarUrl, isNull);
      expect(page.comments[1].likeCount, 0);
      expect(page.hasMore, isTrue);
    });

    test('hasMore 选择器为 false 时判停', () async {
      final client = FakeCommentClient()..enqueue(jsonListBody(hasMore: false));
      final service = CommentApiService(client: client);
      final page =
          await service.fetchComments(buildSource(comments: jsonComments()), 'v1');
      expect(page.hasMore, isFalse);
    });

    test('未声明 hasMore 时满页推定：非空 true / 空 false', () async {
      final selectors = <String, dynamic>{
        'items': r'$.data.list',
        'commentId': r'$.id',
        'author': r'$.user.name',
        'content': r'$.content',
      };
      final source = buildSource(comments: jsonComments(selectors: selectors));
      final client = FakeCommentClient()
        ..enqueue(jsonListBody())
        ..enqueue(jsonListBody(list: <Map<String, dynamic>>[]));
      final service = CommentApiService(client: client);

      expect((await service.fetchComments(source, 'v1')).hasMore, isTrue);
      expect((await service.fetchComments(source, 'v1', page: 2)).hasMore,
          isFalse);
    });

    test('fetchReplies 走 replies 路由并替换 {commentId}', () async {
      final client = FakeCommentClient()..enqueue(jsonListBody(hasMore: false));
      final service = CommentApiService(client: client);
      await service.fetchReplies(buildSource(comments: jsonComments()), '101',
          page: 3);
      expect(client.requests.single.url,
          'https://example.com/api/comments/101/replies?page=3');
    });

    test('未声明的路由抛 PluginConfigException', () {
      final service = CommentApiService(client: FakeCommentClient());
      final source = buildSource(comments: <String, dynamic>{
        'routes': {
          'list': {'url': '/comments/{id}'},
        },
      });
      expect(() => service.fetchReplies(source, '1'),
          throwsA(isA<PluginConfigException>()));
      expect(() => service.postComment(source, 'v1', 'hi'),
          throwsA(isA<PluginConfigException>()));
    });
  });

  group('CommentApiService HTML 解析', () {
    test('CSS 选择器解析列表与内联回复', () async {
      const html = '''
<html><body>
  <div class="comment">
    <span class="cid">c1</span>
    <a class="author">张三</a>
    <img class="avatar" data-src="https://cdn/z.png">
    <p class="content">第一条</p>
    <span class="time">昨天</span>
    <div class="reply">
      <a class="author">李四</a>
      <p class="content">回一条</p>
    </div>
  </div>
  <div class="comment">
    <span class="cid">c2</span>
    <a class="author">王五</a>
    <p class="content">第二条</p>
  </div>
  <a class="next-page">下一页</a>
</body></html>
''';
      final client = FakeCommentClient()..enqueue(html);
      final service = CommentApiService(client: client);
      final source = buildSource(comments: <String, dynamic>{
        'routes': {
          'list': {'url': '/comments/{id}?p={page}'},
        },
        'selectors': {
          'items': 'body > .comment',
          'commentId': '.cid',
          'author': '.author',
          'avatar': 'img.avatar@data-src',
          'content': '.content',
          'time': '.time',
          'replies': '.reply',
          'hasMore': '.next-page',
        },
      });

      final page = await service.fetchComments(source, 'v9');

      expect(client.requests.single.url, 'https://example.com/comments/v9?p=1');
      expect(page.comments, hasLength(2));
      final first = page.comments.first;
      expect(first.id, 'c1');
      expect(first.author, '张三');
      expect(first.avatarUrl, 'https://cdn/z.png');
      expect(first.timeText, '昨天');
      expect(first.replies, hasLength(1));
      expect(first.replies.single.author, '李四');
      expect(first.replies.single.content, '回一条');
      expect(page.comments[1].id, 'c2');
      expect(page.hasMore, isTrue);
    });

    test('hasMore 选择器未命中判停', () async {
      const html = '<html><body><div class="comment">'
          '<a class="author">a</a><p class="content">x</p>'
          '</div></body></html>';
      final client = FakeCommentClient()..enqueue(html);
      final service = CommentApiService(client: client);
      final source = buildSource(comments: <String, dynamic>{
        'routes': {
          'list': {'url': '/comments/{id}'},
        },
        'selectors': {
          'items': '.comment',
          'author': '.author',
          'content': '.content',
          'hasMore': '.next-page',
        },
      });
      final page = await service.fetchComments(source, 'v1');
      expect(page.comments, hasLength(1));
      expect(page.hasMore, isFalse);
    });
  });

  group('CommentApiService JSON 内嵌 HTML（embeddedHtml / 自动探测）', () {
    // hanime1.me loadComment 形态：{"comments":"<div id=comment-start>…</div>"}
    const hanimeFragment = '''
<div id="comment-create-form-wrapper"><input name="_token" value="tok123"><input name="comment-user-id" value="u9"></div>
<div id="comment-start" class="comment-start">
  <a href="https://ex.com/user/1"><img class="img-circle" src="https://cdn/av1.jpg"></a>
  <div class="report-btn-wrapper"><div class="comment-index-text"><a>甲&nbsp;&nbsp;<span>1天前</span></a></div><div class="comment-index-text">第一楼内容</div><span class="report-btn" data-reportable-id="901"></span></div>
  <div id="comment-like-form-wrapper"><span style="display:none">0</span><span style="color:red">12</span><div id="reply-section-wrapper-901"></div><div class="load-replies-btn">查看 3 則回覆</div></div>
  <br>
  <a href="https://ex.com/user/2"><img class="img-circle" src="https://cdn/av2.jpg"></a>
  <div class="report-btn-wrapper"><div class="comment-index-text"><a>乙&nbsp;&nbsp;<span>2小时前</span></a></div><div class="comment-index-text">第二楼内容</div><span class="report-btn" data-reportable-id="902"></span></div>
  <div id="comment-like-form-wrapper"><span style="display:none">0</span><span style="color:red">5</span><div id="reply-section-wrapper-902"></div></div>
  <br>
</div>''';
    String jsonWrapped(String fragment) =>
        jsonEncode(<String, dynamic>{'comments': fragment});

    Map<String, dynamic> embeddedSelectors() => <String, dynamic>{
          'items': r'$.comments',
          'embeddedHtml': true,
          'container': '#comment-start',
          'chunkSize': 4,
          'commentId': "substring-after(//div[starts-with(@id,'reply-section-wrapper')]/@id, 'wrapper-')",
          'author': "substring-before(//div[@class='comment-index-text'][1]//a/text(), '\u00a0')",
          'avatar': '//a/img/@src',
          'content': "//div[@class='comment-index-text'][2]",
          'time': "//div[@class='comment-index-text'][1]//span",
          'likeCount': "//div[@id='comment-like-form-wrapper']/span[2]",
          'replyCount': "//div[@class='load-replies-btn']",
        };

    test('embeddedHtml:true → JSON 内嵌 HTML 走 HTML 管线 + chunkSize 分楼', () async {
      final client = FakeCommentClient()..enqueue(jsonWrapped(hanimeFragment));
      final service = CommentApiService(client: client);
      final source = buildSource(comments: <String, dynamic>{
        'routes': {
          'list': {'url': '/loadComment?type=video&id={id}'},
          'replies': {'url': '/loadReplies?id={commentId}'},
        },
        'selectors': embeddedSelectors(),
      });

      final page = await service.fetchComments(source, '408458');

      expect(client.requests.single.url,
          'https://example.com/loadComment?type=video&id=408458');
      expect(page.comments, hasLength(2));
      final c1 = page.comments[0];
      expect(c1.id, '901');
      expect(c1.author, '甲');
      expect(c1.avatarUrl, 'https://cdn/av1.jpg');
      expect(c1.content, '第一楼内容');
      expect(c1.timeText, '1天前');
      expect(c1.likeCount, 12);
      expect(c1.replyCount, 3); // 「查看 3 則回覆」数字容错提取
      // 第二楼无 load-replies-btn → replyCount 为 null
      expect(page.comments[1].id, '902');
      expect(page.comments[1].replyCount, isNull);
      expect(page.hasMore, isTrue);
    });

    test('embeddedHtml 未声明但 items 求值为 < 开头字符串时自动转 HTML 管线', () async {
      final selectors = embeddedSelectors()..remove('embeddedHtml');
      final client = FakeCommentClient()..enqueue(jsonWrapped(hanimeFragment));
      final service = CommentApiService(client: client);
      final source = buildSource(comments: <String, dynamic>{
        'routes': {
          'list': {'url': '/loadComment?id={id}'},
        },
        'selectors': selectors,
      });
      final page = await service.fetchComments(source, 'v1');
      expect(page.comments, hasLength(2));
      expect(page.comments.first.author, '甲');
    });

    test('chunkSize 未声明时逐元素一楼（原行为不回归）', () async {
      const html = '<div class="c"><a class="author">x</a></div>'
          '<div class="c"><a class="author">y</a></div>';
      final client = FakeCommentClient()..enqueue(html);
      final service = CommentApiService(client: client);
      final source = buildSource(comments: <String, dynamic>{
        'routes': {
          'list': {'url': '/comments/{id}'},
        },
        'selectors': {
          'items': '.c',
          'author': '.author',
        },
      });
      final page = await service.fetchComments(source, 'v1');
      expect(page.comments, hasLength(2));
      expect(page.comments[0].author, 'x');
      expect(page.comments[1].author, 'y');
    });

    test('routeSelectors.replies 覆盖块级选择器：回复 step2 分楼（hanime1.me）', () async {
      // hanime1.me loadReplies 形态：{"replies":"<div id=reply-start…</div>"}
      // reply-start 直子元素 step2：每楼 2 个子元素——偶=基本信息块（内含
      // a>img 头像 / 用户名 / 内容 / report-btn），奇=点赞表单块
      // （span[style] 第2个 = 赞数）；回复楼无独立 id。
      const repliesFragment = '''
<div id="reply-start-901">
  <div class="reply-basic"><a href="https://ex.com/user/7"><img src="https://cdn/r1.jpg"></a><div class="comment-index-text"><a>子&nbsp;&nbsp;<span>3分鐘前</span></a></div><div class="comment-index-text">回覆一</div><span class="report-btn" data-reportable-type="comment" data-reportable-id="901"></span></div>
  <div class="reply-post"><span style="display:none">0</span><span style="color:red">7</span><input name="comment-like-user-id" value="u7"></div>
  <div class="reply-basic"><a href="https://ex.com/user/8"><img src="https://cdn/r2.jpg"></a><div class="comment-index-text"><a>丑&nbsp;&nbsp;<span>5分鐘前</span></a></div><div class="comment-index-text">回覆二</div><span class="report-btn" data-reportable-type="comment" data-reportable-id="902"></span></div>
  <div class="reply-post"><span style="display:none">0</span><span style="color:red">2</span><input name="comment-like-user-id" value="u8"></div>
</div>''';
      final client = FakeCommentClient()
        ..enqueue(jsonEncode(<String, dynamic>{'replies': repliesFragment}));
      final service = CommentApiService(client: client);
      // 块级 selectors 是 list 的形态（$.comments / #comment-start / chunk4）；
      // replies 路由靠 routeSelectors 覆盖为 $.replies / reply-start / step2。
      final source = buildSource(comments: <String, dynamic>{
        'routes': {
          'list': {'url': '/loadComment?type=video&id={id}'},
          'replies': {'url': '/loadReplies?id={commentId}'},
        },
        'selectors': <String, dynamic>{
          ...embeddedSelectors(),
          'routeSelectors': {
            'replies': {
              'items': r'$.replies',
              'container': "div[id^='reply-start']",
              'chunkSize': 2,
              'commentId': null,
              'author': "substring-before(//div[@class='comment-index-text'][1]//a/text(), '\u00a0')",
              'avatar': '//a/img/@src',
              'content': "//div[@class='comment-index-text'][2]",
              'time': "//div[@class='comment-index-text'][1]//span",
              'likeCount': "//div[@class='reply-post']/span[2]",
            },
          },
        },
      });

      final page = await service.fetchReplies(source, '901');

      expect(client.requests.single.url,
          'https://example.com/loadReplies?id=901');
      expect(page.comments, hasLength(2)); // 6 子元素 step2 → 3 组取齐 2 楼
      final r1 = page.comments[0];
      expect(r1.author, '子');
      expect(r1.content, '回覆一');
      expect(r1.avatarUrl, 'https://cdn/r1.jpg');
      expect(r1.timeText, '3分鐘前');
      expect(r1.likeCount, 7);
      expect(r1.id, ''); // 回复楼无独立 id
      expect(page.comments[1].author, '丑');
      expect(page.comments[1].likeCount, 2);
    });

    test('routeSelectors 值非 Map 时整体跳过（脏配置不部分吞）', () async {
      const html = '<div class="c"><a class="author">x</a></div>';
      final client = FakeCommentClient()..enqueue(html);
      final service = CommentApiService(client: client);
      final source = buildSource(comments: <String, dynamic>{
        'routes': {
          'list': {'url': '/comments/{id}'},
        },
        'selectors': {
          'items': '.c',
          'author': '.author',
          'routeSelectors': {'list': 'not-a-map'},
        },
      });
      final page = await service.fetchComments(source, 'v1');
      expect(page.comments, hasLength(1));
      expect(page.comments[0].author, 'x');
    });
  });

  group('CommentApiService 写操作', () {
    test('postComment：表单体填充占位符，successValue 判定成功', () async {
      final client = FakeCommentClient()..enqueue('{"code": 0}');
      final service = CommentApiService(client: client);
      final source = buildSource(comments: jsonComments());

      final ok = await service.postComment(source, 'v1', '好看');

      expect(ok, isTrue);
      final req = client.requests.single;
      expect(req.method, 'FORM'); // 默认表单编码
      expect(req.url, 'https://example.com/api/comments');
      expect(req.data, {'id': 'v1', 'content': '好看'}); // 体参数不做 URL 编码
    });

    test('postComment：success 不匹配 successValue 判失败', () async {
      final client = FakeCommentClient()..enqueue('{"code": 1}');
      final service = CommentApiService(client: client);
      final ok = await service.postComment(
          buildSource(comments: jsonComments()), 'v1', 'x');
      expect(ok, isFalse);
    });

    test('Content-Type: application/json 时走 JSON 体', () async {
      final client = FakeCommentClient()..enqueue('{"ok": true}');
      final service = CommentApiService(client: client);
      final source = buildSource(comments: <String, dynamic>{
        'routes': {
          'list': {'url': '/comments/{id}'},
          'post': {
            'url': '/api/comments',
            'method': 'POST',
            'headers': {'Content-Type': 'application/json'},
            'params': {'id': '{id}', 'content': '{text}'},
          },
        },
        'selectors': {
          'items': r'$.data.list',
          'success': r'$.ok',
        },
      });

      final ok = await service.postComment(source, 'v1', 'hi');

      expect(ok, isTrue); // $.ok == true 非空判成功
      expect(client.requests.single.method, 'POST');
      expect(client.requests.single.data, {'id': 'v1', 'content': 'hi'});
    });

    test('like/report：URL 占位符替换，无 success 选择器时 2xx 即成功', () async {
      final client = FakeCommentClient()
        ..enqueue('ok')
        ..enqueue('ok');
      final service = CommentApiService(client: client);
      final source = buildSource(comments: <String, dynamic>{
        'routes': {
          'list': {'url': '/comments/{id}'},
          'like': {'url': '/api/comments/{commentId}/like', 'method': 'POST'},
          'report': {
            'url': '/api/comments/{commentId}/report',
            'method': 'POST',
          },
        },
      });

      expect(await service.likeComment(source, '101'), isTrue);
      expect(await service.reportComment(source, '102'), isTrue);
      expect(client.requests[0].url,
          'https://example.com/api/comments/101/like');
      expect(client.requests[1].url,
          'https://example.com/api/comments/102/report');
    });

    test('401/403 映射为 CommentAuthRequiredException', () async {
      final client = FakeCommentClient()
        ..enqueue(const HttpStatusException(url: 'u', statusCode: 401))
        ..enqueue(const HttpStatusException(url: 'u', statusCode: 403))
        ..enqueue(const HttpStatusException(url: 'u', statusCode: 500));
      final service = CommentApiService(client: client);
      final source = buildSource(comments: jsonComments());

      expect(() => service.postComment(source, 'v1', 'x'),
          throwsA(isA<CommentAuthRequiredException>()));
      expect(() => service.likeComment(source, '1'),
          throwsA(isA<CommentAuthRequiredException>()));
      // 非登录类错误原样透出。
      expect(() => service.reportComment(source, '1'),
          throwsA(isA<HttpStatusException>()));
    });

    test('源未声明 comments 段抛 PluginConfigException', () {
      final service = CommentApiService(client: FakeCommentClient());
      expect(() => service.fetchComments(buildSource(), 'v1'),
          throwsA(isA<PluginConfigException>()));
    });
  });
}

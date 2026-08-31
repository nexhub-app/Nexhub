/// 源驱动评论服务：按源 JSON 可选 `comments` 段声明的路由与选择器拉取/发布评论。
///
/// - 路由经 [PluginConfig.resolveRouteUrl] 的 `comments.` 命名空间解析，
///   占位符替换 / 镜像切换 / 相对路径补全与主路由完全一致。
/// - 选择器与顶层 selectors 同引擎：JSON 走 [JsonPath]，HTML 走 [HtmlUtils]
///   （CSS / `a@href` / XPath）。
/// - 服务无状态；HTTP 层经 [CommentHttpClient] 注入，测试可用 fake 替换
///   （[HttpFetcher] 为私有构造单例，无法直接 mock）。
library;

import 'dart:convert';

import '../models/plugin_config.dart';
import '../network/model/effective_network_profile.dart';
import '../network/network_config_service.dart';
import '../scraper/http_fetcher.dart';
import '../scraper/verification_detector.dart';
import '../services/config_loader.dart';
import '../utils/html_utils.dart';
import '../utils/json_path.dart';
import 'package:intl/intl.dart';

/// 单条评论（含内联回复）。字段均按源 selectors 声明解析，缺失为 null。
class SourceComment {
  final String id;
  final String author;
  final String? avatarUrl;
  final String content;
  final String? timeText; // 原样展示站点时间文本，不做本地化转换
  final int? likeCount;
  final int? replyCount;
  final List<SourceComment> replies; // 列表接口内联返回的回复

  const SourceComment({
    required this.id,
    required this.author,
    this.avatarUrl,
    required this.content,
    this.timeText,
    this.likeCount,
    this.replyCount,
    this.replies = const <SourceComment>[],
  });
}

/// 一页评论：`hasMore` 由 selectors.hasMore 判定，未声明时满页推定
/// （本页非空即视为可能有下一页）。
class CommentPage {
  final List<SourceComment> comments;
  final bool hasMore;

  const CommentPage({required this.comments, required this.hasMore});

  static const CommentPage empty =
      CommentPage(comments: <SourceComment>[], hasMore: false);
}

/// 写操作需要登录（401/403 或站点登录墙）时抛出，供 UI 引导登录。
class CommentAuthRequiredException implements Exception {
  final String message;
  const CommentAuthRequiredException([this.message = '需要登录后才能执行该操作']);
  @override
  String toString() => 'CommentAuthRequiredException: $message';
}

/// 评论 HTTP 抽象：默认实现委托 [HttpFetcher.instance]，测试注入 fake。
///
/// [net] 为源的有效网络档案（[NetworkConfigService.effectiveFor]）：必须透传，
/// 否则源的 IP 钉死 / 免 SNI / 自定义 DNS 不生效，请求会以「Network is
/// unreachable」失败（表现为同源其他请求正常、只有评论挂）。
abstract class CommentHttpClient {
  Future<String> getText(
    String url, {
    Map<String, String>? headers,
    String? referer,
    EffectiveNetworkProfile? net,
  });

  Future<String> postText(
    String url, {
    Map<String, String>? headers,
    Object? data,
    String? referer,
    EffectiveNetworkProfile? net,
  });

  Future<String> postFormText(
    String url, {
    Map<String, String>? headers,
    Map<String, String>? data,
    String? referer,
    EffectiveNetworkProfile? net,
  });
}

class _FetcherCommentClient implements CommentHttpClient {
  const _FetcherCommentClient();

  @override
  Future<String> getText(
    String url, {
    Map<String, String>? headers,
    String? referer,
    EffectiveNetworkProfile? net,
  }) =>
      HttpFetcher.instance
          .getHtml(url, headers: headers, referer: referer, net: net);

  @override
  Future<String> postText(
    String url, {
    Map<String, String>? headers,
    Object? data,
    String? referer,
    EffectiveNetworkProfile? net,
  }) =>
      HttpFetcher.instance
          .post(url, headers: headers, data: data, referer: referer, net: net);

  @override
  Future<String> postFormText(
    String url, {
    Map<String, String>? headers,
    Map<String, String>? data,
    String? referer,
    EffectiveNetworkProfile? net,
  }) =>
      HttpFetcher.instance.postForm(
        url,
        headers: headers,
        data: data,
        referer: referer,
        net: net,
      );
}

class CommentApiService {
  const CommentApiService({CommentHttpClient? client})
      : _client = client ?? const _FetcherCommentClient();

  final CommentHttpClient _client;

  /// 拉取顶层评论列表（`comments.list` 路由，必需）。
  Future<CommentPage> fetchComments(
    PluginConfig source,
    String contentId, {
    int page = 1,
  }) =>
      _fetchPage(source, 'list', <String, String>{
        'id': contentId,
        'page': '$page',
      });

  /// 拉取某评论的回复分页（`comments.replies` 路由，可选）。
  Future<CommentPage> fetchReplies(
    PluginConfig source,
    String commentId, {
    int page = 1,
  }) =>
      _fetchPage(source, 'replies', <String, String>{
        'commentId': commentId,
        'page': '$page',
      });

  /// 发布顶层评论（`comments.post`）。返回是否成功（success 选择器判定）。
  Future<bool> postComment(PluginConfig source, String contentId, String text) =>
      _mutate(source, 'post', <String, String>{'id': contentId, 'text': text});

  /// 回复某评论（`comments.reply`）。
  Future<bool> postReply(PluginConfig source, String commentId, String text) =>
      _mutate(source, 'reply',
          <String, String>{'commentId': commentId, 'text': text});

  /// 点赞（`comments.like`）。
  Future<bool> likeComment(PluginConfig source, String commentId) =>
      _mutate(source, 'like', <String, String>{'commentId': commentId});

  /// 举报（`comments.report`）。
  Future<bool> reportComment(PluginConfig source, String commentId) =>
      _mutate(source, 'report', <String, String>{'commentId': commentId});

  // ---- 请求与判定 ----

  CommentsConfig _requireConfig(PluginConfig source) {
    final cfg = source.comments;
    if (cfg == null) {
      throw const PluginConfigException('源未声明 comments 配置段');
    }
    return cfg;
  }

  RouteConfig _requireRoute(CommentsConfig cfg, String name) {
    final route = cfg.routes[name];
    if (route == null) {
      throw PluginConfigException('comments 路由未声明: $name');
    }
    return route;
  }

  Future<CommentPage> _fetchPage(
    PluginConfig source,
    String name,
    Map<String, String> vars,
  ) async {
    final cfg = _requireConfig(source);
    final route = _requireRoute(cfg, name);
    final text = await _request(source, name, route, vars);
    if (_responseTypeFor(source, name, route, cfg) == 'html') {
      return _parseHtmlPage(cfg, text);
    }
    return _parseJsonPage(cfg, _decodeJson(text));
  }

  Future<bool> _mutate(
    PluginConfig source,
    String name,
    Map<String, String> vars,
  ) async {
    final cfg = _requireConfig(source);
    final route = _requireRoute(cfg, name);
    final text = await _request(source, name, route, vars);
    return _isSuccess(cfg, text);
  }

  Future<String> _request(
    PluginConfig source,
    String name,
    RouteConfig route,
    Map<String, String> vars,
  ) async {
    final base = ConfigLoader.instance.getActiveMirror(source);
    final url = source.resolveRouteUrl(
      'comments.$name',
      activeBaseUrl: base,
      vars: vars,
    );
    // 必须带上源的网络档案：源的 IP 钉死 / 免 SNI / 自定义 DNS 只有传了 net
    // 才生效，否则评论请求会走默认通道而连接失败。
    final net = NetworkConfigService.instance.effectiveFor(source);
    try {
      if (route.method.toLowerCase() == 'post') {
        final params = _filledParams(route, vars);
        // route.headers 声明 Content-Type: application/json 时发 JSON 体，
        // 否则默认表单编码（application/x-www-form-urlencoded）。
        if (_isJsonBody(route)) {
          return await _client.postText(
            url,
            headers: route.headers,
            data: params,
            referer: base,
            net: net,
          );
        }
        return await _client.postFormText(
          url,
          headers: route.headers,
          data: params,
          referer: base,
          net: net,
        );
      }
      return await _client.getText(
        url,
        headers: route.headers,
        referer: base,
        net: net,
      );
    } on HttpStatusException catch (e) {
      // 401/403：未登录或会话失效 → 引导登录（302 由 Dio 自动跟随，
      // 登录墙重定向最终多表现为 401/403 或登录页 HTML）。
      if (e.statusCode == 401 || e.statusCode == 403) {
        throw const CommentAuthRequiredException();
      }
      rethrow;
    }
  }

  /// POST 体参数：route.params 模板占位符（`{id}`/`{text}`/`{commentId}`/
  /// `{page}`）用 [vars] 原文填充（表单/JSON 编码由发送层负责，不做 URL 编码）。
  Map<String, String> _filledParams(RouteConfig route, Map<String, String> vars) {
    final out = <String, String>{};
    (route.params ?? const <String, String>{}).forEach((k, v) {
      out[k] = _fillTemplate(v, vars);
    });
    return out;
  }

  String _fillTemplate(String template, Map<String, String> vars) {
    var s = template;
    vars.forEach((k, v) {
      s = s.replaceAll('{$k}', v);
    });
    return s;
  }

  bool _isJsonBody(RouteConfig route) {
    final ct = route.headers?.entries
        .where((e) => e.key.toLowerCase() == 'content-type')
        .map((e) => e.value.toLowerCase())
        .join();
    return ct != null && ct.contains('json');
  }

  /// 响应类型判定：路由级 responseType 优先；未声明时按 items 选择器推断
  /// （`$` 开头为 JSONPath → json，否则 → html）；再回退顶层 responseType。
  String _responseTypeFor(
    PluginConfig source,
    String name,
    RouteConfig route,
    CommentsConfig cfg,
  ) {
    if (route.responseType != null) return route.responseType!;
    final items = cfg.selectors?['items'];
    if (items is String && items.isNotEmpty) {
      return items.startsWith(r'$') ? 'json' : 'html';
    }
    return source.responseTypeFor('comments.$name') ?? 'json';
  }

  /// 写操作结果判定：
  /// - selectors.success 未声明 → HTTP 2xx（未抛异常）即成功；
  /// - 声明 success（JSONPath/CSS）→ 命中值非空即成功；
  /// - 另声明 selectors.successValue → 命中值需与其字符串相等
  ///   （适配 `$.code` == "0" 才算成功一类站点）。
  bool _isSuccess(CommentsConfig cfg, String text) {
    final sel = cfg.selectors?['success'];
    if (sel is! String || sel.isEmpty) return true;
    dynamic value;
    if (sel.startsWith(r'$')) {
      final json = _tryDecodeJson(text);
      if (json == null) return false;
      value = JsonPath.eval(sel, json);
    } else {
      value = HtmlUtils.query(text, sel);
    }
    final expected = cfg.selectors?['successValue'];
    if (expected != null) {
      return value != null && value.toString() == expected.toString();
    }
    if (value == null || value is bool && !value) return false;
    final s = value.toString().trim().toLowerCase();
    return s.isNotEmpty && s != 'false' && s != 'error';
  }

  // ---- JSON 解析 ----

  dynamic _decodeJson(String text) {
    final json = _tryDecodeJson(text);
    if (json == null) {
      throw const FormatException('评论响应不是有效 JSON');
    }
    return json;
  }

  dynamic _tryDecodeJson(String text) {
    try {
      return jsonDecode(text);
    } on FormatException {
      return null;
    }
  }

  CommentPage _parseJsonPage(CommentsConfig cfg, dynamic json) {
    final sel = cfg.selectors ?? const <String, dynamic>{};
    final itemsPath = sel['items'];
    final raw = itemsPath is String ? JsonPath.eval(itemsPath, json) : null;
    final List<dynamic> list;
    if (raw is List) {
      list = raw;
    } else if (raw is Map) {
      // 兼容接口以 id 为键返回对象（如再漫画 commentList）：取值为数组。
      list = raw.values.where((e) => e != null).toList();
    } else {
      list = const <dynamic>[];
    }
    final comments = <SourceComment>[
      for (final item in list) _jsonComment(sel, item),
    ];
    return CommentPage(
      comments: comments,
      hasMore: _hasMoreJson(sel, json, comments),
    );
  }

  SourceComment _jsonComment(Map<String, dynamic> sel, dynamic item) {
    final rawReplies = _jsonValue(sel['replies'], item);
    return SourceComment(
      id: _jsonText(sel['commentId'], item) ?? '',
      author: _jsonText(sel['author'], item) ?? '',
      avatarUrl: _jsonText(sel['avatar'], item),
      content: _jsonText(sel['content'], item) ?? '',
      timeText: _formatTimeText(_jsonValue(sel['time'], item)),
      likeCount: _jsonInt(sel['likeCount'], item),
      replyCount: _jsonInt(sel['replyCount'], item),
      replies: rawReplies is List
          ? <SourceComment>[for (final r in rawReplies) _jsonComment(sel, r)]
          : const <SourceComment>[],
    );
  }

  /// JSONPath（`$` 开头）走求值器；相对键（如 `author`）直接取字段
  /// （与 BuiltinResolver 的字段取值范式一致）。
  dynamic _jsonValue(dynamic selector, dynamic item) {
    if (selector is! String || selector.isEmpty) return null;
    if (selector.startsWith(r'$')) return JsonPath.eval(selector, item);
    return item is Map ? item[selector] : null;
  }

  String? _jsonText(dynamic selector, dynamic item) {
    final v = _jsonValue(selector, item);
    if (v == null) return null;
    final s = v.toString();
    return s.isEmpty ? null : s;
  }

  int? _jsonInt(dynamic selector, dynamic item) {
    final v = _jsonValue(selector, item);
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  /// 评论时间：优先原样展示站点文本；若源返回 Unix 秒/毫秒时间戳（接口常见），
  /// 则格式化为绝对时间串（UI 不做二次转换，避免显示原始数字时间戳）。
  String? _formatTimeText(dynamic value) {
    if (value == null) return null;
    if (value is num) {
      final ms = value < 1000000000000 ? (value * 1000).toInt() : value.toInt();
      final dt = DateTime.fromMillisecondsSinceEpoch(ms);
      try {
        return DateFormat('yyyy-MM-dd HH:mm').format(dt);
      } catch (_) {
        return value.toString();
      }
    }
    final s = value.toString().trim();
    return s.isEmpty ? null : s;
  }

  bool _hasMoreJson(
    Map<String, dynamic> sel,
    dynamic json,
    List<SourceComment> comments,
  ) {
    final hasMoreSel = sel['hasMore'];
    if (hasMoreSel is String && hasMoreSel.isNotEmpty) {
      return _truthy(_jsonValue(hasMoreSel, json));
    }
    // 未声明 hasMore → 满页推定：本页非空即视为可能有下一页。
    return comments.isNotEmpty;
  }

  bool _truthy(dynamic v) {
    if (v == null) return false;
    if (v is bool) return v;
    if (v is num) return v != 0;
    final s = v.toString().trim().toLowerCase();
    return s.isNotEmpty && s != 'false' && s != '0' && s != 'null';
  }

  // ---- HTML 解析 ----

  CommentPage _parseHtmlPage(CommentsConfig cfg, String html) {
    final sel = cfg.selectors ?? const <String, dynamic>{};
    final itemsSel = sel['items'];
    if (itemsSel is! String || itemsSel.isEmpty) return CommentPage.empty;
    final items = HtmlUtils.elements(html, itemsSel);
    final comments = <SourceComment>[
      for (final el in items) _htmlComment(sel, el.outerHtml),
    ];
    final hasMoreSel = sel['hasMore'];
    final hasMore = hasMoreSel is String && hasMoreSel.isNotEmpty
        ? HtmlUtils.query(html, hasMoreSel) != null
        : comments.isNotEmpty;
    return CommentPage(comments: comments, hasMore: hasMore);
  }

  SourceComment _htmlComment(
    Map<String, dynamic> sel,
    String itemHtml, {
    bool parseReplies = true,
  }) {
    String? f(String key) {
      final s = sel[key];
      if (s is! String || s.isEmpty) return null;
      final v = HtmlUtils.queryAttrExpr(itemHtml, s);
      return (v == null || v.isEmpty) ? null : v;
    }

    // 内联回复仅解析一层：回复元素的 outerHtml 再查 replies 选择器会
    // 命中自身（解析后元素本身成为 body 后代），递归会死循环。
    final repliesSel = sel['replies'];
    final replies = <SourceComment>[];
    if (parseReplies && repliesSel is String && repliesSel.isNotEmpty) {
      for (final el in HtmlUtils.elements(itemHtml, repliesSel)) {
        replies.add(_htmlComment(sel, el.outerHtml, parseReplies: false));
      }
    }
    return SourceComment(
      id: f('commentId') ?? '',
      author: f('author') ?? '',
      avatarUrl: f('avatar'),
      content: f('content') ?? '',
      timeText: f('time'),
      likeCount: int.tryParse(f('likeCount') ?? ''),
      replyCount: int.tryParse(f('replyCount') ?? ''),
      replies: replies,
    );
  }
}

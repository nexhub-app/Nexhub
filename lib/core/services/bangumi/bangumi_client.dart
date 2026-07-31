/// Bangumi API 客户端（api.bgm.tv v0）。
///
/// - 强制可识别 User-Agent（Bangumi API 使用条款要求）；
/// - 有 token 时注入 `Authorization: Bearer`；
/// - 顺序节流（请求间隔 >= 300ms，无并发）防止触发限流；
/// - 429/5xx 指数退避重试（最多 2 次）；
/// - 统一错误封装 [BangumiApiException]。
library;

import 'package:dio/dio.dart';

import 'bangumi_models.dart';

/// Bangumi API 错误。
class BangumiApiException implements Exception {
  final int? statusCode;
  final String message;

  const BangumiApiException(this.statusCode, this.message);

  /// 是否为鉴权失败（token 无效 / 过期）。
  bool get isUnauthorized => statusCode == 401;

  @override
  String toString() => 'BangumiApiException($statusCode): $message';
}

/// Bangumi API 客户端。
///
/// token 由外部（[BangumiAuth]）通过 [token] 属性注入；未登录时公开接口
/// （搜索 / 剧集）仍可匿名调用。
class BangumiClient {
  BangumiClient({Dio? dio}) : _dio = dio ?? _buildDio();

  static const String baseUrl = 'https://api.bgm.tv';

  /// Bangumi 要求 UA 标明应用与项目地址，便于滥用时联系。
  static const String userAgent =
      'nexhub/0.1.0 (Flutter; https://github.com/nexhub/nexhub)';

  /// 顺序请求最小间隔。
  static const Duration _minInterval = Duration(milliseconds: 300);

  final Dio _dio;

  /// 当前 Bearer token（null = 匿名）。
  String? token;

  /// 上一次请求完成时间（节流用）。
  DateTime _lastRequestAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 顺序化所有请求（无并发）。
  Future<void> _pending = Future<void>.value();

  static Dio _buildDio() => Dio(BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 15),
        // 404（未收藏）等业务态码不抛异常，统一在 _request 内判定。
        validateStatus: (_) => true,
      ));

  /// 统一请求入口：顺序节流 + 退避重试 + 错误封装。
  Future<Response<dynamic>> _request(
    String method,
    String path, {
    Map<String, dynamic>? query,
    Object? body,
    Set<int> allowedStatus = const <int>{},
  }) {
    final completer = _pending.then((_) async {
      // 节流：距上次请求不足最小间隔时等待。
      final wait = _minInterval - DateTime.now().difference(_lastRequestAt);
      if (wait > Duration.zero) {
        await Future<void>.delayed(wait);
      }
      Response<dynamic>? response;
      Object? lastError;
      for (int attempt = 0; attempt <= 2; attempt++) {
        if (attempt > 0) {
          // 指数退避：1s → 2s。
          await Future<void>.delayed(Duration(seconds: 1 << (attempt - 1)));
        }
        try {
          response = await _dio.request<dynamic>(
            path,
            queryParameters: query,
            data: body,
            options: Options(
              method: method,
              headers: <String, dynamic>{
                'User-Agent': userAgent,
                if (token != null && token!.isNotEmpty)
                  'Authorization': 'Bearer $token',
              },
            ),
          );
          lastError = null;
          final code = response.statusCode ?? 0;
          // 429/5xx 可重试，其余直接返回。
          if (code != 429 && code < 500) break;
        } on DioException catch (e) {
          lastError = e;
          response = null;
        }
      }
      _lastRequestAt = DateTime.now();
      if (response == null) {
        throw BangumiApiException(null, lastError?.toString() ?? 'network error');
      }
      final code = response.statusCode ?? 0;
      final ok = (code >= 200 && code < 300) || allowedStatus.contains(code);
      if (!ok) {
        String message = 'HTTP $code';
        final data = response.data;
        if (data is Map<String, dynamic>) {
          final desc = data['description'] ?? data['title'];
          if (desc is String && desc.isNotEmpty) message = desc;
        }
        throw BangumiApiException(code, message);
      }
      return response;
    });
    // 无论成败都推进队列，避免一次失败卡死后续请求。
    _pending = completer.then((_) {}, onError: (_) {});
    return completer;
  }

  /// 验证 token 并返回用户信息（GET /v0/me）。
  Future<BangumiMe> fetchMe() async {
    final res = await _request('GET', '/v0/me');
    final data = res.data;
    if (data is! Map<String, dynamic>) {
      throw const BangumiApiException(null, 'unexpected /v0/me response');
    }
    return BangumiMe.fromJson(data);
  }

  /// OAuth 端点基址（与 API 基址 [baseUrl] 不同）。
  static const String oauthBaseUrl = 'https://bgm.tv';

  /// 用授权码换取 access_token（POST /oauth/access_token，grant_type=authorization_code）。
  ///
  /// 该端点走 [oauthBaseUrl]，与 API 端点隔离，不携带 Bearer，使用表单编码。
  /// 成功返回 [BangumiToken]；响应缺少 `access_token` 时按授权失败抛
  /// [BangumiApiException]（附 `error_description`）。
  Future<BangumiToken> exchangeCodeForToken({
    required String clientId,
    required String clientSecret,
    required String code,
    required String redirectUri,
  }) async {
    final res = await _dio.post<Map<String, dynamic>>(
      '$oauthBaseUrl/oauth/access_token',
      data: <String, String>{
        'grant_type': 'authorization_code',
        'client_id': clientId,
        'client_secret': clientSecret,
        'code': code,
        'redirect_uri': redirectUri,
      },
      options: Options(
        headers: <String, dynamic>{'User-Agent': userAgent},
        contentType: Headers.formUrlEncodedContentType,
      ),
    );
    final data = res.data;
    if (data is! Map<String, dynamic>) {
      throw const BangumiApiException(null, 'unexpected token response');
    }
    final accessToken = data['access_token'] as String?;
    if (accessToken == null || accessToken.isEmpty) {
      throw BangumiApiException(
        res.statusCode,
        (data['error_description'] as String?) ?? 'missing access_token',
      );
    }
    return BangumiToken(
      accessToken: accessToken,
      refreshToken: data['refresh_token'] as String?,
      expiresIn: (data['expires_in'] as num?)?.toInt(),
      scope: data['scope'] as String?,
    );
  }

  /// 用 refresh_token 续期（POST /oauth/access_token，grant_type=refresh_token）。
  ///
  /// 返回的 refresh_token 会与请求值不同（Bangumi 轮换），方法已回退到原值。
  Future<BangumiToken> refreshToken({
    required String clientId,
    required String clientSecret,
    required String refreshToken,
    required String redirectUri,
  }) async {
    final res = await _dio.post<Map<String, dynamic>>(
      '$oauthBaseUrl/oauth/access_token',
      data: <String, String>{
        'grant_type': 'refresh_token',
        'client_id': clientId,
        'client_secret': clientSecret,
        'refresh_token': refreshToken,
        'redirect_uri': redirectUri,
      },
      options: Options(
        headers: <String, dynamic>{'User-Agent': userAgent},
        contentType: Headers.formUrlEncodedContentType,
      ),
    );
    final data = res.data;
    if (data is! Map<String, dynamic>) {
      throw const BangumiApiException(null, 'unexpected token response');
    }
    final accessToken = data['access_token'] as String?;
    if (accessToken == null || accessToken.isEmpty) {
      throw BangumiApiException(
        res.statusCode,
        (data['error_description'] as String?) ?? 'missing access_token',
      );
    }
    return BangumiToken(
      accessToken: accessToken,
      refreshToken: (data['refresh_token'] as String?) ?? refreshToken,
      expiresIn: (data['expires_in'] as num?)?.toInt(),
      scope: data['scope'] as String?,
    );
  }

  /// 按关键字搜索条目（POST /v0/search/subjects），限定条目类型。
  Future<List<BangumiSubject>> searchSubjects(
    String keyword, {
    required List<int> types,
    int limit = 10,
  }) async {
    final res = await _request(
      'POST',
      '/v0/search/subjects',
      query: <String, dynamic>{'limit': limit},
      body: <String, dynamic>{
        'keyword': keyword,
        'filter': <String, dynamic>{'type': types},
      },
    );
    final data = res.data;
    if (data is! Map<String, dynamic>) return const <BangumiSubject>[];
    final list = data['data'];
    if (list is! List) return const <BangumiSubject>[];
    return list
        .whereType<Map<String, dynamic>>()
        .map(BangumiSubject.fromJson)
        .toList();
  }

  /// 拉取条目本篇剧集（GET /v0/episodes?subject_id=&type=0），分页拉全。
  Future<List<BangumiEpisode>> fetchEpisodes(int subjectId) async {
    final episodes = <BangumiEpisode>[];
    int offset = 0;
    const int pageSize = 100;
    while (true) {
      final res = await _request('GET', '/v0/episodes', query: <String, dynamic>{
        'subject_id': subjectId,
        'type': 0,
        'limit': pageSize,
        'offset': offset,
      });
      final data = res.data;
      if (data is! Map<String, dynamic>) break;
      final list = data['data'];
      if (list is! List) break;
      episodes.addAll(
          list.whereType<Map<String, dynamic>>().map(BangumiEpisode.fromJson));
      final total = (data['total'] as num?)?.toInt() ?? episodes.length;
      offset += pageSize;
      if (episodes.length >= total || list.isEmpty) break;
    }
    // 按 sort 升序，保证 index → 集数映射稳定。
    episodes.sort((a, b) => a.sort.compareTo(b.sort));
    return episodes;
  }

  /// 拉取条目详情（GET /v0/subjects/{id}），含站点评分、简介与标签。
  ///
  /// 公开接口（无需鉴权）；供详情页展示「来自网站」的评分与评价。
  Future<BangumiSubjectDetail> fetchSubject(int subjectId) async {
    final res = await _request('GET', '/v0/subjects/$subjectId');
    final data = res.data;
    if (data is! Map<String, dynamic>) {
      throw const BangumiApiException(null, 'unexpected subject response');
    }
    return BangumiSubjectDetail.fromJson(data);
  }

  /// 查询当前用户对某条目的收藏状态；未收藏返回 null（404）。
  Future<BangumiUserCollection?> fetchUserCollection(int subjectId) async {
    final res = await _request(
      'GET',
      '/v0/users/-/collections/$subjectId',
      allowedStatus: const <int>{404},
    );
    if (res.statusCode == 404) return null;
    final data = res.data;
    if (data is! Map<String, dynamic>) return null;
    return BangumiUserCollection.fromJson(data);
  }

  /// 新建 / 修改收藏（POST /v0/users/-/collections/{subject_id}）。
  ///
  /// 该端点对已存在的收藏同样生效（幂等更新），成功返回 202/204。
  Future<void> updateCollection(int subjectId, CollectionPayload payload) async {
    await _request(
      'POST',
      '/v0/users/-/collections/$subjectId',
      body: payload.toJson(),
    );
  }

  /// 部分更新收藏（PATCH /v0/users/-/collections/{subject_id}）。
  ///
  /// 仅携带变化字段；条目尚未收藏（404）时自动回退 POST 创建。
  Future<void> patchCollection(int subjectId, CollectionPayload payload) async {
    final res = await _request(
      'PATCH',
      '/v0/users/-/collections/$subjectId',
      body: payload.toJson(),
      allowedStatus: const <int>{404},
    );
    if (res.statusCode == 404) {
      await updateCollection(subjectId, payload);
    }
  }

  /// 读取当前用户对某条目的章节收藏状态，分页拉全
  /// （GET /v0/users/-/collections/{subject_id}/episodes）。
  ///
  /// 返回 episodeId → 章节收藏类型（0=未收藏 1=想看 2=看过 3=抛弃）；
  /// 条目未收藏（404）返回空表，供增量对比只标差集。
  Future<Map<int, int>> fetchCollectedEpisodes(int subjectId) async {
    final result = <int, int>{};
    int offset = 0;
    const int pageSize = 100;
    while (true) {
      final res = await _request(
        'GET',
        '/v0/users/-/collections/$subjectId/episodes',
        query: <String, dynamic>{'limit': pageSize, 'offset': offset},
        allowedStatus: const <int>{404},
      );
      if (res.statusCode == 404) return result;
      final data = res.data;
      if (data is! Map<String, dynamic>) break;
      final list = data['data'];
      if (list is! List) break;
      for (final item in list.whereType<Map<String, dynamic>>()) {
        final episode = item['episode'];
        final id = episode is Map<String, dynamic>
            ? (episode['id'] as num?)?.toInt() ?? 0
            : 0;
        if (id > 0) {
          result[id] = (item['type'] as num?)?.toInt() ?? 0;
        }
      }
      final total = (data['total'] as num?)?.toInt() ?? result.length;
      offset += pageSize;
      if (result.length >= total || list.isEmpty) break;
    }
    return result;
  }

  /// 分页拉取用户收藏列表（GET /v0/users/{username}/collections）。
  ///
  /// [subjectType] 限定条目类型；[collectionType] 限定收藏状态
  /// （[BangumiCollectionType] 五状态之一，null = 不限）。
  /// 用于「从 Bangumi 导入」按标题匹配建绑定与设置页收藏浏览。
  Future<List<BangumiUserCollection>> fetchUserCollections(
    String username, {
    required int subjectType,
    int? collectionType,
  }) async {
    final collections = <BangumiUserCollection>[];
    int offset = 0;
    const int pageSize = 50;
    while (true) {
      final res = await _request(
        'GET',
        '/v0/users/$username/collections',
        query: <String, dynamic>{
          'subject_type': subjectType,
          if (collectionType != null) 'type': collectionType,
          'limit': pageSize,
          'offset': offset,
        },
      );
      final data = res.data;
      if (data is! Map<String, dynamic>) break;
      final list = data['data'];
      if (list is! List) break;
      collections.addAll(list
          .whereType<Map<String, dynamic>>()
          .map(BangumiUserCollection.fromJson));
      final total = (data['total'] as num?)?.toInt() ?? collections.length;
      offset += pageSize;
      if (collections.length >= total || list.isEmpty) break;
    }
    return collections;
  }

  /// 批量标记剧集为看过（PATCH /v0/users/-/collections/{subject_id}/episodes）。
  ///
  /// 批量端点不可用（405/404）时回退逐集
  /// `PUT /v0/users/-/collections/-/episodes/{episode_id}`。
  Future<void> markEpisodesWatched(int subjectId, List<int> episodeIds) async {
    if (episodeIds.isEmpty) return;
    try {
      await _request(
        'PATCH',
        '/v0/users/-/collections/$subjectId/episodes',
        body: <String, dynamic>{
          'episode_id': episodeIds,
          'type': 2, // 2 = 看过
        },
      );
      return;
    } on BangumiApiException catch (e) {
      // 端点缺失时回退逐集标记；鉴权/参数错误直接上抛。
      if (e.statusCode != 404 && e.statusCode != 405) rethrow;
    }
    for (final id in episodeIds) {
      await _request(
        'PUT',
        '/v0/users/-/collections/-/episodes/$id',
        body: <String, dynamic>{'type': 2},
      );
    }
  }
}

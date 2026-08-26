import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../settings/danmaku_config.dart';
import 'dandanplay_parser.dart';
import 'danmaku_source.dart';
/// 弹弹play 弹幕服务。
///
/// 签名算法：`base64(sha256(AppId+Timestamp+Path+AppSecret))`
/// 请求头：`X-AppId`、`X-Timestamp`、`X-Signature`
///
/// 按官方 OpenAPI，所有发往 api.dandanplay.net 的请求都必须带应用级签名。
/// 因此本服务在未配置凭据时直接抛出异常，由上层转换为友好提示，
/// 而不是静默返回空结果。
class DandanplayService implements DanmakuSource {
  DandanplayService({
    required DanmakuConfigStore configStore,
    Dio? dio,
  })  : _configStore = configStore,
        _dio = dio ??
            Dio(BaseOptions(
              baseUrl: _baseUrl,
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 12),
              followRedirects: true,
            ));

  static const String _baseUrl = 'https://api.dandanplay.net';

  /// 无真实文件时使用的占位 hash（空文件 MD5）。
  static const String _placeholderFileHash =
      'd41d8cd98f00b204e9800998ecf8427e';

  final DanmakuConfigStore _configStore;
  final Dio _dio;

  DanmakuConfig? _cachedConfig;

  @override
  DanmakuSourceType get type => DanmakuSourceType.dandanplay;

  @override
  String get name => 'DanDanPlay';

  /// 加载最新凭据。
  Future<DanmakuConfig> _loadConfig() async {
    final cfg = await _configStore.load();
    _cachedConfig = cfg;
    return cfg;
  }

  /// 是否启用弹幕。
  ///
  /// 不再要求凭据已配置——签名所需 AppId/Secret 由本服务在请求时读取，
  /// 未配置时会在请求阶段抛出异常并提示用户。
  @override
  bool get isAvailable {
    final cfg = _cachedConfig;
    if (cfg == null) return false;
    return cfg.enabled;
  }

  /// 刷新可用性状态（在使用前调用）。
  Future<void> refreshAvailability() async {
    await _loadConfig();
  }

  /// 搜索番剧。
  ///
  /// 对应 `GET /api/v2/search/anime?keyword={keyword}`。
  @override
  Future<List<DanmakuSearchResult>> search(String keyword) async {
    const path = '/api/v2/search/anime';
    final query = <String, dynamic>{'keyword': keyword};
    final json = await _request(path, query);
    return DandanplayParser.parseSearchResponse(json);
  }

  /// 获取某番剧的剧集列表。
  ///
  /// 对应 `GET /api/v2/search/episodes?anime={animeTitle}`。
  /// 注意：该接口按**作品标题**搜索，而非 animeId。
  @override
  Future<List<DanmakuEpisode>> getEpisodes(String animeTitle) async {
    const path = '/api/v2/search/episodes';
    final query = <String, dynamic>{'anime': animeTitle};
    final json = await _request(path, query);
    return DandanplayParser.parseEpisodesResponse(json);
  }

  /// 获取指定 episodeId 的弹幕。
  ///
  /// 对应 `GET /api/v2/comment/{episodeId}?withRelated=true`。
  @override
  Future<List<ParsedDanmakuItem>> getComments(String episodeId) async {
    final path = '/api/v2/comment/$episodeId';
    final query = <String, dynamic>{'withRelated': 'true'};
    final json = await _request(path, query);
    return DandanplayParser.parseCommentResponse(json);
  }

  /// 文件识别（match）。
  ///
  /// 对应 `POST /api/v2/match`。服务器要求请求体中必须包含 `fileHash` 与
  /// `fileSize` 字段（即使只是占位值），否则返回「一个或多个参数不符合规则」。
  ///
  /// [fileName] 可为清洗后的番剧标题或含集数的文件名；
  /// [fileHash] / [fileSize] 为真实本地文件信息，流视频无法获取时留空，
  /// 本方法会自动填入占位值以满足接口校验。
  ///
  /// 无真实 fileHash 时使用 `fileNameOnly` 匹配模式，避免占位 hash
  /// 在服务端产生错误的 hash 命中；仅当持有真实 hash 时才用
  /// `hashAndFileName`。
  ///
  /// 返回候选匹配（含 episodeId / animeId / isMatched 精确匹配标志）。
  /// 匹配失败 / 网络错误均返回空列表，不影响主流程。
  Future<List<DandanplayMatchEpisode>> matchFile({
    String? fileName,
    String? fileHash,
    int? fileSize,
    int? videoDuration,
  }) async {
    final hasRealHash = fileHash != null && fileHash.isNotEmpty;
    final body = <String, dynamic>{
      'fileHash': hasRealHash ? fileHash : _placeholderFileHash,
      'fileSize': fileSize ?? 0,
      if (fileName != null && fileName.isNotEmpty) 'fileName': fileName,
      if (videoDuration != null && videoDuration > 0)
        'videoDuration': videoDuration,
      'matchMode': hasRealHash ? 'hashAndFileName' : 'fileNameOnly',
    };
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/api/v2/match',
        data: body,
        options: Options(
          headers: <String, String>{
            ...await _authHeaders('/api/v2/match'),
            'User-Agent': 'NexHub/1.0',
            'Accept': 'application/json',
          },
          responseType: ResponseType.json,
        ),
      );
      final data = response.data;
      if (data == null) return const <DandanplayMatchEpisode>[];
      return DandanplayMatchEpisode.parseList(data);
    } on Object catch (e, st) {
      if (kDebugMode) {
        debugPrint('DandanPlay matchFile failed: $e\n$st');
      }
      return const <DandanplayMatchEpisode>[];
    }
  }

  /// 弹弹play 账号登录（F-18 发送弹幕前置）。
  ///
  /// 对应 `POST /api/v2/login`（官方账号服务器）：
  /// - 请求体含 `{userName, password, appId, unixTimestamp, hash}`，
  ///   其中 `hash = md5(AppId + Password + Timestamp + UserName + AppSecret)`；
  /// - 响应携带用户级 token（后续发送弹幕以 `Authorization: Bearer` 携带）
  /// 与用户信息。
  ///
  /// 凭据未配置时抛 [StateError]；账号密码错误 / 网络异常原样抛出由 UI 提示。
  Future<DandanplayLoginResult> login(String userName, String password) async {
    const path = '/api/v2/login';
    final cfg = await _loadConfig();
    if (!cfg.isConfigured) {
      throw StateError('DanDanPlay credentials not configured');
    }
    final timestamp =
        DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    final hash = md5
        .convert(utf8.encode('${cfg.appId}$password$timestamp$userName${cfg.appSecret}'))
        .toString();
    final response = await _dio.post<Map<String, dynamic>>(
      path,
      data: <String, dynamic>{
        'userName': userName,
        'password': password,
        'appId': cfg.appId,
        'unixTimestamp': timestamp,
        'hash': hash,
      },
      options: Options(
        headers: <String, String>{
          ..._signHeaders(cfg, path),
          'User-Agent': 'NexHub/1.0',
          'Accept': 'application/json',
        },
        responseType: ResponseType.json,
      ),
    );
    final data = response.data;
    if (data == null) throw StateError('DanDanPlay empty response');
    return DandanplayLoginResult.fromResponseJson(data, userName);
  }

  /// 弹弹play 新用户注册（"增加弹弹play新用户注册"）。
  ///
  /// 对应 `POST /api/v2/register`（官方账号服务器）：
  /// - 请求体在登录字段基础上增加 `email` 与 `screenName`，并复用同一套
  ///   `hash = md5(AppId + Password + Timestamp + UserName + AppSecret)` 与
  ///   应用级签名头；
  /// - 成功响应与登录一致（`LoginResponse`，携带 token + 用户信息），可直接
  ///   复用 [DandanplayLoginResult] 并自动登录。
  ///
  /// 凭据未配置 / 参数校验失败（用户名已存在、邮箱格式错误等）原样抛出
  /// [StateError]，由 UI 提示。
  Future<DandanplayLoginResult> register({
    required String userName,
    required String password,
    required String email,
    required String screenName,
  }) async {
    const path = '/api/v2/register';
    final cfg = await _loadConfig();
    if (!cfg.isConfigured) {
      throw StateError('DanDanPlay credentials not configured');
    }
    final timestamp =
        DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    final hash = md5
        .convert(utf8.encode('${cfg.appId}$password$timestamp$userName${cfg.appSecret}'))
        .toString();
    final response = await _dio.post<Map<String, dynamic>>(
      path,
      data: <String, dynamic>{
        'userName': userName,
        'password': password,
        'email': email,
        'screenName': screenName,
        'appId': cfg.appId,
        'unixTimestamp': timestamp,
        'hash': hash,
      },
      options: Options(
        headers: <String, String>{
          ..._signHeaders(cfg, path),
          'User-Agent': 'NexHub/1.0',
          'Accept': 'application/json',
        },
        responseType: ResponseType.json,
      ),
    );
    final data = response.data;
    if (data == null) throw StateError('DanDanPlay empty response');
    return DandanplayLoginResult.fromResponseJson(data, userName);
  }

  /// 上传弹幕到指定剧集（F-18）。
  ///
  /// 对应 `POST /api/v2/comment/{episodeId}`：
  /// - 需应用级签名 + 用户级 `Authorization: Bearer {token}`（未登录时服务器拒绝）；
  /// - [time] 为视频内秒数；[mode]：1=滚动 / 4=底部 / 5=顶部；[color] 为 RGB 整数。
  ///
  /// 成功返回弹幕 cid；失败（未登录 / 校验不过 / 网络）原样抛出由 UI 提示。
  Future<String> sendComment({
    required String episodeId,
    required double time,
    required int mode,
    required int color,
    required String comment,
    required String bearerToken,
  }) async {
    final path = '/api/v2/comment/$episodeId';
    final response = await _dio.post<Map<String, dynamic>>(
      path,
      data: <String, dynamic>{
        'time': time,
        'mode': mode,
        'color': color & 0xFFFFFF,
        'comment': comment,
      },
      options: Options(
        headers: <String, String>{
          ...await _authHeaders(path),
          'Authorization': 'Bearer $bearerToken',
          'User-Agent': 'NexHub/1.0',
          'Accept': 'application/json',
        },
        responseType: ResponseType.json,
      ),
    );
    final success = response.data?['success'] == true;
    if (!success) {
      throw StateError(
          'DanDanPlay sendComment rejected: ${response.data?['errorMessage'] ?? response.statusCode}');
    }
    return response.data?['cid']?.toString() ?? '';
  }

  /// 构造当前请求所需的签名头。
  ///
  /// 未配置凭据时抛出 [StateError]，由调用方转换为友好提示。
  Future<Map<String, String>> _authHeaders(String path) async {
    final cfg = await _loadConfig();
    if (!cfg.isConfigured) {
      throw StateError('DanDanPlay credentials not configured');
    }
    return _signHeaders(cfg, path);
  }

  /// 已持有配置时构造签名头（login 等已校验过凭据的路径复用）。
  Map<String, String> _signHeaders(DanmakuConfig cfg, String path) {
    final timestamp = _timestamp();
    final signature = _sign(cfg.appId, cfg.appSecret, timestamp, path);
    return <String, String>{
      'X-AppId': cfg.appId,
      'X-Timestamp': timestamp,
      'X-Signature': signature,
    };
  }

  /// 带签名的 GET 请求。
  Future<Map<String, dynamic>> _request(
    String path,
    Map<String, dynamic> query,
  ) async {
    final response = await _dio.get<Map<String, dynamic>>(
      path,
      queryParameters: query,
      options: Options(
        headers: <String, String>{
          ...await _authHeaders(path),
          'User-Agent': 'NexHub/1.0',
          'Accept': 'application/json',
        },
        responseType: ResponseType.json,
      ),
    );

    final data = response.data;
    if (data == null) throw StateError('DanDanPlay empty response');
    return data;
  }

  /// Unix 时间戳（秒）。
  static String _timestamp() =>
      (DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000).toString();

  /// 签名：`base64(sha256(AppId+Timestamp+Path+AppSecret))`。
  static String _sign(
      String appId, String appSecret, String timestamp, String path) {
    final raw = '$appId$timestamp$path$appSecret';
    final digest = sha256.convert(utf8.encode(raw));
    return base64Encode(digest.bytes);
  }
}

/// `/api/v2/match` 接口的候选匹配项。
class DandanplayMatchEpisode {
  const DandanplayMatchEpisode({
    required this.episodeId,
    required this.animeId,
    required this.animeTitle,
    required this.episodeTitle,
    this.isMatched = false,
  });

  final String episodeId;
  final String animeId;
  final String animeTitle;
  final String episodeTitle;

  /// 服务端返回的精确匹配标志（响应顶层 `isMatched`）。
  ///
  /// 为 true 时表示服务器确信该候选与文件精确对应；为 false 时仅为
  /// 模糊候选，调用方须自行校验作品标题相似度后再采纳。
  final bool isMatched;

  static List<DandanplayMatchEpisode> parseList(Map<String, dynamic> json) {
    final matches = json['matches'];
    if (matches is! List) return const <DandanplayMatchEpisode>[];
    final isMatched = json['isMatched'] == true;
    return matches
        .whereType<Map<String, dynamic>>()
        .map((m) => DandanplayMatchEpisode(
              episodeId: _asString(m['episodeId']),
              animeId: _asString(m['animeId']),
              animeTitle: _asString(m['animeTitle']),
              episodeTitle: _asString(m['episodeTitle']),
              isMatched: isMatched,
            ))
        .where((e) => e.episodeId.isNotEmpty)
        .toList(growable: false);
  }

  static String _asString(dynamic v) => v?.toString() ?? '';
}

/// `/api/v2/login` 与 `/api/v2/register` 共用的成功结果（F-18）。
class DandanplayLoginResult {
  const DandanplayLoginResult({
    required this.token,
    required this.userName,
    required this.screenName,
  });

  /// 用户级访问令牌（发送弹幕以 `Authorization: Bearer` 携带）。
  final String token;

  /// 登录名。
  final String userName;

  /// 展示昵称；服务器未返回时为空串，展示层回退 [userName]。
  final String screenName;

  /// 从 `LoginResponse`（login / register 共用，= `ResponseBase` + 用户字段）
  /// 解析。兼容嵌套 `user` 与扁平两种返回结构。
  ///
  /// `errorCode != 0` 或 `success == false` 时抛出 [StateError] 并携带服务器
  /// `errorMessage`（含 `errorDetail`），便于 UI 直接展示失败原因
  /// （用户名已存在、邮箱格式错误、密码长度不符等）。
  factory DandanplayLoginResult.fromResponseJson(
    Map<String, dynamic> data,
    String fallbackUserName,
  ) {
    final errorCode = data['errorCode'];
    final success = data['success'];
    if ((success is bool && !success) ||
        (errorCode is int && errorCode != 0)) {
      final msg = data['errorMessage']?.toString();
      final detail = data['errorDetail']?.toString();
      final reason = (detail != null && detail.isNotEmpty)
          ? '$msg（$detail）'
          : (msg?.isNotEmpty == true ? msg! : 'DanDanPlay request failed');
      throw StateError(reason);
    }
    final token = data['token']?.toString() ?? '';
    if (token.isEmpty) {
      throw StateError('DanDanPlay request failed: no token in response');
    }
    final user = data['user'];
    final String userName;
    final String screenName;
    if (user is Map) {
      userName = user['userName']?.toString() ?? fallbackUserName;
      screenName = user['screenName']?.toString() ?? '';
    } else {
      userName = data['userName']?.toString() ?? fallbackUserName;
      screenName = data['screenName']?.toString() ?? '';
    }
    return DandanplayLoginResult(
      token: token,
      userName: userName,
      screenName: screenName,
    );
  }
}

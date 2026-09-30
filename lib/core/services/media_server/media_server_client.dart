/// 媒体服务器 API 客户端基类与装配。
///
/// - 每台服务器一个 Dio 实例（baseUrl 动态），connect/receive 超时 8s；
/// - 拦截器统一注入 Authorization 头（scheme 由方言决定：MediaBrowser/Emby），
///   另附 `X-Emby-Token` 头双保险，待实测收敛后裁剪；
/// - 非 2xx 统一映射为 [MediaServerApiException]（401 → isUnauthorized）；
/// - 两家端点差异收敛在子类路径 hook（见 JellyfinClient / EmbyClient），
///   响应结构两家一致为主，解析集中在基类防御式处理；
/// - 字段名按官方 API 文档落地，最终以真机实测返回修正（TODO 文档 §八 M2）。
library;

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive/hive.dart';

import '../../comic/models/reader_preferences.dart';
import 'emby_client.dart';
import 'jellyfin_client.dart';
import 'media_server_auth.dart';
import 'media_server_models.dart';

/// 直连协商的码率上限（首版直连优先，给高值促使服务器报 DirectPlay）。
const int kMaxStreamingBitrate = 200000000;

/// 客户端基类：HTTP 装配、鉴权头、错误映射、公共解析都在这里；
/// 子类只提供端点路径与鉴权 scheme 的方言差异。
abstract class MediaServerClientBase {
  MediaServerClientBase({
    required this.info,
    required this.deviceId,
    String? token,
    String? deviceName,
    this.clientName = 'NexHub',
    this.appVersion = '1.0.0',
    Dio? dio,
  })  : token = token,
        _deviceName = deviceName ?? _defaultDeviceName(),
        _dio = dio ?? _buildDio(info.baseUrl) {
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          options.headers['Authorization'] = authorizationHeader();
          final t = token;
          if (t != null && t.isNotEmpty) {
            options.headers['X-Emby-Token'] = t;
          }
          handler.next(options);
        },
      ),
    );
  }

  /// 本客户端对应的服务器档案。
  final MediaServerInfo info;

  /// 安装级稳定 deviceId（Authorization 头需要；来自 MediaServerAuth.deviceId）。
  final String deviceId;
  final String clientName;
  final String appVersion;

  final Dio _dio;

  /// 当前 AccessToken（对齐 BangumiClient 的可写字段惯例；空 = 未登录）。
  String? token;
  final String _deviceName;

  // ---------- 方言 hook（子类覆盖） ----------

  /// Authorization 头 scheme：Jellyfin 为 `MediaBrowser`，Emby 为 `Emby`。
  String get authScheme;

  /// 通用列表端点（含 /Items 风格差异）。
  String itemsPath(String userId);

  /// 媒体库列表端点（UserViews）。
  String viewsPath(String userId);

  /// 最新添加端点。
  String latestPath(String userId);

  /// 继续观看端点。
  String resumePath(String userId);

  /// 列表类端点是否需要在 query 上补 userId（Jellyfin 需要；Emby 已在路径内）。
  bool get itemsQueryNeedsUserId;

  // ---------- 工厂 ----------

  /// 按服务器类型创建对应方言客户端。
  static MediaServerClientBase createServerClient(
    MediaServerInfo info, {
    required String deviceId,
    String? token,
    String? deviceName,
    String clientName = 'NexHub',
    String appVersion = '1.0.0',
    Dio? dio,
  }) =>
      info.type == ServerType.emby
          ? EmbyClient(
              info: info,
              deviceId: deviceId,
              token: token,
              deviceName: deviceName,
              clientName: clientName,
              appVersion: appVersion,
              dio: dio,
            )
          : JellyfinClient(
              info: info,
              deviceId: deviceId,
              token: token,
              deviceName: deviceName,
              clientName: clientName,
              appVersion: appVersion,
              dio: dio,
            );

  // ---------- 探测 / 登录（无实例态，预 token 请求） ----------

  /// 服务器类型探测：`GET /System/Info/Public`（两家匿名开放）。
  ///
  /// 识别失败抛 [MediaServerApiException]（由上层提示手选或查地址）。
  static Future<MediaServerProbeResult> probe(String baseUrl, {Dio? dio}) async {
    final http = dio ?? _buildDio(baseUrl);
    try {
      final resp = await http.get<dynamic>('/System/Info/Public');
      final data = resp.data;
      if (data is! Map) {
        throw const MediaServerApiException(null, 'malformed probe response');
      }
      final type = ServerType.fromProductName(data['ProductName'] as String?) ??
          ServerType.fromVersion(data['Version'] as String?);
      if (type == null) {
        throw const MediaServerApiException(
          null,
          'unrecognized server product (try manual type)',
        );
      }
      return MediaServerProbeResult(
        type: type,
        serverName: data['ServerName'] as String?,
        version: data['Version'] as String?,
      );
    } on DioException catch (e) {
      throw _mapDioError(e);
    }
  }

  /// 用户名密码登录：`POST /Users/AuthenticateByName`。
  ///
  /// 凭证错误（401）上抛 [MediaServerApiException.isUnauthorized]。
  static Future<MediaServerLoginResult> authenticateByName({
    required String baseUrl,
    required ServerType type,
    required String username,
    required String password,
    required String deviceId,
    String? deviceName,
    String clientName = 'NexHub',
    String appVersion = '1.0.0',
    Dio? dio,
  }) async {
    final http = dio ?? _buildDio(baseUrl);
    final authHeader = _authorizationValue(
      scheme: type == ServerType.emby ? 'Emby' : 'MediaBrowser',
      clientName: clientName,
      deviceName: deviceName ?? _defaultDeviceName(),
      deviceId: deviceId,
      appVersion: appVersion,
    );
    try {
      final resp = await http.post<dynamic>(
        '/Users/AuthenticateByName',
        data: <String, dynamic>{'Username': username, 'Pw': password},
        options: Options(headers: <String, String>{'Authorization': authHeader}),
      );
      final data = resp.data;
      if (data is! Map) {
        throw const MediaServerApiException(null, 'malformed auth response');
      }
      final accessToken = data['AccessToken'] as String?;
      final user = data['User'];
      if (accessToken == null || accessToken.isEmpty || user is! Map) {
        throw const MediaServerApiException(null, 'malformed auth response');
      }
      return MediaServerLoginResult(
        accessToken: accessToken,
        userId: user['Id'] as String? ?? '',
        username: user['Name'] as String? ?? username,
      );
    } on DioException catch (e) {
      throw _mapDioError(e);
    }
  }

  /// 把 API 客户端实现接入 [MediaServerAuth] 的探测 / 登录接缝
  /// （应用装配点；测试可改注入假接缝）。
  static MediaServerAuth createMediaServerAuth({
    FlutterSecureStorage? storage,
    Box<dynamic>? box,
    PrefsBackend? prefs,
  }) =>
      MediaServerAuth(
        storage: storage,
        box: box,
        prefs: prefs,
        probe: (String baseUrl) => MediaServerClientBase.probe(baseUrl),
        authenticate: (
          String baseUrl,
          ServerType type, {
          required String username,
          required String password,
          required String deviceId,
        }) =>
            MediaServerClientBase.authenticateByName(
              baseUrl: baseUrl,
              type: type,
              username: username,
              password: password,
              deviceId: deviceId,
            ),
      );

  // ---------- 浏览 ----------

  /// 媒体库列表（UserViews）。
  Future<List<ServerLibrary>> fetchLibraries() async {
    final resp = await _send(
      () => _dio.get<dynamic>(viewsPath(info.userId), queryParameters: _userQuery()),
    );
    final items = _itemsOf(resp.data);
    return items
        .whereType<Map>()
        .map(_parseLibrary)
        .where((l) => l.id.isNotEmpty)
        .toList();
  }

  /// 最新添加横排（默认按服务器排序，裸数组返回）。
  Future<List<ServerMediaItem>> fetchLatest({int limit = 20}) async {
    final resp = await _send(
      () => _dio.get<dynamic>(
            latestPath(info.userId),
            queryParameters: <String, dynamic>{
              ..._userQuery(),
              'Limit': limit,
            },
          ),
    );
    return _itemsOf(resp.data).whereType<Map>().map(_parseItem).toList();
  }

  /// 继续观看（Resume）。
  Future<ServerItemPage> fetchResume({int startIndex = 0, int limit = 30}) async {
    final resp = await _send(
      () => _dio.get<dynamic>(
            resumePath(info.userId),
            queryParameters: <String, dynamic>{
              ..._userQuery(),
              'StartIndex': startIndex,
              'Limit': limit,
              'Fields': 'Overview',
            },
          ),
    );
    return _pageOf(resp.data, startIndex);
  }

  /// 通用列表 / 服务器内搜索。
  ///
  /// 库内浏览传 [parentId]（媒体库 id）；全服务器搜索传 [searchTerm]。
  Future<ServerItemPage> fetchItems({
    String? parentId,
    String? searchTerm,
    List<String> includeTypes = const <String>['Movie', 'Series'],
    int startIndex = 0,
    int limit = 30,
    String sortBy = 'SortName',
    String sortOrder = 'Ascending',
  }) async {
    final resp = await _send(
      () => _dio.get<dynamic>(
            itemsPath(info.userId),
            queryParameters: <String, dynamic>{
              ..._userQuery(),
              'StartIndex': startIndex,
              'Limit': limit,
              'IncludeItemTypes': includeTypes.join(','),
              'Recursive': true,
              // 实测：列表查询默认不返回 ProductionYear，需显式请求。
              'Fields': 'Overview,ProductionYear',
              'SortBy': sortBy,
              'SortOrder': sortOrder,
              if (parentId != null && parentId.isNotEmpty) 'ParentId': parentId,
              if (searchTerm != null && searchTerm.isNotEmpty)
                'SearchTerm': searchTerm,
            },
          ),
    );
    return _pageOf(resp.data, startIndex);
  }

  /// 条目详情（电影 / 剧集 / 集）。
  Future<ServerMediaItem> fetchItem(String itemId) async {
    final resp = await _send(
      () => _dio.get<dynamic>('/Users/${info.userId}/Items/$itemId'),
    );
    final data = resp.data;
    if (data is! Map) {
      throw const MediaServerApiException(null, 'malformed item response');
    }
    return _parseItem(data.cast<String, dynamic>());
  }

  /// 剧集的季列表。
  Future<List<ServerMediaItem>> fetchSeasons(String seriesId) async {
    final resp = await _send(
      () => _dio.get<dynamic>(
            '/Shows/$seriesId/Seasons',
            queryParameters: _userQuery(),
          ),
    );
    return _itemsOf(resp.data).whereType<Map>().map(_parseItem).toList();
  }

  /// 剧集某季的集列表。
  ///
  /// 额外请求 MediaStreams：集卡片需判断图形字幕（PGS）直连不可播。
  Future<List<ServerMediaItem>> fetchEpisodes(
    String seriesId, {
    String? seasonId,
  }) async {
    final resp = await _send(
      () => _dio.get<dynamic>(
            '/Shows/$seriesId/Episodes',
            queryParameters: <String, dynamic>{
              ..._userQuery(),
              'Fields': 'MediaStreams',
              if (seasonId != null && seasonId.isNotEmpty) 'SeasonId': seasonId,
            },
          ),
    );
    return _itemsOf(resp.data).whereType<Map>().map(_parseItem).toList();
  }

  /// 海报地址（图片端点两家一致；鉴权需求以实测为准，加载器可附 [authHeaders]）。
  String imageUrl(String itemId, {int maxWidth = 400}) =>
      '${info.baseUrl}/Items/$itemId/Images/Primary?maxWidth=$maxWidth&quality=90';

  /// 横幅剧照地址（详情页沉浸式头图用；无剧照时由加载层回退海报）。
  String backdropUrl(String itemId, {int maxWidth = 1200}) =>
      '${info.baseUrl}/Items/$itemId/Images/Backdrop?maxWidth=$maxWidth&quality=80';

  /// 台标（ClearLogo）地址（详情页标题优先显示；缺失由加载层回退文字）。
  String logoUrl(String itemId, {int maxWidth = 600}) =>
      '${info.baseUrl}/Items/$itemId/Images/Logo?maxWidth=$maxWidth&quality=90';

  // ---------- 播放协商 ----------

  /// 播放协商：取 MediaSources[0] 判定直连可行性（决策树见 TODO 文档 M5）。
  ///
  /// 仅转码可用时返回 `requiresTranscode: true`（playUrl 为空），
  /// 无任何可用媒体源时抛 [MediaServerApiException]。
  /// 接收超时放宽到 20s：慢速服务器（公益机）协商可能明显久于普通请求。
  Future<PlaybackInfoResult> createPlaybackInfo(
    String itemId, {
    int? maxStreamingBitrate,
  }) async {
    final resp = await _send(
      () => _dio.post<dynamic>(
            '/Items/$itemId/PlaybackInfo',
            queryParameters: _userQuery(),
            options: Options(
              receiveTimeout: const Duration(seconds: 20),
            ),
            data: <String, dynamic>{
              'UserId': info.userId,
              'MaxStreamingBitrate':
                  maxStreamingBitrate ?? kMaxStreamingBitrate,
            },
          ),
    );
    final data = resp.data;
    if (data is! Map) {
      throw const MediaServerApiException(null, 'malformed playback info');
    }
    final sources = data['MediaSources'];
    if (sources is! List || sources.isEmpty) {
      throw const MediaServerApiException(null, 'no playable media source');
    }
    final ms = sources.first;
    if (ms is! Map) {
      throw const MediaServerApiException(null, 'malformed media source');
    }
    final playSessionId = data['PlaySessionId'] as String? ?? '';
    final mediaSourceId = ms['Id'] as String? ?? itemId;
    final supportsDirectPlay = ms['SupportsDirectPlay'] == true;
    final supportsDirectStream = ms['SupportsDirectStream'] == true;
    final directStreamUrl = ms['DirectStreamUrl'] as String?;

    String? playUrl;
    if (supportsDirectPlay) {
      playUrl = '${info.baseUrl}/Videos/$itemId/stream'
          '?static=true&MediaSourceId=$mediaSourceId&PlaySessionId=$playSessionId';
    } else if (supportsDirectStream && directStreamUrl != null) {
      playUrl = directStreamUrl.startsWith('http')
          ? directStreamUrl
          : '${info.baseUrl}$directStreamUrl';
    }
    // 流地址自鉴权：把 api_key 拼进查询串（参考库同法）。mpv/ffmpeg 跟随
    // 302 重定向时不转发自定义请求头，仅靠 Authorization 头会让流请求
    // 401 卡死（元数据永远不到、表现为无限加载）；请求头仍保留双保险。
    if (playUrl != null) {
      playUrl = _appendApiKey(playUrl);
    }
    return PlaybackInfoResult(
      playSessionId: playSessionId,
      playUrl: playUrl ?? '',
      headers: authHeaders(),
      runTimeTicks: (ms['RunTimeTicks'] as num?)?.toInt(),
      container: ms['Container'] as String?,
      requiresTranscode: playUrl == null,
    );
  }

  // ---------- 播放会话上报与已看标记 ----------

  /// 开始上报：`POST /Sessions/Playing`。
  Future<void> reportPlayingStart({
    required String itemId,
    String? playSessionId,
    int? positionTicks,
    String playMethod = 'DirectPlay',
  }) async {
    await _send(
      () => _dio.post<dynamic>(
            '/Sessions/Playing',
            data: <String, dynamic>{
              'ItemId': itemId,
              'PlaySessionId': playSessionId,
              'PlayMethod': playMethod,
              if (positionTicks != null) 'PositionTicks': positionTicks,
            },
          ),
    );
  }

  /// 进度心跳（约 10s 一次；暂停 / seek 后立即补报一次）。
  Future<void> reportPlayingProgress({
    required String itemId,
    required int positionTicks,
    bool isPaused = false,
    String? playSessionId,
  }) async {
    await _send(
      () => _dio.post<dynamic>(
            '/Sessions/Playing/Progress',
            data: <String, dynamic>{
              'ItemId': itemId,
              'PlaySessionId': playSessionId,
              'PositionTicks': positionTicks,
              'IsPaused': isPaused,
            },
          ),
    );
  }

  /// 停止上报（退出播放兜底调用）。
  Future<void> reportPlayingStopped({
    required String itemId,
    String? playSessionId,
    int? positionTicks,
  }) async {
    await _send(
      () => _dio.post<dynamic>(
            '/Sessions/Playing/Stopped',
            data: <String, dynamic>{
              'ItemId': itemId,
              'PlaySessionId': playSessionId,
              if (positionTicks != null) 'PositionTicks': positionTicks,
            },
          ),
    );
  }

  /// 标记已看。
  Future<void> markPlayed(String itemId) => _send(
        () => _dio.post<dynamic>('/Users/${info.userId}/PlayedItems/$itemId'),
      );

  /// 取消已看标记。
  Future<void> markUnplayed(String itemId) => _send(
        () => _dio.delete<dynamic>('/Users/${info.userId}/PlayedItems/$itemId'),
      );

  // ---------- 请求头 / 资源释放 ----------

  /// 完整 Authorization 头（含当前 token）。
  String authorizationHeader() => _authorizationValue(
        scheme: authScheme,
        clientName: clientName,
        deviceName: _deviceName,
        deviceId: deviceId,
        appVersion: appVersion,
        token: token,
      );

  /// 媒体播放器 / 图片加载用的鉴权头集合。
  Map<String, String> authHeaders() {
    final t = token;
    return <String, String>{
      'Authorization': authorizationHeader(),
      if (t != null && t.isNotEmpty) 'X-Emby-Token': t,
    };
  }

  /// 释放底层 Dio（每服务器一个实例，管理页移除服务器时调用）。
  void dispose() => _dio.close(force: true);

  // ---------- 内部 ----------

  Map<String, dynamic> _userQuery() => <String, dynamic>{
        if (itemsQueryNeedsUserId) 'userId': info.userId,
      };

  Future<Response<T>> _send<T>(Future<Response<T>> Function() run) async {
    try {
      return await run();
    } on DioException catch (e) {
      throw _mapDioError(e);
    }
  }

  static Dio _buildDio(String baseUrl) => Dio(
        BaseOptions(
          baseUrl: baseUrl,
          connectTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 8),
        ),
      );

  /// Authorization 头格式：`<scheme> Client=".." Device=".." DeviceId=".."
  /// Version=".."[, Token=".."]`（字段逗号分隔；分隔风格待实测校准）。
  static String _authorizationValue({
    required String scheme,
    required String clientName,
    required String deviceName,
    required String deviceId,
    required String appVersion,
    String? token,
  }) {
    final parts = <String>[
      'Client="$clientName"',
      'Device="$deviceName"',
      'DeviceId="$deviceId"',
      'Version="$appVersion"',
      if (token != null && token.isNotEmpty) 'Token="$token"',
    ];
    return '$scheme ${parts.join(', ')}';
  }

  static String _defaultDeviceName() {
    try {
      return Platform.localHostname;
    } on Object {
      return 'flutter';
    }
  }

  static MediaServerApiException _mapDioError(DioException e) {
    final status = e.response?.statusCode;
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return MediaServerApiException(status, 'timeout: ${e.requestOptions.uri}');
      case DioExceptionType.badResponse:
        return MediaServerApiException(
          status,
          'http $status: ${e.requestOptions.uri}',
        );
      default:
        return MediaServerApiException(status, 'network: ${e.message}');
    }
  }

  /// 给服务器相对 / 绝对播放地址追加 api_key（已带则不重复）。
  String _appendApiKey(String url) {
    final t = token;
    if (t == null || t.isEmpty) return url;
    if (Uri.tryParse(url)?.queryParameters.containsKey('api_key') == true) {
      return url;
    }
    return '$url${url.contains('?') ? '&' : '?'}api_key=${Uri.encodeComponent(t)}';
  }

  /// 列表响应归一：`{Items: []}` 或裸数组（Latest）。
  static List<dynamic> _itemsOf(Object? data) {
    if (data is List) return data;
    if (data is Map) return (data['Items'] as List?) ?? const <dynamic>[];
    return const <dynamic>[];
  }

  static ServerItemPage _pageOf(Object? data, int startIndex) {
    final items =
        _itemsOf(data).whereType<Map>().map(_parseItem).toList();
    final total = data is Map
        ? (data['TotalRecordCount'] as num?)?.toInt() ?? items.length
        : items.length;
    return ServerItemPage(items: items, total: total, startIndex: startIndex);
  }

  static ServerLibrary _parseLibrary(Map<dynamic, dynamic> j) => ServerLibrary(
        id: j['Id'] as String? ?? '',
        name: j['Name'] as String? ?? '',
        collectionType: j['CollectionType'] as String?,
      );

  static ServerUserData? _parseUserData(Map<dynamic, dynamic>? j) {
    if (j == null) return null;
    return ServerUserData(
      played: j['Played'] == true,
      unplayedItemCount: (j['UnplayedItemCount'] as num?)?.toInt(),
      playbackPositionTicks: (j['PlaybackPositionTicks'] as num?)?.toInt(),
    );
  }

  static ServerMediaItem _parseItem(Map<dynamic, dynamic> j) => ServerMediaItem(
        id: j['Id'] as String? ?? '',
        name: j['Name'] as String? ?? '',
        type: j['Type'] as String? ?? '',
        productionYear: (j['ProductionYear'] as num?)?.toInt(),
        overview: j['Overview'] as String?,
        runTimeTicks: (j['RunTimeTicks'] as num?)?.toInt(),
        seriesName: j['SeriesName'] as String?,
        seriesId: j['SeriesId'] as String?,
        seasonId: j['SeasonId'] as String?,
        parentIndexNumber: (j['ParentIndexNumber'] as num?)?.toInt(),
        indexNumber: (j['IndexNumber'] as num?)?.toInt(),
        userData:
            j['UserData'] is Map ? _parseUserData(j['UserData'] as Map) : null,
        container: j['Container'] as String?,
        subtitleCodecs: _parseSubtitleCodecs(j['MediaStreams']),
      );

  /// 从 MediaStreams 提取字幕轨道编码（仅 Type == Subtitle）。
  static List<String>? _parseSubtitleCodecs(Object? streams) {
    if (streams is! List) return null;
    final codecs = <String>[];
    for (final s in streams) {
      if (s is! Map) continue;
      if (s['Type'] != 'Subtitle') continue;
      final codec = s['Codec'] as String?;
      if (codec != null && codec.isNotEmpty) codecs.add(codec);
    }
    return codecs.isEmpty ? null : codecs;
  }
}

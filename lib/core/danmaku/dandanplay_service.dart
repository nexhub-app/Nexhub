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

  /// 构造当前请求所需的签名头。
  ///
  /// 未配置凭据时抛出 [StateError]，由调用方转换为友好提示。
  Future<Map<String, String>> _authHeaders(String path) async {
    final cfg = await _loadConfig();
    if (!cfg.isConfigured) {
      throw StateError('DanDanPlay credentials not configured');
    }
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

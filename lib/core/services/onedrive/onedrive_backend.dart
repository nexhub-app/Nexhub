/// OneDrive 存储后端 —— Microsoft Graph API v1.0。
///
/// 备份落在用户 OneDrive 的「应用专用目录」（`drive/special/approot`，
/// 对用户不可见、卸载应用可清空，权限仅 [Files.ReadWrite.AppFolder]）。
/// 文件命名与 WebDAV 一致：`nexhub-backup-<millis>.zip`。
///
/// 上传：≤ 3MB 直接 PUT；更大走 `createUploadSession` 分片上传（分片大小
/// 必须是 320KiB 的倍数）。下载走 `/content`（Graph 会 302 到 CDN）。
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../cloud_sync_backend.dart';
import 'onedrive_auth_service.dart';

/// OneDrive（Microsoft Graph）后端实现。
class OneDriveBackend implements CloudSyncBackend {
  OneDriveBackend(this._auth);

  static const String _graphBase = 'https://graph.microsoft.com/v1.0';

  /// 应用专用目录根（OneDrive「应用」文件夹）。
  static const String _appRoot = '/me/drive/special/approot';

  /// 分片上传块大小：320KiB × 20 = 6.25MB（Graph 要求分片为 320KiB 倍数）。
  static const int kUploadChunkSize = 327680 * 20;

  /// 小于该阈值直接 PUT（Graph 简单上传上限 4MB，留余量）。
  static const int _simpleUploadLimit = 3 * 1024 * 1024;

  final OneDriveAuthService _auth;

  Dio _dio(String token,
      {Duration receiveTimeout = const Duration(seconds: 120)}) {
    return Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: receiveTimeout,
      sendTimeout: const Duration(seconds: 120),
      headers: <String, String>{'Authorization': 'Bearer $token'},
    ));
  }

  @override
  Future<void> prepare() async {
    // 预取有效 token：未登录 / 刷新失败在此抛 CloudAuthException。
    await _auth.getValidAccessToken();
  }

  @override
  Future<List<RemoteBackupFile>> listBackups() async {
    final token = await _auth.getValidAccessToken();
    final dio = _dio(token);
    final files = <RemoteBackupFile>[];
    String? next =
        '$_appRoot/children?\$select=name,size,lastModifiedDateTime&\$top=200';
    var pages = 0;
    while (next != null && pages < 10) {
      final resp = await dio.get<Map<String, dynamic>>(next);
      files.addAll(
          parseChildrenResponse(resp.data ?? const <String, dynamic>{}));
      next = resp.data?['@odata.nextLink'] as String?;
      pages++;
    }
    return files;
  }

  /// 解析 children 列表响应（公开供单测覆盖）。
  static List<RemoteBackupFile> parseChildrenResponse(
      Map<String, dynamic> json) {
    final files = <RemoteBackupFile>[];
    final value = json['value'];
    if (value is! List) return files;
    for (final item in value) {
      if (item is! Map<String, dynamic>) continue;
      final name = item['name'] as String?;
      if (name == null || name.isEmpty) continue;
      if (item['file'] == null) continue; // 跳过子目录
      final size = (item['size'] as num?)?.toInt();
      final modified = _parseGraphTime(item['lastModifiedDateTime'] as String?);
      files.add(RemoteBackupFile(name: name, size: size, modifiedMs: modified));
    }
    return files;
  }

  /// 解析 Graph ISO8601 时间（如 `2026-09-29T12:34:56.789Z`）为毫秒。
  static int? _parseGraphTime(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw)?.millisecondsSinceEpoch;
  }

  @override
  Future<void> uploadBackup(String fileName, List<int> bytes) async {
    final token = await _auth.getValidAccessToken();
    final dio = _dio(token);
    final encodedName = Uri.encodeComponent(fileName);
    if (bytes.length <= _simpleUploadLimit) {
      // 简单上传：/content 端点默认同名覆盖
      await dio.put<Uint8List>(
        '$_appRoot:/$encodedName:/content',
        data: Uint8List.fromList(bytes),
        options: Options(
          headers: <String, String>{'Content-Type': 'application/zip'},
          validateStatus: (s) => s != null && s >= 200 && s < 300,
        ),
      );
      return;
    }
    // 分片上传会话（显式指定冲突行为为覆盖）
    final sessionResp = await dio.post<Map<String, dynamic>>(
      '$_appRoot:/$encodedName:/createUploadSession',
      data: <String, dynamic>{
        'item': <String, String>{
          '@microsoft.graph.conflictBehavior': 'replace',
        },
      },
      options: Options(
        validateStatus: (s) => s != null && s >= 200 && s < 300,
      ),
    );
    final uploadUrl = sessionResp.data?['uploadUrl'] as String?;
    if (uploadUrl == null || uploadUrl.isEmpty) {
      throw StateError('onedrive: upload session missing url');
    }
    // 预签名 URL，不带 Bearer
    final plain = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 120),
      sendTimeout: const Duration(seconds: 120),
    ));
    final total = bytes.length;
    for (var offset = 0; offset < total; offset += kUploadChunkSize) {
      final end = min(offset + kUploadChunkSize, total);
      final chunk = Uint8List.fromList(bytes.sublist(offset, end));
      // 分片偶发 5xx/429 可重试
      await _retry(() async {
        await plain.put<void>(
          uploadUrl,
          data: chunk,
          options: Options(
            headers: <String, String>{
              'Content-Range': 'bytes $offset-${end - 1}/$total',
            },
            validateStatus: (s) =>
                s != null && (s == 200 || s == 201 || s == 202),
          ),
        );
      });
    }
  }

  Future<void> _retry(Future<void> Function() action) async {
    var delayMs = 1000;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await action();
        return;
      } on DioException catch (e) {
        final status = e.response?.statusCode ?? 0;
        final retryable = status == 429 || (status >= 500 && status < 600);
        if (!retryable || attempt == 2) rethrow;
        await Future<void>.delayed(Duration(milliseconds: delayMs));
        delayMs *= 2;
      }
    }
  }

  @override
  Future<Uint8List> downloadBackup(String fileName) async {
    final token = await _auth.getValidAccessToken();
    final encodedName = Uri.encodeComponent(fileName);
    final resp = await _dio(token).get<List<int>>(
      '$_appRoot:/$encodedName:/content',
      options: Options(
        responseType: ResponseType.bytes,
        // /content 会 302 到 CDN，允许跟随重定向
        validateStatus: (s) => s != null && s >= 200 && s < 400,
      ),
    );
    return Uint8List.fromList(resp.data ?? <int>[]);
  }

  @override
  Future<void> deleteBackup(String fileName) async {
    final token = await _auth.getValidAccessToken();
    final encodedName = Uri.encodeComponent(fileName);
    try {
      await _dio(token).delete<void>(
        '$_appRoot:/$encodedName',
        options: Options(
          validateStatus: (s) =>
              s != null && (s == 200 || s == 204 || s == 404),
        ),
      );
    } catch (_) {
      // 忽略单个删除失败
    }
  }

  /// 测试 OneDrive 连接（读取应用专用目录元数据，同时校验 token 与
  /// AppFolder 权限）。返回 (success, latencyMs)。
  static Future<(bool, int)> testConnection(OneDriveAuthService auth) async {
    final stopwatch = Stopwatch()..start();
    try {
      final token = await auth.getValidAccessToken();
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
        headers: <String, String>{'Authorization': 'Bearer $token'},
      ));
      final resp = await dio.get<Map<String, dynamic>>('$_graphBase$_appRoot');
      stopwatch.stop();
      final ok = resp.statusCode != null && resp.statusCode! < 400;
      return (ok, stopwatch.elapsedMilliseconds);
    } on Object {
      stopwatch.stop();
      return (false, stopwatch.elapsedMilliseconds);
    }
  }
}

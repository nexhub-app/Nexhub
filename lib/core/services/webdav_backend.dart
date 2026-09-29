/// WebDAV 存储后端 —— 用 dio 手写 MKCOL/PROPFIND/PUT/GET/DELETE，不引入 webdav 包。
///
/// 从 [CloudSyncService] 中拆出：Basic Auth 认证，备份目录固定 `/nexhub`。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:xml/xml.dart';

import 'cloud_sync_backend.dart';

/// WebDAV 后端实现。
class WebDavBackend implements CloudSyncBackend {
  WebDavBackend({
    required String baseUrl,
    required this.username,
    required this.password,
    this.remoteDir = '/nexhub',
  }) : _baseUrl = baseUrl;

  final String _baseUrl;
  final String username;
  final String password;
  final String remoteDir;

  /// 构造 Basic Auth header value（含 "Basic " 前缀）。
  static String basicAuth(String username, String password) {
    final creds = base64Encode(utf8.encode('$username:$password'));
    return 'Basic $creds';
  }

  /// 规范化 WebDAV URL，确保以 / 结尾的根路径能正确拼接子路径。
  String _buildUrl(String path) {
    String base = _baseUrl;
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    if (path.isEmpty || path == '/') return base;
    if (!path.startsWith('/')) path = '/$path';
    return '$base$path';
  }

  Dio _buildDio({Duration receiveTimeout = const Duration(seconds: 60)}) {
    return Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: receiveTimeout,
      sendTimeout: const Duration(seconds: 60),
      headers: <String, String>{
        'Authorization': basicAuth(username, password),
      },
    ));
  }

  @override
  Future<void> prepare() async {
    try {
      await _buildDio().request<void>(
        _buildUrl('$remoteDir/'),
        data: '',
        options: Options(
          method: 'MKCOL',
          validateStatus: (s) =>
              s != null && (s == 201 || s == 405 || s == 409 || s == 301),
        ),
      );
    } catch (_) {
      // 忽略：目录可能已存在或允许后续 PUT 自动创建
    }
  }

  @override
  Future<List<RemoteBackupFile>> listBackups() async {
    const propfindBody = '<?xml version="1.0" encoding="utf-8"?>'
        '<D:propfind xmlns:D="DAV:">'
        '<D:prop><D:displayname/><D:resourcetype/></D:prop>'
        '</D:propfind>';
    try {
      final resp = await _buildDio().request<String>(
        _buildUrl('$remoteDir/'),
        data: propfindBody,
        options: Options(
          method: 'PROPFIND',
          headers: <String, String>{
            'Depth': '1',
            'Content-Type': 'application/xml; charset=utf-8',
          },
          responseType: ResponseType.plain,
          validateStatus: (s) => s != null && s >= 200 && s < 400,
        ),
      );
      return parsePropfind(resp.data ?? '');
    } catch (_) {
      return <RemoteBackupFile>[];
    }
  }

  /// 解析 PROPFIND Depth:1 multistatus 响应（公开供单测覆盖）。
  static List<RemoteBackupFile> parsePropfind(String body) {
    final files = <RemoteBackupFile>[];
    if (body.isEmpty) return files;
    try {
      final doc = XmlDocument.parse(body);
      for (final response in doc.findAllElements('response', namespace: '*')) {
        final hrefElement =
            response.findElements('href', namespace: '*').firstOrNull;
        if (hrefElement == null) continue;
        // ⚠️ XmlElement.value 恒为 null（xml 6.x 只对文本/属性节点提供 value），
        // 元素文本必须用 innerText —— 此处曾误用 .value 导致远端列表恒为空。
        final href = hrefElement.innerText.trim();
        if (href.isEmpty) continue;
        // 解析出最后一段文件名
        final decoded = Uri.decodeFull(href);
        if (decoded.endsWith('/')) {
          continue;
        }
        String name = decoded;
        final lastSlash = decoded.lastIndexOf('/');
        if (lastSlash >= 0 && lastSlash < decoded.length - 1) {
          name = decoded.substring(lastSlash + 1);
        }
        final isCollection = response
                .findElements('propstat', namespace: '*')
                .firstOrNull
                ?.findElements('prop', namespace: '*')
                .firstOrNull
                ?.findElements('resourcetype', namespace: '*')
                .firstOrNull
                ?.findElements('collection', namespace: '*')
                .isNotEmpty ??
            false;
        if (isCollection) continue;
        files.add(RemoteBackupFile(name: name));
      }
    } catch (_) {
      // XML 解析失败：返回空列表
    }
    return files;
  }

  @override
  Future<void> uploadBackup(String fileName, List<int> bytes) async {
    await _buildDio().put(
      _buildUrl('$remoteDir/$fileName'),
      data: Stream.fromIterable(<List<int>>[bytes]),
      options: Options(
        headers: <String, String>{
          'Content-Type': 'application/zip',
          'Content-Length': '${bytes.length}',
        },
        validateStatus: (s) => s != null && s >= 200 && s < 300,
      ),
    );
  }

  @override
  Future<Uint8List> downloadBackup(String fileName) async {
    final resp = await _buildDio(receiveTimeout: const Duration(seconds: 120))
        .get<List<int>>(
      _buildUrl('$remoteDir/$fileName'),
      options: Options(
        responseType: ResponseType.bytes,
        validateStatus: (s) => s != null && s >= 200 && s < 300,
      ),
    );
    return Uint8List.fromList(resp.data ?? <int>[]);
  }

  @override
  Future<void> deleteBackup(String fileName) async {
    try {
      await _buildDio().delete(
        _buildUrl('$remoteDir/$fileName'),
        options: Options(
          validateStatus: (s) => s != null && s >= 200 && s < 300,
        ),
      );
    } catch (_) {
      // 忽略单个删除失败
    }
  }

  /// 测试 WebDAV 连接（PROPFIND Depth:0 探测根目录）。返回 (success, latencyMs)。
  static Future<(bool, int)> testConnection({
    required String url,
    required String username,
    required String password,
  }) async {
    final stopwatch = Stopwatch()..start();
    try {
      String base = url;
      while (base.endsWith('/')) {
        base = base.substring(0, base.length - 1);
      }
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
        headers: <String, String>{
          'Authorization': basicAuth(username, password),
        },
      ));
      final resp = await dio.request<String>(
        base,
        data: '',
        options: Options(
          method: 'PROPFIND',
          headers: <String, String>{
            'Depth': '0',
            'Content-Type': 'application/xml; charset=utf-8',
          },
          responseType: ResponseType.plain,
          validateStatus: (s) => s != null && s >= 200 && s < 400,
        ),
      );
      stopwatch.stop();
      // 207 Multistatus 是 PROPFIND 的标准成功响应
      final ok = resp.statusCode != null && resp.statusCode! < 400;
      return (ok, stopwatch.elapsedMilliseconds);
    } catch (_) {
      stopwatch.stop();
      return (false, stopwatch.elapsedMilliseconds);
    }
  }
}

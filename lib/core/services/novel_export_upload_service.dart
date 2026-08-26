/// 小说导出产物 WebDAV 上传服务（F6：exportToWebDav）。
///
/// 与整包备份 / 进度同步共享 WebDAV 配置（[CloudSyncConfigStore]），
/// 把导出的 EPUB 单文件上传到远端 `nexhub/exports/` 目录。上传为
/// best-effort 旁路：任何失败向上抛出，由调用方决定提示方式，
/// 不影响本地下载结果。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import 'cloud_sync_service.dart';

/// 上传结果。
class NovelExportUploadResult {
  /// 远端完整 URL。
  final String remoteUrl;

  /// 本地文件名（远端同名）。
  final String remoteName;

  const NovelExportUploadResult({required this.remoteUrl, required this.remoteName});
}

/// 导出产物上传服务。
class NovelExportUploadService {
  NovelExportUploadService({CloudSyncConfigStore? store})
      : _store = store ?? CloudSyncConfigStore();

  final CloudSyncConfigStore _store;

  String? _password;

  /// 远端导出目录（相对 WebDAV 根）。
  static const String remoteExportsDir = 'nexhub/exports';

  Future<({String url, String username, String password})?>
      _loadConfig() async {
    final config = await _store.load();
    if (config.url.isEmpty) return null;
    final pw = _password ??= await _store.loadPassword() ?? '';
    return (url: config.url, username: config.username, password: pw);
  }

  Dio _dio(String username, String password) {
    final creds = base64Encode(utf8.encode('$username:$password'));
    return Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 60),
      sendTimeout: const Duration(seconds: 120),
      headers: <String, String>{'Authorization': 'Basic $creds'},
    ));
  }

  String buildUrl(String base, String path) {
    var b = base;
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    return '$b/$path';
  }

  /// 本地路径对应的远端文件名（取 basename，非法字符替换为 `_`）。
  String remoteNameFor(String localPath) => p
      .basename(localPath)
      .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

  /// 确保 `nexhub` 与 `nexhub/exports` 目录存在（逐级 MKCOL；
  /// 已存在时服务器返回 405/301，视为成功）。
  Future<void> _ensureDirs(Dio dio, String base) async {
    for (final dir in const <String>['nexhub', remoteExportsDir]) {
      try {
        await dio.put('${buildUrl(base, dir)}/',
            options: Options(validateStatus: (s) => s != null && s < 500));
      } on Object {
        // MKCOL 失败不阻断：部分服务器自动建目录或对 PUT 容错。
      }
    }
  }

  /// 是否已配置 WebDAV（未配置时调用方应提示先去配置而非静默失败）。
  Future<bool> isConfigured() async {
    final cfg = await _loadConfig();
    return cfg != null;
  }

  /// 上传单个本地文件到 `nexhub/exports/<basename>`，返回远端信息。
  ///
  /// 未配置 WebDAV / 文件不存在 / 上传非 2xx 时抛 [NovelExportUploadException]。
  Future<NovelExportUploadResult> uploadFile(String filePath) async {
    final cfg = await _loadConfig();
    if (cfg == null) {
      throw const NovelExportUploadException('WebDAV 未配置');
    }
    final file = File(filePath);
    if (!file.existsSync()) {
      throw NovelExportUploadException('文件不存在: $filePath');
    }
    final name = remoteNameFor(filePath);
    final dio = _dio(cfg.username, cfg.password);
    try {
      await _ensureDirs(dio, cfg.url);
      final bytes = file.readAsBytesSync();
      final resp = await dio.put<List<int>>(
        buildUrl(cfg.url, '$remoteExportsDir/$name'),
        data: Stream.fromIterable(<List<int>>[bytes]),
        options: Options(
          headers: <String, String>{
            'Content-Type': 'application/octet-stream',
            'Content-Length': '${bytes.length}',
          },
          validateStatus: (s) => s != null && s >= 200 && s < 300,
        ),
      );
      if (resp.statusCode == null || resp.statusCode! >= 300) {
        throw NovelExportUploadException('上传失败: HTTP ${resp.statusCode}');
      }
      return NovelExportUploadResult(
        remoteUrl: buildUrl(cfg.url, '$remoteExportsDir/$name'),
        remoteName: name,
      );
    } on NovelExportUploadException {
      rethrow;
    } on Object catch (e) {
      throw NovelExportUploadException('上传失败: $e');
    } finally {
      dio.close(force: true);
    }
  }
}

/// 上传异常（携带用户可读信息）。
class NovelExportUploadException implements Exception {
  final String message;
  const NovelExportUploadException(this.message);

  @override
  String toString() => message;
}

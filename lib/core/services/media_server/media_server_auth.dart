/// 媒体服务器多服务器认证与本地档案管理。
///
/// - 服务器列表（非敏感字段）存 Hive box `media_servers`，key = 服务器 id；
/// - AccessToken 按 serverId 分键存 [FlutterSecureStorage]，绝不进 Hive；
/// - deviceId（安装级稳定标识）走 [PrefsBackend]（shared_preferences），
///   探测 / 登录请求共用，首用生成、之后复用；
/// - 网络探测与登录通过构造注入的 [MediaServerProbe] /
///   [MediaServerAuthenticator] 接缝执行：真实实现在 API 客户端层就绪后
///   接线传入，测试注入假实现即可覆盖完整持久化往返。
library;

import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive/hive.dart';

import '../../comic/models/reader_preferences.dart';
import 'media_server_models.dart';

/// 服务器状态（管理列表 / 详情页按此渲染在线态）。
enum MediaServerStatus {
  /// 在线且 token 有效。
  ok,

  /// 不可达（网络 / 超时 / 5xx）。
  offline,

  /// token 缺失或已失效（401），需重新登录。
  needRelogin,
}

/// 服务器类型探测接缝（`GET /System/Info/Public` 的归一化）。
typedef MediaServerProbe = Future<MediaServerProbeResult> Function(
  String baseUrl,
);

/// 登录接缝（`POST /Users/AuthenticateByName` 的归一化）。
typedef MediaServerAuthenticator = Future<MediaServerLoginResult> Function(
  String baseUrl,
  ServerType type, {
  required String username,
  required String password,
  required String deviceId,
});

/// 媒体服务器认证管理器——多服务器档案的单一事实源（Provider 注入）。
class MediaServerAuth extends ChangeNotifier {
  MediaServerAuth({
    FlutterSecureStorage? storage,
    Box<dynamic>? box,
    PrefsBackend? prefs,
    MediaServerProbe? probe,
    MediaServerAuthenticator? authenticate,
  })  : _storage = storage ?? const FlutterSecureStorage(),
        _box = box,
        _prefs = prefs ?? const SharedPrefsBackend(),
        _probe = probe,
        _authenticate = authenticate;

  /// Hive box 名（须注册 kStorageBoxNames）。
  static const String boxName = 'media_servers';

  static const String _deviceIdKey = 'media_server_device_id';
  static const String _tokenKeyPrefix = 'media_server_token_';

  final FlutterSecureStorage _storage;
  final Box<dynamic>? _box;
  final PrefsBackend _prefs;
  final MediaServerProbe? _probe;
  final MediaServerAuthenticator? _authenticate;

  final List<MediaServerInfo> _servers = <MediaServerInfo>[];
  bool _loaded = false;
  String? _cachedDeviceId;

  /// 已添加的服务器档案（只读视图）。
  List<MediaServerInfo> get servers => List.unmodifiable(_servers);

  String _tokenKeyFor(String serverId) => '$_tokenKeyPrefix$serverId';

  Future<Box<dynamic>> _openBox() async {
    final injected = _box;
    if (injected != null) return injected;
    if (Hive.isBoxOpen(boxName)) return Hive.box(boxName);
    return Hive.openBox(boxName);
  }

  /// 冷启动恢复服务器列表（幂等；box 打开后的任意时机可调）。
  Future<void> init() async {
    if (_loaded) return;
    final box = await _openBox();
    final restored = <MediaServerInfo>[];
    for (final key in box.keys) {
      final raw = box.get(key);
      if (raw is! String || raw.isEmpty) continue;
      try {
        restored
            .add(MediaServerInfo.fromJson(jsonDecode(raw) as Map<String, dynamic>));
      } on Object {
        // 单条损坏不拖垮整体，跳过该条。
        continue;
      }
    }
    _servers
      ..clear()
      ..addAll(restored);
    _loaded = true;
    notifyListeners();
  }

  /// 添加服务器：规范化地址 → 探测类型与服务器名 → 预填别名并持久化。
  ///
  /// 登录随后通过 [login] 完成。地址重复时抛 [StateError]；
  /// 探测不可达时上抛异常由调用方提示。
  Future<MediaServerInfo> addServer(String baseUrl) async {
    final probe = _probe;
    if (probe == null) {
      throw StateError('media server probe not wired yet');
    }
    final normalized = normalizeBaseUrl(baseUrl);
    if (normalized.isEmpty) {
      throw ArgumentError.value(baseUrl, 'baseUrl', 'empty');
    }
    await init();
    if (_servers.any((s) => s.baseUrl == normalized)) {
      throw StateError('server already added: $normalized');
    }
    final result = await probe(normalized);
    final serverName = result.serverName;
    final info = MediaServerInfo(
      id: _generateId(),
      type: result.type,
      name: (serverName != null && serverName.isNotEmpty)
          ? serverName
          : normalized,
      baseUrl: normalized,
      serverName: serverName,
      version: result.version,
    );
    await _persist(info);
    _servers.add(info);
    notifyListeners();
    return info;
  }

  /// 登录服务器：成功后回写 userId / username 并持久化，token 存安全存储。
  ///
  /// 凭证错误（401）等异常原样上抛供调用方提示。
  Future<void> login(String serverId, String username, String password) async {
    final authenticate = _authenticate;
    if (authenticate == null) {
      throw StateError('media server authenticator not wired yet');
    }
    await init();
    final index = _servers.indexWhere((s) => s.id == serverId);
    if (index < 0) {
      throw StateError('unknown server: $serverId');
    }
    final result = await authenticate(
      _servers[index].baseUrl,
      _servers[index].type,
      username: username,
      password: password,
      deviceId: await deviceId(),
    );
    _servers[index] = _servers[index].copyWith(
      userId: result.userId,
      username: result.username,
    );
    await _persist(_servers[index]);
    await _storage.write(key: _tokenKeyFor(serverId), value: result.accessToken);
    notifyListeners();
  }

  /// 读取某服务器的 AccessToken（客户端层注入 Authorization 头用）。
  Future<String?> tokenOf(String serverId) => _storage.read(
        key: _tokenKeyFor(serverId),
      );

  /// 删除服务器：清本地档案与 token（确认交互由 UI 层负责；
  /// 服务器端数据与观看进度不受影响）。
  Future<void> removeServer(String serverId) async {
    await init();
    _servers.removeWhere((s) => s.id == serverId);
    final box = await _openBox();
    await box.delete(serverId);
    await _storage.delete(key: _tokenKeyFor(serverId));
    notifyListeners();
  }

  /// 服务器状态：无 token → [MediaServerStatus.needRelogin]；
  /// 有 token 时经探测接缝判在线（探测未接线则直接视为在线，
  /// 由后续请求的 401 / 超时兜底）。
  Future<MediaServerStatus> statusOf(String serverId) async {
    await init();
    MediaServerInfo? server;
    for (final s in _servers) {
      if (s.id == serverId) {
        server = s;
        break;
      }
    }
    if (server == null) return MediaServerStatus.offline;
    final token = await tokenOf(serverId);
    if (token == null || token.isEmpty) {
      return MediaServerStatus.needRelogin;
    }
    final probe = _probe;
    if (probe == null) return MediaServerStatus.ok;
    try {
      await probe(server.baseUrl);
      return MediaServerStatus.ok;
    } on MediaServerApiException catch (e) {
      return e.isUnauthorized
          ? MediaServerStatus.needRelogin
          : MediaServerStatus.offline;
    } on Object {
      return MediaServerStatus.offline;
    }
  }

  /// 安装级稳定 deviceId：首用生成并持久化，之后复用。
  Future<String> deviceId() async {
    final cached = _cachedDeviceId;
    if (cached != null) return cached;
    final stored = await _prefs.get(_deviceIdKey);
    if (stored != null && stored.isNotEmpty) {
      _cachedDeviceId = stored;
      return stored;
    }
    final generated = _generateId();
    await _prefs.set(_deviceIdKey, generated);
    _cachedDeviceId = generated;
    return generated;
  }

  Future<void> _persist(MediaServerInfo info) async {
    final box = await _openBox();
    await box.put(info.id, jsonEncode(info.toJson()));
  }

  /// 时间戳 + 随机数拼 base36（同登录防 CSRF state 的生成法，无 uuid 依赖）。
  String _generateId() {
    final r = Random();
    final ts = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final rand = r.nextInt(1 << 32).toRadixString(36);
    return '$ts-$rand';
  }
}

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

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart'
    show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;
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
/// 内置前台探活：60s 周期，仅 app 前台运行，结果驱动状态点实时化。
class MediaServerAuth extends ChangeNotifier
    with WidgetsBindingObserver {
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

  // ── 前台探活 ──
  Timer? _healthTimer;
  bool _healthRunning = false;

  /// 探活结果（serverId → 是否可达；未探测过的服务器不含该键）。
  final Map<String, bool> _health = <String, bool>{};
  Map<String, bool> get health => Map.unmodifiable(_health);

  /// 启动前台探活（默认 60s；生命周期 paused 暂停、resumed 恢复）。
  void startHealthCheck({Duration interval = const Duration(seconds: 60)}) {
    if (_healthRunning) return;
    _healthRunning = true;
    WidgetsBinding.instance.addObserver(this);
    _healthTimer = Timer.periodic(interval, (_) => unawaited(_probeAll()));
    unawaited(_probeAll());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_healthRunning) return;
    if (state == AppLifecycleState.paused) {
      _healthTimer?.cancel();
      _healthTimer = null;
    } else if (state == AppLifecycleState.resumed) {
      _healthTimer?.cancel();
      _healthTimer = Timer.periodic(
        const Duration(seconds: 60),
        (_) => unawaited(_probeAll()),
      );
      unawaited(_probeAll());
    }
  }

  /// 逐台轻量探活（探测端点，8s 超时）；仅更新状态不弹错误。
  Future<void> _probeAll() async {
    await init();
    final probe = _probe;
    if (probe == null) return;
    for (final s in List<MediaServerInfo>.from(_servers)) {
      if (!_healthRunning) return;
      var ok = false;
      try {
        await probe(s.baseUrl).timeout(const Duration(seconds: 8));
        ok = true;
      } on Object {
        ok = false;
      }
      if (_health[s.id] != ok) {
        _health[s.id] = ok;
        notifyListeners();
      }
    }
  }

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

  /// 添加服务器：支持多地址（换行 / 逗号分隔，内外网双地址）——
  /// 逐个探测，**首个成功者设为活动地址**；候选全集存入档案。
  ///
  /// 登录随后通过 [login] 完成。地址重复时抛 [StateError]；
  /// 无手选类型且全部探测失败时上抛最后一次异常。
  ///
  /// [typeOverride] 非空时跳过自动识别（探测降级为尽力而为，仅用于预填
  /// ServerName，失败不阻断添加），供「手动选择类型」路径使用。
  Future<MediaServerInfo> addServer(
    String baseUrl, {
    ServerType? typeOverride,
  }) async {
    final candidates = baseUrl
        .split(RegExp(r'[\n,]'))
        .map(normalizeBaseUrl)
        .where((u) => u.isNotEmpty)
        .toList(growable: false);
    if (candidates.isEmpty) {
      throw ArgumentError.value(baseUrl, 'baseUrl', 'empty');
    }
    await init();
    if (_servers.any((s) =>
        candidates.contains(s.baseUrl) ||
        s.urls.any(candidates.contains))) {
      throw StateError('server already added');
    }
    MediaServerProbeResult? result;
    var active = candidates.first;
    final probe = _probe;
    if (typeOverride != null) {
      if (probe != null) {
        for (final c in candidates) {
          try {
            result = await probe(c);
            active = c;
            break;
          } on Object {
            result = null;
          }
        }
      }
    } else {
      if (probe == null) {
        throw StateError('media server probe not wired yet');
      }
      Object? lastError;
      for (final c in candidates) {
        try {
          result = await probe(c);
          active = c;
          break;
        } on Object catch (e) {
          lastError = e;
        }
      }
      if (result == null) {
        throw lastError ??
            const MediaServerApiException(null, 'probe failed');
      }
    }
    final type = typeOverride ?? result?.type;
    if (type == null) {
      throw StateError('server type unresolved');
    }
    final serverName = result?.serverName;
    final info = MediaServerInfo(
      id: _generateId(),
      type: type,
      name: (serverName != null && serverName.isNotEmpty)
          ? serverName
          : active,
      baseUrl: active,
      urls: candidates,
      serverName: serverName,
      version: result?.version,
    );
    await _persist(info);
    _servers.add(info);
    notifyListeners();
    return info;
  }

  /// 更新服务器候选地址（管理页地址编辑）。探测首个可达地址设为
  /// 活动地址；全部不可达时保留原活动地址。
  Future<void> updateServerUrls(String serverId, List<String> urls) async {
    await init();
    final index = _servers.indexWhere((s) => s.id == serverId);
    if (index < 0) {
      throw StateError('unknown server: $serverId');
    }
    final info = _servers[index];
    final previousActive = info.baseUrl;
    info
      ..urls = urls
      ..baseUrl = previousActive;
    info.normalizeUrls();
    final probe = _probe;
    if (probe != null) {
      for (final c in info.urls) {
        try {
          await probe(c);
          info.baseUrl = c;
          break;
        } on Object {
          // 该地址不可达，尝试下一个。
        }
      }
    }
    await _persist(info);
    notifyListeners();
  }

  /// 仅探测（添加向导「探测」按钮的预览用，不落库）。
  Future<MediaServerProbeResult> probeAddress(String baseUrl) async {
    final probe = _probe;
    if (probe == null) {
      throw StateError('media server probe not wired yet');
    }
    return probe(normalizeBaseUrl(baseUrl));
  }

  /// 重命名服务器别名。
  Future<void> renameServer(String serverId, String name) async {
    await init();
    final index = _servers.indexWhere((s) => s.id == serverId);
    if (index < 0) {
      throw StateError('unknown server: $serverId');
    }
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    _servers[index] = _servers[index].copyWith(name: trimmed);
    await _persist(_servers[index]);
    notifyListeners();
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

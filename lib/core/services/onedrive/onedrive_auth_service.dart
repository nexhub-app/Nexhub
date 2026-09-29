/// OneDrive 账号认证 —— OAuth 2.0 authorization code + PKCE（主路径）
/// 与设备码登录（无 WebView 平台的兜底路径）。
///
/// - token / refresh_token / 过期时间 / 账号名全部存 [FlutterSecureStorage]；
/// - 内嵌 WebView 打开 `login.microsoftonline.com` 授权页，回跳
///   `http://localhost?code=...` 时由 WebView 截获（与 Bangumi 同一范式）；
/// - refresh_token 按 MSA 滚动更新：每次续期后落盘新值；
/// - [getValidAccessToken] 供 [OneDriveBackend] 在每次 Graph 调用前取有效
///   token（过期前 60s 内自动刷新，刷新失败抛 [CloudAuthException]）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../cloud_sync_backend.dart';
import 'onedrive_device_code_dialog.dart';
import 'onedrive_oauth_browser.dart';
import 'onedrive_oauth_config.dart';

/// OneDrive 认证管理器 —— 由 [CloudSyncService] 持有并转发通知。
class OneDriveAuthService extends ChangeNotifier {
  OneDriveAuthService({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const String _accessTokenKey = 'onedrive_access_token';
  static const String _refreshTokenKey = 'onedrive_refresh_token';
  static const String _expiresAtKey = 'onedrive_expires_at';
  static const String _accountKey = 'onedrive_account';

  final FlutterSecureStorage _storage;

  String? _accessToken;
  String? _refreshToken;
  int? _expiresAt;
  String? _account;

  /// 是否已登录（有可用凭证即视为已登录，access token 可能待刷新）。
  bool get isLoggedIn =>
      _refreshToken != null ||
      (_accessToken != null &&
          (_expiresAt == null ||
              _expiresAt! > DateTime.now().millisecondsSinceEpoch));

  /// 登录账号展示名（邮箱 / 用户名），未登录为 null。
  String? get accountName => _account;

  /// 冷启动恢复已存凭证。
  Future<void> init() async {
    try {
      _accessToken = await _storage.read(key: _accessTokenKey);
      _refreshToken = await _storage.read(key: _refreshTokenKey);
      _account = await _storage.read(key: _accountKey);
      final expiresRaw = await _storage.read(key: _expiresAtKey);
      _expiresAt = int.tryParse(expiresRaw ?? '');
    } catch (_) {
      // secure storage 不可用（如桌面端缺 keyring）时按未登录处理。
      _accessToken = null;
      _refreshToken = null;
      _expiresAt = null;
      _account = null;
    }
    notifyListeners();
  }

  /// 取有效 access token：未过期直接返回，否则用 refresh_token 续期。
  ///
  /// 未登录 / 续期失败抛 [CloudAuthException]。
  Future<String> getValidAccessToken() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_accessToken != null &&
        (_expiresAt == null || _expiresAt! > now + 60000)) {
      return _accessToken!;
    }
    if (_refreshToken == null || _refreshToken!.isEmpty) {
      throw const CloudAuthException('onedrive: not logged in');
    }
    await _refreshTokens();
    return _accessToken!;
  }

  /// OAuth 2.0 授权码 + PKCE 登录（内嵌 WebView）。
  ///
  /// 用户取消 / 关闭授权页时抛 [StateError]；网络或凭据错误上抛原异常。
  Future<void> loginWithBrowser(BuildContext context) async {
    if (!OneDriveOAuthConfig.configured) {
      throw StateError('onedrive oauth not configured');
    }
    final verifier = _randomBase64Url(48);
    final challenge = deriveCodeChallenge(verifier);
    final state = _randomBase64Url(16);
    final authorizeUrl = Uri.https(
      'login.microsoftonline.com',
      '/${OneDriveOAuthConfig.tenant}/oauth2/v2.0/authorize',
      <String, String>{
        'client_id': OneDriveOAuthConfig.clientId,
        'response_type': 'code',
        'redirect_uri': OneDriveOAuthConfig.redirectUri,
        'scope': OneDriveOAuthConfig.scopes.join(' '),
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        'state': state,
        'prompt': 'select_account',
      },
    ).toString();

    final code = await openOneDriveOAuthBrowser(
      context: context,
      authorizeUrl: authorizeUrl,
      redirectPrefix: OneDriveOAuthConfig.redirectUri,
    );
    if (code == null || code.isEmpty) {
      throw StateError('onedrive oauth cancelled');
    }
    await _exchangeCodeForTokens(code, verifier);
  }

  /// 设备码登录（Linux 等无 WebView 平台的兜底）。
  ///
  /// 弹出对话框展示 user_code 与验证网址，后台轮询 token 端点；
  /// 用户关闭对话框不影响轮询（此后完成授权仍会自动登录）。
  /// 返回对话框内是否完成了授权。
  Future<bool> loginWithDeviceCode(BuildContext context) async {
    if (!OneDriveOAuthConfig.configured) {
      throw StateError('onedrive oauth not configured');
    }
    final dio = _tokenDio();
    final startResp = await dio.post<Map<String, dynamic>>(
      '${OneDriveOAuthConfig.authority}/devicecode',
      data: <String, String>{
        'client_id': OneDriveOAuthConfig.clientId,
        'scope': OneDriveOAuthConfig.scopes.join(' '),
      },
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        validateStatus: (s) => s != null && s < 400,
      ),
    );
    final start = startResp.data;
    final deviceCode = start?['device_code'] as String?;
    final userCode = start?['user_code'] as String?;
    final verificationUri = (start?['verification_uri'] as String?) ??
        'https://microsoft.com/devicelogin';
    final expiresIn = (start?['expires_in'] as num?)?.toInt() ?? 900;
    final interval = max((start?['interval'] as num?)?.toInt() ?? 5, 5);
    if (deviceCode == null || userCode == null) {
      throw const CloudAuthException('device code start failed');
    }
    if (!context.mounted) return false;

    return await showOneDriveDeviceCodeDialog(
      context: context,
      userCode: userCode,
      verificationUri: verificationUri,
      waitFlow: () => _pollDeviceCodeToken(deviceCode, expiresIn, interval),
    );
  }

  /// 轮询设备码 token 端点直至成功（落盘并通知）或失败（抛异常）。
  Future<void> _pollDeviceCodeToken(
    String deviceCode,
    int expiresIn,
    int interval,
  ) async {
    final deadline = DateTime.now().millisecondsSinceEpoch + expiresIn * 1000;
    var wait = interval;
    final dio = _tokenDio();
    while (DateTime.now().millisecondsSinceEpoch < deadline) {
      await Future<void>.delayed(Duration(seconds: wait));
      final Response<Map<String, dynamic>> resp;
      try {
        resp = await dio.post<Map<String, dynamic>>(
          '${OneDriveOAuthConfig.authority}/token',
          data: <String, String>{
            'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
            'client_id': OneDriveOAuthConfig.clientId,
            'device_code': deviceCode,
          },
          options: Options(
            contentType: Headers.formUrlEncodedContentType,
            validateStatus: (s) => s != null && s < 500,
          ),
        );
      } on DioException {
        continue; // 网络抖动：按 pending 处理，继续轮询
      }
      final body = resp.data ?? const <String, dynamic>{};
      if (resp.statusCode == 200 && body['access_token'] != null) {
        await _persistTokenResponse(body);
        return;
      }
      switch (body['error'] as String?) {
        case 'authorization_pending':
          continue;
        case 'slow_down':
          wait += 5;
          continue;
        default:
          throw CloudAuthException(
              body['error']?.toString() ?? 'device code failed');
      }
    }
    throw const CloudAuthException('device code expired');
  }

  /// 用授权码换 token（PKCE）。
  Future<void> _exchangeCodeForTokens(String code, String verifier) async {
    final dio = _tokenDio();
    final resp = await dio.post<Map<String, dynamic>>(
      '${OneDriveOAuthConfig.authority}/token',
      data: <String, String>{
        'grant_type': 'authorization_code',
        'client_id': OneDriveOAuthConfig.clientId,
        'code': code,
        'redirect_uri': OneDriveOAuthConfig.redirectUri,
        'code_verifier': verifier,
        'scope': OneDriveOAuthConfig.scopes.join(' '),
      },
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        validateStatus: (s) => s != null && s < 500,
      ),
    );
    final body = resp.data ?? const <String, dynamic>{};
    if (resp.statusCode != 200 || body['access_token'] == null) {
      throw CloudAuthException(
          body['error']?.toString() ?? 'token exchange failed');
    }
    await _persistTokenResponse(body);
  }

  /// 用 refresh_token 续期（MSA 会滚动下发新 refresh_token，必须落盘）。
  Future<void> _refreshTokens() async {
    final dio = _tokenDio();
    final Response<Map<String, dynamic>> resp;
    try {
      resp = await dio.post<Map<String, dynamic>>(
        '${OneDriveOAuthConfig.authority}/token',
        data: <String, String>{
          'grant_type': 'refresh_token',
          'client_id': OneDriveOAuthConfig.clientId,
          'refresh_token': _refreshToken!,
          'scope': OneDriveOAuthConfig.scopes.join(' '),
        },
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          validateStatus: (s) => s != null && s < 500,
        ),
      );
    } on DioException catch (e) {
      throw CloudAuthException('refresh failed: ${e.message ?? e.type.name}');
    }
    final body = resp.data ?? const <String, dynamic>{};
    if (resp.statusCode != 200 || body['access_token'] == null) {
      // refresh_token 失效（改密码 / 过久未用 / 被撤销）：清除本地会话。
      await logout();
      throw CloudAuthException(body['error']?.toString() ?? 'refresh failed');
    }
    await _persistTokenResponse(body);
  }

  /// 落盘 token 响应（access / 滚动 refresh / 过期时间），并拉取账号名。
  Future<void> _persistTokenResponse(Map<String, dynamic> body) async {
    _accessToken = body['access_token'] as String?;
    final rotated = body['refresh_token'] as String?;
    if (rotated != null && rotated.isNotEmpty) _refreshToken = rotated;
    final expiresIn = (body['expires_in'] as num?)?.toInt();
    _expiresAt = expiresIn == null
        ? null
        : DateTime.now().millisecondsSinceEpoch + expiresIn * 1000;
    try {
      await _storage.write(key: _accessTokenKey, value: _accessToken!);
      if (_refreshToken != null) {
        await _storage.write(key: _refreshTokenKey, value: _refreshToken!);
      }
      if (_expiresAt != null) {
        await _storage.write(key: _expiresAtKey, value: _expiresAt!.toString());
      }
    } catch (_) {
      // secure storage 写失败：保持内存会话，下次冷启动需重新登录。
    }
    notifyListeners();
    // 账号名仅用于展示，失败不影响登录。
    try {
      await refreshAccount();
    } on Object {
      // /me 拉取失败可忽略
    }
  }

  /// 用当前 token 拉取 `/v1.0/me`，补齐账号展示名。
  Future<void> refreshAccount() async {
    if (_accessToken == null) return;
    final dio = _tokenDio();
    final resp = await dio.get<Map<String, dynamic>>(
      'https://graph.microsoft.com/v1.0/me',
      options: Options(
        headers: <String, String>{'Authorization': 'Bearer $_accessToken'},
      ),
    );
    final me = resp.data ?? const <String, dynamic>{};
    final name = (me['mail'] as String?) ??
        (me['userPrincipalName'] as String?) ??
        (me['displayName'] as String?);
    if (name != null && name.isNotEmpty) {
      _account = name;
      try {
        await _storage.write(key: _accountKey, value: name);
      } on Object {
        // 展示信息写失败可忽略
      }
      notifyListeners();
    }
  }

  /// 退出登录：清除本地凭证。
  Future<void> logout() async {
    _accessToken = null;
    _refreshToken = null;
    _expiresAt = null;
    _account = null;
    for (final key in <String>[
      _accessTokenKey,
      _refreshTokenKey,
      _expiresAtKey,
      _accountKey,
    ]) {
      try {
        await _storage.delete(key: key);
      } on Object {
        // 单个 key 清理失败不影响登出
      }
    }
    notifyListeners();
  }

  Dio _tokenDio() => Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
      ));

  /// PKCE S256 challenge（公开供单测）：base64url(sha256(verifier)) 去填充。
  static String deriveCodeChallenge(String verifier) =>
      _base64UrlNoPad(crypto.sha256.convert(utf8.encode(verifier)).bytes);

  String _randomBase64Url(int byteCount) {
    final r = Random.secure();
    final bytes = List<int>.generate(byteCount, (_) => r.nextInt(256));
    return _base64UrlNoPad(bytes);
  }

  static String _base64UrlNoPad(List<int> bytes) =>
      base64UrlEncode(bytes).replaceAll('=', '');
}

/// Bangumi 账号认证（个人 Access Token 路径 + OAuth 2.0 发布形态）。
///
/// - token 与用户名存 [FlutterSecureStorage]；
/// - `saveToken` 先调 `/v0/me` 校验有效性再落盘；
/// - OAuth 完整形态见 [loginWithOAuth]：引导浏览器授权 → 深链回调取 code →
///   换 access_token + refresh_token（均存安全存储，refresh 用以续期）。
library;

import 'dart:async';
import 'dart:math';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:url_launcher/url_launcher.dart';

import 'bangumi_client.dart';
import 'bangumi_oauth_config.dart';

/// Bangumi 认证管理器——全应用单例（Provider 注入）。
class BangumiAuth extends ChangeNotifier {
  BangumiAuth({
    required BangumiClient client,
    FlutterSecureStorage? storage,
  })  : _client = client,
        _storage = storage ?? const FlutterSecureStorage();

  static const String _tokenKey = 'bangumi_access_token';
  static const String _usernameKey = 'bangumi_username';
  static const String _nicknameKey = 'bangumi_nickname';
  static const String _refreshTokenKey = 'bangumi_refresh_token';
  static const String _expiresAtKey = 'bangumi_expires_at';

  final BangumiClient _client;
  final FlutterSecureStorage _storage;

  String? _token;
  String? _username;
  String? _nickname;

  /// OAuth refresh_token（用于 [refresh] 续期）。
  String? _refreshToken;

  /// access_token 过期时刻（毫秒时间戳），null = 未知/不过期。
  int? _expiresAt;

  bool get isLoggedIn => _token != null && _token!.isNotEmpty;

  /// 登录名（API 路径用，如拉取用户收藏列表）。
  String? get username => _username;

  /// 展示名：优先昵称，缺省回退登录名。
  String? get displayName =>
      (_nickname != null && _nickname!.isNotEmpty) ? _nickname : _username;

  /// OAuth refresh_token（空表示非 OAuth 登录，无法续期）。
  String? get refreshToken => _refreshToken;

  /// access_token 是否已过期（基于 [expiresAt]）；未知时视为未过期。
  bool get isExpired =>
      _expiresAt != null &&
      DateTime.now().millisecondsSinceEpoch >= _expiresAt!;

  /// 深链回调监听（懒加载，避免无 OAuth 时也初始化）。
  AppLinks? _appLinksInstance;
  AppLinks get _appLinks => _appLinksInstance ??= AppLinks();

  /// 冷启动恢复已存 token（注入 client 后通知 UI）。
  Future<void> init() async {
    try {
      _token = await _storage.read(key: _tokenKey);
      _username = await _storage.read(key: _usernameKey);
      _nickname = await _storage.read(key: _nicknameKey);
      _refreshToken = await _storage.read(key: _refreshTokenKey);
      final expiresRaw = await _storage.read(key: _expiresAtKey);
      _expiresAt = int.tryParse(expiresRaw ?? '');
    } catch (_) {
      // secure storage 不可用（如桌面端缺 keyring）时按未登录处理。
      _token = null;
      _username = null;
      _nickname = null;
      _refreshToken = null;
      _expiresAt = null;
    }
    _client.token = _token;
    notifyListeners();
  }

  /// 落盘会话（token / 用户名 / 昵称）。refresh_token 与过期时间由调用方另行写入。
  Future<void> _persistSession({
    required String token,
    required String username,
    String? nickname,
  }) async {
    _token = token;
    _username = username;
    _nickname = nickname;
    _client.token = token;
    await _storage.write(key: _tokenKey, value: token);
    await _storage.write(key: _usernameKey, value: username);
    if (nickname != null) {
      await _storage.write(key: _nicknameKey, value: nickname);
    }
    notifyListeners();
  }

  /// 校验并保存个人 Access Token。
  ///
  /// 先用该 token 调 `/v0/me`，通过后才持久化；校验失败抛
  /// [BangumiApiException]（401 = token 无效）。
  Future<void> saveToken(String token) async {
    final trimmed = token.trim();
    if (trimmed.isEmpty) {
      throw const BangumiApiException(401, 'empty token');
    }
    final previous = _client.token;
    _client.token = trimmed;
    try {
      final me = await _client.fetchMe();
      await _persistSession(
        token: trimmed,
        username: me.username,
        nickname: me.nickname,
      );
    } catch (_) {
      _client.token = previous;
      rethrow;
    }
  }

  /// OAuth 2.0 授权码登录（发布形态）。
  ///
  /// 流程：在系统浏览器打开 `https://bgm.tv/oauth/authorize` →
  /// 用户授权后 Bangumi 通过深链 `nexhub://oauth/callback?code=...` 回调 →
  /// 用 code 换 access_token，再走与 [saveToken] 相同的存储路径（并额外存
  /// refresh_token 与过期时间）。
  ///
  /// 前置条件：已在 [BangumiOAuthConfig] 填入 Client ID / Secret，否则抛
  /// [StateError]。用户超时未授权（10 分钟）抛 [StateError]。
  Future<void> loginWithOAuth() async {
    if (!BangumiOAuthConfig.configured) {
      throw StateError('bangumi oauth not configured');
    }
    final code = await _authorizeAndWaitCode();
    final token = await _client.exchangeCodeForToken(
      clientId: BangumiOAuthConfig.clientId,
      clientSecret: BangumiOAuthConfig.clientSecret,
      code: code,
      redirectUri: BangumiOAuthConfig.redirectUri,
    );
    // 复用 saveToken 的 /v0/me 校验 + 落盘逻辑。
    await saveToken(token.accessToken);
    if (token.refreshToken != null) {
      _refreshToken = token.refreshToken;
      await _storage.write(key: _refreshTokenKey, value: token.refreshToken!);
    }
    if (token.expiresIn != null) {
      _expiresAt = DateTime.now()
          .add(Duration(seconds: token.expiresIn!))
          .millisecondsSinceEpoch;
      await _storage.write(key: _expiresAtKey, value: _expiresAt!.toString());
    }
    notifyListeners();
  }

  /// 打开浏览器授权页并等待深链回调带回的授权码。
  Future<String> _authorizeAndWaitCode() async {
    final state = _randomState();
    final uri = Uri.https('bgm.tv', '/oauth/authorize', <String, String>{
      'client_id': BangumiOAuthConfig.clientId,
      'response_type': 'code',
      'redirect_uri': BangumiOAuthConfig.redirectUri,
      if (BangumiOAuthConfig.scopes.isNotEmpty)
        'scope': BangumiOAuthConfig.scopes.join(' '),
      'state': state,
    });

    final completer = Completer<String>();
    late final StreamSubscription<Uri> sub;
    var handled = false;

    Future<void> handle(Uri? u) async {
      if (u == null || handled) return;
      if (u.scheme == 'nexhub' && u.host == 'oauth' && u.path == '/callback') {
        final code = u.queryParameters['code'];
        final ret = u.queryParameters['state'];
        // 校验 state 防 CSRF（bgm.tv 原样回传）。
        if (code != null && (ret == null || ret == state)) {
          handled = true;
          await sub.cancel();
          if (!completer.isCompleted) completer.complete(code);
        }
      }
    }

    sub = _appLinks.uriLinkStream.listen(handle);
    // 冷启动经深链进入时，首链可能已是回调。
    await handle(await _appLinks.getInitialLink());
    await launchUrl(uri, mode: LaunchMode.externalApplication);
    try {
      return await completer.future.timeout(const Duration(minutes: 10));
    } on TimeoutException {
      await sub.cancel();
      throw StateError('bangumi oauth timed out');
    }
  }

  /// 用 refresh_token 续期 access_token（OAuth 登录且未过期时调用）。
  ///
  /// 非 OAuth 登录（_refreshToken 为空）时直接返回，不做任何操作。
  Future<void> refresh() async {
    if (_refreshToken == null || _refreshToken!.isEmpty) return;
    final token = await _client.refreshToken(
      clientId: BangumiOAuthConfig.clientId,
      clientSecret: BangumiOAuthConfig.clientSecret,
      refreshToken: _refreshToken!,
      redirectUri: BangumiOAuthConfig.redirectUri,
    );
    _token = token.accessToken;
    _client.token = token.accessToken;
    _refreshToken = token.refreshToken ?? _refreshToken;
    _expiresAt = token.expiresIn != null
        ? DateTime.now()
            .add(Duration(seconds: token.expiresIn!))
            .millisecondsSinceEpoch
        : null;
    await _storage.write(key: _tokenKey, value: _token!);
    await _storage.write(key: _refreshTokenKey, value: _refreshToken!);
    if (_expiresAt != null) {
      await _storage.write(key: _expiresAtKey, value: _expiresAt!.toString());
    }
    notifyListeners();
  }

  /// 用已存 token 重新拉取 `/v0/me`，补齐 / 刷新用户名与昵称。
  ///
  /// 冷启动后若本地未存 username（旧版本升级、secure storage 曾读失败），
  /// 可借此恢复；未登录时直接返回，网络 / 鉴权失败上抛供调用方处理。
  Future<void> refreshProfile() async {
    if (!isLoggedIn) return;
    final me = await _client.fetchMe();
    _username = me.username;
    _nickname = me.nickname;
    await _storage.write(key: _usernameKey, value: me.username);
    await _storage.write(key: _nicknameKey, value: me.nickname);
    notifyListeners();
  }

  /// 退出登录：清除本地凭证。
  Future<void> logout() async {
    _token = null;
    _username = null;
    _nickname = null;
    _refreshToken = null;
    _expiresAt = null;
    _client.token = null;
    await _storage.delete(key: _tokenKey);
    await _storage.delete(key: _usernameKey);
    await _storage.delete(key: _nicknameKey);
    await _storage.delete(key: _refreshTokenKey);
    await _storage.delete(key: _expiresAtKey);
    notifyListeners();
  }

  /// 生成随机 state（防 CSRF），base36 时间戳 + 随机数。
  String _randomState() {
    final r = Random();
    final ts = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final rand = r.nextInt(1 << 32).toRadixString(36);
    return '$ts-$rand';
  }
}

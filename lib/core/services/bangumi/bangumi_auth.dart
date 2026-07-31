/// Bangumi 账号认证（个人 Access Token 路径）。
///
/// - token 与用户名存 [FlutterSecureStorage]；
/// - `saveToken` 先调 `/v0/me` 校验有效性再落盘；
/// - OAuth 完整应用形态后置（见 [loginWithOAuth] 占位）。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'bangumi_client.dart';

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

  final BangumiClient _client;
  final FlutterSecureStorage _storage;

  String? _token;
  String? _username;
  String? _nickname;

  bool get isLoggedIn => _token != null && _token!.isNotEmpty;

  /// 登录名（API 路径用，如拉取用户收藏列表）。
  String? get username => _username;

  /// 展示名：优先昵称，缺省回退登录名。
  String? get displayName =>
      (_nickname != null && _nickname!.isNotEmpty) ? _nickname : _username;

  /// 冷启动恢复已存 token（注入 client 后通知 UI）。
  Future<void> init() async {
    try {
      _token = await _storage.read(key: _tokenKey);
      _username = await _storage.read(key: _usernameKey);
      _nickname = await _storage.read(key: _nicknameKey);
    } catch (_) {
      // secure storage 不可用（如桌面端缺 keyring）时按未登录处理。
      _token = null;
      _username = null;
      _nickname = null;
    }
    _client.token = _token;
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
      _token = trimmed;
      _username = me.username;
      _nickname = me.nickname;
      await _storage.write(key: _tokenKey, value: trimmed);
      await _storage.write(key: _usernameKey, value: me.username);
      await _storage.write(key: _nicknameKey, value: me.nickname);
      notifyListeners();
    } catch (_) {
      _client.token = previous;
      rethrow;
    }
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
    _client.token = null;
    await _storage.delete(key: _tokenKey);
    await _storage.delete(key: _usernameKey);
    await _storage.delete(key: _nicknameKey);
    notifyListeners();
  }

  /// OAuth 授权登录（发布形态）——本轮不实现。
  ///
  /// 计划：bgm.tv/dev 注册应用 + deep link 回调（nexhub://oauth/callback），
  /// 用 app_links 接收授权码换 token 后走与 [saveToken] 相同的存储路径。
  Future<void> loginWithOAuth() async {
    throw UnimplementedError('Bangumi OAuth login is not implemented yet');
  }
}

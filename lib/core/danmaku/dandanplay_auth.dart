/// 弹弹play 账号认证管理（F-18 弹幕发送上传的前置登录态）。
///
/// - token / 用户名存 [FlutterSecureStorage]（对齐 [BangumiAuth] 的存储策略）；
/// - 登录经 `DandanplayService.login`（POST /api/v2/login，应用签名 + 账号
///   密码 hash），成功后 token 供发送弹幕以 `Authorization: Bearer` 携带；
/// - 全应用单例（`instance`），播放器弹幕输入与全局设置页共用同一登录态。
///
/// 注意：token 有效期由服务器控制（默认约 90 天）；过期时发送请求会被拒绝，
/// 由调用方提示重新登录（不做自动续期）。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../settings/danmaku_config.dart';
import 'dandanplay_service.dart';

class DandanplayAuth extends ChangeNotifier {
  DandanplayAuth._();

  /// 全应用单例。
  static final DandanplayAuth instance = DandanplayAuth._();

  static const String _tokenKey = 'dandanplay_access_token';
  static const String _usernameKey = 'dandanplay_username';
  static const String _screenNameKey = 'dandanplay_screen_name';

  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  String? _token;
  String? _userName;
  String? _screenName;
  bool _loaded = false;

  bool get isLoggedIn => _token != null && _token!.isNotEmpty;

  /// 当前用户 token（未登录为 null）。发送弹幕前读取。
  String? get token => _token;

  /// 登录名；展示名优先昵称，缺省回退登录名。
  String? get userName => _userName;

  String? get displayName {
    final screen = _screenName;
    if (screen != null && screen.isNotEmpty) return screen;
    return _userName;
  }

  /// 冷启动恢复已存登录态（幂等，可重复调用）。
  Future<void> init() async {
    if (_loaded) return;
    try {
      _token = await _storage.read(key: _tokenKey);
      _userName = await _storage.read(key: _usernameKey);
      _screenName = await _storage.read(key: _screenNameKey);
    } catch (_) {
      // secure storage 不可用（如桌面端缺 keyring）时按未登录处理。
      _token = null;
      _userName = null;
      _screenName = null;
    }
    _loaded = true;
    notifyListeners();
  }

  /// 登录并持久化 token。凭据未配置 / 账号密码错误原样抛出由 UI 提示。
  Future<void> login(String userName, String password) async {
    await init();
    final service = DandanplayService(configStore: DanmakuConfigStore());
    final result = await service.login(userName, password);
    _token = result.token;
    _userName = result.userName;
    _screenName = result.screenName;
    try {
      await _storage.write(key: _tokenKey, value: _token);
      await _storage.write(key: _usernameKey, value: _userName);
      await _storage.write(key: _screenNameKey, value: _screenName);
    } catch (_) {
      // 写盘失败不阻断登录：本次会话内仍可发送，下次需重新登录。
    }
    notifyListeners();
  }

  /// 登出：清除内存与安全存储中的登录态。
  Future<void> logout() async {
    _token = null;
    _userName = null;
    _screenName = null;
    try {
      await _storage.delete(key: _tokenKey);
      await _storage.delete(key: _usernameKey);
      await _storage.delete(key: _screenNameKey);
    } catch (_) {
      // 清理失败忽略，内存态已置空。
    }
    notifyListeners();
  }

  /// 注册新账号并自动登录（持久化 token）。
  ///
  /// 经 `DandanplayService.register`（POST /api/v2/register），成功后响应与
  /// 登录一致（带 token + 用户信息），直接落盘并切换为已登录态，无需再调
  /// [login]。凭据未配置 / 参数校验失败原样抛出由 UI 提示。
  Future<void> register({
    required String userName,
    required String password,
    required String email,
    required String screenName,
  }) async {
    await init();
    final service = DandanplayService(configStore: DanmakuConfigStore());
    final result = await service.register(
      userName: userName,
      password: password,
      email: email,
      screenName: screenName,
    );
    _token = result.token;
    _userName = result.userName;
    _screenName = result.screenName;
    try {
      await _storage.write(key: _tokenKey, value: _token);
      await _storage.write(key: _usernameKey, value: _userName);
      await _storage.write(key: _screenNameKey, value: _screenName);
    } catch (_) {
      // 写盘失败不阻断注册：本次会话内已登录。
    }
    notifyListeners();
  }
}

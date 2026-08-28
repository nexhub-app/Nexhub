/// 源登录态管理：按源 `comments.login` 声明判定并维护各源的登录状态。
///
/// - 快速路径：该源相关 host 的 Cookie 头中出现 `login.checkCookie` 键名
///   即视为已登录（同步判定，UI 直接可用）。
/// - 可选确认：声明 `login.checkUrl` 时经 [refreshLoginState] 异步探测
///   （`loggedInSelector` 命中非空即登录有效），结果缓存并广播。
/// - 订阅 [HttpFetcher.cookieVersionStream]：Cookie 变化（WebView 回灌 /
///   登出 / 过期清除）自动重新评估已关注源的登录态。
///
/// 依赖均可经构造注入（测试免 Hive / 免真实网络）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/plugin_config.dart';
import '../scraper/http_fetcher.dart';
import '../services/config_loader.dart';
import '../utils/html_utils.dart';
import '../utils/json_path.dart';
import 'source_auth_header.dart';
import 'source_key_store.dart';

class SourceAuthManager extends ChangeNotifier {
  SourceAuthManager({
    String? Function(String host)? cookieHeader,
    Stream<int>? cookieVersions,
    void Function(String host)? clearCookies,
    Future<String> Function(String url, {String? referer})? probe,
  })  : _cookieHeader = cookieHeader ?? HttpFetcher.instance.getCookieHeader,
        _clearCookies = clearCookies ?? HttpFetcher.instance.clearCookiesFor,
        _probe = probe ?? _defaultProbe {
    _sub = (cookieVersions ?? HttpFetcher.instance.cookieVersionStream)
        .listen((_) => _reevaluateAll());
  }

  static Future<String> _defaultProbe(String url, {String? referer}) =>
      HttpFetcher.instance.getHtml(url, referer: referer);

  final String? Function(String host) _cookieHeader;
  final void Function(String host) _clearCookies;
  final Future<String> Function(String url, {String? referer}) _probe;

  /// 各源登录态缓存（key = source.id）。
  final Map<String, bool> _loginState = <String, bool>{};

  /// 被关注的源（isLoggedIn/refreshLoginState 查询过的）：Cookie 变化时
  /// 仅对这些源重新评估，避免持有全部源配置。
  final Map<String, PluginConfig> _watched = <String, PluginConfig>{};

  StreamSubscription<int>? _sub;

  /// 同步判定某源是否已登录（快速路径）。
  /// - `sendTokenAs: "key"` 模式：用户已在登录面板粘贴并持久化 API Key 即视为已登录。
  /// - 其余：Cookie 中 `checkCookie` 键名匹配即已登录（结果缓存）。
  /// 源未声明 comments.login 时恒为 false。
  bool isLoggedIn(PluginConfig source) {
    final login = source.comments?.login;
    if (login == null) return false;
    _watched[source.id] = source;
    if (login.sendTokenAs == 'key') {
      final param = login.apiKeyParam ?? 'apiKey';
      final hasKey = SourceKeyStore.get(source.id, param) != null;
      if (hasKey) return _loginState[source.id] ??= true;
    }
    return _loginState[source.id] ??= _cookieLoggedIn(source);
  }

  /// 重新评估某源登录态：先 Cookie 快速判定，声明 checkUrl 时再异步探测
  /// 二次确认。结果缓存，变化时 notifyListeners。
  Future<bool> refreshLoginState(PluginConfig source) async {
    final login = source.comments?.login;
    if (login == null) return false;
    _watched[source.id] = source;
    final hasCheckCookie =
        login.checkCookie != null && login.checkCookie!.isNotEmpty;
    var loggedIn = hasCheckCookie && _cookieLoggedIn(source);
    // checkUrl 探测：Cookie 快速路径命中时二次确认；未声明 checkCookie 时
    // （如会话 Cookie 名不固定）直接以探测结果为准。
    if (login.checkUrl != null &&
        login.checkUrl!.isNotEmpty &&
        (loggedIn || !hasCheckCookie)) {
      loggedIn = await _probeLoggedIn(source, login);
    }
    _setState(source.id, loggedIn);
    return loggedIn;
  }

  /// 登出：清除该源相关 host 的 Cookie（内存 + 持久化）。若为 `key` 模式，
  /// 同时清除持久化的手动 API Key（二者皆清，登录态归零）并广播。
  Future<void> logout(PluginConfig source) async {
    for (final host in _hostsFor(source)) {
      _clearCookies(host);
    }
    final login = source.comments?.login;
    if (login?.sendTokenAs == 'key') {
      final param = login!.apiKeyParam ?? 'apiKey';
      await SourceKeyStore.clear(source.id, param);
    }
    _setState(source.id, false);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _sub = null;
    super.dispose();
  }

  // ---- 内部 ----

  /// Cookie 快速判定：源相关 host（baseUrl 与 login.url）的 Cookie 头中
  /// 出现 checkCookie 键名即视为已登录。
  ///
  /// 匹配规则：① 精确（正则 `checkCookie=`，兼容既有配置）；② 前缀（cookie 名
  /// 以 checkCookie 开头，如某源配置写 `session` 而后端实际下发
  /// `sessionid`）——避免出现「Cookie 已回灌、却因名字差一个 id 而始终判未登录」。
  bool _cookieLoggedIn(PluginConfig source) {
    final key = source.comments?.login?.checkCookie;
    if (key == null || key.isEmpty) return false;
    final pattern = RegExp('(^|;\\s*)${RegExp.escape(key)}=');
    for (final host in _hostsFor(source)) {
      final header = _cookieHeader(host);
      if (header == null || header.isEmpty) continue;
      if (pattern.hasMatch(header)) return true;
      var matched = false;
      for (final part in header.split(';')) {
        final eq = part.indexOf('=');
        if (eq <= 0) continue;
        final name = part.substring(0, eq).trim();
        if (name == key || name.startsWith(key)) {
          matched = true;
          break;
        }
      }
      if (matched) return true;
    }
    return false;
  }

  /// 该源涉及的 host 集合：站点 baseUrl、当前激活镜像与登录页 url。
  List<String> _hostsFor(PluginConfig source) {
    final hosts = <String>{};
    void add(String? url) {
      final host = Uri.tryParse(url ?? '')?.host;
      if (host != null && host.isNotEmpty) hosts.add(host);
    }

    add(source.site.baseUrl);
    add(ConfigLoader.instance.getActiveMirror(source));
    add(source.comments?.login?.url);
    return hosts.toList();
  }

  /// checkUrl 探测：GET 后按 loggedInSelector 判定（JSONPath/CSS 命中非空
  /// 即有效；未声明选择器时 2xx 即有效）。请求失败（401 等）判未登录。
  /// 探测请求会附加源声明的 Authorization 头（[sourceAuthHeader]，如 `key`
  /// 模式的 `Key <apiKey>`），使受保护端点（如 `/api/v2/user` 一类接口）能真实校验。
  Future<bool> _probeLoggedIn(
    PluginConfig source,
    CommentsLoginConfig login,
  ) async {
    final base = ConfigLoader.instance.getActiveMirror(source);
    final raw = login.checkUrl!;
    final url = raw.startsWith('http')
        ? raw
        : '${base.replaceAll(RegExp(r'/+$'), '')}/${raw.replaceAll(RegExp(r'^/+'), '')}';
    // 受保护端点（如 /api/v2/user 一类接口）需在探测时附加源声明的 Authorization
    // 头（[sourceAuthHeader]，如 `key` 模式的 `Key <apiKey>`）才能真实校验。
    // 有头时直接走 HttpFetcher 注入；无头时仍走可注入的 _probe（测试免真实网络）。
    final authHeaders = sourceAuthHeader(source);
    final String text;
    try {
      text = authHeaders != null
          ? await HttpFetcher.instance.getHtml(
              url, referer: base, headers: authHeaders)
          : await _probe(url, referer: base);
    } catch (_) {
      return false;
    }
    final selector = login.loggedInSelector;
    if (selector == null || selector.isEmpty) return true;
    if (selector.startsWith(r'$')) {
      try {
        final v = JsonPath.eval(selector, jsonDecode(text));
        return v != null && v.toString().isNotEmpty;
      } on FormatException {
        return false;
      }
    }
    final v = HtmlUtils.query(text, selector);
    return v != null && v.isNotEmpty;
  }

  void _setState(String sourceId, bool value) {
    final changed = _loginState[sourceId] != value;
    _loginState[sourceId] = value;
    if (changed) notifyListeners();
  }

  /// Cookie 变化（回灌/登出/过期）→ 对已关注源按快速路径重新评估。
  void _reevaluateAll() {
    var changed = false;
    for (final source in _watched.values) {
      final v = _cookieLoggedIn(source);
      if (_loginState[source.id] != v) {
        _loginState[source.id] = v;
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }
}

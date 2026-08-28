/// 源评论登录：内嵌 WebView 完成登录，结束后手动回灌 Cookie。
///
/// 采用内嵌 [InAppWebView]（应用内网页视图）。用户在视图内完成登录后：
/// - 手动回灌：点击底部浮动按钮「获取 Cookie」，从 WebView 共享 Cookie 存储
///   读取该源相关域的 Cookie 并同步到 [HttpFetcher]（内存 jar + CookieStore 落盘），
///   随后关闭页面、由调用方经 SourceAuthManager.refreshLoginState 重新评估登录态。
/// - 不再轮询：旧实现用 2s 定时器反复读取并回灌 Cookie，登录态未变时也会持续
///   触发封面重载，现改为用户主动点击，只在确实拿到登录 Cookie 时回灌一次。
///
/// 桌面端（InAppWebView 不可用）回退为提示使用「粘贴 Cookie」方式。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../core/models/plugin_config.dart';
import '../../../core/platform/platform_service.dart';
import '../../../core/scraper/http_fetcher.dart';
import '../../../core/theme/app_tokens.dart';

/// 源登录「内嵌网页」页面。返回 `true` 表示 Cookie 已同步、应重新评估登录态。
class WebViewLoginScreen extends StatefulWidget {
  final PluginConfig source;

  const WebViewLoginScreen({super.key, required this.source});

  @override
  State<WebViewLoginScreen> createState() => _WebViewLoginScreenState();
}

class _WebViewLoginScreenState extends State<WebViewLoginScreen> {
  @override
  void initState() {
    super.initState();
    // 源声明的 UA 可能极简/与 WebView 环境不符（nhentai 为 `Mozilla/5.0`），
    // 且与能过 turnstile 的 WebView 默认 Android UA 不一致 → CF 600010。
    // 登录前把相关 host 钉为完整浏览器 UA（Android 移动版），登录页与回灌后
    // 的抓取请求同 UA，cf_clearance 才有效。
    _applyFullBrowserUa();
  }

  /// 把本源登录涉及的 host（登录地址 + 站点主域）UA 覆盖为完整浏览器 UA。
  void _applyFullBrowserUa() {
    try {
      final String ua = HttpFetcher.instance.fullBrowserUserAgent();
      final String? loginHost =
          Uri.tryParse(widget.source.comments?.login?.url ?? '')?.host;
      final String? baseHost = Uri.tryParse(widget.source.site.baseUrl)?.host;
      final Set<String> hosts = <String>{};
      if (loginHost != null && loginHost.isNotEmpty) hosts.add(loginHost);
      if (baseHost != null && baseHost.isNotEmpty) hosts.add(baseHost);
      for (final h in hosts) {
        HttpFetcher.instance.registerHostUserAgent(h, ua);
      }
    } catch (_) {
      // UA 覆盖失败不影响登录主流程。
    }
  }

  /// 当前页面地址（onLoadStop 同步维护；getUrl() 是 Future 不能同步用）。
  String? _currentPageUrl;

  /// 本次是否回灌到 Cookie（供返回结果）。
  bool _synced = false;

  /// 防止浮动按钮重复 pop。
  bool _popped = false;

  CommentsLoginConfig? get _login => widget.source.comments?.login;

  String get _loginUrl => _login?.url ?? '';

  /// 是否支持内嵌网页（移动端）；桌面/Web 回退「粘贴 Cookie」提示。
  bool get _supported =>
      PlatformService.instance.isAndroid || PlatformService.instance.isIOS;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.sourceLogin)),
      body: _supported ? _buildWebView(l10n) : _buildUnsupported(l10n),
      floatingActionButton: _supported
          ? FloatingActionButton.extended(
              onPressed: _onGetCookie,
              icon: const Icon(Icons.cookie),
              label: Text(l10n.getCookie),
            )
          : null,
    );
  }

  /// 内嵌网页视图：用站点 baseUrl 的 UA 登录（与后续抓取一致，避免会话绑定到
  /// 不同 UA 被判失效）。
  Widget _buildWebView(AppLocalizations l10n) {
    final String ua = HttpFetcher.instance.userAgentForUrl(
      widget.source.site.baseUrl,
    );
    return InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(_loginUrl)),
      initialSettings: InAppWebViewSettings(userAgent: ua),
      onLoadStop: (_, url) async {
        if (url != null) _currentPageUrl = url.toString();
      },
    );
  }

  /// 浮动按钮：「获取 Cookie」——读取 WebView 共享 Cookie 并回灌一次，随后退出。
  Future<void> _onGetCookie() async {
    final ok = await _syncCookies();
    if (!mounted) return;
    _synced = _synced || ok;
    if (!_popped) {
      _popped = true;
      Navigator.of(context).pop(_synced);
    }
  }

  /// 桌面/Web 回退：提示使用「粘贴 Cookie」方式登录。
  Widget _buildUnsupported(AppLocalizations l10n) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.spaceXl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.web_asset_off,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppTokens.spaceMd),
            Text(
              l10n.webviewLoginUnsupported,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 本次登录涉及的目标地址：当前页面（跳转后的实际域）+ 登录页 + 站点主域。
  List<Uri> _targetUris() {
    final uris = <String, Uri>{};
    void add(String? url) {
      final uri = Uri.tryParse(url ?? '');
      if (uri != null && uri.host.isNotEmpty) uris[uri.host] = uri;
    }

    add(_currentPageUrl);
    add(_loginUrl);
    add(widget.source.site.baseUrl);
    return uris.values.toList();
  }

  /// 从 WebView 共享 Cookie 存储取回各相关域的 Cookie 并回灌到 [HttpFetcher]
  /// （内存 jar + CookieStore 落盘），返回是否命中到任意 Cookie。
  Future<bool> _syncCookies() async {
    final checkCookie = _login?.checkCookie;
    var wroteAny = false;
    // 优先一次性取回全部 Cookie 并按自身 domain 分组回灌：登录往往把会话
    // cookie 下发到主域（Domain=.example.com），而登录页可能停在子域/跳转后
    // 的域，逐域 getCookies('scheme://host') 容易漏域、且无 path 时读不到
    // Path 非 / 的 cookie → 表现为「登录了但点获取 Cookie 拿不到 / 仍未登录」。
    try {
      final List<Cookie> all = await CookieManager.instance().getAllCookies();
      if (all.isNotEmpty) {
        final List<Uri> targets = _targetUris();
        final Map<String, List<Cookie>> byDomain =
            <String, List<Cookie>>{};
        for (final Cookie c in all) {
          final String? d = c.domain;
          if (d == null || d.isEmpty) continue;
          final String host =
              (d.startsWith('.') ? d.substring(1) : d).toLowerCase();
          // 仅回灌与本源相关的域（相同/父子域），避免污染其他站点的 jar。
          final bool related = targets.any((Uri t) {
            final String th = t.host.toLowerCase();
            return host == th || host.endsWith('.$th') || th.endsWith('.$host');
          });
          if (!related) continue;
          byDomain.putIfAbsent(host, () => <Cookie>[]).add(c);
        }
        for (final MapEntry<String, List<Cookie>> e in byDomain.entries) {
          final String header = e.value
              .where((c) =>
                  c.value != null && c.value.toString().isNotEmpty)
              .map((c) => '${c.name}=${c.value}')
              .join('; ');
          if (header.isEmpty) continue;
          HttpFetcher.instance.syncCookies(e.key, header);
          wroteAny = true;
        }
        if (checkCookie != null &&
            checkCookie.isNotEmpty &&
            all.any((Cookie c) => c.name == checkCookie)) {
          wroteAny = true;
        }
        return wroteAny;
      }
    } catch (_) {
      // getAllCookies 失败（低版本 WebView / 不支持 GET_COOKIE_INFO）：回退逐域。
    }
    // 回退：逐域读取（原逻辑）。
    for (final uri in _targetUris()) {
      try {
        final cookies = await CookieManager.instance().getCookies(
          url: WebUri('${uri.scheme}://${uri.host}'),
        );
        if (cookies.isEmpty) continue;
        final cookieHeader = cookies
            .where((c) => c.value != null && c.value.toString().isNotEmpty)
            .map((c) => '${c.name}=${c.value}')
            .join('; ');
        if (cookieHeader.isNotEmpty) {
          HttpFetcher.instance.syncCookies(uri.host, cookieHeader);
          wroteAny = true;
        }
        if (checkCookie != null &&
            checkCookie.isNotEmpty &&
            cookies.any((c) => c.name == checkCookie)) {
          wroteAny = true;
        }
      } catch (_) {
        // 单域取 Cookie 失败不阻断其余域。
      }
    }
    return wroteAny;
  }
}

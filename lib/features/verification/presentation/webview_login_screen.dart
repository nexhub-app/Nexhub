/// 源评论 WebView 登录页。
///
/// 加载源声明的 `comments.login.url`，用户在页内完成登录后：
/// - 自动检测：`onLoadStop` 及后续轮询查询 [CookieManager] 的 Cookie，
///   出现 `login.checkCookie` 键名即同步 Cookie 到 [HttpFetcher]
///   （与 webview_verification_screen 同款回灌模式）→ SnackBar「登录成功」
///   → `Navigator.pop(true)`。
/// - 手动兜底：AppBar「完成」按钮强制同步 Cookie 后返回 true，
///   由调用方经 SourceAuthManager.refreshLoginState 重新评估登录态。
///
/// 桌面端（InAppWebView 不可用）回退为提示使用「粘贴 Cookie」方式
/// （与验证流程的桌面降级一致）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../core/models/plugin_config.dart';
import '../../../core/platform/platform_service.dart';
import '../../../core/scraper/http_fetcher.dart';
import '../../../core/theme/app_tokens.dart';

/// 源登录 WebView 页面。返回 `true` 表示 Cookie 已同步、应重新评估登录态。
class WebViewLoginScreen extends StatefulWidget {
  final PluginConfig source;

  const WebViewLoginScreen({super.key, required this.source});

  @override
  State<WebViewLoginScreen> createState() => _WebViewLoginScreenState();
}

class _WebViewLoginScreenState extends State<WebViewLoginScreen> {
  bool _pageLoaded = false;

  /// 当前页面地址（onLoadStop 同步维护；getUrl() 是 Future 不能同步用）。
  String? _currentPageUrl;

  /// 是否已回传（防轮询多次触发重复 pop）。
  bool _popped = false;

  /// checkCookie 轮询计时器（登录多为页内 XHR，不一定触发新的 onLoadStop）。
  Timer? _pollTimer;

  CommentsLoginConfig? get _login => widget.source.comments?.login;

  String get _loginUrl => _login?.url ?? '';

  /// 是否支持内嵌 WebView（移动端）；桌面/Web 回退「粘贴 Cookie」提示。
  bool get _webViewSupported =>
      PlatformService.instance.isAndroid || PlatformService.instance.isIOS;

  @override
  void initState() {
    super.initState();
    final checkCookie = _login?.checkCookie;
    if (_webViewSupported && checkCookie != null && checkCookie.isNotEmpty) {
      _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
        if (!mounted || _popped || !_pageLoaded) return;
        if (await _syncWebviewCookies()) _onLoginDetected();
      });
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
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

  /// 从 WebView 的 CookieManager 取回各相关域的 Cookie 并回灌到
  /// [HttpFetcher]（内存 jar + CookieStore 落盘），返回是否命中 checkCookie。
  Future<bool> _syncWebviewCookies() async {
    final checkCookie = _login?.checkCookie;
    var detected = false;
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
        }
        if (checkCookie != null &&
            checkCookie.isNotEmpty &&
            cookies.any((c) => c.name == checkCookie)) {
          detected = true;
        }
      } catch (_) {
        // 单域取 Cookie 失败不阻断其余域。
      }
    }
    return detected;
  }

  /// 自动检测命中：提示登录成功并回传 true。
  void _onLoginDetected() {
    if (!mounted || _popped) return;
    _popped = true;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context).loginSuccess)),
    );
    Navigator.of(context).pop(true);
  }

  /// 手动兜底：「完成」按钮强制同步 Cookie 后返回 true。
  Future<void> _finishManually() async {
    if (_popped) return;
    await _syncWebviewCookies();
    if (!mounted || _popped) return;
    _popped = true;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.sourceLogin),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(false),
        ),
        actions: <Widget>[
          if (_webViewSupported)
            TextButton(
              onPressed: _finishManually,
              child: Text(l10n.loginDone),
            ),
        ],
      ),
      body: _webViewSupported ? _buildWebView() : _buildUnsupported(l10n),
    );
  }

  Widget _buildWebView() {
    return Stack(
      children: <Widget>[
        InAppWebView(
          initialUrlRequest: URLRequest(url: WebUri(_loginUrl)),
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            // UA 与 HttpFetcher 保持一致，避免 Cookie 绑 UA 导致回灌后失效。
            userAgent: HttpFetcher.instance.userAgentForUrl(_loginUrl),
          ),
          onLoadStop: (InAppWebViewController controller, WebUri? url) async {
            if (url != null) _currentPageUrl = url.toString();
            if (!_pageLoaded && mounted) {
              setState(() => _pageLoaded = true);
            }
            if (await _syncWebviewCookies()) _onLoginDetected();
          },
        ),
        if (!_pageLoaded)
          const Center(child: CircularProgressIndicator()),
      ],
    );
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
}

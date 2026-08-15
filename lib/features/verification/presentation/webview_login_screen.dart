/// 源评论登录：跳转「内置浏览器」完成登录，结束后回灌 Cookie。
///
/// 采用 [InAppBrowser]（应用内原生浏览器，带独立工具栏/地址栏/前进后退/关闭按钮），
/// 而非嵌入式 WebView 小窗。用户在浏览器内完成登录后：
/// - 自动检测：`onLoadStop` 及轮询查询 [CookieManager] 的 Cookie，
///   出现 `login.checkCookie` 键名即同步 Cookie 到 [HttpFetcher]
///   （与之前嵌入式 WebView 回灌模式一致）→ 提示「登录成功」→ 关闭浏览器。
/// - 手动兜底：点浏览器自带「关闭」按钮，[onExit] 触发末次 Cookie 回灌，
///   由调用方经 SourceAuthManager.refreshLoginState 重新评估登录态。
///
/// 桌面端（InAppBrowser 不可用）回退为提示使用「粘贴 Cookie」方式。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../core/models/plugin_config.dart';
import '../../../core/platform/platform_service.dart';
import '../../../core/scraper/http_fetcher.dart';
import '../../../core/theme/app_tokens.dart';

/// 源登录「内置浏览器」页面。返回 `true` 表示 Cookie 已同步、应重新评估登录态。
class WebViewLoginScreen extends StatefulWidget {
  final PluginConfig source;

  const WebViewLoginScreen({super.key, required this.source});

  @override
  State<WebViewLoginScreen> createState() => _WebViewLoginScreenState();
}

class _WebViewLoginScreenState extends State<WebViewLoginScreen> {
  /// 本次是否回灌到 Cookie（供返回结果）。
  bool _synced = false;

  /// 防止 open 完成回调重复 pop。
  bool _popped = false;

  CommentsLoginConfig? get _login => widget.source.comments?.login;

  String get _loginUrl => _login?.url ?? '';

  /// 是否支持内置浏览器（移动端）；桌面/Web 回退「粘贴 Cookie」提示。
  bool get _supported =>
      PlatformService.instance.isAndroid || PlatformService.instance.isIOS;

  @override
  void initState() {
    super.initState();
    if (_supported) {
      // 进入即跳转内置浏览器登录。
      WidgetsBinding.instance.addPostFrameCallback((_) => _openBrowser());
    }
  }

  Future<void> _openBrowser() async {
    final browser = _LoginBrowser(
      source: widget.source,
      onCookiesSynced: () => _synced = true,
    );
    await browser.openUrlRequest(
      urlRequest: URLRequest(url: WebUri(_loginUrl)),
    );
    // 浏览器关闭后，openUrlRequest 的 Future 完成 → 返回结果。
    if (mounted && !_popped) {
      _popped = true;
      Navigator.of(context).pop(_synced);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.sourceLogin)),
      body: _supported
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const CircularProgressIndicator(),
                  const SizedBox(height: AppTokens.spaceMd),
                  Text(
                    l10n.loading,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            )
          : _buildUnsupported(l10n),
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

/// 内置浏览器封装：登录页加载完成后同步 Cookie 到 [HttpFetcher]。
class _LoginBrowser extends InAppBrowser {
  _LoginBrowser({
    required this.source,
    required this.onCookiesSynced,
  });

  final PluginConfig source;

  /// 任一相关域回灌到 Cookie 时回调（外层据此标记 _synced）。
  final VoidCallback onCookiesSynced;

  CommentsLoginConfig? get _login => source.comments?.login;

  String get _loginUrl => _login?.url ?? '';

  /// 防轮询/多次关闭重复触发。
  bool _closing = false;

  /// 检测计时器（登录多为页内 XHR，不一定触发新的 onLoadStop）。
  Timer? _pollTimer;

  @override
  void onBrowserCreated() {
    final checkCookie = _login?.checkCookie;
    if (checkCookie != null && checkCookie.isNotEmpty) {
      _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
        final detected = await _syncCookies();
        if (detected) _closeIfNeeded();
      });
    }
  }

  @override
  void onLoadStop(WebUri? url) async {
    if (url != null) _currentPageUrl = url.toString();
    final detected = await _syncCookies();
    if (detected) _closeIfNeeded();
  }

  @override
  Future<void> onExit() async {
    _pollTimer?.cancel();
    // 浏览器关闭前再做一次兜底回灌。
    await _syncCookies();
  }

  void _closeIfNeeded() {
    if (_closing) return;
    _closing = true;
    close();
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
    add(source.site.baseUrl);
    return uris.values.toList();
  }

  /// 当前页面地址（onLoadStop 同步维护；getUrl() 是 Future 不能同步用）。
  String? _currentPageUrl;

  /// 从内置浏览器的 CookieManager 取回各相关域的 Cookie 并回灌到
  /// [HttpFetcher]（内存 jar + CookieStore 落盘），返回是否命中 checkCookie。
  Future<bool> _syncCookies() async {
    final checkCookie = _login?.checkCookie;
    var detected = false;
    var wroteAny = false;
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
          detected = true;
        }
      } catch (_) {
        // 单域取 Cookie 失败不阻断其余域。
      }
    }
    if (wroteAny) onCookiesSynced();
    return detected;
  }
}

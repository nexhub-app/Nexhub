/// 内置浏览器（InAppBrowser）完成 Bangumi OAuth 授权。
///
/// 用 [InAppBrowser]（应用内原生浏览器，带独立工具栏/地址栏/前进后退/关闭按钮）
/// 打开授权页，经 [shouldOverrideUrlLoading] 与 [onLoadStart] 截获
/// `nexhub://oauth/callback?code=...` 自定义协议回跳——避免原先「外部浏览器 +
/// 深链回调」在返回应用时深链不触发、导致 [_oauthing] 永远为 true、界面一直
/// 转圈的故障。截获到 code 即关闭浏览器并回传；用户主动点关闭则返回 null。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// 打开内置浏览器完成 Bangumi OAuth 授权，返回授权码；用户主动关闭则返回 null。
///
/// [authorizeUrl] 为完整授权页地址；[redirectScheme] 为回跳协议头
/// （如 `nexhub://oauth/callback`），命中即视为授权完成。
Future<String?> openBangumiOAuthBrowser({
  required String authorizeUrl,
  required String redirectScheme,
}) async {
  final completer = Completer<String?>();
  final browser = _BangumiOAuthBrowser(
    redirectScheme: redirectScheme,
    onCode: (code) {
      if (!completer.isCompleted) completer.complete(code);
    },
    onExitCallback: () {
      if (!completer.isCompleted) completer.complete(null);
    },
  );
  // openUrlRequest 的 Future 在浏览器关闭后完成；code / 关闭回调会先完成 completer。
  await browser.openUrlRequest(
    urlRequest: URLRequest(url: WebUri(authorizeUrl)),
  );
  // 10 分钟无操作兜底超时（理论上 onExit 必然触发，不会走到这里）。
  try {
    return await completer.future.timeout(const Duration(minutes: 10));
  } on TimeoutException {
    return null;
  }
}

/// 内置浏览器封装：截获 Bangumi OAuth 的自定义协议回跳，取出 code。
class _BangumiOAuthBrowser extends InAppBrowser {
  _BangumiOAuthBrowser({
    required this.redirectScheme,
    required this.onCode,
    required this.onExitCallback,
  });

  /// 回跳协议头（如 `nexhub://oauth/callback`），仅用于快速前缀判断。
  final String redirectScheme;

  /// 截获授权码后回调。
  final ValueChanged<String> onCode;

  /// 浏览器关闭（含用户主动关闭、取消授权）后回调。
  final VoidCallback onExitCallback;

  /// 防止重复处理（onLoadStart / shouldOverrideUrlLoading 可能多次触发）。
  bool _handled = false;

  /// 尝试从 URL 解析授权码；命中返回 true 并触发 [onCode]。
  bool _tryHandle(String? url) {
    if (url == null || _handled) return false;
    if (!url.startsWith(redirectScheme)) return false;
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    if (uri.scheme == 'nexhub' &&
        uri.host == 'oauth' &&
        uri.path == '/callback') {
      final code = uri.queryParameters['code'];
      if (code != null && code.isNotEmpty) {
        _handled = true;
        onCode(code);
        return true;
      }
    }
    return false;
  }

  @override
  Future<NavigationActionPolicy> shouldOverrideUrlLoading(
    NavigationAction navigationAction,
  ) async {
    // 截获回跳：取消该次导航（避免浏览器报「未知协议」错误）并关闭。
    if (_tryHandle(navigationAction.request.url?.toString())) {
      close();
      return NavigationActionPolicy.CANCEL;
    }
    return NavigationActionPolicy.ALLOW;
  }

  @override
  void onLoadStart(WebUri? url) {
    // shouldOverrideUrlLoading 不触发时的兜底（部分 WebView 版本对自定义协议
    // 302 重定向不回调 shouldOverrideUrlLoading）。
    if (_tryHandle(url?.toString())) {
      close();
    }
  }

  @override
  void onExit() {
    onExitCallback();
  }
}

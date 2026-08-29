/// Shared verification handler used by the online list pages.
///
/// Bridges the core [VerificationNavigator] (which cannot import features)
/// with the existing [WebViewVerificationScreen] navigation helpers. Cookie
/// sync is already performed inside the verification screen, so this callback
/// only decides whether the original request should be retried.
library;

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../../core/models/plugin_config.dart';
import '../../../core/network/runtime/webview_source_network.dart';
import '../../../core/resolver/webview_resolver.dart';
import '../../../core/scraper/verification_detector.dart';
import '../../../core/services/source_repository.dart';
import 'webview_verification_screen.dart';

/// 按 host 去重的验证单飞：同一 host 已有验证在进行时，后续请求直接 `await`
/// 同一个 Future，不再重复打开 WebView（避免 9 个 homeSections 各弹一次验证、
/// 连开多个浏览器导致高频请求 → IP 被封）。验证完成后回灌的 Cookie 对同 host
/// 后续重试同样有效。
final Map<String, Future<bool>> _inFlightVerification = {};

/// 单飞包装：同一 [url] 的 host 并发验证只开一个 WebView；其余并发请求复用其结果。
Future<bool> _singleFlight(String url, Future<bool> Function() action) {
  final host = Uri.tryParse(url)?.host ?? url;
  final existing = _inFlightVerification[host];
  if (existing != null) return existing;
  final future = action().whenComplete(() => _inFlightVerification.remove(host));
  _inFlightVerification[host] = future;
  return future;
}

/// Routes a verification exception to the proper verification screen.
///
/// - [WebViewExtractionRequest]: opens the embedded JS extraction view. When
///   an address is extracted or the user explicitly requests a retry, returns
///   `true`.
/// - [VerificationRequiredException]: opens the manual verification view.
///   Returns `true` when the user reports verification done.
/// - [WebViewRequiredException]: same as above, using the exception url.
///
/// Returns `false` when the user cancels or [error] is not a verification
/// exception handled here.
Future<bool> handleVerificationRequest(
  BuildContext context,
  Object error, {
  void Function(String extractedUrl)? onExtracted,
  void Function(String renderedHtml)? onRenderedHtml,
}) async {
  if (error is WebViewHtmlRequest) {
    // 单飞：同一 host 并发的多个路由请求（如 9 个 homeSections）只走一次
    // 抓取/验证流程，其余并发请求 await 同一结果，避免重复弹页与高频请求。
    return _singleFlight(error.url, () async {
      // 让源 WebView 跟随源网络覆盖（hosts/DoH/代理），绕开 DNS 污染。
      final source = context.read<SourceRepository>().getById(error.sourceId);
      await WebviewSourceNetwork.instance.applyForSource(source);
      if (!context.mounted) return false;
      try {
        final outcome = await navigateToHtmlCapture(context, request: error);
        if (outcome == null) return false;
        // 把渲染后的整页 HTML 回灌给调用方，用于复用源选择器解析
        // （修复「列表由 JS 动态渲染、静态抓取为空」）。
        if (outcome.hasRenderedHtml && outcome.renderedHtml != null) {
          onRenderedHtml?.call(outcome.renderedHtml!);
        }
        // 取回渲染 HTML 或用户显式「已完成验证」都触发重试：重试路径会带上
        // 回灌的 renderedHtml 用既有选择器解析。
        return outcome.shouldRetry || outcome.hasRenderedHtml;
      } finally {
        await WebviewSourceNetwork.instance.releaseForSource();
      }
    });
  }
  if (error is WebViewExtractionRequest) {
    // 让源 WebView 跟随源网络覆盖（hosts/DoH/代理），绕开 DNS 污染。
    final source = context.read<SourceRepository>().getById(error.sourceId);
    await WebviewSourceNetwork.instance.applyForSource(source);
    if (!context.mounted) return false;
    try {
      final outcome = await navigateToExtraction(context, request: error);
      if (outcome == null) return false;
      // 把抽取到的真实地址回灌给调用方，用于复用源选择器解析
      // （修复「浏览器能打开网页，但列表解析不到内容」）。
      if (outcome.hasExtractedUrl && outcome.extractedUrl != null) {
        onExtracted?.call(outcome.extractedUrl!);
      }
      // An extracted address or an explicit "done" both warrant a retry: the
      // original fetch path will pick up the synced cookies / use the new
      // session established inside the webview.
      return outcome.shouldRetry || outcome.hasExtractedUrl;
    } finally {
      await WebviewSourceNetwork.instance.releaseForSource();
    }
  }
  if (error is VerificationRequiredException) {
    // 让手动验证 WebView 也跟随源网络覆盖（hosts/DoH/代理），绕开 DNS 污染
    // （如 hanime1.me 经 Cloudflare 边缘、普通 DNS 解析不到）。否则 WebView
    // 加载不出验证页、用户永远过不了验证。exception 不带 sourceId，按 URL host
    // 反查源。
    final source = _sourceForUrl(context, error.url);
    await WebviewSourceNetwork.instance.applyForSource(source);
    try {
      return await _singleFlight(
        error.url,
        () => navigateToVerification(
          context,
          url: error.url,
          exception: error,
        ),
      );
    } finally {
      await WebviewSourceNetwork.instance.releaseForSource();
    }
  }
  if (error is WebViewRequiredException) {
    final source = _sourceForUrl(context, error.url);
    await WebviewSourceNetwork.instance.applyForSource(source);
    try {
      return await _singleFlight(
        error.url,
        () => navigateToVerification(context, url: error.url),
      );
    } finally {
      await WebviewSourceNetwork.instance.releaseForSource();
    }
  }
  return false;
}

/// 按 URL host 反查源：用于 [VerificationRequiredException]/[WebViewRequiredException]
/// （这两类异常不带 sourceId）。匹配源的 `site.domain` 或任意 `site.mirrors[].domain`。
/// 找不到返回 null，[WebviewSourceNetwork.applyForSource] 对 null 安全空转。
PluginConfig? _sourceForUrl(BuildContext context, String url) {
  final host = Uri.tryParse(url)?.host;
  if (host == null || host.isEmpty) return null;
  final repo = context.read<SourceRepository>();
  for (final s in repo.all) {
    if (s.site.domain == host) return s;
    if (s.site.mirrors.any((m) => m.domain == host)) return s;
  }
  return null;
}

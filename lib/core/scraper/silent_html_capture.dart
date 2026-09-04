/// 无界面（headless WebView）静默渲染 HTML 抓取服务。
///
/// 背景：webview-html / useWebview 源的「渲染后抽取」此前在直连抓取拿不到
/// JS 渲染内容时，一律抛 WebViewHtmlRequest 弹可见抓取页、要求用户手动点
/// 「抓取本页渲染内容」。但多数源并没有真正的 Cloudflare 挑战页，页面本身
/// 可以无交互加载完成——这类源应该静默完成「加载 → 等渲染 → 取整页 HTML」，
/// 不打断用户；只有真命中挑战页时才值得回退可见验证页。
///
/// 关键细节（对齐可见验证页 WebViewVerificationScreen 的既有行为）：
/// - 验证域 host 钉完整浏览器 UA：cf_clearance 绑定 UA+IP，headless WebView
///   与后续 HttpFetcher 重试必须同 UA，否则 Cookie 失效 → 反复弹验证；
/// - onLoadStop 后等待渲染稳定再轮询 `getHtml()`（列表/详情由 JS 异步挂载）；
/// - 抓到的 HTML 经 [VerificationDetector] 挑战特征检测：非挑战页 → 回传；
/// - 命中挑战页（cf 5 秒盾等）→ 继续轮询一小段观察窗，给非交互式挑战自动
///   通过/重定向的机会；超时仍为挑战页 → 返回 null，由调用方回退可见验证页；
/// - 成功后同步 WebView 会话 Cookie 给 HttpFetcher，后续直连重试带同一会话；
/// - 同 URL 并发抓取按单飞合并（9 个 homeSection 重复请求同一路由只抓一次）；
///   不同 URL 各自独立抓取——回灌的是页面正文，按 host 合并会让同 host 不同
///   路由（show 筛选 / search 关键词）串味。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'http_fetcher.dart';
import 'verification_detector.dart';

/// 静默渲染 HTML 抓取。
class SilentHtmlCapture {
  SilentHtmlCapture._();

  /// 同 URL 单飞表：并发请求共享同一次抓取 Future。
  static final Map<String, Future<String?>> _inFlight =
      <String, Future<String?>>{};

  /// 页面加载等待上限：onLoadStop 迟迟不触发时仍会继续轮询已渲染的 DOM
  /// （部分站点持续加载资源，onLoadStop 永不回调但 DOM 已就绪）。
  static const Duration _loadTimeout = Duration(seconds: 15);

  /// onLoadStop 后的渲染稳定等待：JS 框架通常在加载完成后异步挂载列表/详情。
  static const Duration _renderSettle = Duration(milliseconds: 1500);

  /// 挑战页自动通过观察窗：cf 非交互式挑战通常 3–8s 内放行并重定向。
  static const Duration _challengeWait = Duration(seconds: 10);

  static const Duration _pollInterval = Duration(milliseconds: 1000);

  /// 视为「真实渲染内容」的最小 HTML 长度。headless WebView 在以下情况会拿到
  /// 极小/空 HTML（约 39 字节 ≈ `<html><head></head><body></body></html>`）：
  /// 未导航成功（about:blank）、Cloudflare 在无 `cf_clearance` Cookie 时直接
  /// 拒绝加载、或页面尚未挂载。这类 HTML 不含任何卡片，若当作成功回传 → 解析
  /// 0 条且**不触发可见验证页** → 用户只见空列表。故低于此阈值一律视为抓取
  /// 失败，回传 null 让 [WebViewResolver] 回退可见验证页（用户验证一次后
  /// `cf_clearance` 落盘，后续静默抓取即正常）。
  static const int _minHtmlBytes = 1024;

  /// 统计 [marker] 在 [html] 中的出现次数（诊断用：确认真实渲染 HTML 是否含
  /// 目标卡片/链接结构，避免「抓到了但解析 0 条」时只能盲猜 DOM）。
  static int _count(String html, String marker) =>
      html.split(marker).length - 1;

  /// 针对 hanime1.me 搜索/分类页的扩展探针：线上站点搜索结果容器已不再是
  /// 首页用的 `.horizontal-card`，需通过子串计数定位真实结果容器名。
  /// 仅在 host 为 hanime1.me 且路径含 /search 时调用，避免污染其它源日志。
  static String _hanimeSearchProbe(String html, String url) {
    final uri = Uri.tryParse(url);
    if (uri?.host != 'hanime1.me' || !(uri?.path.contains('/search') ?? false)) {
      return '';
    }
    final markers = <String, String>{
      'content-padding-new': 'content-padding-new',
      'content-padding': 'content-padding',
      'video-item-container': 'video-item-container',
      'main-thumb': 'main-thumb',
      'video-link': 'video-link',
      'thumbnail/': 'thumbnail/',
      'single-video-tag': 'single-video-tag',
      'home-rows-videos-wrapper': 'home-rows-videos-wrapper',
      'genre=': 'genre=',
    };
    final parts = markers.entries
        .map((e) => '${e.key}=${_count(html, e.value)}')
        .join(' ');
    return ' [hanime-search-probe $parts]';
  }

  /// 静默抓取 [url] 渲染后的整页 HTML。
  ///
  /// 返回 null 表示不应静默处理（命中挑战页 / 加载失败 / WebView 不可用），
  /// 由调用方回退可见验证页。同 URL 并发调用共享同一次抓取结果。
  ///
  /// [userAgent]：可选钉定 UA。默认用完整桌面浏览器 UA；源声明
  /// `webviewConfig.extraUserAgent`（如移动 Chrome UA）时由调用方传入，
  /// 供「仅移动端可见」的页面按移动浏览器渲染。
  ///
  /// [scrollToLoad]：渲染稳定后逐屏滚动到页底再抓取。用于懒加载站点——
  /// 部分页面（如漫画阅读页）的图片由站点 JS 在滚动进视口时才注入 DOM，
  /// 无头 WebView 不滚动 → HTML 里完全没有图片 URL。开启后滚动触发注入，
  /// 滚动到底且页面高度/图片数连续稳定后返回。由源的 meta `__webviewScroll`
  /// 显式开启，不影响未声明的源。
  static Future<String?> capture(
    String url, {
    Map<String, String>? headers,
    String? userAgent,
    bool scrollToLoad = false,
  }) {
    final existing = _inFlight[url];
    if (existing != null) return existing;
    final future = _run(url, headers, userAgent, scrollToLoad)
        .whenComplete(() {
      _inFlight.remove(url);
      debugPrint('[SilentHtmlCapture] capture whenComplete 完成 url=$url');
    });
    _inFlight[url] = future;
    return future;
  }

  static Future<String?> _run(
    String url,
    Map<String, String>? headers,
    String? userAgent,
    bool scrollToLoad,
  ) async {
    // 剥离源声明里可能存在的极简 UA 请求头（如 `Mozilla/5.0`）：统一交给
    // initialSettings 的完整浏览器 UA 接管，避免请求头覆盖设置值后 CF 以
    // 「非合法浏览器」拒绝（600010）。
    final effectiveHeaders = <String, String>{
      for (final e in (headers ?? const <String, String>{}).entries)
        if (e.key.toLowerCase() != 'user-agent') e.key: e.value,
    };

    // 钉浏览器 UA（对齐可见验证页 initState 的 _applyFullBrowserUa）：
    // 默认路径钉完整桌面 UA 并注册到 host（userAgentForUrl 优先取用，
    // 后续直连请求同 UA，保证下发的 cf_clearance 与请求 UA 一致）。
    // 调用方显式传入 [userAgent]（如源声明的移动 Chrome UA）时**只作用于
    // 本次 WebView**（initialSettings 直设），不注册到 host——否则会把该站
    // 后续所有直连请求的 UA 拉成移动 UA，可能让站点切换页面模板、破坏既有
    // 解析（桌面/移动模板 DOM 不同）。
    String? effectiveUa;
    try {
      final host = Uri.tryParse(url)?.host;
      if (host != null && host.isNotEmpty) {
        if (userAgent != null && userAgent.isNotEmpty) {
          effectiveUa = userAgent;
        } else {
          final fullUa = HttpFetcher.instance.fullBrowserUserAgent();
          HttpFetcher.instance.registerHostUserAgent(host, fullUa);
          effectiveUa = fullUa;
        }
      }
    } on Object {
      // UA 覆盖失败不影响主流程。
    }

    HeadlessInAppWebView? webview;
    final created = Completer<InAppWebViewController>();
    final pageLoaded = Completer<void>();
    try {
      webview = HeadlessInAppWebView(
        initialUrlRequest: URLRequest(
          url: WebUri(url),
          headers: effectiveHeaders.isEmpty ? null : effectiveHeaders,
        ),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          // 与可见验证页一致：完整浏览器 UA，保证已下发的 cf_clearance 有效。
          // 调用方传入自定义 UA（源声明移动 UA）时以其为准。
          userAgent: effectiveUa ?? HttpFetcher.instance.userAgentForUrl(url),
        ),
        onWebViewCreated: (controller) {
          if (!created.isCompleted) created.complete(controller);
        },
        onLoadStop: (controller, uri) {
          if (!pageLoaded.isCompleted) pageLoaded.complete();
        },
      );
      await webview.run();
      await pageLoaded.future.timeout(_loadTimeout, onTimeout: () {});
      // 渲染稳定等待：列表/详情通常在 onLoadStop 之后由 JS 异步挂载。
      await Future<void>.delayed(_renderSettle);

      final controller = await created.future;
      // 懒加载触发：逐屏滚动注入视口外资源（图片等），到底且稳定后再抓取。
      if (scrollToLoad) {
        await _scrollToLoad(controller);
      }
      final deadline = DateTime.now().add(_challengeWait);
      // 多数站点列表/详情由 JS 异步挂载：若首次轮询即回传「未命中挑战但卡片
      // 尚未渲染」的壳，解析侧会拿到 0 条 → 用户只见空白/一直转圈。故改为
      // 在挑战观察窗内持续轮询，保留「最长的非挑战 HTML」（≈ JS 挂载完成后的
      // 完整正文），并在相邻两次轮询长度稳定（变化 ≤ 256B）时提前回传，
      // 兼顾「抓到完整内容」与「不过度等待」。
      String? bestHtml;
      int? prevLen;
      while (true) {
        final html = await _safeGetHtml(controller);
        if (html != null &&
            html.isNotEmpty &&
            html.length >= _minHtmlBytes &&
            !VerificationDetector.isVerificationRequired(
              statusCode: 200,
              body: html,
            )) {
          if (bestHtml == null || html.length > bestHtml.length) {
            bestHtml = html;
          }
          // 内容已稳定 → 视为渲染完成，提前返回最完整的一份。
          if (prevLen != null && (html.length - prevLen).abs() <= 256) {
            await _syncCookies(url);
            debugPrint(
              '[SilentHtmlCapture] 静默渲染抓取成功(已稳定) host='
              '${Uri.tryParse(url)?.host} htmlLen=${html.length}',
            );
            debugPrint(
              '[SilentHtmlCapture] 诊断 host=${Uri.tryParse(url)?.host} '
              'horizontal-card=${_count(html, 'horizontal-card')} '
              'playlist-hover-wrap=${_count(html, 'playlist-hover-wrap')} '
              'watch=${_count(html, 'watch?v=')}'
              '${_hanimeSearchProbe(html, url)}',
            );
            return html;
          }
          prevLen = html.length;
        }
        if (!DateTime.now().isBefore(deadline)) break;
        await Future<void>.delayed(_pollInterval);
      }
      if (bestHtml != null && bestHtml.length >= _minHtmlBytes) {
        // 观察窗结束仍未稳定，但已拿到非挑战正文：回传最长一份（最完整）。
        await _syncCookies(url);
        debugPrint(
          '[SilentHtmlCapture] 静默渲染抓取成功 host='
          '${Uri.tryParse(url)?.host} htmlLen=${bestHtml.length}',
        );
        debugPrint(
          '[SilentHtmlCapture] 诊断 host=${Uri.tryParse(url)?.host} '
          'horizontal-card=${_count(bestHtml, 'horizontal-card')} '
          'playlist-hover-wrap=${_count(bestHtml, 'playlist-hover-wrap')} '
          'watch=${_count(bestHtml, 'watch?v=')}'
          '${_hanimeSearchProbe(bestHtml, url)}',
        );
        return bestHtml;
      }
      debugPrint(
        '[SilentHtmlCapture] 抓取内容过小/空(about:blank?)，回退可见验证 '
        'host=${Uri.tryParse(url)?.host} htmlLen=${bestHtml?.length ?? 0}',
      );
      debugPrint(
        '[SilentHtmlCapture] 命中挑战页/空内容，回退可见验证 url=$url',
      );
      return null;
    } on Object catch (e) {
      debugPrint('[SilentHtmlCapture] 静默抓取失败 url=$url: $e');
      return null;
    } finally {
      // 关键修复：headless WebView 在 Windows 等平台 `dispose()` 原生侧已
      // 完成 dealloc（日志可见 dealloc 行），但 Dart Future 不回调；若在此
      // await，_run 永久挂起 → capture 返回的 Future 永不完成 → 调用方
      // (WebViewResolver.resolve) 卡在 await capture → 列表一直转圈。
      // 故不 await，改为带超时的 best-effort 释放，确保 _run 立即返回抓取到的 HTML。
      final w = webview;
      if (w != null) {
        try {
          w
              .dispose()
              .timeout(const Duration(seconds: 3))
              .catchError((Object _) {});
        } on Object {
          // 忽略 dispose 同步异常，不阻塞抓取结果返回。
        }
      }
    }
  }

  static Future<String?> _safeGetHtml(InAppWebViewController controller) async {
    try {
      return await controller.getHtml();
    } on Object {
      return null;
    }
  }

  /// 懒加载滚动：单步 0.8 屏、每步 350ms；到底且「页面高度 + 已加载图片数」
  /// 连续 2 轮不变即提前结束。上限 60 步（≈48 屏），防无限滚动页拖死。
  static const int _scrollMaxSteps = 60;
  static const Duration _scrollStepDelay = Duration(milliseconds: 350);

  /// 逐屏滚动触发懒加载注入（best-effort：JS 执行失败直接跳过，不影响主流程）。
  static Future<void> _scrollToLoad(InAppWebViewController controller) async {
    int? prevHeight;
    int? prevLoaded;
    var stableRounds = 0;
    const probe = '''
(function() {
  window.scrollBy(0, Math.round(window.innerHeight * 0.8));
  var imgs = document.images;
  var loaded = 0;
  for (var k = 0; k < imgs.length; k++) {
    var s = imgs[k].currentSrc || imgs[k].src || '';
    if (s.indexOf('http') === 0) loaded++;
  }
  return JSON.stringify({
    h: document.body ? document.body.scrollHeight : 0,
    loaded: loaded,
    y: window.scrollY
  });
})()
''';
    try {
      for (var i = 0; i < _scrollMaxSteps; i++) {
        final raw = await _evalJs(controller, probe);
        Map<String, dynamic>? m;
        if (raw is String && raw.isNotEmpty) {
          try {
            m = (jsonDecode(raw) as Map).cast<String, dynamic>();
          } on Object {
            m = null;
          }
        }
        final h = (m?['h'] as num?)?.toInt() ?? 0;
        final loaded = (m?['loaded'] as num?)?.toInt() ?? 0;
        final y = (m?['y'] as num?)?.toInt() ?? 0;
        final atBottom = y > 0 && h > 0 && (h - y) < 1200;
        final stable = prevHeight == h && prevLoaded == loaded;
        if (atBottom && stable) {
          stableRounds++;
          if (stableRounds >= 2) break;
        } else {
          stableRounds = 0;
        }
        prevHeight = h;
        prevLoaded = loaded;
        await Future<void>.delayed(_scrollStepDelay);
      }
      // 注入完成后留一小段余量，等最后一批图片请求发出/挂载。
      await Future<void>.delayed(const Duration(milliseconds: 800));
      debugPrint(
          '[SilentHtmlCapture] 懒加载滚动完成 steps<=${_scrollMaxSteps}');
    } on Object catch (e) {
      debugPrint('[SilentHtmlCapture] 懒加载滚动失败(忽略): $e');
    }
  }

  static Future<Object?> _evalJs(
    InAppWebViewController controller,
    String source,
  ) async {
    try {
      return await controller.evaluateJavascript(source: source);
    } on Object {
      return null;
    }
  }

  /// 同步 WebView 会话 Cookie 到 HttpFetcher（对齐可见验证页
  /// `_syncWebviewCookies`，best-effort：失败不影响抓取结果）。
  static Future<void> _syncCookies(String url) async {
    try {
      final uri = Uri.tryParse(url);
      if (uri == null) return;
      final cookies = await CookieManager.instance().getCookies(
        url: WebUri('${uri.scheme}://${uri.host}'),
      );
      final cookieHeader = cookies
          .where((c) => c.value.isNotEmpty)
          .map((c) => '${c.name}=${c.value}')
          .join('; ');
      if (cookieHeader.isNotEmpty) {
        HttpFetcher.instance.syncCookies(uri.host, cookieHeader);
      }
    } on Object {
      // Cookie 读取失败不影响主流程。
    }
  }
}

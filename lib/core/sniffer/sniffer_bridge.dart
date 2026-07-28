/// 嗅探桥接层：把 [InAppWebViewController] 接入 [SnifferEngine]。
///
/// - 注入 JS 钩子（由 [userScript] 生成，在文档起始处运行）；
/// - 注册 `sniffer` JS handler 接收钩子回传；
/// - [onResource] 作为 `onLoadResource` 被动兜底（宽网捕获）；
/// - [deepScan] 在加载完成后扫描 DOM 中的 `<video>`/`<source>`。
library;

import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:nexhub/core/sniffer/sniffer_engine.dart' show SnifferEngine;

/// 嗅探桥接器（与单个 WebView 生命周期绑定）。
///
/// 默认使用 [SnifferEngine.shared]（进程级共享实例），使嗅探页与源视频路由
/// WebView 捕获的结果互相累积；也可传入独立 [engine] 隔离。
class SnifferBridge {
  final SnifferEngine engine;

  InAppWebViewController? _controller;
  bool _deep = true;

  SnifferBridge([SnifferEngine? engine]) : engine = engine ?? SnifferEngine.shared;

  /// 是否启用深度嗅探（DOM 扫描）。
  bool get deep => _deep;

  set deep(bool v) => _deep = v;

  /// 构造文档起始注入的钩子脚本。
  ///
  /// `forMainFrameOnly: false` 是关键：插件默认 true（只注入主框架），而
  /// 播放器几乎都在 iframe 内请求 m3u8——不进 iframe 就等于嗅探不到。
  static UserScript userScript(String source) => UserScript(
        source: source,
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        forMainFrameOnly: false,
      );

  /// 在 WebView 创建时调用：注册 JS handler。
  void attach(InAppWebViewController controller) {
    _controller = controller;
    controller.addJavaScriptHandler(
      handlerName: 'sniffer',
      callback: (args) {
        final url = (args.isNotEmpty && args[0] is String)
            ? args[0] as String
            : null;
        if (url == null) return;
        final kind = args.length > 1 && args[1] is String
            ? args[1] as String
            : null;
        final ref = args.length > 2 && args[2] is String
            ? args[2] as String
            : null;
        final mime = args.length > 3 && args[3] is String
            ? args[3] as String
            : null;
        unawaited(engine.add(url, kind: kind, referer: ref, mime: mime));
      },
    );
  }

  /// `onLoadResource` 被动捕获（兜底，扩大召回面）。
  ///
  /// 注意：插件 v6 的 LoadedResource 只有 url/duration/initiatorType/startTime，
  /// 不含响应对象；MIME 由 JS 钩子在响应阶段读取 Content-Type 后经 handler 回传。
  void onResource(String? url, {String? mime}) {
    if (url == null || url.isEmpty) return;
    unawaited(engine.add(url, kind: 'resource', mime: mime));
  }

  /// 网络层请求拦截（`shouldInterceptRequest`，Android）捕获：可在 JS 钩子就绪前
  /// 抓到请求，并顺带记录 Referer（猫爪 onSendHeaders 的等价物）。返回 null 表示
  /// 不拦截、照常放行。
  void onRequest(String? url, String? referer) {
    if (url == null || url.isEmpty) return;
    unawaited(engine.add(url, kind: 'request', referer: referer));
  }

  /// 加载完成后执行 DOM 扫描（深度嗅探）。
  Future<void> deepScan() async {
    if (!_deep) return;
    try {
      await _controller
          ?.evaluateJavascript(source: 'window.__sniffDeepScan && window.__sniffDeepScan();');
    } catch (_) {
      // best-effort
    }
  }

  /// 主动重新扫描当前页 DOM。
  Future<void> rescan() => deepScan();
}

/// 让源自带的 WebView（flutter_inappwebview）也跟随源的「网络覆盖」配置。
///
/// 背景：WebView 走系统 WebView 网络栈，默认不读源的 `network` 块
/// （hosts / DoH / 手动代理）。而引擎自带 HttpClient 已通过
/// [DnsResolver] 按源 profile 解析（见 [NetworkClientBuilder]）。本文件补齐
/// WebView 一侧：起一个本地正向代理，把命中源域名的 WebView 流量经
/// [DnsResolver] 解析（hosts 优先、回退 DoH、再回退系统），从而绕开 DNS 污染。
///
/// 接线：Android 侧经 `ProxyController.setProxyOverride` + PAC 把源域名导到本地
/// 代理（API 28+）。本文件只做配置驱动的逻辑，不写死任何站点。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../models/plugin_config.dart';
import '../model/effective_network_profile.dart';
import '../model/network_config.dart';
import 'dns_resolver.dart';
import '../network_config_service.dart';

/// 源 WebView 网络跟随桥（进程内单例）。
///
/// 用法：打开源 WebView 前调用 [applyForSource]，关闭后调用 [releaseForSource]。
/// 多次 apply 以引用计数共享同一本地代理与 ProxyController 覆盖。
class WebviewSourceNetwork {
  WebviewSourceNetwork._();
  static final WebviewSourceNetwork instance = WebviewSourceNetwork._();

  static const MethodChannel _channel =
      MethodChannel('nexhub/webview_proxy');

  HttpServer? _server;
  int _port = 0;
  int _refCount = 0;

  // 当前生效的源 DNS 配置（供本地代理解析使用）。
  DnsConfig? _dns;
  List<HostsEntry>? _hosts;
  String? _pacContent;

  /// 打开源 WebView 前调用：若该源声明了 hosts/DoH/手动代理，则让 WebView 跟随。
  ///
  /// [source] 为 null 时直接返回（无网络覆盖可应用）。
  Future<void> applyForSource(PluginConfig? source) async {
    if (source == null) return;
    try {
      final profile = NetworkConfigService.instance.effectiveFor(source);
    final hasCustomDns =
        profile.hosts.isNotEmpty || profile.needsCustomConnection;
    final manualProxy = profile.proxy.mode == ProxyMode.manual &&
        profile.proxy.host.isNotEmpty &&
        profile.proxy.port > 0;
    if (!hasCustomDns && !manualProxy) return;

    // 手动代理模式：直接让 ProxyController 走该代理，无需本地代理。
    if (!hasCustomDns && manualProxy) {
      final proxyUrl = profile.proxy.protocol == ProxyProtocol.socks5
          ? 'SOCKS ${profile.proxy.host}:${profile.proxy.port}'
          : 'PROXY ${profile.proxy.host}:${profile.proxy.port}';
      final ok = await _setProxy(proxyUrl: proxyUrl);
      if (ok) _refCount++;
      return;
    }

    // hosts / DoH 模式：起本地代理 + PAC 把源域名导到本地代理。
    await _ensureStarted();
    _dns = profile.dns;
    _hosts = profile.hosts;

    final hostnames = <String>{};
    for (final h in profile.hosts) {
      if (h.enabled && h.host.isNotEmpty) hostnames.add(h.host.toLowerCase());
    }
    final site = source.site;
    if (site.domain.isNotEmpty) hostnames.add(site.domain.toLowerCase());
    for (final m in site.mirrors) {
      if (m.domain.isNotEmpty) hostnames.add(m.domain.toLowerCase());
    }
    _pacContent = _buildPac(hostnames, _port);

    final ok = await _setProxy(
      pacUrl: 'pac+http://127.0.0.1:$_port/proxy.pac',
    );
    if (ok) _refCount++;
    } on Object catch (e) {
      // 网络跟随是 best-effort：任何失败都不应阻断验证 WebView 打开。
      debugPrint('WebviewSourceNetwork.applyForSource failed: $e');
    }
  }

  /// 关闭源 WebView 后调用：引用归零时清除 ProxyController 覆盖并停代理。
  Future<void> releaseForSource() async {
    if (_refCount <= 0) return;
    _refCount--;
    if (_refCount > 0) return;
    try {
      await _clearProxy();
      await _stop();
    } on Object catch (e) {
      debugPrint('WebviewSourceNetwork.releaseForSource failed: $e');
    }
    _dns = null;
    _hosts = null;
    _pacContent = null;
  }

  // ---- 本地正向代理 ----

  Future<void> _ensureStarted() async {
    if (_server != null) return;
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _port = _server!.port;
    _server!.listen(_onRequest);
  }

  Future<void> _stop() async {
    await _server?.close(force: true);
    _server = null;
    _port = 0;
  }

  Future<void> _onRequest(HttpRequest request) async {
    // 提供 PAC 脚本（ProxyController 经 http 拉取）。
    if (request.method == 'GET' &&
        request.uri.path == '/proxy.pac' &&
        _pacContent != null) {
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType('application', 'x-ns-proxy-autoconfig')
        ..write(_pacContent!);
      await request.response.close();
      return;
    }

    if (request.method == 'CONNECT') {
      await _tunnel(request, 443);
    } else {
      await _forward(request);
    }
  }

  /// HTTPS 隧道：CONNECT host:port → 解析 IP → 直连 → 双向透传。
  Future<void> _tunnel(HttpRequest request, int defaultPort) async {
    // dart:io 对 CONNECT 的 uri 解析在不同版本可能落在 authority 或 host/port，
    // 这里两者都兼容。
    final uri = request.uri;
    final authority = uri.authority;
    final host = uri.host.isNotEmpty
        ? uri.host
        : (authority.contains(':')
            ? authority.substring(0, authority.lastIndexOf(':'))
            : authority);
    final port = uri.port != 0
        ? uri.port
        : (authority.contains(':')
            ? int.tryParse(authority.substring(authority.lastIndexOf(':') + 1)) ??
                defaultPort
            : defaultPort);
    try {
      final ip = await _resolveIp(host);
      final targetSocket = await Socket.connect(ip, port);
      // 直接 detach：detachSocket(writeHeaders:true) 会把已设的 200 状态行写给
      // 客户端。注意不能先 close() 再 detach —— 那样会抛 StateError（dart:io 已
      // 接管 socket），导致 HTTPS 隧道建立失败。
      request.response.statusCode = 200;
      request.response.reasonPhrase = 'Connection Established';
      request.response.headers.clear();
      final clientSocket = await request.response.detachSocket();
      _pipe(clientSocket, targetSocket);
    } on Object catch (e) {
      debugPrint('WebviewProxy tunnel($host:$port) failed: $e');
      try {
        request.response.statusCode = 502;
        await request.response.close();
      } on Object {
        // 已 detached 或关闭，忽略。
      }
    }
  }

  /// 明文 HTTP 代理：重写请求行到解析后的 IP，双向透传原始字节。
  Future<void> _forward(HttpRequest request) async {
    final uri = request.uri;
    final host = uri.host;
    final port = uri.port == 0 ? 80 : uri.port;
    try {
      final ip = await _resolveIp(host);
      final targetSocket = await Socket.connect(ip, port);
      // 重写请求行为绝对路径（去掉 scheme+host），Host 头保留原域名（SNI 等价）。
      final path = uri.path.isEmpty ? '/' : uri.path;
      final raw = StringBuffer()
        ..write('${request.method} $path${uri.query.isNotEmpty ? '?${uri.query}' : ''} ${request.protocolVersion}\r\n');
      request.headers.forEach((name, values) {
        for (final v in values) raw.writeln('$name: $v');
      });
      raw.writeln();
      targetSocket.add(utf8.encode(raw.toString()));
      final clientSocket = await request.response.detachSocket(writeHeaders: false);
      _pipe(clientSocket, targetSocket);
    } on Object catch (e) {
      debugPrint('WebviewProxy forward($host:$port) failed: $e');
      try {
        request.response.statusCode = 502;
        await request.response.close();
      } on Object {
        // 忽略。
      }
    }
  }

  Future<InternetAddress> _resolveIp(String host) async {
    final addresses = await DnsResolver.instance.resolve(
      host,
      _dns ?? DnsConfig(),
      _hosts ?? <HostsEntry>[],
    );
    if (addresses.isEmpty) {
      throw StateError('no address for $host');
    }
    // 优先 IPv4（Cloudflare anycast 多为 IPv4）。
    return addresses.firstWhere(
      (a) => a.type == InternetAddressType.IPv4,
      orElse: () => addresses.first,
    );
  }

  void _pipe(Socket a, Socket b) {
    a.listen(
      (d) => b.add(d),
      onDone: () {
        try {
          b.close();
        } on Object {
          // 忽略。
        }
      },
      onError: (_) {
        try {
          b.close();
        } on Object {
          // 忽略。
        }
      },
      cancelOnError: true,
    );
    b.listen(
      (d) => a.add(d),
      onDone: () {
        try {
          a.close();
        } on Object {
          // 忽略。
        }
      },
      onError: (_) {
        try {
          a.close();
        } on Object {
          // 忽略。
        }
      },
      cancelOnError: true,
    );
  }

  // ---- PAC 生成 ----

  String _buildPac(Set<String> hostnames, int port) {
    final rules = hostnames.map((h) {
      return "  if (host == '$h' || shExpMatch(host, '*.$h')) "
          "return 'PROXY 127.0.0.1:$port';";
    }).join('\n');
    return 'function FindProxyForURL(url, host) {\n'
        '$rules\n'
        "  return 'DIRECT';\n"
        '}\n';
  }

  // ---- 平台通道（Android ProxyController）----

  Future<bool> _setProxy({String? pacUrl, String? proxyUrl}) async {
    try {
      final r = await _channel.invokeMethod<bool>('setProxyOverride', <String, dynamic>{
        if (pacUrl != null) 'pacUrl': pacUrl,
        if (proxyUrl != null) 'proxyUrl': proxyUrl,
      });
      return r == true;
    } on Object catch (e) {
      // 非 Android（如 Windows / 桌面）未注册 nexhub/webview_proxy handler，
      // invokeMethod 抛 MissingPluginException——必须兜底，否则异常会冲出
      // applyForSource 阻断验证界面打开。网络跟随是 best-effort，失败即回落。
      debugPrint('WebviewProxy setProxyOverride failed: $e');
      return false;
    }
  }

  Future<void> _clearProxy() async {
    try {
      await _channel.invokeMethod<void>('clearProxyOverride');
    } on Object catch (e) {
      debugPrint('WebviewProxy clearProxyOverride failed: $e');
    }
  }
}

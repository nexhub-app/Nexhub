/// 网络客户端构建器：把「有效档案 → 配置好的 HttpClient」的映射集中到一处。
///
/// 同时被全局 [NexHubHttpOverrides] 与 [HttpFetcher] 的多档案 Dio 复用，
/// 消除代理三模式 / connectionFactory / badCertificateCallback 的重复。
library;

import 'dart:io';

import '../model/effective_network_profile.dart';
import '../model/network_config.dart';
import 'dns_resolver.dart';

/// 从 [EffectiveNetworkProfile] 构建 [HttpClient] 的单一入口。
class NetworkClientBuilder {
  const NetworkClientBuilder._();

  /// 构建配置好的 [HttpClient]。
  ///
  /// [proxyPassword] 为手动代理的密码（不入档案/JSON，由调用方从安全存储取），
  /// 仅在 manual 模式且有用户名时用于 `addProxyCredentials`。
  static HttpClient buildHttpClient(
    EffectiveNetworkProfile profile, {
    SecurityContext? ctx,
    String? proxyPassword,
  }) {
    final client = _rawHttpClient(ctx);
    // 保留原 HttpFetcher 的自签容忍（部分源使用非标准 SSL 配置）。
    client.badCertificateCallback = (cert, host, port) => true;

    _applyProxy(client, profile.proxy, proxyPassword);

    if (profile.needsCustomConnection) {
      _applyCustomConnection(client, profile);
    }

    return client;
  }

  /// 创建一个「绕过全局 [HttpOverrides]」的裸 [HttpClient]。
  ///
  /// 关键：本构建器同时是 [NexHubHttpOverrides] 的委托目标。若这里直接用
  /// `HttpClient()` 工厂，会再次命中 `HttpOverrides.global` → 回到本方法 →
  /// 无限递归 → `StackOverflowError`，导致全应用所有请求失败。故在无覆盖的
  /// zone 内创建真实客户端，彻底断开自引用。
  static HttpClient _rawHttpClient(SecurityContext? ctx) {
    return HttpOverrides.runWithHttpOverrides<HttpClient>(
      () => HttpClient(context: ctx),
      _RawHttpOverrides(),
    );
  }

  static void _applyProxy(
    HttpClient client,
    ProxyConfig proxy,
    String? proxyPassword,
  ) {
    switch (proxy.mode) {
      case ProxyMode.direct:
        client.findProxy = (_) => 'DIRECT';
        break;
      case ProxyMode.system:
        // 桌面基于环境变量（尽力而为），非读取 OS GUI 代理。
        client.findProxy = (uri) => HttpClient.findProxyFromEnvironment(uri);
        break;
      case ProxyMode.manual:
        if (proxy.host.isNotEmpty && proxy.port > 0) {
          final scheme =
              proxy.protocol == ProxyProtocol.socks5 ? 'SOCKS' : 'PROXY';
          client.findProxy = (_) => '$scheme ${proxy.host}:${proxy.port}';
          if (proxy.username.isNotEmpty &&
              proxy.protocol == ProxyProtocol.http) {
            client.addProxyCredentials(
              proxy.host,
              proxy.port,
              '',
              HttpClientBasicCredentials(
                proxy.username,
                proxyPassword ?? '',
              ),
            );
          }
        } else {
          client.findProxy = (_) => 'DIRECT';
        }
        break;
    }
  }

  static void _applyCustomConnection(
    HttpClient client,
    EffectiveNetworkProfile profile,
  ) {
    client.connectionFactory = (Uri uri, String? proxyHost, int? proxyPort) {
      // 有代理时 connectionFactory 收到的是代理主机；否则为目标主机。
      final targetHost = proxyHost ?? uri.host;
      final targetPort =
          proxyPort ?? (uri.scheme == 'https' ? 443 : 80);
      return DnsResolver.instance
          .resolve(targetHost, profile.dns, profile.hosts)
          .then((addresses) {
        if (addresses.isEmpty) {
          return Socket.startConnect(targetHost, targetPort);
        }
        // SNI 自定义值受平台限制（域前置无法经标准路径生效），此处仅完成
        // DNS/Hosts 定向连接；TLS SNI 由 HttpClient 用 url.host 决定。
        return Socket.startConnect(addresses.first, targetPort);
      });
    };
  }
}

/// 空覆盖：`createHttpClient` 沿用基类实现（直接创建真实客户端），
/// 供 [NetworkClientBuilder._rawHttpClient] 在 zone 内临时替换全局覆盖，避免递归。
class _RawHttpOverrides extends HttpOverrides {}

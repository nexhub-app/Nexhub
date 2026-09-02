/// 网络客户端构建器：把「有效档案 → 配置好的 HttpClient」的映射集中到一处。
///
/// 同时被全局 [NexHubHttpOverrides] 与 [HttpFetcher] 的多档案 Dio 复用，
/// 消除代理三模式 / connectionFactory / badCertificateCallback 的重复。
library;

import 'dart:async';
import 'dart:io';

import '../model/effective_network_profile.dart';
import '../model/network_config.dart';
import 'dns_resolver.dart';
import 'sni_policy.dart';

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
      _applyCustomConnection(client, profile, ctx: ctx);
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

  /// 自定义连接工厂：DNS/Hosts 定向 + 直连 HTTPS 的 TLS 接管。
  ///
  /// 关键契约（见 SDK `_ConnectionTarget.connect`）：connectionFactory 返回的
  /// socket 会被 HttpClient 原样使用——**https 直连时客户端不会再补做 TLS**，
  /// 工厂必须自行完成握手并返回已加密的 [SecureSocket]（此前返回裸 socket 会
  /// 把明文 HTTP 打到 443 端口）。
  ///
  /// TLS 在裸 socket 上以 [SniPolicy] 解析出的名字完成：
  /// - 不覆盖：SNI = 请求域名（与默认路径一致）；
  /// - 自定义：SNI = 配置域名（证书失配由 onBadCertificate 容忍）；
  /// - `-` 免 SNI：host 传 IP 字面量，引擎不发送 server_name 扩展。
  ///
  /// 走外部代理（proxyHost != null）时由 HttpClient 自己做 CONNECT 隧道 + TLS
  /// （SNI=目标域名），本工厂只负责把 TCP 连到（可能被 hosts/DNS 覆盖的）代理
  /// 地址，SNI 覆盖在该路径不可用。
  static void _applyCustomConnection(
    HttpClient client,
    EffectiveNetworkProfile profile, {
    SecurityContext? ctx,
  }) {
    client.connectionFactory = (Uri uri, String? proxyHost, int? proxyPort) {
      // 有代理时 connectionFactory 收到的是代理主机；否则为目标主机。
      final targetHost = proxyHost ?? uri.host;
      // uri.port 在未显式给端口时为 0，须按 scheme 回落默认端口；
      // 显式端口必须原样保留（否则带端口的源地址会连到 443/80 上）。
      final defaultPort = uri.scheme == 'https' ? 443 : 80;
      final targetPort =
          proxyPort ?? (uri.port != 0 ? uri.port : defaultPort);
      final tlsDirect = proxyHost == null && uri.scheme == 'https';
      final sniOverride =
          tlsDirect ? SniPolicy.resolve(profile.sni, uri.host) : null;

      // DNS/Hosts 定向 TCP：解析结果为空时回退原域名交给系统解析。
      Future<ConnectionTask<Socket>> tcpTask() => DnsResolver.instance
          .resolve(targetHost, profile.dns, profile.hosts)
          .then((addresses) => addresses.isEmpty
              ? Socket.startConnect(targetHost, targetPort)
              : _connectFirstReachable(targetHost, targetPort, addresses));

      if (!tlsDirect) return tcpTask();

      // https 直连：工厂必须交回已握手的 SecureSocket（见方法注释的契约）。
      return tcpTask().then((raw) {
        final Future<Socket> secured = raw.socket.then<Socket>((socket) {
          // Dart 的 SecureSocket.secure(host:) 同时决定 SNI 与证书校验名；
          // host 传 IP 字面量时引擎不发送 SNI 扩展（免 SNI 模式的实现基础）。
          final tlsName = switch (sniOverride) {
            null => uri.host,
            '' => socket.remoteAddress.host,
            _ => sniOverride,
          };
          return SecureSocket.secure(
            socket,
            host: tlsName,
            context: ctx,
            // 与 client.badCertificateCallback=true 对齐：容忍自签，以及
            // 自定义 SNI 与证书名的必然失配。
            onBadCertificate: (_) => true,
          );
        });
        return ConnectionTask.fromSocket(secured, raw.cancel);
      });
    };
  }

  /// 从解析结果中逐个尝试连接，直到成功；全部失败则回退系统解析原域名直连。
  ///
  /// 修复「浏览器能开、应用超时」：DNS 常返回多个 IP（CDN / 多线机房），
  /// 其中部分地址不可达（被投毒 / 机房屏蔽 / 仅某个 IP 可达）。此前只连
  /// `addresses.first`，第一个不可达就整体连接超时；这里按顺序逐个尝试，
  /// 任意一个成功即建连成功（与浏览器的多 IP 回退行为一致）。
  static Future<ConnectionTask<Socket>> _connectFirstReachable(
    String host,
    int port,
    List<InternetAddress> addresses,
  ) async {
    Object? lastErr;
    for (final addr in addresses) {
      try {
        final task = await Socket.startConnect(addr, port);
        // 等待本次连接结果：成功即返回（调用方后续 await socket 已完成）；
        // 失败则记录并尝试下一个地址。
        await task.socket;
        return task;
      } on Object catch (e) {
        lastErr = e;
      }
    }
    // 全部候选失败：回退系统解析原域名直连（行为同旧路径，尽量不丢）。
    try {
      return await Socket.startConnect(host, port);
    } on Object catch (e) {
      // 兜底失败：抛出原始（更可读）的连接错误。
      throw lastErr ?? e;
    }
  }
}

/// 空覆盖：`createHttpClient` 沿用基类实现（直接创建真实客户端），
/// 供 [NetworkClientBuilder._rawHttpClient] 在 zone 内临时替换全局覆盖，避免递归。
class _RawHttpOverrides extends HttpOverrides {}

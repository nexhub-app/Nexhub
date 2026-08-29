/// 有效网络档案：全局与源级共用的「最终取值」货币类型。
///
/// - 全局 = `NetworkConfigService.effectiveFor(null)`；
/// - 源级 = `effectiveFor(source)`（逐方面把源覆盖合并到全局之上）。
///
/// [signature] 是 `HttpFetcher` 多档案 Dio 的缓存键（内容归一化拼接），
/// 相同配置得相同签名（复用同一 Dio），不同配置签名不同（隔离连接池）。
/// [needsCustomConnection] 决定是否需要安装自定义 `connectionFactory`
/// （DNS 非 system / 有启用的 Hosts / 启用自定义 SNI）。
library;

import 'network_config.dart';
import 'source_network_config.dart';

/// 不可变的有效网络档案。
class EffectiveNetworkProfile {
  final ProxyConfig proxy;
  final DnsConfig dns;
  final List<HostsEntry> hosts;
  final SniConfig sni;
  final EchConfig ech;

  /// 稳定签名（缓存键）。
  final String signature;

  const EffectiveNetworkProfile._({
    required this.proxy,
    required this.dns,
    required this.hosts,
    required this.sni,
    required this.ech,
    required this.signature,
  });

  /// 从全局配置（可选叠加源级覆盖）构建有效档案，逐方面合并。
  ///
  /// [override] 的某方面非 null 则整方面覆盖全局；null 则继承全局。
  factory EffectiveNetworkProfile.fromConfig(
    NetworkConfig global, {
    SourceNetworkConfig? override,
  }) {
    final proxy = override?.proxy ?? global.proxy;
    final dns = override?.dns ?? global.dns;
    final hosts = override?.hosts ?? global.hosts;
    final sni = override?.sni ?? global.sni;
    final ech = override?.ech ?? global.ech;
    return EffectiveNetworkProfile._(
      proxy: proxy,
      dns: dns,
      hosts: List<HostsEntry>.unmodifiable(hosts),
      sni: sni,
      ech: ech,
      signature: _computeSignature(
        proxy: proxy,
        dns: dns,
        hosts: hosts,
        sni: sni,
        ech: ech,
      ),
    );
  }

  /// 是否需要自定义连接（决定是否安装 connectionFactory）。
  bool get needsCustomConnection {
    if (dns.mode != DnsMode.system) return true;
    if (hosts.any((h) => h.enabled && h.ip.isNotEmpty && h.host.isNotEmpty)) {
      return true;
    }
    if (sni.enabled &&
        ((sni.defaultSni?.isNotEmpty ?? false) || sni.domainSni.isNotEmpty)) {
      return true;
    }
    if (dns.resolveSuffix.isNotEmpty) return true;
    return false;
  }

  /// 归一化拼接各方面，作为缓存键。相同配置得相同签名。
  static String _computeSignature({
    required ProxyConfig proxy,
    required DnsConfig dns,
    required List<HostsEntry> hosts,
    required SniConfig sni,
    required EchConfig ech,
  }) {
    final proxyPart =
        'p:${proxy.mode.name}|${proxy.protocol.name}|${proxy.host}|${proxy.port}|${proxy.username}';
    final servers = List<String>.from(dns.servers)..sort();
    final suffixScope = List<String>.from(dns.resolveSuffixDomains)..sort();
    final dnsPart =
        'd:${dns.mode.name}|${servers.join(',')}|${dns.dohUrl}|${dns.dotHost}|${dns.dotPort}|${dns.cacheEnabled}|${dns.resolveSuffix}|${suffixScope.join(',')}';
    final hostEntries = hosts
        .map((h) => '${h.ip}@${h.host}#${h.enabled}')
        .toList()
      ..sort();
    final hostsPart = 'h:${hostEntries.join(',')}';
    final sniDomains = sni.domainSni.entries
        .map((e) => '${e.key}=${e.value}')
        .toList()
      ..sort();
    final sniPart =
        's:${sni.enabled}|${sni.defaultSni ?? ''}|${sniDomains.join(',')}';
    final echPart = 'e:${ech.enabled}|${ech.echConfigList}';
    return [proxyPart, dnsPart, hostsPart, sniPart, echPart].join(';');
  }

  @override
  bool operator ==(Object other) =>
      other is EffectiveNetworkProfile && other.signature == signature;

  @override
  int get hashCode => signature.hashCode;
}

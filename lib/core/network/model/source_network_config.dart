/// 源级网络覆盖配置：`NetworkConfig` 的可空子集。
///
/// 每个方面（proxy/dns/hosts/sni/ech）为 null 表示「继承全局」，
/// 非 null 则整方面覆盖全局。逐方面独立合并见
/// `NetworkConfigService.effectiveFor(source)`。
///
/// 用于两处：
/// 1. 源 JSON 顶层可选 `"network"` 块（随源文件下发）。
/// 2. 用户对某源的 UI 覆盖（存 [SourceNetworkOverrideStore]）。
library;

import 'network_config.dart';
import 'network_validators.dart';

/// 源级网络覆盖（全部可空表示继承全局）。
class SourceNetworkConfig {
  final ProxyConfig? proxy;
  final DnsConfig? dns;
  final List<HostsEntry>? hosts;
  final SniConfig? sni;
  final EchConfig? ech;

  const SourceNetworkConfig({
    this.proxy,
    this.dns,
    this.hosts,
    this.sni,
    this.ech,
  });

  /// 是否为空覆盖（所有方面继承全局）。
  bool get isEmpty =>
      proxy == null &&
      dns == null &&
      hosts == null &&
      sni == null &&
      ech == null;

  SourceNetworkConfig copyWith({
    ProxyConfig? proxy,
    DnsConfig? dns,
    List<HostsEntry>? hosts,
    SniConfig? sni,
    EchConfig? ech,
  }) =>
      SourceNetworkConfig(
        proxy: proxy ?? this.proxy,
        dns: dns ?? this.dns,
        hosts: hosts ?? this.hosts,
        sni: sni ?? this.sni,
        ech: ech ?? this.ech,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (proxy != null) 'proxy': proxy!.toJson(),
        if (dns != null) 'dns': dns!.toJson(),
        if (hosts != null)
          'hosts': hosts!.map((e) => e.toJson()).toList(),
        if (sni != null) 'sni': sni!.toJson(),
        if (ech != null) 'ech': ech!.toJson(),
      };

  /// 从 JSON 容错解析：非法方面忽略（回退继承），不抛异常。
  factory SourceNetworkConfig.fromJson(Map<String, dynamic> json) {
    ProxyConfig? proxy;
    if (json['proxy'] is Map) {
      try {
        proxy =
            ProxyConfig.fromJson((json['proxy'] as Map).cast<String, dynamic>());
      } on Object {
        proxy = null;
      }
    }
    DnsConfig? dns;
    if (json['dns'] is Map) {
      try {
        dns = DnsConfig.fromJson((json['dns'] as Map).cast<String, dynamic>());
      } on Object {
        dns = null;
      }
    }
    List<HostsEntry>? hosts;
    if (json['hosts'] is List) {
      try {
        hosts = (json['hosts'] as List)
            .whereType<Map>()
            .map((e) => HostsEntry.fromJson(e.cast<String, dynamic>()))
            .toList();
      } on Object {
        hosts = null;
      }
    }
    SniConfig? sni;
    if (json['sni'] is Map) {
      try {
        sni = SniConfig.fromJson((json['sni'] as Map).cast<String, dynamic>());
      } on Object {
        sni = null;
      }
    }
    EchConfig? ech;
    if (json['ech'] is Map) {
      try {
        ech = EchConfig.fromJson((json['ech'] as Map).cast<String, dynamic>());
      } on Object {
        ech = null;
      }
    }
    return SourceNetworkConfig(
      proxy: proxy,
      dns: dns,
      hosts: hosts,
      sni: sni,
      ech: ech,
    );
  }

  /// 校验（复用 [NetworkValidators]），返回错误 key 列表（作为警告，不阻断启用）。
  List<String> validate() {
    final errors = <String>[];
    final p = proxy;
    if (p != null) {
      errors.addAll(NetworkValidators.validateProxy(
        mode: p.mode.name,
        host: p.host,
        portText: p.port.toString(),
      ));
    }
    final d = dns;
    if (d != null) {
      for (final s in d.servers) {
        errors.addAll(NetworkValidators.validateDnsServer(s));
      }
      if (d.dohUrl.isNotEmpty) {
        errors.addAll(NetworkValidators.validateDohUrl(d.dohUrl));
      }
      if (d.dotHost.isNotEmpty) {
        errors.addAll(NetworkValidators.validateDot(
          host: d.dotHost,
          portText: d.dotPort.toString(),
        ));
      }
    }
    final h = hosts;
    if (h != null) {
      for (final e in h) {
        errors.addAll(NetworkValidators.validateHostsEntry(
          ip: e.ip,
          host: e.host,
        ));
      }
    }
    final s = sni;
    if (s != null) {
      errors.addAll(NetworkValidators.validateSniValue(s.defaultSni ?? ''));
      for (final e in s.domainSni.entries) {
        errors.addAll(NetworkValidators.validateSniEntry(
          host: e.key,
          value: e.value,
        ));
      }
    }
    return errors;
  }
}

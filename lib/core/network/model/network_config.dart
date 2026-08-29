/// 网络配置数据模型（全局网络设置的持久化结构）。
///
/// 聚合六大方面：代理 / DNS / Hosts / SNI / ECH（+ DoH/DoT 属 DNS 子模式）。
/// 每个子配置的字段都设计成「可空 = 未设置」友好，便于源级子集
/// （[SourceNetworkConfig]）复用并逐方面继承全局（见 effective_network_profile.dart）。
///
/// 持久化：整体 `toJson` 存 SharedPreferences（key `network_config_v1`）；
/// 代理密码不入 JSON，单独经 flutter_secure_storage 加密存储。
library;

/// 代理模式。
enum ProxyMode {
  /// 直连（忽略系统/环境代理）。
  direct,

  /// 系统代理（桌面基于环境变量，尽力而为）。
  system,

  /// 手动指定代理服务器。
  manual,
}

/// 代理协议（仅 manual 模式有意义）。
enum ProxyProtocol { http, socks5 }

/// DNS 解析模式。
enum DnsMode {
  /// 系统解析（默认）。
  system,

  /// 自定义 DNS 服务器（UDP :53）。
  custom,

  /// DNS over HTTPS。
  doh,

  /// DNS over TLS。
  dot,
}

/// 从字符串安全解析枚举，失败回退默认值。
T _enumFromName<T extends Enum>(List<T> values, Object? name, T fallback) {
  if (name is String) {
    for (final v in values) {
      if (v.name == name) return v;
    }
  }
  return fallback;
}

/// 代理配置。
class ProxyConfig {
  final ProxyMode mode;
  final ProxyProtocol protocol;
  final String host;
  final int port;
  final String username;

  const ProxyConfig({
    this.mode = ProxyMode.system,
    this.protocol = ProxyProtocol.http,
    this.host = '',
    this.port = 0,
    this.username = '',
  });

  static const ProxyConfig defaults = ProxyConfig();

  ProxyConfig copyWith({
    ProxyMode? mode,
    ProxyProtocol? protocol,
    String? host,
    int? port,
    String? username,
  }) =>
      ProxyConfig(
        mode: mode ?? this.mode,
        protocol: protocol ?? this.protocol,
        host: host ?? this.host,
        port: port ?? this.port,
        username: username ?? this.username,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'mode': mode.name,
        'protocol': protocol.name,
        'host': host,
        'port': port,
        'username': username,
      };

  factory ProxyConfig.fromJson(Map<String, dynamic> json) => ProxyConfig(
        mode: _enumFromName(ProxyMode.values, json['mode'], ProxyMode.system),
        protocol: _enumFromName(
            ProxyProtocol.values, json['protocol'], ProxyProtocol.http),
        host: (json['host'] as String?) ?? '',
        port: (json['port'] as num?)?.toInt() ?? 0,
        username: (json['username'] as String?) ?? '',
      );
}

/// DNS 配置（含 DoH / DoT 子模式所需字段）。
class DnsConfig {
  final DnsMode mode;
  final List<String> servers;
  final String dohUrl;
  final String dotHost;
  final int dotPort;
  final bool cacheEnabled;

  /// 解析后缀：非空时把「目标主机 + 后缀」交给 DNS 查询，用查到的地址建连，
  /// Host 头仍是原主机名。空字符串表示不启用。
  ///
  /// 作用：地址由每台设备自己的 DNS 现算，配置文件里不写死任何 IP，
  /// 也不会把某台设备解析到的地址带给别人。
  final String resolveSuffix;

  /// [resolveSuffix] 的生效范围。空列表 = 对所有主机生效；
  /// 非空则只对列出的主机生效（键以 `.` 开头表示匹配其子域）。
  ///
  /// 建议显式列出：后缀对不适用的主机（如图片节点）会先查一次注定失败的名字，
  /// 白等一轮超时才回退。
  final List<String> resolveSuffixDomains;

  const DnsConfig({
    this.mode = DnsMode.system,
    this.servers = const <String>[],
    this.dohUrl = '',
    this.dotHost = '',
    this.dotPort = 853,
    this.cacheEnabled = true,
    this.resolveSuffix = '',
    this.resolveSuffixDomains = const <String>[],
  });

  static const DnsConfig defaults = DnsConfig();

  DnsConfig copyWith({
    DnsMode? mode,
    List<String>? servers,
    String? dohUrl,
    String? dotHost,
    int? dotPort,
    bool? cacheEnabled,
    String? resolveSuffix,
    List<String>? resolveSuffixDomains,
  }) =>
      DnsConfig(
        mode: mode ?? this.mode,
        servers: servers ?? this.servers,
        dohUrl: dohUrl ?? this.dohUrl,
        dotHost: dotHost ?? this.dotHost,
        dotPort: dotPort ?? this.dotPort,
        cacheEnabled: cacheEnabled ?? this.cacheEnabled,
        resolveSuffix: resolveSuffix ?? this.resolveSuffix,
        resolveSuffixDomains:
            resolveSuffixDomains ?? this.resolveSuffixDomains,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'mode': mode.name,
        'servers': servers,
        'dohUrl': dohUrl,
        'dotHost': dotHost,
        'dotPort': dotPort,
        'cacheEnabled': cacheEnabled,
        if (resolveSuffix.isNotEmpty) 'resolveSuffix': resolveSuffix,
        if (resolveSuffixDomains.isNotEmpty)
          'resolveSuffixDomains': resolveSuffixDomains,
      };

  factory DnsConfig.fromJson(Map<String, dynamic> json) => DnsConfig(
        mode: _enumFromName(DnsMode.values, json['mode'], DnsMode.system),
        servers: _stringList(json['servers']),
        dohUrl: (json['dohUrl'] as String?) ?? '',
        dotHost: (json['dotHost'] as String?) ?? '',
        dotPort: (json['dotPort'] as num?)?.toInt() ?? 853,
        cacheEnabled: json['cacheEnabled'] as bool? ?? true,
        resolveSuffix: (json['resolveSuffix'] as String?) ?? '',
        resolveSuffixDomains: _stringList(json['resolveSuffixDomains']),
      );
}

/// 自定义 Hosts 条目（ip → host 映射）。
class HostsEntry {
  final String ip;
  final String host;
  final bool enabled;

  const HostsEntry({
    this.ip = '',
    this.host = '',
    this.enabled = true,
  });

  HostsEntry copyWith({String? ip, String? host, bool? enabled}) => HostsEntry(
        ip: ip ?? this.ip,
        host: host ?? this.host,
        enabled: enabled ?? this.enabled,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ip': ip,
        'host': host,
        'enabled': enabled,
      };

  factory HostsEntry.fromJson(Map<String, dynamic> json) => HostsEntry(
        ip: (json['ip'] as String?) ?? '',
        host: (json['host'] as String?) ?? '',
        enabled: json['enabled'] as bool? ?? true,
      );
}

/// SNI 配置（默认 SNI / 域名→SNI 映射）。
///
/// 运行时对「https 直连」生效（见 [SniPolicy] 与 NetworkClientBuilder 的
/// connectionFactory）：值 `-` 表示免 SNI（握手不发送 server_name）；普通域名
/// 表示以该域名作 SNI。仅直连可用；走外部代理时 TLS 由 HttpClient 自理，
/// SNI 固定为目标域名。
class SniConfig {
  final String? defaultSni;
  final Map<String, String> domainSni;
  final bool enabled;

  const SniConfig({
    this.defaultSni,
    this.domainSni = const <String, String>{},
    this.enabled = false,
  });

  static const SniConfig defaults = SniConfig();

  SniConfig copyWith({
    String? defaultSni,
    Map<String, String>? domainSni,
    bool? enabled,
  }) =>
      SniConfig(
        defaultSni: defaultSni ?? this.defaultSni,
        domainSni: domainSni ?? this.domainSni,
        enabled: enabled ?? this.enabled,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (defaultSni != null) 'defaultSni': defaultSni,
        'domainSni': domainSni,
        'enabled': enabled,
      };

  factory SniConfig.fromJson(Map<String, dynamic> json) => SniConfig(
        defaultSni: json['defaultSni'] as String?,
        domainSni: _stringMap(json['domainSni']),
        enabled: json['enabled'] as bool? ?? false,
      );
}

/// ECH（Encrypted Client Hello）配置。
///
/// 平台限制：Dart TLS 栈（BoringSSL 封装）不暴露 ECH API 且无插件，本配置
/// 运行时不生效。UI/持久化保留是为：(1) 源文件 network 块可声明意图；
/// (2) 未来接入原生 TLS 后无需迁移。当前让受限站点可用的路径：
/// 配合 SNI 免 SNI 模式、或经支持 ECH 的本地代理内核（手动代理）。
class EchConfig {
  final bool enabled;
  final String echConfigList;

  const EchConfig({
    this.enabled = false,
    this.echConfigList = '',
  });

  static const EchConfig defaults = EchConfig();

  EchConfig copyWith({bool? enabled, String? echConfigList}) => EchConfig(
        enabled: enabled ?? this.enabled,
        echConfigList: echConfigList ?? this.echConfigList,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'enabled': enabled,
        'echConfigList': echConfigList,
      };

  factory EchConfig.fromJson(Map<String, dynamic> json) => EchConfig(
        enabled: json['enabled'] as bool? ?? false,
        echConfigList: (json['echConfigList'] as String?) ?? '',
      );
}

/// 全局网络配置聚合。
class NetworkConfig {
  final ProxyConfig proxy;
  final DnsConfig dns;
  final List<HostsEntry> hosts;
  final SniConfig sni;
  final EchConfig ech;

  const NetworkConfig({
    this.proxy = ProxyConfig.defaults,
    this.dns = DnsConfig.defaults,
    this.hosts = const <HostsEntry>[],
    this.sni = SniConfig.defaults,
    this.ech = EchConfig.defaults,
  });

  static const NetworkConfig defaults = NetworkConfig();

  NetworkConfig copyWith({
    ProxyConfig? proxy,
    DnsConfig? dns,
    List<HostsEntry>? hosts,
    SniConfig? sni,
    EchConfig? ech,
  }) =>
      NetworkConfig(
        proxy: proxy ?? this.proxy,
        dns: dns ?? this.dns,
        hosts: hosts ?? this.hosts,
        sni: sni ?? this.sni,
        ech: ech ?? this.ech,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'proxy': proxy.toJson(),
        'dns': dns.toJson(),
        'hosts': hosts.map((e) => e.toJson()).toList(),
        'sni': sni.toJson(),
        'ech': ech.toJson(),
      };

  factory NetworkConfig.fromJson(Map<String, dynamic> json) => NetworkConfig(
        proxy: json['proxy'] is Map
            ? ProxyConfig.fromJson(
                (json['proxy'] as Map).cast<String, dynamic>())
            : ProxyConfig.defaults,
        dns: json['dns'] is Map
            ? DnsConfig.fromJson((json['dns'] as Map).cast<String, dynamic>())
            : DnsConfig.defaults,
        hosts: (json['hosts'] is List)
            ? (json['hosts'] as List)
                .whereType<Map>()
                .map((e) => HostsEntry.fromJson(e.cast<String, dynamic>()))
                .toList()
            : const <HostsEntry>[],
        sni: json['sni'] is Map
            ? SniConfig.fromJson((json['sni'] as Map).cast<String, dynamic>())
            : SniConfig.defaults,
        ech: json['ech'] is Map
            ? EchConfig.fromJson((json['ech'] as Map).cast<String, dynamic>())
            : EchConfig.defaults,
      );
}

/// 解析 JSON 中的字符串列表（容错：过滤非字符串与空白项）。
List<String> _stringList(Object? raw) {
  if (raw is List) {
    return raw
        .whereType<String>()
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }
  return const <String>[];
}

/// 解析 JSON 中的字符串→字符串映射（容错）。
Map<String, String> _stringMap(Object? raw) {
  if (raw is Map) {
    final out = <String, String>{};
    raw.forEach((k, v) {
      if (k is String && v is String) out[k] = v;
    });
    return out;
  }
  return const <String, String>{};
}

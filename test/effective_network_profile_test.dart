// EffectiveNetworkProfile 逐方面 inherit 合并、优先级、signature 稳定性/区分度、
// needsCustomConnection 判定测试。
//
// 纯函数，无网络与 IO。
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/network/model/effective_network_profile.dart';
import 'package:nexhub/core/network/model/network_config.dart';
import 'package:nexhub/core/network/model/source_network_config.dart';

void main() {
  group('EffectiveNetworkProfile 合并（逐方面 inherit）', () {
    test('无覆盖时逐方面继承全局', () {
      final p = EffectiveNetworkProfile.fromConfig(NetworkConfig.defaults);
      expect(p.proxy.mode, NetworkConfig.defaults.proxy.mode);
      expect(p.dns.mode, NetworkConfig.defaults.dns.mode);
      expect(p.hosts, isEmpty);
      expect(p.sni.enabled, isFalse);
      expect(p.ech.enabled, isFalse);
    });

    test('覆盖某方面仅替换该方面，其余仍继承全局', () {
      const global = NetworkConfig(
        proxy: ProxyConfig(mode: ProxyMode.system),
        dns: DnsConfig(mode: DnsMode.system),
        hosts: <HostsEntry>[],
        sni: SniConfig(),
        ech: EchConfig(),
      );
      const override = SourceNetworkConfig(
        proxy: ProxyConfig(
          mode: ProxyMode.manual,
          protocol: ProxyProtocol.socks5,
          host: '127.0.0.1',
          port: 1080,
        ),
      );
      final p = EffectiveNetworkProfile.fromConfig(global, override: override);
      // proxy 被源级覆盖
      expect(p.proxy.mode, ProxyMode.manual);
      expect(p.proxy.host, '127.0.0.1');
      // 其余方面继承全局
      expect(p.dns.mode, DnsMode.system);
      expect(p.sni.enabled, isFalse);
    });

    test('override 优先于全局（同方面取源级值）', () {
      const global = NetworkConfig(
        proxy: ProxyConfig(mode: ProxyMode.direct),
        dns: DnsConfig(mode: DnsMode.system),
        hosts: <HostsEntry>[],
        sni: SniConfig(),
        ech: EchConfig(),
      );
      const override = SourceNetworkConfig(
        dns: DnsConfig(
          mode: DnsMode.doh,
          dohUrl: 'https://cloudflare-dns.com/dns-query',
        ),
      );
      final p = EffectiveNetworkProfile.fromConfig(global, override: override);
      expect(p.dns.mode, DnsMode.doh);
      expect(p.dns.dohUrl, contains('cloudflare'));
      // proxy 仍是全局
      expect(p.proxy.mode, ProxyMode.direct);
    });
  });

  group('signature 稳定性与区分度', () {
    test('相同配置得相同签名（可复用同一 Dio）', () {
      final a = EffectiveNetworkProfile.fromConfig(NetworkConfig.defaults);
      final b = EffectiveNetworkProfile.fromConfig(NetworkConfig.defaults);
      expect(a.signature, b.signature);
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('不同配置得不同签名（隔离连接池）', () {
      final base = EffectiveNetworkProfile.fromConfig(NetworkConfig.defaults);
      final other = EffectiveNetworkProfile.fromConfig(
        NetworkConfig.defaults,
        override: const SourceNetworkConfig(
          proxy: ProxyConfig(
            mode: ProxyMode.manual,
            host: '10.0.0.1',
            port: 8080,
          ),
        ),
      );
      expect(base.signature, isNot(other.signature));
      expect(base, isNot(equals(other)));
    });

    test('Hosts 顺序无关（归一化排序）得相同签名', () {
      const h1 = HostsEntry(ip: '1.1.1.1', host: 'a.com');
      const h2 = HostsEntry(ip: '2.2.2.2', host: 'b.com');
      final a = EffectiveNetworkProfile.fromConfig(
        NetworkConfig.defaults,
        override: const SourceNetworkConfig(hosts: <HostsEntry>[h1, h2]),
      );
      final b = EffectiveNetworkProfile.fromConfig(
        NetworkConfig.defaults,
        override: const SourceNetworkConfig(hosts: <HostsEntry>[h2, h1]),
      );
      expect(a.signature, b.signature);
    });
  });

  group('needsCustomConnection 判定', () {
    test('默认（system DNS / 无 Hosts / 无 SNI）不需要自定义连接', () {
      final p = EffectiveNetworkProfile.fromConfig(NetworkConfig.defaults);
      expect(p.needsCustomConnection, isFalse);
    });

    test('DNS 非 system 需要自定义连接', () {
      final p = EffectiveNetworkProfile.fromConfig(
        NetworkConfig.defaults,
        override: const SourceNetworkConfig(
          dns: DnsConfig(mode: DnsMode.doh, dohUrl: 'https://x/dns-query'),
        ),
      );
      expect(p.needsCustomConnection, isTrue);
    });

    test('有启用且完整的 Hosts 需要自定义连接', () {
      final p = EffectiveNetworkProfile.fromConfig(
        NetworkConfig.defaults,
        override: const SourceNetworkConfig(
          hosts: <HostsEntry>[
            HostsEntry(ip: '104.21.0.1', host: 'www.example.com'),
          ],
        ),
      );
      expect(p.needsCustomConnection, isTrue);
    });

    test('禁用的 Hosts 不触发自定义连接', () {
      final p = EffectiveNetworkProfile.fromConfig(
        NetworkConfig.defaults,
        override: const SourceNetworkConfig(
          hosts: <HostsEntry>[
            HostsEntry(ip: '104.21.0.1', host: 'x.com', enabled: false),
          ],
        ),
      );
      expect(p.needsCustomConnection, isFalse);
    });

    test('启用自定义 SNI 需要自定义连接', () {
      final p = EffectiveNetworkProfile.fromConfig(
        NetworkConfig.defaults,
        override: const SourceNetworkConfig(
          sni: SniConfig(defaultSni: 'example.org', enabled: true),
        ),
      );
      expect(p.needsCustomConnection, isTrue);
    });
  });
}

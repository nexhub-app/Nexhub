// NetworkConfig / SourceNetworkConfig JSON 往返、默认兜底与校验器测试。
//
// 纯数据/纯函数，无网络与 IO，稳定可重复。
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/network/model/network_config.dart';
import 'package:nexhub/core/network/model/network_validators.dart';
import 'package:nexhub/core/network/model/source_network_config.dart';

void main() {
  group('NetworkConfig JSON 往返', () {
    test('默认配置往返后等价', () {
      final json = NetworkConfig.defaults.toJson();
      final back = NetworkConfig.fromJson(json);
      expect(back.proxy.mode, NetworkConfig.defaults.proxy.mode);
      expect(back.dns.mode, NetworkConfig.defaults.dns.mode);
      expect(back.dns.dotPort, 853);
      expect(back.hosts, isEmpty);
      expect(back.sni.enabled, isFalse);
      expect(back.ech.enabled, isFalse);
    });

    test('完整配置往返保真', () {
      const cfg = NetworkConfig(
        proxy: ProxyConfig(
          mode: ProxyMode.manual,
          protocol: ProxyProtocol.socks5,
          host: '127.0.0.1',
          port: 1080,
          username: 'u',
        ),
        dns: DnsConfig(
          mode: DnsMode.doh,
          servers: <String>['1.1.1.1'],
          dohUrl: 'https://cloudflare-dns.com/dns-query',
          dotHost: 'dns.google',
          dotPort: 853,
          cacheEnabled: false,
        ),
        hosts: <HostsEntry>[
          HostsEntry(ip: '104.21.0.1', host: 'www.example.com'),
        ],
        sni: SniConfig(defaultSni: 'example.org', enabled: true),
        ech: EchConfig(enabled: true, echConfigList: 'AEX+'),
      );
      final back = NetworkConfig.fromJson(cfg.toJson());
      expect(back.proxy.protocol, ProxyProtocol.socks5);
      expect(back.proxy.port, 1080);
      expect(back.dns.mode, DnsMode.doh);
      expect(back.dns.dohUrl, contains('cloudflare'));
      expect(back.dns.cacheEnabled, isFalse);
      expect(back.hosts.single.host, 'www.example.com');
      expect(back.sni.defaultSni, 'example.org');
      expect(back.ech.echConfigList, 'AEX+');
    });

    test('非法/缺失字段回退默认，不抛异常', () {
      final back = NetworkConfig.fromJson(<String, dynamic>{
        'proxy': <String, dynamic>{'mode': 'bogus'},
        'dns': 'not-a-map',
      });
      expect(back.proxy.mode, ProxyMode.direct); // 未识别枚举回退默认直连
      expect(back.dns.mode, DnsMode.system); // 非 Map 回退默认
    });
  });

  group('SourceNetworkConfig 子集', () {
    test('空覆盖 isEmpty 为真，toJson 无方面键', () {
      const empty = SourceNetworkConfig();
      expect(empty.isEmpty, isTrue);
      expect(empty.toJson(), isEmpty);
    });

    test('部分覆盖往返仅保留非空方面', () {
      const ov = SourceNetworkConfig(
        proxy: ProxyConfig(
          mode: ProxyMode.manual,
          host: '10.0.0.1',
          port: 8080,
        ),
      );
      final json = ov.toJson();
      expect(json.containsKey('proxy'), isTrue);
      expect(json.containsKey('dns'), isFalse);
      final back = SourceNetworkConfig.fromJson(json);
      expect(back.proxy, isNotNull);
      expect(back.dns, isNull);
      expect(back.isEmpty, isFalse);
    });

    test('validate 复用校验器，返回错误 key', () {
      const bad = SourceNetworkConfig(
        proxy: ProxyConfig(mode: ProxyMode.manual, host: '', port: 0),
      );
      final errs = bad.validate();
      expect(errs, contains('networkErrorInvalidHost'));
      expect(errs, contains('networkErrorInvalidPort'));
    });
  });

  group('NetworkValidators', () {
    test('IPv4 校验', () {
      expect(NetworkValidators.isIpv4('192.168.1.1'), isTrue);
      expect(NetworkValidators.isIpv4('256.1.1.1'), isFalse);
      expect(NetworkValidators.isIpv4('01.2.3.4'), isFalse); // 前导零
      expect(NetworkValidators.isIpv4('1.2.3'), isFalse);
    });

    test('IPv6 校验', () {
      expect(NetworkValidators.isIpv6('::1'), isTrue);
      expect(NetworkValidators.isIpv6('2001:db8::1'), isTrue);
      expect(NetworkValidators.isIpv6('1.2.3.4'), isFalse);
      expect(NetworkValidators.isIpv6('gg::1'), isFalse);
    });

    test('端口校验', () {
      expect(NetworkValidators.isPort(1), isTrue);
      expect(NetworkValidators.isPort(65535), isTrue);
      expect(NetworkValidators.isPort(0), isFalse);
      expect(NetworkValidators.isPort(70000), isFalse);
      expect(NetworkValidators.isPortString('443'), isTrue);
      expect(NetworkValidators.isPortString('abc'), isFalse);
    });

    test('https URL 校验', () {
      expect(
          NetworkValidators.isHttpsUrl('https://dns.google/dns-query'), isTrue);
      expect(NetworkValidators.isHttpsUrl('http://foo'), isFalse);
      expect(NetworkValidators.isHttpsUrl('not a url'), isFalse);
    });

    test('域名校验', () {
      expect(NetworkValidators.isDomain('www.example.com'), isTrue);
      expect(NetworkValidators.isDomain('example'), isFalse); // 单标签
      expect(NetworkValidators.isDomain('-bad.com'), isFalse);
    });

    test('组合校验：direct 模式无需 host/port', () {
      expect(
        NetworkValidators.validateProxy(mode: 'direct', host: '', portText: ''),
        isEmpty,
      );
    });

    test('组合校验：DoH URL / DoT / hosts', () {
      expect(NetworkValidators.validateDohUrl('http://x'),
          contains('networkErrorInvalidDohUrl'));
      expect(
        NetworkValidators.validateDot(host: 'dns.google', portText: '853'),
        isEmpty,
      );
      expect(
        NetworkValidators.validateHostsEntry(ip: 'bad', host: 'no dots'),
        isNotEmpty,
      );
    });
  });
}

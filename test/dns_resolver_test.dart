// DnsResolver 网络无关行为测试：IP 字面量直返、Hosts 优先命中、
// clearCache / cacheSize。
//
// 不发起真实 DNS 查询（仅走 IP 字面量与 Hosts 命中分支）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/network/model/network_config.dart';
import 'package:nexhub/core/network/runtime/dns_resolver.dart';

void main() {
  final resolver = DnsResolver.instance;

  setUp(resolver.clearCache);

  group('IP 字面量直返（不进 DNS，不缓存）', () {
    test('IPv4 字面量原样返回', () async {
      final r = await resolver.resolve(
        '1.2.3.4',
        const DnsConfig(),
        const <HostsEntry>[],
      );
      expect(r, hasLength(1));
      expect(r.first.address, '1.2.3.4');
      expect(resolver.cacheSize, 0); // 字面量不缓存
    });

    test('IPv6 字面量原样返回', () async {
      final r = await resolver.resolve(
        '::1',
        const DnsConfig(),
        const <HostsEntry>[],
      );
      expect(r, hasLength(1));
      expect(r.first.type, InternetAddressType.IPv6);
      expect(resolver.cacheSize, 0);
    });
  });

  group('Hosts 优先命中（不进 DNS，不缓存）', () {
    test('启用且命中的 Hosts 直接返回其 IP', () async {
      final r = await resolver.resolve(
        'www.example.com',
        const DnsConfig(mode: DnsMode.system),
        const <HostsEntry>[
          HostsEntry(ip: '104.21.0.1', host: 'www.example.com'),
        ],
      );
      expect(r, hasLength(1));
      expect(r.first.address, '104.21.0.1');
      expect(resolver.cacheSize, 0); // Hosts 命中不缓存
    });

    test('host 大小写不敏感命中', () async {
      final r = await resolver.resolve(
        'WWW.Example.COM',
        const DnsConfig(),
        const <HostsEntry>[
          HostsEntry(ip: '203.0.113.9', host: 'www.example.com'),
        ],
      );
      expect(r.single.address, '203.0.113.9');
    });

    test('禁用的 Hosts 不命中', () async {
      const hosts = <HostsEntry>[
        HostsEntry(ip: '10.0.0.1', host: 'x.internal', enabled: false),
      ];
      // 禁用条目不应短路返回；'x.internal' 非 IP 字面量会进入解析分支，
      // 这里改测「命中判定」——用另一条启用条目验证优先级与禁用被跳过。
      final r = await resolver.resolve(
        'x.internal',
        const DnsConfig(),
        <HostsEntry>[
          ...hosts,
          const HostsEntry(ip: '10.0.0.2', host: 'x.internal'),
        ],
      );
      // 跳过禁用条目，命中后一条启用条目。
      expect(r.single.address, '10.0.0.2');
    });
  });

  group('缓存维护', () {
    test('clearCache 清空、cacheSize 归零', () async {
      // 通过 IP 字面量/Hosts 不写缓存，这里仅验证 clearCache 幂等且 size 稳定。
      resolver.clearCache();
      expect(resolver.cacheSize, 0);
      // 再次 Hosts 命中仍不增长缓存。
      await resolver.resolve(
        'a.test',
        const DnsConfig(),
        const <HostsEntry>[HostsEntry(ip: '198.51.100.7', host: 'a.test')],
      );
      expect(resolver.cacheSize, 0);
      resolver.clearCache();
      expect(resolver.cacheSize, 0);
    });
  });
}

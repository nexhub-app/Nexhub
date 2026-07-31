// NetworkClientBuilder 测试：三代理模式与自定义连接档案均能构建
// HttpClient 而不抛异常。
//
// 说明：`HttpClient.findProxy` / `connectionFactory` 均为 setter-only，
// 无法读回断言其值，故以「构建成功且可关闭」为可验证行为。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/network/model/effective_network_profile.dart';
import 'package:nexhub/core/network/model/network_config.dart';
import 'package:nexhub/core/network/model/source_network_config.dart';
import 'package:nexhub/core/network/runtime/network_client_builder.dart';

EffectiveNetworkProfile _profile({SourceNetworkConfig? override}) =>
    EffectiveNetworkProfile.fromConfig(NetworkConfig.defaults,
        override: override);

void main() {
  group('NetworkClientBuilder.buildHttpClient 代理模式', () {
    test('direct 模式构建成功', () {
      final client = NetworkClientBuilder.buildHttpClient(
        _profile(
          override: const SourceNetworkConfig(
            proxy: ProxyConfig(mode: ProxyMode.direct),
          ),
        ),
      );
      expect(client, isA<HttpClient>());
      client.close(force: true);
    });

    test('system 模式构建成功', () {
      final client = NetworkClientBuilder.buildHttpClient(
        _profile(
          override: const SourceNetworkConfig(
            proxy: ProxyConfig(mode: ProxyMode.system),
          ),
        ),
      );
      expect(client, isA<HttpClient>());
      client.close(force: true);
    });

    test('manual http + 用户名 注入凭据构建成功', () {
      final client = NetworkClientBuilder.buildHttpClient(
        _profile(
          override: const SourceNetworkConfig(
            proxy: ProxyConfig(
              mode: ProxyMode.manual,
              protocol: ProxyProtocol.http,
              host: '127.0.0.1',
              port: 8080,
              username: 'user',
            ),
          ),
        ),
        proxyPassword: 'secret',
      );
      expect(client, isA<HttpClient>());
      client.close(force: true);
    });

    test('manual socks5 构建成功', () {
      final client = NetworkClientBuilder.buildHttpClient(
        _profile(
          override: const SourceNetworkConfig(
            proxy: ProxyConfig(
              mode: ProxyMode.manual,
              protocol: ProxyProtocol.socks5,
              host: '127.0.0.1',
              port: 1080,
            ),
          ),
        ),
      );
      expect(client, isA<HttpClient>());
      client.close(force: true);
    });

    test('manual 缺 host/port 回退直连仍构建成功', () {
      final client = NetworkClientBuilder.buildHttpClient(
        _profile(
          override: const SourceNetworkConfig(
            proxy: ProxyConfig(mode: ProxyMode.manual, host: '', port: 0),
          ),
        ),
      );
      expect(client, isA<HttpClient>());
      client.close(force: true);
    });
  });

  group('needsCustomConnection 档案安装 connectionFactory', () {
    test('DoH 档案（需自定义连接）构建成功', () {
      final profile = _profile(
        override: const SourceNetworkConfig(
          dns: DnsConfig(mode: DnsMode.doh, dohUrl: 'https://x/dns-query'),
        ),
      );
      expect(profile.needsCustomConnection, isTrue);
      final client = NetworkClientBuilder.buildHttpClient(profile);
      expect(client, isA<HttpClient>());
      client.close(force: true);
    });

    test('默认档案（无需自定义连接）构建成功', () {
      final profile = _profile();
      expect(profile.needsCustomConnection, isFalse);
      final client = NetworkClientBuilder.buildHttpClient(profile);
      expect(client, isA<HttpClient>());
      client.close(force: true);
    });
  });

  group('HttpOverrides 递归回归', () {
    // 回归：安装一个「委托回 buildHttpClient」的全局覆盖（模拟
    // NexHubHttpOverrides + main.dart 的生产环境）。若 buildHttpClient 内部用
    // 公开 HttpClient() 工厂，会无限递归 StackOverflow，导致全应用请求失败。
    test('全局覆盖委托 buildHttpClient 时构建不递归（不抛 StackOverflow）', () {
      final previous = HttpOverrides.current;
      HttpOverrides.global = _DelegatingOverrides();
      try {
        // 公开工厂：经全局覆盖 → buildHttpClient → 裸客户端，不得递归。
        final viaFactory = HttpClient();
        expect(viaFactory, isA<HttpClient>());
        viaFactory.close(force: true);
        // 直接调用：即便处于活动覆盖下也应安全。
        final direct = NetworkClientBuilder.buildHttpClient(_profile());
        expect(direct, isA<HttpClient>());
        direct.close(force: true);
      } finally {
        HttpOverrides.global = previous;
      }
    });
  });
}

/// 测试用覆盖：像 NexHubHttpOverrides 一样把 createHttpClient 委托回
/// [NetworkClientBuilder.buildHttpClient]，用于验证不会自引用递归。
class _DelegatingOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return NetworkClientBuilder.buildHttpClient(
      _profile(),
      ctx: context,
    );
  }
}

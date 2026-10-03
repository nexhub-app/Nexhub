// Bangumi ECH 代理：作用域判定（三套 ECH 的并集）与代理链不被吞的回归。
//
// 说明：`HttpClient.findProxy` 为 setter-only，无法读回断言。故此处直接对
// 「域名判定」与「代理决策组合」两个纯函数断言——它们是实际安装到 HttpClient
// 上那段逻辑的唯一来源（见 NetworkClientBuilder.composeProxyResolver）。
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/models/plugin_config.dart';
import 'package:nexhub/core/network/model/network_config.dart';
import 'package:nexhub/core/network/runtime/network_client_builder.dart';
import 'package:nexhub/core/services/bangumi/bangumi_ech_proxy.dart';
import 'package:nexhub/core/services/bangumi/bangumi_proxy_config.dart';

void main() {
  group('isEchTargetHost 作用范围（仅 Bangumi 自有域）', () {
    test('命中 bgm.tv 及其子域', () {
      for (final host in const [
        'bgm.tv',
        'api.bgm.tv',
        'lain.bgm.tv',
        'next.bgm.tv',
        'www.bgm.tv',
      ]) {
        expect(isEchTargetHost(host), isTrue, reason: host);
      }
    });

    test('命中 chii.in 及其子域', () {
      for (final host in const ['chii.in', 'bgm.chii.in']) {
        expect(isEchTargetHost(host), isTrue, reason: host);
      }
    });

    test('放行一切非 Bangumi 域（含公共 DNS、近似域与空串）', () {
      for (final host in const [
        '',
        'cloudflare-dns.com',
        'dns.google',
        'example.com',
        'github.com',
        // 近似域不得因字符串包含而误命中：
        'bgm.tv.evil.com',
        'notbgm.tv',
        'api.bgm.tv.example.com',
      ]) {
        expect(isEchTargetHost(host), isFalse, reason: host);
      }
    });
  });

  group('BangumiProxyConfig 连接模式三选一（对齐参考 ProxyMode）', () {
    test('echEnabled 由 mode 派生：仅 ech 模式为真', () {
      expect(const BangumiProxyConfig().echEnabled, isFalse);
      expect(
          const BangumiProxyConfig(mode: BangumiProxyMode.mirror).echEnabled,
          isFalse);
      expect(const BangumiProxyConfig(mode: BangumiProxyMode.ech).echEnabled,
          isTrue);
    });

    test('旧版迁移：独立开关 echEnabled=true 一律迁为 ech 模式', () {
      for (final legacyMode in const ['direct', 'mirror']) {
        final cfg = BangumiProxyConfig.fromJson(
          <String, dynamic>{'mode': legacyMode, 'echEnabled': true},
        );
        expect(cfg.mode, BangumiProxyMode.ech, reason: legacyMode);
        expect(cfg.echEnabled, isTrue, reason: legacyMode);
      }
    });

    test('新版 json 不含 echEnabled 字段时按 mode 解析', () {
      expect(
          BangumiProxyConfig.fromJson(
                  <String, dynamic>{'mode': 'mirror'}).mode,
          BangumiProxyMode.mirror);
      expect(
          BangumiProxyConfig.fromJson(<String, dynamic>{'mode': 'ech'}).mode,
          BangumiProxyMode.ech);
    });

    test('未知模式名回退直连', () {
      expect(BangumiProxyConfig.fromJson(<String, dynamic>{'mode': 'xxx'}).mode,
          BangumiProxyMode.direct);
    });

    test('toJson 保留 echEnabled 字段（旧版本回滚安装仍可恢复状态）', () {
      expect(const BangumiProxyConfig(mode: BangumiProxyMode.ech).toJson(),
          containsPair('echEnabled', true));
      expect(const BangumiProxyConfig(mode: BangumiProxyMode.direct).toJson(),
          containsPair('echEnabled', false));
    });
  });

  group('computeEchScope bangumi 专用：ECH 模式接管自有域，镜像域不再并入', () {
    test('直连模式不注入 bangumi 域（应用级关闭时不接管任何域）', () {
      const cfg = BangumiProxyConfig();
      final spec = BangumiEchProxy.instance.computeEchScope(cfg);
      for (final host in const ['bgm.tv', 'api.bgm.tv', 'example.com']) {
        expect(spec.handles(host), isFalse, reason: host);
      }
    });

    test('ECH 模式注入自有域（bgm.tv / chii.in 及其子域）', () {
      const cfg = BangumiProxyConfig(mode: BangumiProxyMode.ech);
      final spec = BangumiEchProxy.instance.computeEchScope(cfg);
      for (final host in const [
        'bgm.tv',
        'api.bgm.tv',
        'lain.bgm.tv',
        'next.bgm.tv',
        'chii.in',
        'bgm.chii.in',
      ]) {
        expect(spec.handles(host), isTrue, reason: host);
      }
      // 应用级未开：第三方域仍不接管。
      expect(spec.handles('example.com'), isFalse);
      expect(spec.handles('cloudflare-dns.com'), isFalse);
    });

    test('镜像模式的自建域不属于 bangumi ECH 作用域（三选一互斥；如需覆盖走应用级）', () {
      const cfg = BangumiProxyConfig(
        mode: BangumiProxyMode.mirror,
        mainSite: 'https://mirror.example.com',
        api: 'https://api-mirror.example.net',
        image: 'https://img.example.org',
      );
      final spec = BangumiEchProxy.instance.computeEchScope(cfg);
      for (final host in const [
        'mirror.example.com',
        'api-mirror.example.net',
        'img.example.org',
      ]) {
        expect(spec.handles(host), isFalse, reason: host);
      }
      // ECH 与镜像互斥：镜像模式下自有域也不由本套接管。
      expect(spec.handles('api.bgm.tv'), isFalse);
    });
  });

  group('resolveProxyOverride 代理覆盖策略', () {
    test('未运行时对任何域名都不接管（含 Bangumi 域）', () {
      final proxy = BangumiEchProxy.instance;
      // 测试宿主非 Android：enable 不生效，端口恒 0、running 恒 false。
      expect(proxy.isEchProxyRunning(), isFalse);
      expect(proxy.getEchProxyPort(), 0);
      expect(proxy.resolveProxyOverride(Uri.parse('https://api.bgm.tv/x')),
          isNull);
      expect(proxy.resolveProxyOverride(Uri.parse('https://example.com/x')),
          isNull);
    });

    test('非 Android 平台 enable 返回 0（安全降级，不抛异常）', () async {
      final port = await BangumiEchProxy.instance.enableEchProxy();
      expect(port, 0);
      expect(BangumiEchProxy.instance.isEchProxyRunning(), isFalse);
      await BangumiEchProxy.instance.disableEchProxy();
    });

    test('单例首次访问即挂载全局覆盖策略', () {
      // ignore: unnecessary_statements
      BangumiEchProxy.instance;
      expect(NetworkClientBuilder.proxyOverrideResolver, isNotNull);
    });
  });

  group('ECH 与用户代理共存：只接管 Bangumi，不吞用户代理', () {
    const userProxy = ProxyConfig(
      mode: ProxyMode.manual,
      protocol: ProxyProtocol.http,
      host: '127.0.0.1',
      port: 8080,
    );

    test('ECH 挂载但未运行时，Bangumi 请求仍走用户代理', () {
      final resolver = BangumiEchProxy.instance.resolveProxyOverride;
      final composed = NetworkClientBuilder.composeProxyResolver(
        userProxy,
        override: resolver,
      );
      expect(composed(Uri.parse('https://api.bgm.tv/v0/subjects/1')),
          'PROXY 127.0.0.1:8080');
      expect(composed(Uri.parse('https://github.com/x')),
          'PROXY 127.0.0.1:8080');
    });

    test('ECH 运行时仅 Bangumi 域被接管，其余仍走用户代理', () {
      // 用与 BangumiEchProxy 同构的替身模拟「运行中」状态（测试宿主无法
      // 真正启动原生代理），验证组合语义而非原生实现。
      String? echLike(Uri uri) =>
          isEchTargetHost(uri.host) ? 'PROXY localhost:41234' : null;
      final composed = NetworkClientBuilder.composeProxyResolver(
        userProxy,
        override: echLike,
      );
      expect(composed(Uri.parse('https://lain.bgm.tv/pic/cover/l/1.jpg')),
          'PROXY localhost:41234');
      expect(composed(Uri.parse('https://api.bgm.tv/v0/subjects/1')),
          'PROXY localhost:41234');
      expect(composed(Uri.parse('https://cloudflare-dns.com/dns-query')),
          'PROXY 127.0.0.1:8080');
      expect(composed(Uri.parse('https://example.com/x')),
          'PROXY 127.0.0.1:8080');
    });
  });

  group('EchScopeSpec 作用域判定（三套 ECH 并集，越具体越优先）', () {
    test('空作用域不接管任何域（三套全关时引擎不必常驻）', () {
      const spec = EchScopeSpec();
      expect(spec.isEmpty, isTrue);
      for (final host in const ['bgm.tv', 'example.com', '']) {
        expect(spec.handles(host), isFalse, reason: host);
      }
    });

    test('显式点名的域含子域，近似域不得误命中', () {
      const spec = EchScopeSpec(targets: <String>['bgm.tv', 'ech.example.com']);
      for (final host in const [
        'bgm.tv',
        'api.bgm.tv',
        'ech.example.com',
        'www.ech.example.com',
      ]) {
        expect(spec.handles(host), isTrue, reason: host);
      }
      for (final host in const [
        'example.com',
        'bgm.tv.evil.com',
        'notbgm.tv',
        'api.bgm.tv.example.com',
        '',
      ]) {
        expect(spec.handles(host), isFalse, reason: host);
      }
    });

    test('源级显式关闭优先于点名与应用级：该域必不接管', () {
      const spec = EchScopeSpec(
        targets: <String>['bgm.tv'],
        excluded: <String>['api.bgm.tv'],
        allowAnyHost: true,
      );
      expect(spec.handles('api.bgm.tv'), isFalse);
      expect(spec.handles('lain.bgm.tv'), isTrue);
      // 应用级兜住未被排除的任意域。
      expect(spec.handles('example.com'), isTrue);
    });

    test('应用级接管任意 https 域', () {
      const spec = EchScopeSpec(allowAnyHost: true);
      expect(spec.isEmpty, isFalse);
      expect(spec.handles('example.com'), isTrue);
      expect(spec.handles('a.b.c.d.example.net'), isTrue);
    });

    test('toNativeScope 原样透传 CSV 与 ECL', () {
      const spec = EchScopeSpec(
        targets: <String>['bgm.tv', 'chii.in'],
        echConfigList: 'AEX+DQBB',
      );
      final map = spec.toNativeScope(verboseLog: true);
      expect(map['targets'], 'bgm.tv,chii.in');
      expect(map['echConfigList'], 'AEX+DQBB');
      expect(map['allowAnyHost'], isFalse);
      expect(map['verboseLog'], isTrue);
    });
  });

  group('computeEchScope 源级 ECH（注入源列表）', () {
    PluginConfig src(String id, String baseUrl, {bool? ech, String ecl = ''}) =>
        PluginConfig.fromJson(<String, dynamic>{
          'id': id,
          'type': 'mangaSource',
          'site': <String, dynamic>{'baseUrl': baseUrl},
          if (ech != null)
            'network': <String, dynamic>{
              'ech': <String, dynamic>{'enabled': ech, 'echConfigList': ecl},
            },
        });

    setUp(() {
      // 隔离：源列表是缓存快照，逐例重置避免相互污染。
      BangumiEchProxy.instance.setSourceConfigs(const <PluginConfig>[]);
    });

    test('打开 ECH 的源按其 baseUrl 域进入作用域，并带上其 ECL', () {
      final proxy = BangumiEchProxy.instance;
      proxy.setSourceConfigs(<PluginConfig>[
        src('a', 'https://a.example.com', ech: true, ecl: 'AEX+DQBB'),
      ]);
      final spec = proxy.computeEchScope();
      expect(spec.handles('a.example.com'), isTrue);
      expect(spec.handles('img.a.example.com'), isTrue);
      expect(spec.handles('b.example.com'), isFalse);
      expect(spec.echConfigList, 'AEX+DQBB');
    });

    test('显式关闭 ECH 的源进排除表（应用级打开也不接管它）', () {
      final proxy = BangumiEchProxy.instance;
      proxy.setSourceConfigs(<PluginConfig>[
        src('a', 'https://a.example.com', ech: false),
      ]);
      final spec = proxy.computeEchScope();
      expect(spec.excluded, contains('a.example.com'));
      expect(spec.handles('a.example.com'), isFalse);
      expect(spec.handles('img.a.example.com'), isFalse);
    });

    test('未声明 network.ech 的源不算显式点名（继承应用级）', () {
      final proxy = BangumiEchProxy.instance;
      proxy.setSourceConfigs(<PluginConfig>[
        src('a', 'https://a.example.com'),
      ]);
      final spec = proxy.computeEchScope();
      expect(spec.targets, isNot(contains('a.example.com')));
      expect(spec.excluded, isEmpty);
      expect(spec.handles('a.example.com'), isFalse);
    });

    test('baseUrl 缺失的源被跳过，不影响其余源', () {
      final proxy = BangumiEchProxy.instance;
      proxy.setSourceConfigs(<PluginConfig>[
        src('bad', '', ech: true),
        src('good', 'https://good.example.com', ech: true),
      ]);
      final spec = proxy.computeEchScope();
      expect(spec.handles('good.example.com'), isTrue);
      expect(spec.targets, contains('good.example.com'));
      expect(spec.excluded, isEmpty);
    });
  });
}

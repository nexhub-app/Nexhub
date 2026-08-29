// SniPolicy 单元测试：匹配优先级、大小写不敏感、后缀通配与免 SNI 哨兵。
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/network/model/network_config.dart';
import 'package:nexhub/core/network/runtime/sni_policy.dart';

SniConfig _cfg({
  bool enabled = true,
  String? defaultSni,
  Map<String, String> domainSni = const {},
}) =>
    SniConfig(
      enabled: enabled,
      defaultSni: defaultSni,
      domainSni: domainSni,
    );

void main() {
  group('SniPolicy.resolve 未启用/未配置', () {
    test('enabled=false 恒返回 null（不覆盖）', () {
      expect(
        SniPolicy.resolve(
          _cfg(enabled: false, defaultSni: 'front.example.com'),
          'a.example.org',
        ),
        isNull,
      );
    });

    test('启用但无任何配置 → null（正常握手）', () {
      expect(SniPolicy.resolve(_cfg(), 'a.example.org'), isNull);
      expect(SniPolicy.resolve(_cfg(defaultSni: ''), 'a.example.org'), isNull);
    });

    test('defaultSni 未命中映射时生效（大小写不敏感）', () {
      expect(
        SniPolicy.resolve(_cfg(defaultSni: 'Front.Example.com'),
            'a.example.org'),
        'Front.Example.com',
      );
    });
  });

  group('SniPolicy.resolve 免 SNI 哨兵', () {
    test("defaultSni='-' → 空串（免 SNI）", () {
      expect(SniPolicy.resolve(_cfg(defaultSni: '-'), 'a.example.org'), '');
    });

    test("domainSni 值 '-' → 空串（免 SNI）", () {
      expect(
        SniPolicy.resolve(
          _cfg(domainSni: {'blocked.example.org': '-'}),
          'blocked.example.org',
        ),
        '',
      );
    });
  });

  group('SniPolicy.resolve 域名映射', () {
    test('精确匹配优先于 defaultSni', () {
      final cfg = _cfg(
        defaultSni: 'front.example.com',
        domainSni: {'a.example.org': 'other.example.net'},
      );
      expect(SniPolicy.resolve(cfg, 'a.example.org'), 'other.example.net');
      expect(SniPolicy.resolve(cfg, 'b.example.org'), 'front.example.com');
    });

    test('键大小写不敏感', () {
      expect(
        SniPolicy.resolve(
          _cfg(domainSni: {'A.Example.ORG': 'x.example.com'}),
          'a.example.org',
        ),
        'x.example.com',
      );
    });

    test('`.` 前缀键按后缀通配（含裸域）', () {
      final cfg = _cfg(
        domainSni: {'.example.org': 'wild.example.com'},
      );
      expect(SniPolicy.resolve(cfg, 'a.example.org'), 'wild.example.com');
      expect(SniPolicy.resolve(cfg, 'x.y.example.org'), 'wild.example.com');
      expect(SniPolicy.resolve(cfg, 'example.org'), 'wild.example.com');
      // 不应误伤以相同字符串结尾的其他域名。
      expect(SniPolicy.resolve(cfg, 'notexample.org'), isNull);
    });

    test('值为空串的映射条目视为无效，继续向后匹配', () {
      final cfg = _cfg(
        defaultSni: 'front.example.com',
        domainSni: {'a.example.org': ''},
      );
      expect(SniPolicy.resolve(cfg, 'a.example.org'), 'front.example.com');
    });
  });

  group('SniPolicy.normalize', () {
    test('空串 → null（无效条目）', () {
      expect(SniPolicy.normalize(''), isNull);
      expect(SniPolicy.normalize('   '), isNull);
    });
    test("'-' → 空串（免 SNI）", () {
      expect(SniPolicy.normalize('-'), '');
      expect(SniPolicy.normalize(' - '), '');
    });
    test('普通值原样返回（去除首尾空白）', () {
      expect(SniPolicy.normalize(' a.example.com '), 'a.example.com');
    });
  });
}

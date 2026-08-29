import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/update/update_manager.dart';

void main() {
  group('UpdateManager.isNewer（SemVer 含预发布段）', () {
    test('核心版本号比较（原有行为保持）', () {
      final m = UpdateManager.instance;
      expect(m.isNewer('v1.2.0', '1.1.0'), isTrue);
      expect(m.isNewer('v1.2.0', '1.2.0'), isFalse);
      expect(m.isNewer('v1.1.0', '1.2.0'), isFalse);
      expect(m.isNewer('v2.0.0-beta.1', '1.2.0'), isTrue);
    });

    test('同核心版本的预发布迭代可被检测到（修复点）', () {
      final m = UpdateManager.instance;
      // 测试版通道：beta.1 → beta.2 旧实现会被判为「已是最新」。
      expect(m.isNewer('v2.0.0-beta.2', '2.0.0-beta.1'), isTrue);
      expect(m.isNewer('v2.0.0-beta.2', '2.0.0-beta.2'), isFalse);
      expect(m.isNewer('v2.0.0-beta.1', '2.0.0-beta.2'), isFalse);
      expect(m.isNewer('v2.0.0-beta.10', '2.0.0-beta.9'), isTrue);
    });

    test('正式版高于同核心版本预发布', () {
      final m = UpdateManager.instance;
      expect(m.isNewer('v2.0.0', '2.0.0-beta.2'), isTrue);
      expect(m.isNewer('v2.0.0-beta.2', '2.0.0'), isFalse);
    });

    test('忽略 build 元数据与前后空白', () {
      final m = UpdateManager.instance;
      expect(m.isNewer('2.0.0-beta.2', '2.0.0-beta.1+30'), isTrue);
      expect(m.isNewer('v2.0.0-beta.1', '2.0.0-beta.1+30'), isFalse);
      expect(m.isNewer(' 2.0.1 ', '2.0.0'), isTrue);
    });

    test('多段预发布标识符（SemVer 规则）', () {
      final m = UpdateManager.instance;
      expect(m.isNewer('1.0.0-alpha.beta.1', '1.0.0-alpha'), isTrue);
      expect(m.isNewer('1.0.0-alpha', '1.0.0-alpha.1'), isFalse);
      expect(m.isNewer('1.0.0-alpha.beta', '1.0.0-beta'), isFalse);
      expect(m.isNewer('1.0.0-rc.1', '1.0.0-beta.11'), isTrue);
    });
  });

  group('UpdateManager.isPrereleaseVersion（alpha/beta/rc 识别）', () {
    test('alpha / beta / rc 均识别为测试版', () {
      expect(UpdateManager.isPrereleaseVersion('v2.1.0-alpha.1'), isTrue);
      expect(UpdateManager.isPrereleaseVersion('v2.1.0-beta.2'), isTrue);
      expect(UpdateManager.isPrereleaseVersion('v2.1.0-rc.1'), isTrue);
      expect(UpdateManager.isPrereleaseVersion('2.1.0-rc.1+30'), isTrue);
    });

    test('正式版与 build 元数据不算测试版', () {
      expect(UpdateManager.isPrereleaseVersion('v2.1.0'), isFalse);
      expect(UpdateManager.isPrereleaseVersion('2.1.0+30'), isFalse);
    });

    test('预发布阶段排序 alpha < beta < rc', () {
      final m = UpdateManager.instance;
      expect(m.isNewer('v2.1.0-rc.1', '2.1.0-alpha.9'), isTrue);
      expect(m.isNewer('v2.1.0-rc.1', '2.1.0-beta.9'), isTrue);
      expect(m.isNewer('v2.1.0-alpha.1', '2.1.0-rc.1'), isFalse);
      // rc 之后到正式版仍可升级。
      expect(m.isNewer('v2.1.0', '2.1.0-rc.1'), isTrue);
    });
  });
}

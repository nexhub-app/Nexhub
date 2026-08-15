/// ConfigLoader 自定义镜像管理单元测试。
///
/// 覆盖 getCustomMirrors / addCustomMirror / removeCustomMirror 的往返逻辑，
/// 使用 Hive 临时目录初始化（不依赖 path_provider）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:nexhub/core/models/plugin_config.dart';
import 'package:nexhub/core/services/config_loader.dart';

void main() {
  setUpAll(() async {
    final dir =
        await Directory.systemTemp.createTemp('config_loader_mirror_test_');
    // 同进程内可能已有其它测试初始化过 Hive；Hive.init 二次调用可能抛错或静默，
    // 包一层避免影响。
    try {
      Hive.init(dir.path);
    } catch (_) {}
    await ConfigLoader.instance.init();
  });

  // 每个测试使用唯一 sourceId，避免单例缓存跨测试污染。

  group('ConfigLoader custom mirrors', () {
    test('getCustomMirrors 对未写入的 sourceId 返回空列表', () {
      expect(
        ConfigLoader.instance.getCustomMirrors('never_used_source'),
        isEmpty,
      );
    });

    test('addCustomMirror 持久化后 getCustomMirrors 返回该镜像', () async {
      const sourceId = 'test_add_source';
      const mirror = MirrorConfig(
        name: 'mirror1',
        domain: 'mirror1.example.com',
        baseUrl: 'https://mirror1.example.com',
      );
      await ConfigLoader.instance.addCustomMirror(sourceId, mirror);
      final result = ConfigLoader.instance.getCustomMirrors(sourceId);
      expect(result, hasLength(1));
      expect(result.first.baseUrl, mirror.baseUrl);
      expect(result.first.name, mirror.name);
      expect(result.first.domain, mirror.domain);
    });

    test('addCustomMirror 按 baseUrl 去重（同 baseUrl 不重复添加）', () async {
      const sourceId = 'test_dedup_source';
      const mirror1 = MirrorConfig(
        name: 'mirror-a',
        domain: 'a.example.com',
        baseUrl: 'https://a.example.com',
      );
      const mirror2 = MirrorConfig(
        name: 'mirror-a-alias',
        domain: 'a.example.com',
        baseUrl: 'https://a.example.com',
      );
      await ConfigLoader.instance.addCustomMirror(sourceId, mirror1);
      await ConfigLoader.instance.addCustomMirror(sourceId, mirror2);
      final result = ConfigLoader.instance.getCustomMirrors(sourceId);
      expect(result, hasLength(1));
    });

    test('removeCustomMirror 按 baseUrl 删除指定镜像', () async {
      const sourceId = 'test_remove_source';
      const m1 = MirrorConfig(
        name: 'keep',
        domain: 'keep.example.com',
        baseUrl: 'https://keep.example.com',
      );
      const m2 = MirrorConfig(
        name: 'delete',
        domain: 'del.example.com',
        baseUrl: 'https://del.example.com',
      );
      await ConfigLoader.instance.addCustomMirror(sourceId, m1);
      await ConfigLoader.instance.addCustomMirror(sourceId, m2);
      expect(ConfigLoader.instance.getCustomMirrors(sourceId), hasLength(2));

      await ConfigLoader.instance.removeCustomMirror(sourceId, m2.baseUrl);
      final result = ConfigLoader.instance.getCustomMirrors(sourceId);
      expect(result, hasLength(1));
      expect(result.first.baseUrl, m1.baseUrl);
    });

    test('removeCustomMirror 对不存在的 baseUrl 为空操作', () async {
      const sourceId = 'test_remove_noop_source';
      const m1 = MirrorConfig(
        name: 'mirror',
        domain: 'x.example.com',
        baseUrl: 'https://x.example.com',
      );
      await ConfigLoader.instance.addCustomMirror(sourceId, m1);
      await ConfigLoader.instance.removeCustomMirror(
        sourceId,
        'https://nonexistent.example.com',
      );
      expect(ConfigLoader.instance.getCustomMirrors(sourceId), hasLength(1));
    });

    test('多源隔离：不同 sourceId 互不干扰', () async {
      const sourceA = 'test_isolation_a';
      const sourceB = 'test_isolation_b';
      const mA = MirrorConfig(
        name: 'mirror-a',
        domain: 'a.example.com',
        baseUrl: 'https://a.example.com',
      );
      const mB = MirrorConfig(
        name: 'mirror-b',
        domain: 'b.example.com',
        baseUrl: 'https://b.example.com',
      );
      await ConfigLoader.instance.addCustomMirror(sourceA, mA);
      await ConfigLoader.instance.addCustomMirror(sourceB, mB);

      final resultA = ConfigLoader.instance.getCustomMirrors(sourceA);
      final resultB = ConfigLoader.instance.getCustomMirrors(sourceB);
      expect(resultA, hasLength(1));
      expect(resultB, hasLength(1));
      expect(resultA.first.baseUrl, mA.baseUrl);
      expect(resultB.first.baseUrl, mB.baseUrl);
    });

    test('持久化往返：数据确实写入 Hive box（非仅内存缓存）', () async {
      const sourceId = 'test_persist_source';
      const mirror = MirrorConfig(
        name: 'persist',
        domain: 'persist.example.com',
        baseUrl: 'https://persist.example.com',
      );
      await ConfigLoader.instance.addCustomMirror(sourceId, mirror);

      // 直接从 Hive box 读取原始值，验证确实持久化。
      final box = Hive.box<dynamic>(ConfigLoader.customMirrorsBoxName);
      final raw = box.get(sourceId);
      expect(raw, isA<String>());
      expect(raw as String, contains('persist.example.com'));
    });

    test('多条镜像追加后按写入顺序返回', () async {
      const sourceId = 'test_order_source';
      const m1 = MirrorConfig(
        name: 'first',
        domain: 'first.example.com',
        baseUrl: 'https://first.example.com',
      );
      const m2 = MirrorConfig(
        name: 'second',
        domain: 'second.example.com',
        baseUrl: 'https://second.example.com',
      );
      const m3 = MirrorConfig(
        name: 'third',
        domain: 'third.example.com',
        baseUrl: 'https://third.example.com',
      );
      await ConfigLoader.instance.addCustomMirror(sourceId, m1);
      await ConfigLoader.instance.addCustomMirror(sourceId, m2);
      await ConfigLoader.instance.addCustomMirror(sourceId, m3);

      final result = ConfigLoader.instance.getCustomMirrors(sourceId);
      expect(result, hasLength(3));
      expect(result[0].baseUrl, m1.baseUrl);
      expect(result[1].baseUrl, m2.baseUrl);
      expect(result[2].baseUrl, m3.baseUrl);
    });
  });
}

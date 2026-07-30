/// CookieStore 单元测试：save/get/TTL 过期/load/clear。
///
/// 不依赖 path_provider，直接用 `Hive.init(临时目录)` 初始化（与运行期
/// `Hive.initFlutter` 是同一个 Hive 单例）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:nexhub/core/scraper/cookie_store.dart';

void main() {
  setUpAll(() async {
    final dir = await Directory.systemTemp.createTemp('cookie_store_test_');
    // 同进程内可能已有其它测试（如 novel_reader_test）初始化过 Hive；
    // Hive.init 二次调用或抛错或静默返回，包一层避免影响。
    try {
      Hive.init(dir.path);
    } catch (_) {}
    await CookieStore.init();
  });

  tearDown(() async {
    await CookieStore.clear();
  });

  // 注意：不在此全局 Hive.close()，避免同进程内其它依赖 Hive 的测试受影响。

  test('save 后 get 返回存入的 cookie 与 ua', () async {
    await CookieStore.save('example.com', 'a=1; b=2', 'Mozilla/5.0');
    final rec = await CookieStore.get('example.com');
    expect(rec, isNotNull);
    expect(rec!['cookie'], 'a=1; b=2');
    expect(rec['ua'], 'Mozilla/5.0');
  });

  test('load 返回所有未过期 host -> cookie 的映射', () async {
    await CookieStore.save('a.com', 'x=1', 'UA-A');
    await CookieStore.save('b.com', 'y=2', 'UA-B');
    final map = await CookieStore.load();
    expect(map['a.com'], 'x=1');
    expect(map['b.com'], 'y=2');
  });

  test('超过 TTL 的条目视为不存在', () async {
    // 手动写入一个 8 天前的记录（远超 7 天 TTL）。
    final box = Hive.box('http_cookies');
    await box.put('expired.com', <String, String>{
      'cookie': 'old=1',
      'ua': 'UA-old',
      'updatedAt':
          DateTime.now().subtract(const Duration(days: 8)).toIso8601String(),
    });
    expect(await CookieStore.get('expired.com'), isNull);
    expect((await CookieStore.load())['expired.com'], isNull);
  });

  test('clear 移除所有条目', () async {
    await CookieStore.save('c.com', 'z=9', 'UA-C');
    await CookieStore.clear();
    expect(await CookieStore.get('c.com'), isNull);
    expect(await CookieStore.load(), isEmpty);
  });
}

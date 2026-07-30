/// 持久化 Cookie 存储：把各 host 的会话 Cookie（含该 host 当时使用的 UA）落盘，
/// 避免「每次冷启动都重新过验证」导致高频请求 → IP 被封。
///
/// 反爬会话通常绑定 UA+IP+Cookie，故持久化时一并存 UA，回灌时若 UA 漂移会失效，
/// 上层应保证全链路 UA 一致（见 [HttpFetcher.userAgentForUrl]）。
library;

import 'package:hive_flutter/hive_flutter.dart';

/// 各 host 会话 Cookie 的持久化层（Hive box `http_cookies`）。
///
/// 每条记录结构：`{cookie: <Cookie 头字符串>, ua: <该 host 当时 UA>,
/// updatedAt: <ISO8601 时间戳>}`。记录超过 [ttl] 视为无效（避免长期陈旧会话）。
class CookieStore {
  static const String _boxName = 'http_cookies';

  /// Cookie 有效期：超过 7 天未更新的会话视为失效，重新过验证。
  static const Duration ttl = Duration(days: 7);

  static Box? _box;

  /// 初始化 Hive box（须在 `Hive.initFlutter` 之后调用，通常在 SplashScreen）。
  static Future<void> init() async {
    if (_box != null && _box!.isOpen) return;
    _box = await Hive.openBox(_boxName);
  }

  static Future<void> _ensureOpen() async {
    if (_box == null || !_box!.isOpen) {
      await init();
    }
  }

  static bool _isExpired(Map<dynamic, dynamic> rec) {
    final ts = rec['updatedAt'];
    if (ts == null) return true;
    final dt = DateTime.tryParse(ts.toString());
    if (dt == null) return true;
    return DateTime.now().difference(dt) > ttl;
  }

  /// 读取所有未过期的 `host -> cookie 头`，供 [HttpFetcher] 回填内存 jar。
  static Future<Map<String, String>> load() async {
    await _ensureOpen();
    final out = <String, String>{};
    for (final key in _box!.keys) {
      final rec = _box!.get(key);
      if (rec is Map && !_isExpired(rec)) {
        final cookie = rec['cookie'];
        if (cookie is String && cookie.isNotEmpty) {
          out[key.toString()] = cookie;
        }
      }
    }
    return out;
  }

  /// 持久化单个 host 的 cookie 与该 host 当时 UA（UA 配套验证回灌，防漂移）。
  static Future<void> save(String host, String cookie, String ua) async {
    await _ensureOpen();
    await _box!.put(host, <String, String>{
      'cookie': cookie,
      'ua': ua,
      'updatedAt': DateTime.now().toIso8601String(),
    });
  }

  /// 读取单个 host 记录（含 cookie/ua/updatedAt），过期返回 null。
  static Future<Map<String, String>?> get(String host) async {
    await _ensureOpen();
    final rec = _box!.get(host);
    if (rec is Map && !_isExpired(rec)) {
      return Map<String, String>.from(rec);
    }
    return null;
  }

  static Future<void> clear() async {
    await _ensureOpen();
    await _box!.clear();
  }
}

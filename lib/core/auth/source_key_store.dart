/// 按源隔离的手动密钥持久化（Hive box `source_keys`）。
///
/// 用途：部分源（如 nhentai 的 v2 API）的受保护请求不认 Cookie / Bearer，
/// 而是要求用户在站点账户设置页手动获取的 API Key，并以
/// `Authorization: Key <api_key>` 形式附加。该 Key 不在登录 Cookie 里、
/// WebView 登录也拿不到，只能由用户粘贴，故需要一个按源持久化的键值仓库。
///
/// 设计原则（「源即插件」）：本类只提供通用存储能力，**不写死任何站点逻辑**；
/// 某个源是否需要 API Key、用何种头前缀，完全由源 JSON 的 `comments.login`
/// 声明驱动（见 [CommentsLoginConfig]）。
library;

import 'package:hive/hive.dart';

/// 按源存储手动密钥（如 API Key）。key 形如 `<sourceId>:<param>`。
class SourceKeyStore {
  /// 持久化 box 名（已在 [kStorageBoxNames] 注册，splash 冷启动与云同步自动覆盖）。
  static const String boxName = 'source_keys';

  static Box? _box;

  /// 取 box：splash 已按 [kStorageBoxNames] 打开；此处做安全兜底
  /// （未打开时返回 null，调用方降级为「无密钥」）。
  static Box? get _safeBox {
    try {
      _box ??= Hive.isBoxOpen(boxName) ? Hive.box(boxName) : null;
    } on Object {
      _box = null;
    }
    return _box;
  }

  static String _fullKey(String sourceId, String param) => '$sourceId:$param';

  /// 读取某源某个参数对应的手动密钥；不存在/未开 box 时返回 null。
  static String? get(String sourceId, String param) {
    final box = _safeBox;
    if (box == null) return null;
    final v = box.get(_fullKey(sourceId, param));
    return v is String && v.isNotEmpty ? v : null;
  }

  /// 写入某源某个参数的手动密钥（空值视为清除）。
  static Future<void> set(String sourceId, String param, String value) async {
    final box = _safeBox;
    if (box == null) return;
    final key = _fullKey(sourceId, param);
    if (value.isEmpty) {
      await box.delete(key);
    } else {
      await box.put(key, value);
    }
  }

  /// 清除某源某个参数的手动密钥。
  static Future<void> clear(String sourceId, String param) async {
    final box = _safeBox;
    if (box == null) return;
    await box.delete(_fullKey(sourceId, param));
  }
}

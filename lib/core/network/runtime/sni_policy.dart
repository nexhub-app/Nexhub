/// SNI 覆盖策略：把 [SniConfig] 解析成单个 host 的 TLS SNI 取值。
///
/// Dart 的 `SecureSocket.secure(host:)` 同时决定 SNI 与证书校验名；把 host 传成
/// IP 字面量时引擎不会发送 server_name 扩展（免 SNI）。据此约定：
///
/// - SNI 值为普通域名 → 以该域名作 SNI（TCP 仍连真实目标 IP）；
/// - SNI 值为 `-`（[noSniToken]）→ 免 SNI：握手不携带 server_name 扩展；
/// - 未命中任何规则 → 正常握手（SNI = 请求域名）。
///
/// 典型用途：对被「SNI 阻断」的站点配合自定义 Hosts（钉 Cloudflare 边缘 IP）+
/// 免 SNI / 自定义 SNI 完成握手（Cloudflare 边缘接受无 SNI 握手并按 Host 头路由）。
///
/// 返回值语义：`null` = 不覆盖；空串 = 免 SNI；非空 = 以该值作 SNI。
library;

import '../model/network_config.dart';

/// SNI 覆盖策略（无状态，纯静态方法）。
class SniPolicy {
  const SniPolicy._();

  /// 「免 SNI」哨兵值：配置里填 `-` 表示握手时不发送 server_name。
  static const String noSniToken = '-';

  /// 解析 [host] 应使用的 SNI。返回 `null` 表示不覆盖（正常握手）。
  ///
  /// 匹配规则：
  /// 1. [SniConfig.domainSni] 键大小写不敏感；键以 `.` 开头时匹配「以此结尾的
  ///    子域」（如键 `.example.org` 命中 `a.example.org`）；
  /// 2. 未命中 → [SniConfig.defaultSni]；
  /// 3. [SniConfig.enabled] 为 false 时恒返回 null。
  static String? resolve(SniConfig sni, String host) {
    if (!sni.enabled) return null;
    final h = host.trim().toLowerCase();
    if (h.isEmpty) return null;
    for (final entry in sni.domainSni.entries) {
      final key = entry.key.trim().toLowerCase();
      if (key.isEmpty) continue;
      final matched = key.startsWith('.')
          ? (h.endsWith(key) || h == key.substring(1))
          : (key == h);
      if (matched) {
        final v = normalize(entry.value);
        if (v != null) return v;
      }
    }
    final d = sni.defaultSni?.trim() ?? '';
    if (d.isEmpty) return null;
    return normalize(d);
  }

  /// 归一化配置值：空串视为无效条目（返回 null 忽略）；`-` 免 SNI（空串）。
  static String? normalize(String raw) {
    final v = raw.trim();
    if (v.isEmpty) return null;
    if (v == noSniToken) return '';
    return v;
  }
}

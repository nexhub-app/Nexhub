/// 网络配置校验器：纯函数集合，返回错误消息 key 列表（供 l10n 显示）。
///
/// 全局 UI、源级 UI、源文件解析三处共用同一套校验，保证一致性。
/// 约定：返回空列表表示校验通过；非空则每项为一个本地化 key
/// （UI 侧用 `AppLocalizations` 映射为文案）。
library;

/// 网络配置校验器（无状态，纯静态方法）。
class NetworkValidators {
  const NetworkValidators._();

  /// 校验 IPv4 地址。
  static bool isIpv4(String value) {
    final parts = value.split('.');
    if (parts.length != 4) return false;
    for (final p in parts) {
      if (p.isEmpty || p.length > 3) return false;
      final n = int.tryParse(p);
      if (n == null || n < 0 || n > 255) return false;
      // 禁止前导零（如 01）。
      if (p.length > 1 && p[0] == '0') return false;
    }
    return true;
  }

  /// 校验 IPv6 地址（宽松：含 `:`，允许 `::` 压缩与内嵌 IPv4）。
  static bool isIpv6(String value) {
    if (!value.contains(':')) return false;
    // 拒绝多于一个 `::`。
    final doubleColon = '::'.allMatches(value).length;
    if (doubleColon > 1) return false;
    final hextetRe = RegExp(r'^[0-9a-fA-F]{1,4}$');
    // 去掉可能的 zone id（%eth0）。
    final core = value.split('%').first;
    final groups = core.split(':');
    for (final g in groups) {
      if (g.isEmpty) continue; // `::` 产生的空段
      if (g.contains('.')) {
        if (!isIpv4(g)) return false; // 内嵌 IPv4
        continue;
      }
      if (!hextetRe.hasMatch(g)) return false;
    }
    return true;
  }

  /// 校验 IP 地址（v4 或 v6）。
  static bool isIpAddress(String value) =>
      isIpv4(value.trim()) || isIpv6(value.trim());

  /// 校验端口号（1–65535）。
  static bool isPort(int port) => port >= 1 && port <= 65535;

  /// 校验端口字符串。
  static bool isPortString(String value) {
    final n = int.tryParse(value.trim());
    return n != null && isPort(n);
  }

  /// 校验 https URL（DoH 端点必须 https）。
  static bool isHttpsUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host.isNotEmpty;
  }

  /// 校验域名格式（RFC 1123 宽松版：标签 1–63 字符，字母数字与连字符）。
  static bool isDomain(String value) {
    final v = value.trim();
    if (v.isEmpty || v.length > 253) return false;
    final labelRe =
        RegExp(r'^(?!-)[A-Za-z0-9-]{1,63}(?<!-)$');
    final labels = v.split('.');
    if (labels.length < 2) return false;
    for (final label in labels) {
      if (!labelRe.hasMatch(label)) return false;
    }
    return true;
  }

  /// 校验主机名（域名或 IP 均可，用于 DoT host / hosts 条目 host）。
  static bool isHostname(String value) =>
      isDomain(value) || isIpAddress(value);

  // ---- 组合校验：返回错误 key 列表 ----

  /// 校验代理配置（仅 manual 模式需 host/port）。
  /// [mode] 传入枚举 name，避免本文件依赖 model 层。
  static List<String> validateProxy({
    required String mode,
    required String host,
    required String portText,
  }) {
    final errors = <String>[];
    if (mode != 'manual') return errors;
    if (host.trim().isEmpty || !isHostname(host)) {
      errors.add('networkErrorInvalidHost');
    }
    if (!isPortString(portText)) {
      errors.add('networkErrorInvalidPort');
    }
    return errors;
  }

  /// 校验单条 hosts 条目。
  static List<String> validateHostsEntry({
    required String ip,
    required String host,
  }) {
    final errors = <String>[];
    if (!isIpAddress(ip)) errors.add('networkErrorInvalidIp');
    if (!isDomain(host)) errors.add('networkErrorInvalidDomain');
    return errors;
  }

  /// 校验 DNS 服务器地址（IP）。
  static List<String> validateDnsServer(String value) {
    if (!isIpAddress(value)) return <String>['networkErrorInvalidIp'];
    return const <String>[];
  }

  /// 校验 DoH URL。
  static List<String> validateDohUrl(String value) {
    if (!isHttpsUrl(value)) return <String>['networkErrorInvalidDohUrl'];
    return const <String>[];
  }

  /// 校验 DoT host + port。
  static List<String> validateDot({
    required String host,
    required String portText,
  }) {
    final errors = <String>[];
    if (!isHostname(host)) errors.add('networkErrorInvalidHost');
    if (!isPortString(portText)) errors.add('networkErrorInvalidPort');
    return errors;
  }

  /// 校验单条 SNI 域名映射：host 为域名（允许 `.` 前缀的子域通配），
  /// 值为域名或 `-`（免 SNI 哨兵）。
  static List<String> validateSniEntry({
    required String host,
    required String value,
  }) {
    final errors = <String>[];
    final h = host.trim();
    if (h.startsWith('.')) {
      if (!isDomain(h.substring(1))) errors.add('networkErrorInvalidDomain');
    } else if (!isDomain(h)) {
      errors.add('networkErrorInvalidDomain');
    }
    final v = value.trim();
    if (v != '-' && !isDomain(v)) errors.add('networkErrorInvalidDomain');
    return errors;
  }

  /// 校验 SNI 值（默认值 / 映射值）：域名的或 `-`（免 SNI）或空。
  static List<String> validateSniValue(String value) {
    final v = value.trim();
    if (v.isEmpty) return const <String>[];
    if (v != '-' && !isDomain(v)) return <String>['networkErrorInvalidDomain'];
    return const <String>[];
  }

  /// 校验 DNS 解析后缀：空表示不启用；非空须以 `.` 开头且余下为合法域名。
  ///
  /// 用途：解析时把 `目标主机 + 后缀` 交给 DNS，让每台设备用自己的 DNS
  /// 拿到就近可用的地址，配置文件里不需要写死任何 IP。
  static List<String> validateResolveSuffix(String value) {
    final v = value.trim();
    if (v.isEmpty) return const <String>[];
    if (!v.startsWith('.') || !isDomain(v.substring(1))) {
      return <String>['networkErrorInvalidDomain'];
    }
    return const <String>[];
  }

  /// 校验解析后缀的作用域条目：域名，或以 `.` 开头的子域通配。
  static List<String> validateResolveSuffixDomain(String value) {
    final v = value.trim();
    if (v.isEmpty) return const <String>[];
    final core = v.startsWith('.') ? v.substring(1) : v;
    if (!isDomain(core)) return <String>['networkErrorInvalidDomain'];
    return const <String>[];
  }
}

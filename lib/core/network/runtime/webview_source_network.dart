/// 让源自带的 WebView（flutter_inappwebview）也跟随源的「网络覆盖」配置。
///
/// 背景：WebView 走系统 WebView 网络栈，默认不读源的 `network` 块
/// （hosts / DoH / 手动代理）。而引擎自带 HttpClient 已通过
/// [DnsResolver] 按源 profile 解析（见 [NetworkClientBuilder]）。本文件补齐
/// WebView 一侧：起一个本地正向代理，把命中源域名的 WebView 流量经
/// [DnsResolver] 解析（hosts 优先、回退 DoH、再回退系统），从而绕开 DNS 污染。
///
/// 接线：Android 侧经 `ProxyController.setProxyOverride` + PAC 把源域名导到本地
/// 代理（API 28+）。Windows 侧 WebView2 不支持运行期 ProxyController，改为
/// 创建带 `--proxy-server` 启动参数的 WebView2 环境（[WebViewEnvironment]）：
/// hosts/DoH 模式全量指向本地正向代理（非源域名由代理按系统 DNS 回退），
/// 手动代理模式直指用户代理。不同启动参数必须配不同 `userDataFolder`
/// （WebView2 共享浏览器进程按 options 匹配，不匹配 → ERROR_INVALID_STATE）。
/// 本文件只做配置驱动的逻辑，不写死任何站点。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';

import '../../models/plugin_config.dart';
import '../model/network_config.dart';
import 'dns_resolver.dart';
import '../network_config_service.dart';

/// 源 WebView 网络跟随桥（进程内单例）。
///
/// 用法：打开源 WebView 前调用 [applyForSource]，关闭后调用 [releaseForSource]。
/// 多次 apply 以引用计数共享同一本地代理与 ProxyController 覆盖。
class WebviewSourceNetwork {
  WebviewSourceNetwork._();
  static final WebviewSourceNetwork instance = WebviewSourceNetwork._();

  static const MethodChannel _channel =
      MethodChannel('nexhub/webview_proxy');

  HttpServer? _server;
  int _port = 0;
  int _refCount = 0;

  // Windows：带启动参数的 WebView2 环境缓存（key=完整启动参数串）与当前生效环境。
  final Map<String, WebViewEnvironment> _windowsEnvs =
      <String, WebViewEnvironment>{};
  WebViewEnvironment? _activeEnv;

  /// 当前 WebView 窗口（apply/release 之间）应使用的 WebView2 环境。
  ///
  /// 仅 Windows 且本次 apply 成功创建/复用代理环境时非空；窗口外恒为 null
  /// （WebView 构造点不传 env → 平台默认环境，行为与改动前一致）。
  WebViewEnvironment? get activeEnvironment =>
      _refCount > 0 ? _activeEnv : null;

  // 当前生效的源 DNS 配置（供本地代理解析使用）。
  DnsConfig? _dns;
  List<HostsEntry>? _hosts;
  String? _pacContent;

  /// 当前持有跟随的源 id（首个 apply 的源）。
  String? _currentSourceId;

  /// 打开源 WebView 前调用：若该源声明了 hosts/DoH/手动代理，则让 WebView 跟随。
  ///
  /// [source] 为 null 时直接返回（无网络覆盖可应用）。
  ///
  /// 叠加语义（先到先得）：已有跟随在生效时不再重建 PAC/代理——异源抢占会
  /// 换掉共享本地代理的解析配置，打断正在使用的其它源 WebView；同源重复
  /// apply 也无需重建（配置幂等）。仍递增引用计数保证 apply/release 严格
  /// 配对，全部 release 后下次 apply 重新生效。
  Future<void> applyForSource(PluginConfig? source) async {
    if (source == null) return;
    if (_refCount > 0) {
      if (_currentSourceId != source.id) {
        debugPrint(
            'WebviewSourceNetwork: source ${source.id} skipped, '
            'follow $_currentSourceId active');
      }
      _refCount++;
      return;
    }
    _currentSourceId = source.id;
    try {
      final profile = NetworkConfigService.instance.effectiveFor(source);
    final hasCustomDns =
        profile.hosts.isNotEmpty || profile.needsCustomConnection;
    final manualProxy = profile.proxy.mode == ProxyMode.manual &&
        profile.proxy.host.isNotEmpty &&
        profile.proxy.port > 0;
    if (!hasCustomDns && !manualProxy) return;

    // 手动代理模式：直接让 ProxyController 走该代理，无需本地代理。
    if (!hasCustomDns && manualProxy) {
      final proxyUrl = profile.proxy.protocol == ProxyProtocol.socks5
          ? 'SOCKS ${profile.proxy.host}:${profile.proxy.port}'
          : 'PROXY ${profile.proxy.host}:${profile.proxy.port}';
      final ok = await _setProxy(proxyUrl: proxyUrl);
      if (ok) {
        _refCount++;
      } else {
        // Windows 等 ProxyController 不可用平台：WebView2 用 --proxy-server
        // 启动参数直指用户代理（socks5 → socks5:// 前缀）。（该分支 hosts 必空：
        // hasCustomDns 含 hosts 非空判定，故无需 resolver-rules。）
        final env = await _ensureWindowsEnv(windowsBrowserArgs(
          proxyArg: windowsProxyServerArg(
            profile.proxy.host,
            profile.proxy.port,
            socks5: profile.proxy.protocol == ProxyProtocol.socks5,
          ),
        ));
        if (env != null) {
          _refCount++;
        } else {
          debugPrint(
              'WebviewSourceNetwork: WebView2 env unavailable, WebView 未跟随源代理'
              '（后续诊断看 env create failed 行）');
        }
      }
      return;
    }

    // hosts / DoH 模式：起本地代理 + PAC 把源域名导到本地代理。
    await _ensureStarted();
    _dns = profile.dns;
    _hosts = profile.hosts;

    final hostnames = <String>{};
    for (final h in profile.hosts) {
      if (h.enabled && h.host.isNotEmpty) hostnames.add(h.host.toLowerCase());
    }
    final site = source.site;
    if (site.domain.isNotEmpty) hostnames.add(site.domain.toLowerCase());
    for (final m in site.mirrors) {
      if (m.domain.isNotEmpty) hostnames.add(m.domain.toLowerCase());
    }
    _pacContent = _buildPac(hostnames, _port);

    final ok = await _setProxy(
      pacUrl: 'pac+http://127.0.0.1:$_port/proxy.pac',
    );
    if (ok) {
      _refCount++;
    } else {
      // Windows 等 ProxyController 不可用平台：双通路——①WebView2 全量指向
      // 本地正向代理（不用 PAC-URL——WebView2 对 PAC 的拉取行为不稳；本地代理
      // 按 hosts→DoH→系统回退解析，语义与 Android PAC 一致）。代理常驻保证
      // 端口稳定。②--host-resolver-rules 直接把源域 MAP 到 hosts IP：即便
      // 代理线程挂掉，DIRECT 流量也能按 hosts 正确解析（Chromium 通用参数）。
      final env = await _ensureWindowsEnv(windowsBrowserArgs(
        proxyArg: '127.0.0.1:$_port',
        hostMaps: hostResolverRules(profile.hosts),
      ));
      if (env != null) {
        _refCount++;
      } else {
        debugPrint(
            'WebviewSourceNetwork: WebView2 env unavailable, WebView 未跟随源 hosts'
            '（后续诊断看 env create failed 行）');
      }
    }
    } on Object catch (e) {
      // 网络跟随是 best-effort：任何失败都不应阻断验证 WebView 打开。
      debugPrint('WebviewSourceNetwork.applyForSource failed: $e');
    }
  }

  /// 关闭源 WebView 后调用：引用归零时清除 ProxyController 覆盖并停代理。
  ///
  /// Windows 下本地代理与 WebView2 环境**常驻**（仅摘除 activeEnvironment）：
  /// 环境销毁/重建会连带浏览器进程重启，且停代理会换端口使已缓存环境失效。
  Future<void> releaseForSource() async {
    if (_refCount <= 0) return;
    _refCount--;
    if (_refCount > 0) return;
    _activeEnv = null;
    try {
      await _clearProxy();
      if (!Platform.isWindows) await _stop();
    } on Object catch (e) {
      debugPrint('WebviewSourceNetwork.releaseForSource failed: $e');
    }
    _dns = null;
    _hosts = null;
    _pacContent = null;
    _currentSourceId = null;
  }

  // ---- Windows WebView2 环境（--proxy-server 启动参数）----

  /// 取（或创建）绑定 [browserArgs]（完整 Chromium 启动参数串）的 WebView2 环境。
  ///
  /// 命中缓存直接复用；否则在应用支持目录下按参数哈希建独立 userDataFolder
  /// （WebView2 共享浏览器进程按启动选项匹配，不同参数共用目录 →
  /// ERROR_INVALID_STATE）。失败 debugPrint 回传 null（best-effort，同
  /// Android 侧 MissingPluginException 语义），不阻断 WebView 打开。
  Future<WebViewEnvironment?> _ensureWindowsEnv(String browserArgs) async {
    if (!Platform.isWindows) return null;
    final cached = _windowsEnvs[browserArgs];
    if (cached != null) {
      _activeEnv = cached;
      return cached;
    }
    try {
      final supportDir = await getApplicationSupportDirectory();
      final folder =
          '${supportDir.path}${Platform.pathSeparator}webview2-${stableHash(browserArgs)}';
      final env = await WebViewEnvironment.create(
        settings: WebViewEnvironmentSettings(
          additionalBrowserArguments: browserArgs,
          userDataFolder: folder,
        ),
      );
      _windowsEnvs[browserArgs] = env;
      _activeEnv = env;
      debugPrint(
          'WebviewSourceNetwork: WebView2 env ready args=$browserArgs userDataFolder=$folder');
      return env;
    } on Object catch (e) {
      debugPrint('WebviewSourceNetwork: WebView2 env create failed: $e');
      return null;
    }
  }

  /// 组装 Windows WebView2 启动参数串（纯函数）。
  ///
  /// `[proxyArg]`：`--proxy-server` 值（可空——hosts 直连模式不需要代理）。
  /// `[hostMaps]`：`--host-resolver-rules` 的 `MAP host ip` 映射（可空）。两条
  /// 通路并存：代理是全量转发兜底，resolver-rules 让 Chromium DNS 直接按 hosts
  /// 解析——即便代理挂掉，DIRECT 流量也能命中正确服务器。
  /// 同输入恒同输出（MAP 项由调用方保证去重排序），保证缓存 key 稳定复用。
  static String windowsBrowserArgs({
    String? proxyArg,
    List<String> hostMaps = const <String>[],
  }) {
    final parts = <String>[];
    if (proxyArg != null && proxyArg.isNotEmpty) {
      parts.add('--proxy-server=$proxyArg');
    }
    if (hostMaps.isNotEmpty) {
      // --host-resolver-rules 语法：多条规则逗号连接，规则内部以空格分词
      // （MAP host ip / EXCLUDE host）。整段值含空格必须整体加引号：WebView2
      // 把 additionalBrowserArguments 原样追加进浏览器命令行，不引号会被
      // Chromium 按空格切碎（开关值只剩 'MAP'）→ 规则全部失效，WebView 直接
      // 用系统 DNS 解析命中污染 IP（Windows DIRECT 兜底从未真正生效的根因）。
      parts.add('--host-resolver-rules="${hostMaps.join(',')},EXCLUDE localhost"');
    }
    return parts.join(' ');
  }

  /// 由 hosts 配置生成 `MAP host ip` 规则列表（纯函数，确定性排序）。
  ///
  /// 仅取 enabled 且 host/ip 均非空的条目；host 统一小写去重，同一 host 多 IP
  /// 时取第一个（Chromium resolver-rules 每域只接受一条 MAP）。
  static List<String> hostResolverRules(List<HostsEntry> hosts) {
    final byHost = <String, String>{};
    for (final h in hosts) {
      if (!h.enabled || h.host.isEmpty || h.ip.isEmpty) continue;
      byHost.putIfAbsent(h.host.toLowerCase(), () => h.ip.trim());
    }
    final keys = byHost.keys.toList()..sort();
    return [for (final k in keys) 'MAP $k ${byHost[k]}'];
  }

  /// Windows WebView2 `--proxy-server` 参数值（纯函数）。
  ///
  /// WebView2 原生接受 `host:port` 与 `socks5://host:port` 形态；socks5 不带
  /// scheme 会被当作 HTTP 代理静默失败，故必须显式前缀。
  static String windowsProxyServerArg(
    String host,
    int port, {
    bool socks5 = false,
  }) =>
      socks5 ? 'socks5://$host:$port' : '$host:$port';

  /// FNV-1a 32 位哈希（十六进制）：为启动参数派生跨重启稳定的目录名。
  static String stableHash(String input) {
    var h = 0x811c9dc5;
    for (final unit in input.codeUnits) {
      h ^= unit & 0xff;
      h = (h * 0x01000193) & 0xFFFFFFFF;
      h ^= unit >> 8;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }

  // ---- 本地正向代理 ----

  Future<void> _ensureStarted() async {
    if (_server != null) return;
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _port = _server!.port;
    _server!.listen(_onRequest);
  }

  Future<void> _stop() async {
    await _server?.close(force: true);
    _server = null;
    _port = 0;
  }

  Future<void> _onRequest(HttpRequest request) async {
    // 提供 PAC 脚本（ProxyController 经 http 拉取）。
    if (request.method == 'GET' &&
        request.uri.path == '/proxy.pac' &&
        _pacContent != null) {
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType('application', 'x-ns-proxy-autoconfig')
        ..write(_pacContent!);
      await request.response.close();
      return;
    }

    if (request.method == 'CONNECT') {
      await _tunnel(request, 443);
    } else {
      await _forward(request);
    }
  }

  /// HTTPS 隧道：CONNECT host:port → 解析 IP → 直连 → 双向透传。
  Future<void> _tunnel(HttpRequest request, int defaultPort) async {
    // dart:io 对 CONNECT 的 uri 解析在不同版本可能落在 authority 或 host/port，
    // 这里两者都兼容。
    final uri = request.uri;
    final authority = uri.authority;
    final host = uri.host.isNotEmpty
        ? uri.host
        : (authority.contains(':')
            ? authority.substring(0, authority.lastIndexOf(':'))
            : authority);
    final port = uri.port != 0
        ? uri.port
        : (authority.contains(':')
            ? int.tryParse(authority.substring(authority.lastIndexOf(':') + 1)) ??
                defaultPort
            : defaultPort);
    try {
      final addresses = await _resolveAddresses(host);
      final targetSocket =
          await _connectFirstReachable(host, port, addresses);
      // 直接 detach：detachSocket(writeHeaders:true) 会把已设的 200 状态行写给
      // 客户端。注意不能先 close() 再 detach —— 那样会抛 StateError（dart:io 已
      // 接管 socket），导致 HTTPS 隧道建立失败。
      request.response.statusCode = 200;
      request.response.reasonPhrase = 'Connection Established';
      request.response.headers.clear();
      final clientSocket = await request.response.detachSocket();
      _pipe(clientSocket, targetSocket);
    } on Object catch (e) {
      debugPrint('WebviewProxy tunnel($host:$port) failed: $e');
      try {
        request.response.statusCode = 502;
        await request.response.close();
      } on Object {
        // 已 detached 或关闭，忽略。
      }
    }
  }

  /// 明文 HTTP 代理：重写请求行到解析后的 IP，双向透传原始字节。
  Future<void> _forward(HttpRequest request) async {
    final uri = request.uri;
    final host = uri.host;
    final port = uri.port == 0 ? 80 : uri.port;
    try {
      final addresses = await _resolveAddresses(host);
      final targetSocket =
          await _connectFirstReachable(host, port, addresses);
      // 重写请求行为绝对路径（去掉 scheme+host），Host 头保留原域名（SNI 等价）。
      final path = uri.path.isEmpty ? '/' : uri.path;
      final raw = StringBuffer()
        ..write('${request.method} $path${uri.query.isNotEmpty ? '?${uri.query}' : ''} ${request.protocolVersion}\r\n');
      request.headers.forEach((name, values) {
        for (final v in values) raw.writeln('$name: $v');
      });
      raw.writeln();
      targetSocket.add(utf8.encode(raw.toString()));
      final clientSocket = await request.response.detachSocket(writeHeaders: false);
      _pipe(clientSocket, targetSocket);
    } on Object catch (e) {
      debugPrint('WebviewProxy forward($host:$port) failed: $e');
      try {
        request.response.statusCode = 502;
        await request.response.close();
      } on Object {
        // 忽略。
      }
    }
  }

  Future<List<InternetAddress>> _resolveAddresses(String host) async {
    final addresses = await DnsResolver.instance.resolve(
      host,
      _dns ?? DnsConfig(),
      _hosts ?? <HostsEntry>[],
    );
    if (addresses.isEmpty) {
      throw StateError('no address for $host');
    }
    // IPv4 优先（Cloudflare anycast 多为 IPv4）；DnsResolver 对 hosts 命中的
    // 多候选只做了打乱，未做 v4/v6 分组，这里补齐次序。
    final v4 = addresses
        .where((a) => a.type == InternetAddressType.IPv4)
        .toList(growable: false);
    if (v4.isEmpty || v4.length == addresses.length) return addresses;
    return <InternetAddress>[
      ...v4,
      ...addresses.where((a) => a.type != InternetAddressType.IPv4),
    ];
  }

  /// 逐个候选地址尝试建连，直到成功；全部失败回退系统解析原域名直连。
  ///
  /// 与 [NetworkClientBuilder._connectFirstReachable] 同语义（hosts/DNS 常给
  /// 出多个候选 IP，其中部分不可达，只连第一个会整体超时）。单次尝试限时
  /// 8s：被防火墙静默丢弃的地址 TCP 会一直挂起，不限时则隧道永久无响应。
  Future<Socket> _connectFirstReachable(
    String host,
    int port,
    List<InternetAddress> addresses,
  ) async {
    Object? lastErr;
    for (final addr in addresses) {
      try {
        return await Socket.connect(addr, port).timeout(
              const Duration(seconds: 8),
              onTimeout: () => throw TimeoutException('connect $addr'),
            );
      } on Object catch (e) {
        lastErr = e;
      }
    }
    try {
      return await Socket.connect(host, port).timeout(
            const Duration(seconds: 8),
            onTimeout: () => throw TimeoutException('connect $host'),
          );
    } on Object catch (e) {
      throw lastErr ?? e;
    }
  }

  void _pipe(Socket a, Socket b) {
    a.listen(
      (d) => b.add(d),
      onDone: () {
        try {
          b.close();
        } on Object {
          // 忽略。
        }
      },
      onError: (_) {
        try {
          b.close();
        } on Object {
          // 忽略。
        }
      },
      cancelOnError: true,
    );
    b.listen(
      (d) => a.add(d),
      onDone: () {
        try {
          a.close();
        } on Object {
          // 忽略。
        }
      },
      onError: (_) {
        try {
          a.close();
        } on Object {
          // 忽略。
        }
      },
      cancelOnError: true,
    );
  }

  // ---- PAC 生成 ----

  String _buildPac(Set<String> hostnames, int port) {
    final rules = hostnames.map((h) {
      return "  if (host == '$h' || shExpMatch(host, '*.$h')) "
          "return 'PROXY 127.0.0.1:$port';";
    }).join('\n');
    return 'function FindProxyForURL(url, host) {\n'
        '$rules\n'
        "  return 'DIRECT';\n"
        '}\n';
  }

  // ---- 平台通道（Android ProxyController）----

  Future<bool> _setProxy({String? pacUrl, String? proxyUrl}) async {
    try {
      final r = await _channel.invokeMethod<bool>('setProxyOverride', <String, dynamic>{
        if (pacUrl != null) 'pacUrl': pacUrl,
        if (proxyUrl != null) 'proxyUrl': proxyUrl,
      });
      return r == true;
    } on Object catch (e) {
      // 非 Android（如 Windows / 桌面）未注册 nexhub/webview_proxy handler，
      // invokeMethod 抛 MissingPluginException——必须兜底，否则异常会冲出
      // applyForSource 阻断验证界面打开。网络跟随是 best-effort，失败即回落。
      debugPrint('WebviewProxy setProxyOverride failed: $e');
      return false;
    }
  }

  Future<void> _clearProxy() async {
    try {
      await _channel.invokeMethod<void>('clearProxyOverride');
    } on Object catch (e) {
      debugPrint('WebviewProxy clearProxyOverride failed: $e');
    }
  }
}

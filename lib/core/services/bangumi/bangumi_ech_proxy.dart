/// Bangumi ECH（Encrypted Client Hello）本地代理管理层。
///
/// 移植自参考项目 Bangumi-master 的 `src/utils/proxy/ech/*`：
/// 在 Android 上启动本地 HTTP 代理（ECH + DoH），让 Bangumi 域名的请求
/// 走本地代理透明接管（不再改写 URL）。本文件对应参考的 `ech/index.ts` +
/// `ech/native.ts` + `ech/types.ts` 的 Dart 侧管理等价物。
///
/// 与参考项目的差异（仅因平台能力边界，不影响 API 形态）：
/// - 参考项目依赖原生 Rust 代理（EchProxyModule + Java OkHttp ProxySelector）；
///   Flutter 侧无该原生库，故通过 [MethodChannel]('nexhub/ech_proxy') 桥接，
///   原生未实现时安全降级（enable 返回 0、isRunning 恒 false）。
/// - 请求路由由本层注册进 [NetworkClientBuilder.proxyOverrideResolver] 全局
///   代理覆盖策略，经 `main.dart` 的 [HttpOverrides.global] 生效。**作用范围是
///   本应用三套 ECH 的并集**，优先级「越具体越优先」：
///   ① **bangumi 专用**（`BangumiProxyConfig.echEnabled`），范围由
///   [isBangumiScopedHost] 单点定义：Bangumi 自有域 + 镜像模式下为本板块配置的基址域；
///   ② **源级**（`SourceNetworkConfig.ech`）：打开 ECH 的源，接管其 `site.baseUrl` 的 host，
///   显式关闭则该源被排除（即使应用级 ECH 打开）；
///   ③ **应用级**（`NetworkConfig.ech`）：接管任意 https 域——不支持的域由原生侧
///   **逐域自适应回落**（拿不到 ECH 收益的域回落直连 / 原始 TCP 隧道），不会把
///   「不支持 ECH 的站点」搞断。
///   范围之外的请求一律返回 null，交回档案自身代理决策，因此不干扰用户配置的代理。
///   合并逻辑单点实现于 [BangumiEchProxy.computeEchScope] 与 [EchScopeSpec.handles]，
///   并被单测覆盖。
///
///   之所以三套必须汇入同一个引擎：ECH 代理是本地 MITM，自签 CA 与监听端口全局唯一
///   （native 侧 `SERVER` / `HOST_GATES` 均为 static），**不可能为三套各起一个实例**，
///   三套配置只决定「哪些请求被路由进来」。因此 native 侧的接管域名是**运行期可配**的
///   （`setScope`），而不是参考项目那样的编译期常量。
///   之所以挂全局而非只挂 Bangumi 的 Dio：Bangumi 图片走 `CachedNetworkImage`
///   （独立 HttpClient），局部 adapter 覆盖不到，且会覆盖掉已设的 findProxy。
///
/// 本层只做 Dart 侧状态机 + MethodChannel 桥接；是否真正有网络代理能力
/// 取决于原生侧是否实现了 `nexhub/ech_proxy` 通道。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode, kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;

import '../../network/network_config_service.dart';
import '../../network/runtime/network_client_builder.dart';
import '../../network/source_network_override_store.dart';
import '../../models/plugin_config.dart' show PluginConfig;
import 'bangumi_proxy_config.dart';

/// ECH 代理配置（对应参考 `EchProxyConfig`）。
///
/// 除参考项目的 `port` / `dns` 外，本移植额外携带**作用域**四个字段（对应 native 侧
/// `setScope` 的入参）。全部为 null 时表示「由 [BangumiEchProxy.computeEchScope] 从
/// 三套 ECH 配置实时推导」——绝大多数调用方只需要 `const EchProxyConfig()`。
class EchProxyConfig {
  /// 监听端口，传 0 由原生侧分配随机端口。
  final int? port;

  /// DoH 服务器地址（默认 Cloudflare）。
  final String? dns;

  /// 显式接管的域名（英文逗号分隔）。null = 实时推导。
  final String? targets;

  /// 用户自备 ECHConfigList（标准 base64）。null = 实时推导；空串 = 走 GREASE 探测。
  final String? echConfigList;

  /// 是否接管任意域（应用级 ECH）。null = 实时推导。
  final bool? allowAnyHost;

  /// 是否打开 native 侧 debug 日志。null = 由调用方决定（默认 [kDebugMode]）。
  final bool? verboseLog;

  const EchProxyConfig({
    this.port,
    this.dns,
    this.targets,
    this.echConfigList,
    this.allowAnyHost,
    this.verboseLog,
  });

  /// 用实时推导出的作用域补齐未显式指定的字段。
  EchProxyConfig withScope(EchScopeSpec spec, {required bool verboseLog}) =>
      EchProxyConfig(
        port: port,
        dns: dns,
        targets: targets ?? spec.targets.join(','),
        echConfigList: echConfigList ?? spec.echConfigList,
        allowAnyHost: allowAnyHost ?? spec.allowAnyHost,
        verboseLog: this.verboseLog ?? verboseLog,
      );

  Map<String, dynamic> toNative() => <String, dynamic>{
        'port': port ?? 0,
        'dns': dns ?? _defaultDns,
        'targets': targets ?? '',
        'echConfigList': echConfigList ?? '',
        'allowAnyHost': allowAnyHost ?? false,
        'verboseLog': verboseLog ?? false,
      };
}

/// 三套 ECH（应用级 / 源级 / bangumi 专用）合并后的**作用域快照**。
///
/// ECH 原生引擎是本地 MITM：自签 CA 与监听端口全局唯一，**不可能为三套各起一个实例**，
/// 只能共用一个引擎、由上层决定「哪些请求被路由进来」。本类就是那个决定：
/// [BangumiEchProxy.resolveProxyOverride] 每次请求只查这里，不做任何 IO。
class EchScopeSpec {
  /// 显式点名的接管域（bangumi 自有域/镜像域 + 打开 ECH 的源站域）。
  final List<String> targets;

  /// 显式排除的域：源级显式关闭 ECH 时，即使应用级 ECH 打开也不接管该源。
  /// 体现「越具体越优先」。
  final List<String> excluded;

  /// 应用级 ECH 打开 → 接管任意 https 域（由原生侧逐域自适应：拿不到 ECH 收益的域
  /// 回落直连/原始隧道，不会把不支持 ECH 的站点搞断）。
  final bool allowAnyHost;

  /// 用户自备 ECHConfigList（源级优先于应用级）；空串 = 让原生侧走 GREASE 探测。
  final String echConfigList;

  const EchScopeSpec({
    this.targets = const <String>[],
    this.excluded = const <String>[],
    this.allowAnyHost = false,
    this.echConfigList = '',
  });

  /// 三套全关（没有任何接管意图）→ 本地引擎没必要常驻。
  bool get isEmpty => !allowAnyHost && targets.isEmpty;

  /// 该 host 是否应被路由进本地 ECH 引擎。
  bool handles(String host) {
    if (host.isEmpty) return false;
    for (final e in excluded) {
      if (host == e || host.endsWith('.$e')) return false;
    }
    for (final t in targets) {
      if (host == t || host.endsWith('.$t')) return true;
    }
    return allowAnyHost;
  }

  /// 下发给 native 侧 `setScope` 的入参。
  Map<String, dynamic> toNativeScope({required bool verboseLog}) => <String, dynamic>{
        'targets': targets.join(','),
        'echConfigList': echConfigList,
        'allowAnyHost': allowAnyHost,
        'verboseLog': verboseLog,
      };
}

/// ECH 代理状态（对应参考 `EchProxyStatus`）。
class EchProxyStatus {
  final bool running;
  final int port;
  final String? caPem;

  const EchProxyStatus({required this.running, required this.port, this.caPem});

  factory EchProxyStatus.fromNative(Map<Object?, Object?> map) => EchProxyStatus(
        running: map['running'] as bool? ?? false,
        port: map['port'] as int? ?? 0,
        caPem: map['caPem'] as String?,
      );

  const EchProxyStatus.idle()
      : running = false,
        port = 0,
        caPem = null;
}

/// ECH 代理日志（对应参考 `EchProxyLog`）。
class EchProxyLog {
  final int time;
  final String level;
  final String type;
  final String message;

  const EchProxyLog({
    required this.time,
    required this.level,
    required this.type,
    required this.message,
  });

  factory EchProxyLog.fromNative(Map<Object?, Object?> map) => EchProxyLog(
        time: map['time'] as int? ?? 0,
        level: map['level'] as String? ?? 'info',
        type: map['type'] as String? ?? 'proxy',
        message: map['message'] as String? ?? '',
      );
}

/// 原生未实现 ECH 代理（MethodChannel 不可达 / 抛 MissingPluginException）时的错误。
class EchProxyNotImplemented implements Exception {
  @override
  String toString() =>
      'EchProxyNotImplemented: native ECH proxy (nexhub/ech_proxy) is not linked';
}

/// 默认 DoH 服务器（与参考 `native.ts` 一致）。
const String _defaultDns = 'https://cloudflare-dns.com/dns-query';

/// 参考 `ECH_PROXY_ENABLED` 等价开关：本移植的 ECH 功能总开关。
///
/// 参考项目在 config 中硬编码 true（仅 android 生效）。此处同样默认开启，
/// 但受 [BangumiProxyConfig.echEnabled] 持久化开关与平台共同约束。
const bool echProxyEnabled = true;

/// ECH 透明接管的域名白名单：**仅 Bangumi 自有域**。
///
/// 该列表是「ECH 只作用于 Bangumi 相关内容」这一硬性范围的唯一来源：未命中
/// 的任何请求（含 `cloudflare-dns.com` 等公共基础设施、任意第三方域）一律
/// 不接管，交回档案自身的代理决策。
///
/// 与参考项目 `ECH_TARGET_DOMAINS` 的差异及原因：
/// - `lain.bgm.tv` / `next.bgm.tv` / `api.bgm.tv`：均为 `bgm.tv` 子域，已被
///   子域匹配隐含覆盖，无需重复列出；
/// - `cloudflare-dns.com`：参考项目列入是为了让 App 自身的 DoH 查询也过本地
///   代理。本项目 `dns_resolver.dart` 的 DoH 使用「不挂 HttpOverrides 的裸
///   HttpClient」，本就不经此路由（列入等于空转），故排除以严守 Bangumi-only。
const List<String> echTargetDomains = <String>[
  'bgm.tv',
  'chii.in',
];

/// 请求 host 是否属于 ECH 透明接管的 **Bangumi 自有域**（固定清单）。
///
/// 匹配域名本身及其全部子域：`bgm.tv` 命中 `bgm.tv` / `api.bgm.tv` /
/// `lain.bgm.tv` / `next.bgm.tv`；`chii.in` 命中 `chii.in` / `bgm.chii.in` 等。
/// 其余一切 host（含 `cloudflare-dns.com`、任意第三方域）恒返回 false。
bool isEchTargetHost(String host) {
  if (host.isEmpty) return false;
  return echTargetDomains.any((d) => host == d || host.endsWith('.$d'));
}

/// ECH 的**完整作用域**判定：Bangumi 自有域 **或** 用户为本板块配置的镜像域。
///
/// 镜像 / 反代模式（[BangumiProxyMode.mirror]）下，Bangumi 流量实际发往
/// [BangumiProxyConfig.apiBaseUrl] / [nextBaseUrl] / [oauthBaseUrl] /
/// [imageBaseUrl]——它们同样是「Bangumi 有关的内容」，若不在作用域内，开了
/// ECH 的用户会发现功能静默失效（而这正是最需要 ECH 的网络环境）。
///
/// 但作用域**到此为止**：只认这三个基址的 host（及其子域），其余任何域一律
/// 放行回档案自身的代理决策，绝不吞掉用户代理，也不影响其他板块。
bool isBangumiScopedHost(String host, [BangumiProxyConfig? config]) {
  if (isEchTargetHost(host)) return true;
  final cfg = config ?? BangumiProxyConfig.instance;
  for (final base in <String>[
    cfg.apiBaseUrl,
    cfg.nextBaseUrl,
    cfg.oauthBaseUrl,
    cfg.imageBaseUrl,
  ]) {
    final h = Uri.tryParse(base)?.host ?? '';
    if (h.isEmpty) continue;
    if (host == h || host.endsWith('.$h')) return true;
  }
  return false;
}

/// ECH 代理管理（对应参考 `ech/index.ts` 模块级单例）。
///
/// 内部维护内存态 [getEchProxyPort] / [isEchProxyRunning]，并提供与参考一致的
/// [enableEchProxy] / [disableEchProxy] / [restoreEchProxy] / [setupEchLifecycle]
/// 以及导出别名 [enable] / [disable]。
class BangumiEchProxy {
  BangumiEchProxy._() {
    // 首次通过 [instance] 访问单例时自动挂载全局代理路由（幂等：同一实例的
    // tear-off 每次赋值都等价）。挂载后即使 ECH 从未启用也零行为影响——
    // [resolveProxyOverride] 在非运行态恒返回 null，交由档案自身代理决策。
    NetworkClientBuilder.proxyOverrideResolver = resolveProxyOverride;
    // 应用级 / 源级 ECH 的来源是网络配置：订阅其变更回调，配置一改就重算并
    // 下发作用域（否则用户切了应用级 ECH 要等下次冷启动才生效）。
    NetworkConfigService.instance
        .addEffectiveConfigListener(_onNetworkConfigChanged);
  }

  /// 网络配置（应用级 / 源级 ECH 的来源）变更 → 重算并下发作用域。
  void _onNetworkConfigChanged() {
    unawaited(applyEchScope());
  }

  static final BangumiEchProxy instance = BangumiEchProxy._();

  static const MethodChannel _channel = MethodChannel('nexhub/ech_proxy');

  /// 当前代理端口，0 表示未启用（对应参考 `_port`）。
  int _port = 0;

  /// 是否正在运行（对应参考 `_running`）。
  bool _running = false;

  /// 生命周期监听是否已注册（对应参考 `_lifecycleSetup`）。
  bool _lifecycleSetup = false;

  /// 原生通道是否可用（探测一次后缓存；原生未实现时整体降级）。
  bool? _nativeAvailable;

  /// 当前生效的三套 ECH 作用域快照。
  ///
  /// 由 [applyEchScope] / [enableEchProxy] 刷新，[resolveProxyOverride] 只读它 ——
  /// 代理覆盖策略在 `findProxy` 的热路径上被逐请求调用，绝不能在里边做配置读取。
  EchScopeSpec _scope = const EchScopeSpec();

  /// 当前生效的作用域（调试/UI 展示用）。
  EchScopeSpec get currentScope => _scope;

  /// 源列表快照（由调用方注入，见 [setSourceConfigs]）。
  List<PluginConfig> _sourceConfigs = const <PluginConfig>[];

  /// 注入源列表快照，供 [computeEchScope] 扫描源级 ECH 声明。
  ///
  /// **为什么是注入而不是自己取**：[SourceRepository] 不是单例（构造于
  /// `SplashScreen` 启动序列并交给 Provider），而 [applyEchScope] 还会被生命周期
  /// 观察者调用——那里没有 `BuildContext`，拿不到 Repository。缓存一份快照即可
  /// 让两侧共用同一份数据，也避免 core/service 反向依赖 UI 层的 Repository。
  ///
  /// 调用点：`SplashScreen` 启动序列（紧随 `SourceRepository.loadImported()`）与
  /// 源级网络设置页保存后。只替换引用，不做逐项 diff（源列表本身很小且已在内存）。
  void setSourceConfigs(List<PluginConfig> configs) {
    _sourceConfigs = List<PluginConfig>.unmodifiable(configs);
  }

  static bool get _isAndroid => !kIsWeb && Platform.isAndroid;

  /// 启动 ECH 代理（对应参考 `enableEchProxy`）。
  ///
  /// 仅 Android 且 [echProxyEnabled] 时生效；其余平台或关闭时返回 0（不启用）。
  /// 原生返回端口 <= 0 时回滚并置 0；原生不可用时捕获异常安全降级。
  ///
  /// 与参考的差异：启动时会**一并下发三套 ECH 合并后的作用域**（域白名单 / 是否接管
  /// 任意域 / 用户自备 ECHConfigList），因为 native 侧要据此决定启动时预热哪些域。
  Future<int> enableEchProxy([EchProxyConfig config = const EchProxyConfig()]) async {
    if (!_isAndroid || !echProxyEnabled) return 0;

    _scope = computeEchScope();
    final effective = config.withScope(_scope, verboseLog: kDebugMode);

    try {
      final port = await _nativeEnable(effective);
      if (port > 0) {
        _port = port;
        _running = true;
      } else {
        // 原生返回 0，回滚。
        await _nativeDisable();
        _port = 0;
        _running = false;
      }
      return _port;
    } catch (e) {
      // 失败时回滚原生服务，防止残留。
      try {
        await _nativeDisable();
      } catch (_) {
        // 忽略回滚失败。
      }
      _port = 0;
      _running = false;
      return 0;
    }
  }

  /// 重新计算三套 ECH 的合并作用域，并据此启停 / 热更新本地引擎。
  ///
  /// 这是「三套 ECH 真正生效」的统一入口：任何一套的开关变化后调用它即可，
  /// 不需要分别关心「引擎该不该起、怎么起」。
  /// - 三套全关 → 停掉引擎（没有作用域就没有必要常驻本地代理）
  /// - 有作用域但引擎没跑 → 启动（作用域随之在 `startProxy` 前下发）
  /// - 引擎已在跑 → 只热更新作用域（native 侧支持运行期替换，不重启服务）
  Future<void> applyEchScope() async {
    if (!_isAndroid || !echProxyEnabled) return;
    final spec = computeEchScope();
    _scope = spec;

    if (spec.isEmpty) {
      if (_running) await disableEchProxy();
      return;
    }

    if (!_running) {
      await enableEchProxy();
      return;
    }

    // 已在运行：把新作用域热更新给 native。失败不影响已建立的连接，
    // 下次 [applyEchScope] 会重试。
    try {
      await _nativeSetScope(spec);
    } catch (e) {
      debugPrint('BangumiEchProxy.applyEchScope: setScope failed: $e');
    }
  }

  /// 计算三套 ECH 的**并集作用域**（优先级：bangumi 专用 > 源级 > 应用级）。
  ///
  /// - **bangumi 专用**（[BangumiProxyConfig.echEnabled]）：Bangumi 自有域 +
  ///   镜像模式下用户为本板块配置的基址域，由 [isBangumiScopedHost] 单点定义；
  /// - **源级**（[SourceNetworkConfig.ech]）：打开 ECH 的源，接管其
  ///   [PluginConfig.site] 的 host；显式关闭则进排除表（即使应用级 ECH 打开也不接管）；
  /// - **应用级**（[NetworkConfig.ech]）：接管任意 https 域。
  ///
  /// `echConfigList` 取「源级 > 应用级」第一个非空值（用户显式给了配置就以用户为准）。
  EchScopeSpec computeEchScope() {
    final targets = <String>{};
    final excluded = <String>{};
    String ecl = '';

    // ① bangumi 专用
    final bgmCfg = BangumiProxyConfig.instance;
    if (bgmCfg.echEnabled) {
      targets.addAll(echTargetDomains);
      for (final base in <String>[
        bgmCfg.apiBaseUrl,
        bgmCfg.nextBaseUrl,
        bgmCfg.oauthBaseUrl,
        bgmCfg.imageBaseUrl,
      ]) {
        final h = Uri.tryParse(base)?.host ?? '';
        if (h.isNotEmpty) targets.add(h);
      }
    }

    // ② 源级（只看「源自己声明的那一层」：继承应用级的源不算显式点名，
    //    否则每个源都会变成显式域，应用级的「逐域自适应回退」就失效了）
    for (final src in _sourceConfigs) {
      final specific =
          SourceNetworkOverrideStore.instance.get(src.id)?.ech ?? src.network?.ech;
      if (specific == null) continue;
      final h = Uri.tryParse(src.site.baseUrl)?.host ?? '';
      if (h.isEmpty) continue;
      if (specific.enabled) {
        targets.add(h);
        if (ecl.isEmpty) ecl = specific.echConfigList.trim();
      } else {
        excluded.add(h);
      }
    }

    // ③ 应用级
    final appEch = NetworkConfigService.instance.config.ech;
    if (ecl.isEmpty) ecl = appEch.echConfigList.trim();

    return EchScopeSpec(
      targets: targets.difference(excluded).toList(growable: false),
      excluded: excluded.toList(growable: false),
      allowAnyHost: appEch.enabled,
      echConfigList: ecl,
    );
  }

  /// 停止 ECH 代理（对应参考 `disableEchProxy`）。
  Future<void> disableEchProxy() async {
    if (!_isAndroid) return;
    try {
      await _nativeDisable();
    } catch (_) {
      // 忽略原生侧异常，仍清除内存态。
    } finally {
      _port = 0;
      _running = false;
    }
  }

  /// 获取代理端口（同步，读取内存缓存；对应参考 `getEchProxyPort`）。
  int getEchProxyPort() => _port;

  /// ECH 代理是否正在运行（同步，读取内存缓存；对应参考 `isEchProxyRunning`）。
  bool isEchProxyRunning() => _running;

  /// 全局代理覆盖策略：ECH 运行时按**三套 ECH 的并集作用域**接管 https 请求。
  ///
  /// 挂载到 [NetworkClientBuilder.proxyOverrideResolver]，因此能覆盖经
  /// `HttpOverrides.global` 派生的全部 dart:io 客户端（Bangumi API 的 Dio、
  /// `CachedNetworkImage` 的图片、以及各源的抓取客户端）。
  ///
  /// 判定顺序（越具体越优先，由 [EchScopeSpec.handles] 单点实现）：
  /// 1. 源级显式关闭 → 不接管（即使应用级 ECH 打开）；
  /// 2. 显式点名的域（bangumi 自有域/镜像域、打开 ECH 的源站域）→ 接管；
  /// 3. 应用级 ECH 打开 → 接管任意 https 域；
  /// 4. 其余 → 返回 null，交回档案自身的代理决策（绝不吞掉用户配置的应用代理）。
  ///
  /// **只接管 https**：明文 HTTP 走本地 MITM 代理时，原生侧是按 443 建 TLS 的，
  /// 语义不符（会把 http 请求发到 https 端点）。http 请求交回档案决策。
  ///
  /// 对应参考项目 `strategy.ts`：`const ech = isEchProxyRunning()` 时把代理
  /// 指向本地端口，否则完全不干预代理链。
  String? resolveProxyOverride(Uri uri) {
    if (!_running) return null;
    final port = _port;
    if (port <= 0) return null;
    if (uri.scheme != 'https') return null;
    if (!_scope.handles(uri.host)) return null;
    return 'PROXY localhost:$port';
  }

  /// 客户端启动时恢复 ECH 代理状态（对应参考 `restoreEchProxy`）。
  ///
  /// [enabled] 只描述「bangumi 专用」这一套：应用级与源级 ECH 各自独立，所以这里
  /// 统一交给 [applyEchScope] 做三套并集判定（该启动就启动、该热更新就热更新、
  /// 三套全关就把引擎停掉）。参数保留是为了与参考签名一致。
  Future<void> restoreEchProxy(bool enabled) async {
    if (!_isAndroid) return;
    assert(() {
      if (enabled != BangumiProxyConfig.instance.echEnabled) {
        debugPrint(
          'BangumiEchProxy.restoreEchProxy: 入参 enabled=$enabled 与持久化状态 '
          '${BangumiProxyConfig.instance.echEnabled} 不一致，以持久化状态为准',
        );
      }
      return true;
    }());
    await applyEchScope();
  }

  /// 从原生侧同步真实状态（异步，调试用；对应参考 `syncEchProxyStatus`）。
  Future<EchProxyStatus> syncEchProxyStatus() async {
    final status = await _nativeGetStatus();
    _port = status.port;
    _running = status.running;
    return status;
  }

  /// 获取原生端收集的 ECH 日志（对应参考 `getEchProxyLogs`）。
  Future<List<EchProxyLog>> getEchProxyLogs() async {
    if (!_isAndroid || !echProxyEnabled) return const <EchProxyLog>[];
    try {
      final result = await _channel.invokeListMethod<Map<Object?, Object?>>('getLogs');
      if (result == null) return const <EchProxyLog>[];
      return result.map(EchProxyLog.fromNative).toList();
    } on MissingPluginException {
      _nativeAvailable = false;
      return const <EchProxyLog>[];
    }
  }

  /// 注册 App 生命周期监听（对应参考 `setupEchLifecycle`）。
  ///
  /// 后台→前台时若 [BangumiProxyConfig.echEnabled] 且代理已死则重建；仅注册一次。
  /// 使用 Flutter 的 [WidgetsBindingObserver] 等价于参考的 `AppState` 监听。
  void setupEchLifecycle() {
    if (_lifecycleSetup || !_isAndroid || !echProxyEnabled) return;
    _lifecycleSetup = true;
    _EchLifecycleObserver.instance.attach(this);
  }

  // ── MethodChannel 桥接（对应参考 `native.ts`）──

  Future<int> _nativeEnable(EchProxyConfig config) async {
    if (!await _ensureNative()) return 0;
    final port = await _channel.invokeMethod<int>('enable', config.toNative());
    return port ?? 0;
  }

  Future<void> _nativeDisable() async {
    if (!await _ensureNative()) return;
    await _channel.invokeMethod<void>('disable');
  }

  /// 把作用域热更新给 native（引擎运行中调用；启动路径用 `enable` 的入参代替）。
  Future<void> _nativeSetScope(EchScopeSpec spec) async {
    if (!await _ensureNative()) return;
    await _channel.invokeMethod<void>(
      'setScope',
      spec.toNativeScope(verboseLog: kDebugMode),
    );
  }

  Future<EchProxyStatus> _nativeGetStatus() async {
    if (!await _ensureNative()) return const EchProxyStatus.idle();
    final map =
        await _channel.invokeMapMethod<Object?, Object?>('getStatus');
    if (map == null) return const EchProxyStatus.idle();
    return EchProxyStatus.fromNative(map);
  }

  /// 探测并缓存原生通道可用性；缺失时安全降级（对应参考 LINKING_ERROR 兜底）。
  Future<bool> _ensureNative() async {
    if (_nativeAvailable != null) return _nativeAvailable!;
    try {
      // 用一个轻量状态查询探测插件是否注册，避免 enable 带副作用。
      await _channel.invokeMapMethod<Object?, Object?>('getStatus');
      _nativeAvailable = true;
    } on MissingPluginException {
      _nativeAvailable = false;
    } catch (_) {
      // 其他异常（如原生未就绪）先视为可用，交给具体调用处理。
      _nativeAvailable = true;
    }
    return _nativeAvailable!;
  }
}

/// 导出别名（对应参考 `export { enableEchProxy as enable, ... }`）。
Future<int> enable([EchProxyConfig config = const EchProxyConfig()]) =>
    BangumiEchProxy.instance.enableEchProxy(config);

Future<void> disable() => BangumiEchProxy.instance.disableEchProxy();

/// App 生命周期观察者（对应参考 `AppState.addEventListener('change')`）。
///
/// 仅在本类内使用：把 Flutter 的 lifecycle 事件桥接到 [BangumiEchProxy]
/// 的「前台恢复时重建死掉的代理」逻辑。
class _EchLifecycleObserver with WidgetsBindingObserver {
  _EchLifecycleObserver._();

  static final _EchLifecycleObserver instance = _EchLifecycleObserver._();

  BangumiEchProxy? _proxy;
  bool _attached = false;

  void attach(BangumiEchProxy proxy) {
    if (_attached) return;
    _attached = true;
    _proxy = proxy;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final proxy = _proxy;
    if (proxy == null) return;
    // 与参考的差异：不再只看 BangumiProxyConfig.echEnabled —— 应用级/源级 ECH 同样
    // 需要引擎存活。统一交给 applyEchScope 做三套并集判定（全关时它会停掉引擎）。
    unawaited(
      (() async {
        final status = await proxy.syncEchProxyStatus();
        if (!status.running || status.port <= 0) {
          await proxy.applyEchScope();
        }
      })(),
    );
  }
}

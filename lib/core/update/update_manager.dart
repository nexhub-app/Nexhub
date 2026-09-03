/// 应用内更新管理器 —— 检查更新、镜像下载、静默安装。
///
/// 能力：
/// 1. 从 GitHub Releases API 拉取最新版本信息（tag + 各平台资产下载地址）。
/// 2. 支持镜像源下载（官方 / 镜像切换，自动测试延迟选最快镜像）。
/// 3. 静默下载（后台下载不打断使用，完成后提示安装）。
/// 4. 下载进度上报（百分比回调）。
/// 5. 平台安装：Windows 启动安装包；macOS 挂载 dmg；Linux 启动安装包；
///    Android 调用系统安装器。
library;

import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'update_settings.dart';

/// 更新检查结果（从 GitHub Releases API 解析）。
class UpdateReleaseInfo {
  final String tagName;
  final String name;
  final String body;
  final String htmlUrl;
  final List<UpdateAsset> assets;

  const UpdateReleaseInfo({
    required this.tagName,
    required this.name,
    required this.body,
    required this.htmlUrl,
    required this.assets,
  });
}

/// 单个发布资产（安装包）。
class UpdateAsset {
  final String name;
  final String browserDownloadUrl;

  const UpdateAsset({required this.name, required this.browserDownloadUrl});
}

/// 更新状态。
enum UpdateStatus { idle, checking, downloading, installing, done, failed }

/// 更新下载进度（线程安全，UI 直接监听）。
class UpdateProgress {
  final double progress; // 0.0 ~ 1.0
  final String fileName;
  final String? mirrorName;

  const UpdateProgress({
    this.progress = 0,
    this.fileName = '',
    this.mirrorName,
  });

  UpdateProgress copyWith({
    double? progress,
    String? fileName,
    String? mirrorName,
  }) =>
      UpdateProgress(
        progress: progress ?? this.progress,
        fileName: fileName ?? this.fileName,
        mirrorName: mirrorName ?? this.mirrorName,
      );
}

/// GitHub Releases API 返回的 release 资产的 JSON 结构。
class _ReleaseJson {
  final String tagName;
  final String name;
  final String body;
  final String htmlUrl;
  final bool prerelease;
  final List<Map<String, dynamic>> assets;

  _ReleaseJson.fromJson(Map<String, dynamic> json)
      : tagName = json['tag_name'] as String? ?? '',
        name = json['name'] as String? ?? '',
        body = json['body'] as String? ?? '',
        htmlUrl = json['html_url'] as String? ?? '',
        prerelease = json['prerelease'] as bool? ?? false,
        assets = (json['assets'] as List<dynamic>? ?? const <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .toList();
}

/// 应用内更新管理器（单例）。
class UpdateManager extends ChangeNotifier {
  UpdateManager._internal();

  static final UpdateManager instance = UpdateManager._internal();

  /// 项目仓库（GitHub Releases）。
  static const String _repoApi =
      'https://api.github.com/repos/nexhub-app/nexhub/releases';

  /// 默认镜像列表（name + 下载前缀替换规则）。
  ///
  /// 镜像协议：将 `https://github.com/` 前缀替换为镜像地址。
  /// 如 GitHub 官方：不替换；加速镜像采用主流双层协议：
  /// 替换为 `https://<域名>/https://github.com/`。
  ///
  /// 列表按公开测速延迟由低到高排序，方便「自动切换高速镜像」与手动选择。
  /// 镜像由热心网友公益贡献，无法保障稳定性与可用性，在此一并致谢 🙏
  static const List<({String name, String prefix})> _defaultMirrors = <({
    String name,
    String prefix,
  })>[
    (name: 'GitHub 官方', prefix: 'https://github.com/'),
    (
      name: 'gh.jasonzeng.dev',
      prefix: 'https://gh.jasonzeng.dev/https://github.com/'
    ),
    (
      name: 'js.jiangss.shop',
      prefix: 'https://js.jiangss.shop/https://github.com/'
    ),
    (name: 'tvv.tw', prefix: 'https://tvv.tw/https://github.com/'),
    (
      name: 'ghproxy.imciel.com',
      prefix: 'https://ghproxy.imciel.com/https://github.com/'
    ),
    (
      name: '777.z321.cc.cd',
      prefix: 'https://777.z321.cc.cd/https://github.com/'
    ),
    (
      name: 'gg.z321.cc.cd',
      prefix: 'https://gg.z321.cc.cd/https://github.com/'
    ),
    (name: 'gh-proxy.com', prefix: 'https://gh-proxy.com/https://github.com/'),
    (
      name: 'gh.ruan.dpdns.org',
      prefix: 'https://gh.ruan.dpdns.org/https://github.com/'
    ),
    (
      name: 'gh.monlor.com',
      prefix: 'https://gh.monlor.com/https://github.com/'
    ),
    (
      name: 'xsadwsd.kdns.fr',
      prefix: 'https://xsadwsd.kdns.fr/https://github.com/'
    ),
    (name: 'g.z321.cc.cd', prefix: 'https://g.z321.cc.cd/https://github.com/'),
    (name: 'fastgit.cc', prefix: 'https://fastgit.cc/https://github.com/'),
    (
      name: 'githubdog.com',
      prefix: 'https://githubdog.com/https://github.com/'
    ),
    (
      name: 'github.mxw.qzz.io',
      prefix: 'https://github.mxw.qzz.io/https://github.com/'
    ),
    (
      name: 'gh.my-website.ccwu.cc',
      prefix: 'https://gh.my-website.ccwu.cc/https://github.com/'
    ),
    (
      name: 'gh.07150721.xyz',
      prefix: 'https://gh.07150721.xyz/https://github.com/'
    ),
    (name: 'gh.noki.icu', prefix: 'https://gh.noki.icu/https://github.com/'),
    (name: 'ghfast.top', prefix: 'https://ghfast.top/https://github.com/'),
    (
      name: 'ghproxy.felicity.land',
      prefix: 'https://ghproxy.felicity.land/https://github.com/'
    ),
    (
      name: 'jiashu.1win.eu.org',
      prefix: 'https://jiashu.1win.eu.org/https://github.com/'
    ),
    (
      name: 'github.ednovas.xyz',
      prefix: 'https://github.ednovas.xyz/https://github.com/'
    ),
    (
      name: 'ghfile.geekertao.top',
      prefix: 'https://ghfile.geekertao.top/https://github.com/'
    ),
    (
      name: 'gh.927223.xyz',
      prefix: 'https://gh.927223.xyz/https://github.com/'
    ),
    (
      name: 'github.tbap.top',
      prefix: 'https://github.tbap.top/https://github.com/'
    ),
    (
      name: 'gh.felicity.ac.cn',
      prefix: 'https://gh.felicity.ac.cn/https://github.com/'
    ),
    (
      name: 'cdn.gh-proxy.com',
      prefix: 'https://cdn.gh-proxy.com/https://github.com/'
    ),
    (name: 'gh.ddlc.top', prefix: 'https://gh.ddlc.top/https://github.com/'),
    (
      name: 'free.cn.eu.org',
      prefix: 'https://free.cn.eu.org/https://github.com/'
    ),
    (
      name: 'github.dpik.top',
      prefix: 'https://github.dpik.top/https://github.com/'
    ),
    (
      name: 'down.mxw.qzz.io',
      prefix: 'https://down.mxw.qzz.io/https://github.com/'
    ),
    (name: 'git.yylx.win', prefix: 'https://git.yylx.win/https://github.com/'),
    (name: 'ghproxy.net', prefix: 'https://ghproxy.net/https://github.com/'),
    (
      name: 'gh.bugdey.us.kg',
      prefix: 'https://gh.bugdey.us.kg/https://github.com/'
    ),
    (
      name: 'github.nswrz.cn',
      prefix: 'https://github.nswrz.cn/https://github.com/'
    ),
    (
      name: 'gh.sixyin.com',
      prefix: 'https://gh.sixyin.com/https://github.com/'
    ),
    (name: 'gh.dpik.top', prefix: 'https://gh.dpik.top/https://github.com/'),
    (name: 'g.blfrp.cn', prefix: 'https://g.blfrp.cn/https://github.com/'),
    (
      name: 'github.chenc.dev',
      prefix: 'https://github.chenc.dev/https://github.com/'
    ),
    (
      name: 'git.669966.xyz',
      prefix: 'https://git.669966.xyz/https://github.com/'
    ),
    (name: 'gh.b52m.cn', prefix: 'https://gh.b52m.cn/https://github.com/'),
    (
      name: 'ghproxy.monkeyray.net',
      prefix: 'https://ghproxy.monkeyray.net/https://github.com/'
    ),
    (
      name: 'github.xxlab.tech',
      prefix: 'https://github.xxlab.tech/https://github.com/'
    ),
  ];

  /// 公开的默认镜像列表（供镜像设置页使用）。
  static List<({String name, String prefix})> get defaultMirrors =>
      List<({String name, String prefix})>.of(_defaultMirrors);

  UpdateStatus _status = UpdateStatus.idle;
  UpdateProgress _progress = const UpdateProgress();
  UpdateReleaseInfo? _latestRelease;
  String? _lastError;
  bool _silentMode = false;
  String? _downloadedPath;
  UpdateSettings _settings = const UpdateSettings.defaults();
  final Dio _dio = Dio();

  UpdateStatus get status => _status;
  UpdateProgress get progress => _progress;
  UpdateReleaseInfo? get latestRelease => _latestRelease;
  String? get lastError => _lastError;
  bool get silentMode => _silentMode;
  UpdateSettings get settings => _settings;

  /// 是否正在忙碌（检查中 / 下载中 / 安装中）。
  bool get isBusy =>
      _status == UpdateStatus.checking ||
      _status == UpdateStatus.downloading ||
      _status == UpdateStatus.installing;

  /// 初始化：加载持久化设置。
  Future<void> init() async {
    _settings = await UpdateSettingsStore().load();
  }

  /// 重新加载设置（设置页修改后调用）。
  Future<void> reloadSettings() async {
    _settings = await UpdateSettingsStore().load();
  }

  /// 保存设置。
  Future<void> saveSettings(UpdateSettings s) async {
    _settings = s;
    await UpdateSettingsStore().save(s);
    notifyListeners();
  }

  /// 检查最新版本。
  ///
  /// 返回最新 release 信息；无更新/失败时返回 null 并设置 [_lastError]。
  /// [timeout] 用于控制请求超时（静默检查时更长）。
  ///
  /// 按 [_settings.updateChannel] 过滤：
  /// - 稳定版：跳过 pre-release，取最新正式发布；
  /// - 测试版：取最新发布（含 pre-release）。
  Future<UpdateReleaseInfo?> checkForUpdate({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    _status = UpdateStatus.checking;
    _lastError = null;
    notifyListeners();
    try {
      final Response<List<dynamic>> resp = await _dio.get<List<dynamic>>(
        _repoApi,
        options: Options(
          headers: <String, String>{
            'Accept': 'application/vnd.github+json',
          },
          receiveTimeout: timeout,
          sendTimeout: timeout,
        ),
      );
      final List<dynamic>? list = resp.data;
      if (list == null || list.isEmpty) {
        throw Exception('no releases');
      }
      // 解析全部 release，按通道筛选首个可用项。
      final List<_ReleaseJson> all = list
          .whereType<Map<String, dynamic>>()
          .map(_ReleaseJson.fromJson)
          .toList();
      final bool wantBeta = _settings.updateChannel == UpdateChannel.beta;
      _ReleaseJson? first;
      for (final r in all) {
        // 稳定版通道：跳过预发布（GitHub 的 prerelease 标记 + tag 识别兜底，
        // 防止发布时漏勾 prerelease 导致 alpha/beta/rc 混入稳定版）。
        if (!wantBeta &&
            (r.prerelease || isPrereleaseVersion(r.tagName))) {
          continue;
        }
        first = r;
        break;
      }
      first ??= all.first;
      final assets = first.assets
          .map((a) => UpdateAsset(
                name: a['name'] as String? ?? '',
                browserDownloadUrl: a['browser_download_url'] as String? ?? '',
              ))
          .toList();
      _latestRelease = UpdateReleaseInfo(
        tagName: first.tagName,
        name: first.name,
        body: first.body,
        htmlUrl: first.htmlUrl,
        assets: assets,
      );
      return _latestRelease;
    } on Object catch (e) {
      _lastError = e.toString();
      return null;
    } finally {
      _status = UpdateStatus.idle;
      notifyListeners();
    }
  }

  /// 版本是否为测试版（预发布版），供通道过滤与外部识别。
  ///
  /// 判定：去 `v` 前缀与 `+build` 元数据后带预发布段即视为测试版，
  /// 覆盖 alpha、beta、rc 及 dev/preview 等任意预发布标识
  /// （如 `v2.1.0-alpha.1`、`v2.1.0-rc.1`）。
  static bool isPrereleaseVersion(String version) =>
      _splitSemver(version)[1].isNotEmpty;

  /// 判断版本 a 是否比 b 新（SemVer 规则，含预发布段）。
  ///
  /// 核心：去 `v` 前缀与 `+build` 元数据后，逐数字段比较主版本号。
  /// 核心版本相同时按预发布段比较（修复测试版通道检测不到
  /// `v2.0.0-beta.1 → v2.0.0-beta.2` 这类同核心版本的迭代）：
  /// - 正式版 > 预发布版（`2.0.0` > `2.0.0-beta.1`）；
  /// - 两者均为预发布时，按 `.` 拆分逐段比较：纯数字段按数值比较
  ///   （`beta.2` > `beta.1`），数字段小于字母段（SemVer 规范）。
  bool isNewer(String a, String b) {
    final List<String> pa = _splitSemver(a);
    final List<String> pb = _splitSemver(b);
    // 主版本号（点分数字段）
    final List<int> x = pa.first
        .split('.')
        .map((e) => int.tryParse(e) ?? 0)
        .toList();
    final List<int> y = pb.first
        .split('.')
        .map((e) => int.tryParse(e) ?? 0)
        .toList();
    final int n = x.length > y.length ? x.length : y.length;
    for (int i = 0; i < n; i++) {
      final int xi = i < x.length ? x[i] : 0;
      final int yi = i < y.length ? y[i] : 0;
      if (xi > yi) return true;
      if (xi < yi) return false;
    }
    // 核心版本相同：比较预发布段（pa/pb 第二位为预发布串，可能为空）。
    return _comparePrerelease(pa[1], pb[1]) > 0;
  }

  /// 拆分版本号为 `[核心版本, 预发布段]`：去 `v` 前缀与 `+build` 元数据，
  /// 按 `-` 分离预发布段（无预发布段时第二项为空串）。
  static List<String> _splitSemver(String v) {
    final String s = v
        .replaceAll(RegExp(r'^[vV]'), '')
        .split('+')
        .first
        .trim();
    final int dash = s.indexOf('-');
    if (dash < 0) return <String>[s, ''];
    return <String>[s.substring(0, dash), s.substring(dash + 1)];
  }

  /// 比较 SemVer 预发布段：正数表示 a 更新，负数表示 b 更新，0 表示相等。
  ///
  /// 无预发布段的正式版 > 有预发布段；两者均有预发布时按 SemVer 11 条逐段
  /// 比较：纯数字标识符按数值比较，数字标识符 < 字母标识符，字母标识符按
  /// ASCII 字典序。
  static int _comparePrerelease(String a, String b) {
    if (a.isEmpty && b.isEmpty) return 0;
    if (a.isEmpty) return 1; // 正式版 > 预发布
    if (b.isEmpty) return -1;
    final List<String> ia = a.split('.');
    final List<String> ib = b.split('.');
    final int n = ia.length > ib.length ? ia.length : ib.length;
    for (int i = 0; i < n; i++) {
      final String sa = i < ia.length ? ia[i] : '';
      final String sb = i < ib.length ? ib[i] : '';
      if (sa == sb) continue;
      if (sa.isEmpty) return -1; // 标识符少的一方 < 多的一方
      if (sb.isEmpty) return 1;
      final int? na = int.tryParse(sa);
      final int? nb = int.tryParse(sb);
      if (na != null && nb != null) return na.compareTo(nb);
      if (na != null) return -1; // 数字标识符 < 字母标识符
      if (nb != null) return 1;
      final int c = sa.compareTo(sb);
      if (c != 0) return c;
    }
    return 0;
  }

  /// 获取当前平台的安装包资产（Windows/Android/Linux/macOS）。
  UpdateAsset? _selectAssetForPlatform(List<UpdateAsset> assets) {
    if (assets.isEmpty) return null;
    if (kIsWeb) return null;
    if (Platform.isWindows) {
      // 优先 .exe 安装包，其次 .msix / .zip
      for (final a in assets) {
        final n = a.name.toLowerCase();
        if (n.endsWith('.exe')) return a;
      }
      for (final a in assets) {
        final n = a.name.toLowerCase();
        if (n.endsWith('.msix') || n.endsWith('.zip')) return a;
      }
    } else if (Platform.isAndroid) {
      for (final a in assets) {
        final n = a.name.toLowerCase();
        if (n.endsWith('.apk')) return a;
      }
    } else if (Platform.isLinux) {
      for (final a in assets) {
        final n = a.name.toLowerCase();
        if (n.endsWith('.appimage') || n.endsWith('.deb')) return a;
      }
    } else if (Platform.isMacOS) {
      for (final a in assets) {
        final n = a.name.toLowerCase();
        if (n.endsWith('.dmg')) return a;
      }
    }
    // 兜底：第一个资产
    return assets.first;
  }

  /// 应用镜像前缀转换下载 URL（官方前缀不替换）。
  String _applyMirrorPrefix(String originalUrl, String prefix) {
    if (prefix == 'https://github.com/') return originalUrl;
    return originalUrl.replaceFirst('https://github.com/', prefix);
  }

  /// 组装镜像列表（默认镜像 + 自定义镜像）。
  ///
  /// 自定义镜像地址做末尾斜杠归一化（用户常漏写，漏写会导致拼接出
  /// `https://mirrorhttps://github.com/...` 这类非法 URL）。
  List<({String name, String prefix})> _buildMirrorList() {
    final List<({String name, String prefix})> mirrors =
        List<({String name, String prefix})>.of(_defaultMirrors);
    for (final m in _settings.customMirrors) {
      if (m.name.isNotEmpty && m.baseUrl.isNotEmpty) {
        String base = m.baseUrl.trim();
        if (!base.endsWith('/')) base = '$base/';
        mirrors.add((name: m.name, prefix: base));
      }
    }
    return mirrors;
  }

  /// 探测单个 URL 的可达性延迟（毫秒）；不可用返回 null。
  ///
  /// 策略：
  /// 1. 先 HEAD 请求，`validateStatus` 接受任意响应码以便读取状态；
  /// 2. 探测真实安装包路径（URL 含 `/releases/download/`）时要求 2xx/3xx
  ///    ——镜像对安装包返回 403/404 说明无法代理下载，即使响应快也不能选；
  ///    探测普通页面（如 release 页）时保持宽松，4xx/5xx 仅说明路径不被
  ///    代理，不代表镜像不可达；
  /// 3. HEAD 被拒（部分镜像只支持 GET）或状态不达标时降级为 Range GET
  ///    （只取前 1KB），避免下载完整文件；
  /// 4. 仅 DNS/连接/超时等网络层错误，或（安装包路径下）持续的 4xx/5xx
  ///    才判定为不可用。
  Future<int?> _probeUrl(String url, {int timeoutMs = 6000}) async {
    final Stopwatch sw = Stopwatch()..start();
    final Duration timeout = Duration(milliseconds: timeoutMs);
    // 真实下载文件路径才做状态码校验；页面路径宽减免得误伤「只代理文件」的镜像。
    final bool strict = url.contains('/releases/download/');
    int? status;
    try {
      final Response<dynamic> resp = await _dio.head<dynamic>(
        url,
        options: Options(
          receiveTimeout: timeout,
          sendTimeout: timeout,
          followRedirects: true,
          validateStatus: (_) => true,
        ),
      );
      status = resp.statusCode;
    } on Object {
      // HEAD 不支持/被拒：降级 Range GET。
      status = null;
    }
    if (status != null && status >= 200 && status < 400) {
      return sw.elapsedMilliseconds;
    }
    if (status != null && !strict) {
      // 页面路径不被代理（4xx/5xx）不代表镜像不可达。
      return sw.elapsedMilliseconds;
    }
    try {
      final Response<dynamic> resp = await _dio.get<dynamic>(
        url,
        options: Options(
          headers: const <String, String>{'Range': 'bytes=0-1023'},
          receiveTimeout: timeout,
          sendTimeout: timeout,
          followRedirects: true,
          validateStatus: (_) => true,
        ),
      );
      status = resp.statusCode;
    } on Object {
      return null;
    }
    if (status != null && status >= 200 && status < 400) {
      return sw.elapsedMilliseconds;
    }
    return null;
  }

  /// 测试镜像延迟（优先 HEAD，失败降级 GET），返回毫秒；不可达返回 null。
  Future<int?> _probeMirror(String prefix, String url) async {
    final String probeUrl = prefix == 'https://github.com/'
        ? url
        : url.replaceFirst('https://github.com/', prefix);
    return _probeUrl(probeUrl);
  }

  /// 当前是否连接 WiFi（用于「自动下载更新仅在 WiFi 下」判断）。
  Future<bool> isWifiConnected() async {
    try {
      final List<ConnectivityResult> results =
          await Connectivity().checkConnectivity();
      return results.contains(ConnectivityResult.wifi);
    } on Object {
      // 桌面端 connectivity_plus 可能不可用或返回 unknown：视为非移动网络，
      // 放行自动下载（避免桌面端永远无法自动下载）。
      return true;
    }
  }

  /// 静默检查更新后，按设置决定是否自动下载安装包。
  ///
  /// 条件：开启自动下载 + 开启应用内下载 + 有新版本 + 当前非忙碌。
  /// [wifiOnlyAutoDownload] 开启时仅 WiFi 下下载，移动网络挂起等待。
  /// 返回是否已触发下载（false = 未满足条件或失败）。
  Future<bool> maybeAutoDownload(UpdateReleaseInfo release) async {
    if (!_settings.autoDownload) return false;
    if (!_settings.inAppDownload) return false;
    if (isBusy) return false;
    if (_settings.wifiOnlyAutoDownload && !await isWifiConnected()) {
      return false;
    }
    final String? path = await downloadInstaller(release, silent: true);
    return path != null;
  }

  /// 应用内下载关闭时，用系统浏览器打开发布页由用户自行下载。
  Future<bool> openReleaseInBrowser(UpdateReleaseInfo release) async {
    final Uri uri = Uri.parse(release.htmlUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return true;
    }
    return false;
  }

  /// 下载安装包。
  ///
  /// [release] 目标版本信息；[silent] 静默模式（不弹窗、不打断）；
  /// [onProgress] 进度回调（已含 [_progress] 更新）。
  /// 返回下载后的本地文件路径。
  ///
  /// 若 [_settings.inAppDownload] 关闭，改为打开浏览器发布页，返回 null
  /// 并设置 [_lastError] 为提示文案（调用方据此展示「已打开浏览器」）。
  Future<String?> downloadInstaller(
    UpdateReleaseInfo release, {
    bool silent = false,
    void Function(double progress)? onProgress,
  }) async {
    // 应用内下载开关关闭：交给浏览器。
    if (!_settings.inAppDownload) {
      final bool ok = await openReleaseInBrowser(release);
      _lastError = ok ? 'opened-in-browser' : 'cannot-open-browser';
      notifyListeners();
      return null;
    }
    final UpdateAsset? asset = _selectAssetForPlatform(release.assets);
    if (asset == null) {
      _lastError = 'No installer asset for this platform';
      _status = UpdateStatus.failed;
      notifyListeners();
      return null;
    }

    _silentMode = silent;
    _status = UpdateStatus.downloading;
    _progress = UpdateProgress(progress: 0, fileName: asset.name);
    _lastError = null;
    notifyListeners();

    try {
      // 确定目标目录：优先应用文档目录，否则临时目录。
      // 按发布 tag 建独立子目录：部分平台资产名固定不带版本号（如 Android
      // 的 app-release.apk），若平铺在同一目录，上一版下载残留的旧包会被
      // 下方「同名复用」逻辑误认成新包，导致显示下载完成却安装旧版本。
      final Directory base = await _getDownloadDirectory();
      final String versionDirName =
          release.tagName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final Directory versionDir = Directory(
        '${base.path}${Platform.pathSeparator}updates'
        '${Platform.pathSeparator}$versionDirName',
      );
      if (!versionDir.existsSync()) {
        versionDir.createSync(recursive: true);
      }
      // 清理其他版本残留目录（旧版本安装包不再有用，best-effort 删除）。
      _cleanStaleVersionDirs(base, keepDirName: versionDirName);
      final String targetPath =
          '${versionDir.path}${Platform.pathSeparator}${asset.name}';

      // 本地已存在同名安装包（同一版本此前已下载完成，失败残留会被
      // deleteOnError 清掉）：文件头校验通过后直接复用，不再重复下载。
      final File existing = File(targetPath);
      if (existing.existsSync() &&
          existing.lengthSync() > 0 &&
          _looksLikeValidInstaller(existing)) {
        _progress = UpdateProgress(progress: 1.0, fileName: asset.name);
        _downloadedPath = targetPath;
        _status = UpdateStatus.done;
        notifyListeners();
        return targetPath;
      }

      // 组装下载候选：主镜像（自动测速最快者 / 手动选中者）优先，其余镜像
      // 依次兜底，官方直连收尾。镜像对安装包返回 403/404 或网络失败时自动
      // 降级重试，避免单个镜像故障导致更新中断。
      final List<({String name, String prefix})> mirrors = _buildMirrorList();
      ({String name, String prefix})? primary;
      if (mirrors.isNotEmpty) {
        if (_settings.autoSwitchMirror) {
          primary = await _pickFastestMirror(asset.browserDownloadUrl);
        } else {
          primary = mirrors[_settings.mirrorIndex.clamp(0, mirrors.length - 1)];
        }
      }
      final List<({String name, String url})> candidates =
          <({String name, String url})>[];
      final Set<String> seenUrls = <String>{};
      void addCandidate(String name, String prefix) {
        final String url = _applyMirrorPrefix(asset.browserDownloadUrl, prefix);
        if (seenUrls.add(url)) {
          candidates.add((name: name, url: url));
        }
      }

      if (primary != null) addCandidate(primary.name, primary.prefix);
      for (final m in mirrors) {
        if (primary != null && m.prefix == primary.prefix) continue;
        addCandidate(m.name, m.prefix);
      }
      if (candidates.isEmpty) {
        candidates.add((name: 'GitHub 官方', url: asset.browserDownloadUrl));
      }

      Object? lastError;
      for (final ({String name, String url}) c in candidates) {
        try {
          await _dio.download(
            c.url,
            targetPath,
            deleteOnError: true,
            onReceiveProgress: (int received, int total) {
              final double p = total > 0 ? received / total : 0.0;
              _progress = _progress.copyWith(
                progress: p.clamp(0.0, 1.0),
                mirrorName: c.name,
              );
              onProgress?.call(_progress.progress);
              notifyListeners();
            },
          );
          _progress = _progress.copyWith(progress: 1.0, mirrorName: c.name);
          _downloadedPath = targetPath;
          _status = UpdateStatus.done;
          notifyListeners();
          return targetPath;
        } on Object catch (e) {
          // 当前候选失败（HTTP 4xx/5xx 或网络错误）：重置进度换下一个。
          lastError = e;
          _progress = _progress.copyWith(progress: 0.0);
          notifyListeners();
        }
      }
      throw lastError ?? Exception('all mirrors failed');
    } on Object catch (e) {
      _lastError = e.toString();
      _status = UpdateStatus.failed;
      notifyListeners();
      return null;
    }
  }

  /// 取当前设置指向的镜像 URL（供 UI 展示）。
  String get currentMirrorName {
    final mirrors = _buildMirrorList();
    if (mirrors.isEmpty) return 'GitHub 官方';
    return mirrors[_settings.mirrorIndex.clamp(0, mirrors.length - 1)].name;
  }

  /// 公开的镜像探测方法（供镜像设置页测速使用）。
  ///
  /// 使用 [testUrl]（默认 GitHub 最新 release 页面）经镜像前缀转换后发起
  /// 探测（HEAD 优先，失败降级 Range GET，任意 HTTP 响应码视为可达），
  /// 返回延迟毫秒；网络层不可达时抛出异常。
  Future<int> probeMirror(String prefix, {String? testUrl}) async {
    final String actualUrl =
        testUrl ?? 'https://github.com/nexhub-app/nexhub/releases/latest';
    final String probeUrl = prefix == 'https://github.com/'
        ? actualUrl
        : actualUrl.replaceFirst('https://github.com/', prefix);
    final int? ms = await _probeUrl(probeUrl);
    if (ms == null) {
      throw Exception('mirror unreachable');
    }
    return ms;
  }

  /// 供测速使用的真实下载文件 URL。
  ///
  /// 优先取已检查到的最新版「当前平台安装包」资产地址——镜像对真实下载路径
  /// 的代理行为才是用户真正需要的（发布页能访问不代表安装包也能加速）；
  /// 尚未检查过最新版（或无可下载资产）时回退到 release 页面。
  String defaultProbeUrl() {
    final UpdateReleaseInfo? release = _latestRelease;
    if (release != null) {
      final UpdateAsset? asset = _selectAssetForPlatform(release.assets);
      if (asset != null && asset.browserDownloadUrl.isNotEmpty) {
        return asset.browserDownloadUrl;
      }
    }
    return 'https://github.com/nexhub-app/nexhub/releases/latest';
  }

  /// 从镜像列表中探测最快者（HEAD/Range GET 并发比较）。
  ///
  /// 全部不可用时返回 null（调用方应继续用候选链兜底，官方直连收尾）。
  Future<({String name, String prefix})?> _pickFastestMirror(String url) async {
    final List<({String name, String prefix})> mirrors = _buildMirrorList();
    if (mirrors.isEmpty) return null;
    if (mirrors.length == 1) return mirrors.first;

    final List<Future<int?>> probes = <Future<int?>>[
      for (final m in mirrors) _probeMirror(m.prefix, url),
    ];
    final List<int?> latencies = await Future.wait(probes);

    int bestIndex = -1;
    int? bestLatency;
    for (int i = 0; i < latencies.length; i++) {
      final int? l = latencies[i];
      if (l != null && (bestLatency == null || l < bestLatency)) {
        bestLatency = l;
        bestIndex = i;
      }
    }
    if (bestIndex < 0) return null;
    // 用探测到的最快镜像（而非 settings.mirrorIndex 指向的镜像），
    // 保证「自动切换高速镜像」真正生效。
    final ({String name, String prefix}) best = mirrors[bestIndex];
    _progress = _progress.copyWith(mirrorName: best.name);
    return best;
  }

  /// 清理下载目录下其他版本的残留子目录（best-effort，失败忽略）。
  ///
  /// 只删除 [base]/updates/ 下名字不等于 [keepDirName] 的子目录，
  /// 不碰目录外任何文件，避免误删用户数据。
  void _cleanStaleVersionDirs(Directory base, {required String keepDirName}) {
    try {
      final Directory updatesDir = Directory(
        '${base.path}${Platform.pathSeparator}updates',
      );
      if (!updatesDir.existsSync()) return;
      for (final FileSystemEntity e in updatesDir.listSync()) {
        if (e is! Directory) continue;
        if (e.path.endsWith(keepDirName)) continue;
        try {
          e.deleteSync(recursive: true);
        } on Object {
          // 单个目录删除失败不影响下载流程。
        }
      }
    } on Object {
      // 清理失败不影响下载。
    }
  }

  /// 粗校验本地文件是否像完整安装包：按扩展名检查文件头魔数。
  ///
  /// 防御进程被杀等异常留下的截断残留（deleteOnError 只能清 Dio 抛错的
  /// 下载，杀进程不走该路径）。仅覆盖魔数固定的格式：
  /// - .apk（zip 包）：`PK\x03\x04`
  /// - .exe（PE）：`MZ`
  /// - .zip：`PK\x03\x04`
  /// 其他扩展名（deb/dmg/AppImage 等）不做校验，直接视为可用。
  bool _looksLikeValidInstaller(File f) {
    final String n = f.path.toLowerCase();
    bool hasMagic(List<int> magic) {
      try {
        final RandomAccessFile raf = f.openSync();
        try {
          final List<int> head = raf.readSync(magic.length);
          if (head.length < magic.length) return false;
          for (int i = 0; i < magic.length; i++) {
            if (head[i] != magic[i]) return false;
          }
          return true;
        } finally {
          raf.closeSync();
        }
      } on Object {
        return false;
      }
    }

    if (n.endsWith('.apk') || n.endsWith('.zip')) {
      return hasMagic(<int>[0x50, 0x4B, 0x03, 0x04]); // "PK\x03\x04"
    }
    if (n.endsWith('.exe')) {
      return hasMagic(<int>[0x4D, 0x5A]); // "MZ"
    }
    return true;
  }

  /// 获取下载目录（临时/cache 目录；FileProvider 在 [file_paths.xml] 中已配置
  /// [cache-path]，Android 7+ 可据此生成 content:// URI 交给系统安装器）。
  /// 不可用则降级系统临时目录。
  Future<Directory> _getDownloadDirectory() async {
    try {
      return await getTemporaryDirectory();
    } on Object {
      // 忽略，降级系统临时目录
    }
    return Directory.systemTemp;
  }

  /// 安装已下载的安装包。
  ///
  /// Windows：启动 .exe 安装程序；macOS：打开 .dmg；
  /// Linux：启动安装包；Android：交给系统安装器。
  /// 返回是否成功发起安装。
  Future<bool> installDownloaded() async {
    final String? path = _downloadedPath;
    if (path == null || !File(path).existsSync()) {
      _lastError = 'No downloaded installer found';
      return false;
    }
    _status = UpdateStatus.installing;
    notifyListeners();

    try {
      if (kIsWeb) return false;
      if (Platform.isWindows || Platform.isLinux) {
        // 启动安装程序（不等待完成）
        await Process.start(
          path,
          const <String>[],
          mode: ProcessStartMode.detachedWithStdio,
        );
        return true;
      } else if (Platform.isMacOS) {
        final Uri uri = Uri.file(path);
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        return true;
      } else if (Platform.isAndroid) {
        // Android：经 MethodChannel 用 FileProvider 生成 content:// URI 交给系统安装器
        // （Android 7+ 禁止共享 file:// URI）。
        const MethodChannel channel = MethodChannel('nexhub/update_install');
        await channel.invokeMethod<void>('installApk', <String, dynamic>{
          'path': path,
        });
        return true;
      }
      return false;
    } on Object catch (e) {
      _lastError = e.toString();
      return false;
    } finally {
      _status = UpdateStatus.idle;
      notifyListeners();
    }
  }

  /// 重置状态（清除进度/错误，用于新一次更新会话）。
  void reset() {
    _status = UpdateStatus.idle;
    _progress = const UpdateProgress();
    _lastError = null;
    _downloadedPath = null;
    notifyListeners();
  }
}

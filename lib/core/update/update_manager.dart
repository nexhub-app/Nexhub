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
  final List<Map<String, dynamic>> assets;

  _ReleaseJson.fromJson(Map<String, dynamic> json)
      : tagName = json['tag_name'] as String? ?? '',
        name = json['name'] as String? ?? '',
        body = json['body'] as String? ?? '',
        htmlUrl = json['html_url'] as String? ?? '',
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
  /// 如 GitHub 官方：不替换；ghproxy：替换为 `https://ghproxy.com/https://github.com/`。
  ///
  /// 感谢以下镜像提供者的无偿服务 🙏
  static const List<({String name, String prefix})> _defaultMirrors = <({
    String name,
    String prefix,
  })>[
    (name: 'GitHub 官方', prefix: 'https://github.com/'),
    (name: 'GHProxy 镜像', prefix: 'https://ghproxy.com/https://github.com/'),
    (name: 'GHProxy.NET', prefix: 'https://ghproxy.net/https://github.com/'),
    (name: 'GH-Proxy.com', prefix: 'https://gh-proxy.com/https://github.com/'),
    (name: 'ghp.ci', prefix: 'https://ghp.ci/https://github.com/'),
    (name: 'Moeyy 镜像', prefix: 'https://moeyy.cn/gh-proxy/https://github.com/'),
    (name: 'Toolwa 镜像', prefix: 'https://toolwa.com/github/https://github.com/'),
    (name: 'Akams 镜像', prefix: 'https://github.akams.cn/https://github.com/'),
    (name: 'GitClone', prefix: 'https://gitclone.com/github.com/'),
    (name: 'FGit 镜像', prefix: 'https://hub.fgit.cf/https://github.com/'),
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
      final _ReleaseJson first =
          _ReleaseJson.fromJson(list.first as Map<String, dynamic>);
      final assets = first.assets
          .map((a) => UpdateAsset(
                name: a['name'] as String? ?? '',
                browserDownloadUrl:
                    a['browser_download_url'] as String? ?? '',
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

  /// 判断版本 a 是否比 b 新（逐数字段比较，去 v 前缀与预发布后缀）。
  bool isNewer(String a, String b) {
    List<int> norm(String v) => v
        .replaceAll(RegExp(r'^[vV]'), '')
        .split('-')
        .first
        .split('.')
        .map((e) => int.tryParse(e) ?? 0)
        .toList();
    final List<int> x = norm(a);
    final List<int> y = norm(b);
    final int n = x.length > y.length ? x.length : y.length;
    for (int i = 0; i < n; i++) {
      final int xi = i < x.length ? x[i] : 0;
      final int yi = i < y.length ? y[i] : 0;
      if (xi > yi) return true;
      if (xi < yi) return false;
    }
    return false;
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

  /// 将官方下载 URL 转换为当前镜像的 URL。
  ///
  /// [autoSwitchMirror] 开启时，先对各镜像做 HEAD 探测取最快者；
  /// 否则使用 [_settings.mirrorIndex] 指定的镜像（含自定义镜像）。
  String _mirrorUrl(String originalUrl) {
    final List<({String name, String prefix})> mirrors = _buildMirrorList();
    if (mirrors.isEmpty) return originalUrl;

    final int index = _settings.mirrorIndex.clamp(0, mirrors.length - 1);
    final mirror = mirrors[index];
    // GitHub 官方不替换；其他镜像替换前缀
    if (mirror.prefix == 'https://github.com/') return originalUrl;
    return originalUrl.replaceFirst('https://github.com/', mirror.prefix);
  }

  /// 组装镜像列表（默认镜像 + 自定义镜像）。
  List<({String name, String prefix})> _buildMirrorList() {
    final List<({String name, String prefix})> mirrors =
        List<({String name, String prefix})>.of(_defaultMirrors);
    for (final m in _settings.customMirrors) {
      if (m.name.isNotEmpty && m.baseUrl.isNotEmpty) {
        mirrors.add((name: m.name, prefix: m.baseUrl));
      }
    }
    return mirrors;
  }

  /// 测试镜像延迟（HEAD 请求），返回毫秒；失败返回 null。
  Future<int?> _probeMirror(String prefix, String url) async {
    final String probeUrl =
        prefix == 'https://github.com/' ? url : url.replaceFirst(
            'https://github.com/', prefix);
    final Stopwatch sw = Stopwatch()..start();
    try {
      await _dio.head<dynamic>(
        probeUrl,
        options: Options(
          receiveTimeout: const Duration(seconds: 5),
          sendTimeout: const Duration(seconds: 5),
          followRedirects: true,
        ),
      );
      return sw.elapsedMilliseconds;
    } on Object {
      return null;
    }
  }

  /// 下载安装包。
  ///
  /// [release] 目标版本信息；[silent] 静默模式（不弹窗、不打断）；
  /// [onProgress] 进度回调（已含 [_progress] 更新）。
  /// 返回下载后的本地文件路径。
  Future<String?> downloadInstaller(
    UpdateReleaseInfo release, {
    bool silent = false,
    void Function(double progress)? onProgress,
  }) async {
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
      // 确定目标目录：优先应用文档目录，否则临时目录
      final Directory base = await _getDownloadDirectory();
      final String targetPath =
          '${base.path}${Platform.pathSeparator}${asset.name}';

      // 未开启自动切换时直接使用当前镜像
      String url;
      if (_settings.autoSwitchMirror) {
        url = await _pickFastestMirror(asset.browserDownloadUrl);
      } else {
        url = _mirrorUrl(asset.browserDownloadUrl);
      }
      if (url.isEmpty) {
        // 所有镜像失败，退回官方原始地址
        url = asset.browserDownloadUrl;
      }

      await _dio.download(
        url,
        targetPath,
        deleteOnError: true,
        onReceiveProgress: (int received, int total) {
          final double p = total > 0 ? received / total : 0.0;
          _progress = _progress.copyWith(progress: p.clamp(0.0, 1.0));
          onProgress?.call(_progress.progress);
          notifyListeners();
        },
      );

      _progress = _progress.copyWith(progress: 1.0);
      _downloadedPath = targetPath;
      _status = UpdateStatus.done;
      notifyListeners();
      return targetPath;
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
  /// 使用 [testUrl]（默认 GitHub 项目主页）经镜像前缀转换后发起 HEAD 请求，
  /// 返回延迟毫秒；失败时抛出异常。
  Future<int> probeMirror(String prefix, {String? testUrl}) async {
    final String actualUrl = testUrl ?? 'https://github.com/nexhub-app/nexhub';
    final String probeUrl =
        prefix == 'https://github.com/' ? actualUrl : actualUrl.replaceFirst(
            'https://github.com/', prefix);
    final Stopwatch sw = Stopwatch()..start();
    await _dio.head<dynamic>(
      probeUrl,
      options: Options(
        receiveTimeout: const Duration(seconds: 5),
        sendTimeout: const Duration(seconds: 5),
        followRedirects: true,
      ),
    );
    return sw.elapsedMilliseconds;
  }

  /// 从镜像列表中选最快者（HEAD 探测并发比较）。
  Future<String> _pickFastestMirror(String url) async {
    final mirrors = _buildMirrorList();
    if (mirrors.length <= 1) return _mirrorUrl(url);

    final List<Future<int?>> probes = <Future<int?>>[
      for (final m in mirrors) _probeMirror(m.prefix, url),
    ];
    final List<int?> latencies = await Future.wait(probes);

    int bestIndex = 0;
    int? bestLatency;
    for (int i = 0; i < latencies.length; i++) {
      final int? l = latencies[i];
      if (l != null && (bestLatency == null || l < bestLatency)) {
        bestLatency = l;
        bestIndex = i;
      }
    }
    if (bestLatency == null) {
      // 全部失败：退回官方
      return url;
    }
    // 用探测到的最快镜像（而非 settings.mirrorIndex 指向的镜像）替换前缀，
    // 保证「自动切换高速镜像」真正生效。
    final ({String name, String prefix}) best = _buildMirrorList()[bestIndex];
    _progress = _progress.copyWith(mirrorName: best.name);
    if (best.prefix == 'https://github.com/') return url;
    return url.replaceFirst('https://github.com/', best.prefix);
  }

  /// 获取下载目录（应用文档目录；不可用时降级临时目录）。
  Future<Directory> _getDownloadDirectory() async {
    try {
      final Directory appDoc = await getApplicationDocumentsDirectory();
      return appDoc;
    } on Object {
      // 忽略，降级临时目录
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
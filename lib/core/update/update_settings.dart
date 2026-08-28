/// 应用内更新设置 —— 镜像源配置与更新行为偏好。
///
/// 持久化到 shared_preferences，遵循 [PrefsBackend] 抽象（可注入内存后端测试）。
library;

import 'dart:convert';

import '../comic/models/reader_preferences.dart';

/// 升级通道：稳定版只取正式 release，测试版取包含预发布（pre-release）的最新版。
enum UpdateChannel {
  /// 稳定版：跳过 pre-release，只取最新正式发布。
  stable,

  /// 测试版：取最新发布（含 pre-release），可提前体验新功能。
  beta;

  String get name => switch (this) {
        UpdateChannel.stable => 'stable',
        UpdateChannel.beta => 'beta',
      };

  static UpdateChannel fromName(String? name) => switch (name) {
        'beta' => UpdateChannel.beta,
        _ => UpdateChannel.stable,
      };
}

/// 更新下载镜像配置项。
class UpdateMirror {
  /// 镜像名称（如「GitHub 官方」「Gitee 镜像」）。
  final String name;

  /// 镜像基础地址（用于替换 GitHub 下载前缀，如 `https://mirror.example.com/`）。
  final String baseUrl;

  const UpdateMirror({required this.name, required this.baseUrl});

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'baseUrl': baseUrl,
      };

  factory UpdateMirror.fromJson(Map<String, dynamic> json) => UpdateMirror(
        name: json['name'] as String? ?? '',
        baseUrl: json['baseUrl'] as String? ?? '',
      );
}

/// 应用内更新设置数据模型。
class UpdateSettings {
  /// 是否启用自动检查更新。
  final bool autoCheck;

  /// 是否自动切换高速镜像。
  final bool autoSwitchMirror;

  /// 当前使用的镜像索引。
  final int mirrorIndex;

  /// 自定义镜像列表（空 = 使用默认镜像列表）。
  final List<UpdateMirror> customMirrors;

  /// 升级通道：稳定版只取正式 release，测试版取含预发布的最新版。
  final UpdateChannel updateChannel;

  /// 发现新版本时是否自动下载（配合 [wifiOnlyAutoDownload]）。
  final bool autoDownload;

  /// 自动下载仅在连接 WiFi 时进行；移动网络下挂起等待。
  final bool wifiOnlyAutoDownload;

  /// 应用内下载开关（默认开启）。关闭后更新仅跳转浏览器打开发布页，
  /// 不在应用内拉取安装包。
  final bool inAppDownload;

  const UpdateSettings({
    this.autoCheck = true,
    this.autoSwitchMirror = true,
    this.mirrorIndex = 0,
    this.customMirrors = const <UpdateMirror>[],
    this.updateChannel = UpdateChannel.stable,
    this.autoDownload = false,
    this.wifiOnlyAutoDownload = true,
    this.inAppDownload = true,
  });

  const UpdateSettings.defaults()
      : autoCheck = true,
        autoSwitchMirror = true,
        mirrorIndex = 0,
        customMirrors = const <UpdateMirror>[],
        updateChannel = UpdateChannel.stable,
        autoDownload = false,
        wifiOnlyAutoDownload = true,
        inAppDownload = true;

  UpdateSettings copyWith({
    bool? autoCheck,
    bool? autoSwitchMirror,
    int? mirrorIndex,
    List<UpdateMirror>? customMirrors,
    UpdateChannel? updateChannel,
    bool? autoDownload,
    bool? wifiOnlyAutoDownload,
    bool? inAppDownload,
  }) =>
      UpdateSettings(
        autoCheck: autoCheck ?? this.autoCheck,
        autoSwitchMirror: autoSwitchMirror ?? this.autoSwitchMirror,
        mirrorIndex: mirrorIndex ?? this.mirrorIndex,
        customMirrors: customMirrors ?? this.customMirrors,
        updateChannel: updateChannel ?? this.updateChannel,
        autoDownload: autoDownload ?? this.autoDownload,
        wifiOnlyAutoDownload:
            wifiOnlyAutoDownload ?? this.wifiOnlyAutoDownload,
        inAppDownload: inAppDownload ?? this.inAppDownload,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'autoCheck': autoCheck,
        'autoSwitchMirror': autoSwitchMirror,
        'mirrorIndex': mirrorIndex,
        'customMirrors': customMirrors
            .map((m) => m.toJson())
            .toList(growable: false),
        'updateChannel': updateChannel.name,
        'autoDownload': autoDownload,
        'wifiOnlyAutoDownload': wifiOnlyAutoDownload,
        'inAppDownload': inAppDownload,
      };

  factory UpdateSettings.fromJson(Map<String, dynamic> json) => UpdateSettings(
        autoCheck: json['autoCheck'] as bool? ?? true,
        autoSwitchMirror: json['autoSwitchMirror'] as bool? ?? true,
        mirrorIndex: json['mirrorIndex'] as int? ?? 0,
        customMirrors: (json['customMirrors'] as List<dynamic>?)
                ?.map((e) => UpdateMirror.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const <UpdateMirror>[],
        updateChannel:
            UpdateChannel.fromName(json['updateChannel'] as String?),
        autoDownload: json['autoDownload'] as bool? ?? false,
        wifiOnlyAutoDownload:
            json['wifiOnlyAutoDownload'] as bool? ?? true,
        inAppDownload: json['inAppDownload'] as bool? ?? true,
      );

  String toJsonString() => jsonEncode(toJson());

  static UpdateSettings fromJsonString(String raw) =>
      UpdateSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
}

/// 更新设置持久化存储（键 `update_settings`）。
class UpdateSettingsStore {
  static const String _key = 'update_settings';

  final PrefsBackend _backend;

  UpdateSettingsStore({PrefsBackend? backend})
      : _backend = backend ?? const SharedPrefsBackend();

  Future<UpdateSettings> load() async {
    final raw = await _backend.get(_key);
    if (raw == null || raw.isEmpty) return const UpdateSettings.defaults();
    try {
      return UpdateSettings.fromJsonString(raw);
    } on Object {
      return const UpdateSettings.defaults();
    }
  }

  Future<void> save(UpdateSettings settings) async {
    await _backend.set(_key, settings.toJsonString());
  }
}
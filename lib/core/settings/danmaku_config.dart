/// 弹弹 play 弹幕配置（AppId / AppSecret）。
///
/// 持久化到 shared_preferences，遵循 [PrefsBackend] 抽象。
library;

import 'dart:convert';

import '../../core/comic/models/reader_preferences.dart';

/// 弹弹 play 弹幕配置数据模型。
class DanmakuConfig {
  final String appId;
  final String appSecret;
  final bool enabled;

  const DanmakuConfig({
    this.appId = '',
    this.appSecret = '',
    this.enabled = false,
  });

  const DanmakuConfig.defaults()
      : appId = '',
        appSecret = '',
        enabled = false;

  bool get isConfigured => appId.isNotEmpty && appSecret.isNotEmpty;

  DanmakuConfig copyWith({
    String? appId,
    String? appSecret,
    bool? enabled,
  }) =>
      DanmakuConfig(
        appId: appId ?? this.appId,
        appSecret: appSecret ?? this.appSecret,
        enabled: enabled ?? this.enabled,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'appId': appId,
        'appSecret': appSecret,
        'enabled': enabled,
      };

  factory DanmakuConfig.fromJson(Map<String, dynamic> json) => DanmakuConfig(
        appId: json['appId'] as String? ?? '',
        appSecret: json['appSecret'] as String? ?? '',
        enabled: json['enabled'] as bool? ?? false,
      );

  String toJsonString() => jsonEncode(toJson());

  static DanmakuConfig fromJsonString(String raw) =>
      DanmakuConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
}

/// 弹幕配置持久化存储（键 `danmaku_config`）。
///
/// 凭据来源优先级：
/// 1. 用户曾通过界面/脚本保存的 shared_preferences 值（最高优先）；
/// 2. 编译期通过 `--dart-define=DANMAKU_APP_ID/DANMAKU_APP_SECRET` 注入的本地凭据
///    （不写入仓库，仅存在于本地构建产物中）。首次读取到 env 凭据时会自动持久化，
///    使后续普通运行（不带 --dart-define）也能使用。
class DanmakuConfigStore {
  static const String _key = 'danmaku_config';

  // 编译期注入的本地凭据（空字符串表示未注入）。这些值不会出现在仓库源码中。
  static const String _envAppId = String.fromEnvironment('DANMAKU_APP_ID');
  static const String _envSecret =
      String.fromEnvironment('DANMAKU_APP_SECRET');

  final PrefsBackend _backend;

  DanmakuConfigStore({PrefsBackend? backend})
      : _backend = backend ?? const SharedPrefsBackend();

  Future<DanmakuConfig> load() async {
    final raw = await _backend.get(_key);
    if (raw == null || raw.isEmpty) {
      // 回退：读取编译期注入的本地凭据。
      if (_envAppId.isNotEmpty && _envSecret.isNotEmpty) {
        final cfg = DanmakuConfig(
          appId: _envAppId,
          appSecret: _envSecret,
          enabled: true,
        );
        // 持久化，使首次脚本化运行后普通运行也可用。
        await save(cfg);
        return cfg;
      }
      return const DanmakuConfig.defaults();
    }
    try {
      return DanmakuConfig.fromJsonString(raw);
    } on Object {
      return const DanmakuConfig.defaults();
    }
  }

  Future<void> save(DanmakuConfig config) async {
    await _backend.set(_key, config.toJsonString());
  }
}

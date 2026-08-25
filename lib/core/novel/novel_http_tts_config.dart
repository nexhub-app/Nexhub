/// 在线 HTTP TTS 配置（P2-3 / C3）。
///
/// 用户自建或第三方 TTS 服务端点模板：URL 中支持占位符
/// `{text}`（U 编码）、`{voice}`（音色 id）、`{rate}`（语速 0.5-2.0）。
/// 可选角色 → 音色映射（多角色 C5：分句器判出的角色名映射到具体 voice id，
/// 未匹配角色回退默认音色）。
/// 持久化于 SharedPreferences（key: `novel_http_tts_config_v1`）。
library;

import 'dart:convert';

import '../comic/models/reader_preferences.dart'
    show PrefsBackend, SharedPrefsBackend;

/// 在线 TTS 配置。
class NovelHttpTtsConfig {
  /// 是否启用在线 TTS（false = 继续使用 flutter_tts 离线引擎）。
  final bool enabled;

  /// URL 模板，占位符：{text} / {voice} / {rate}。
  final String urlTemplate;

  /// 默认音色 id（模板 {voice} 未映射角色时的回退值）。
  final String defaultVoice;

  /// 角色 → 音色 id 映射（C5 多角色）。
  final Map<String, String> voiceByRole;

  /// 预下载并发数（1-8，Semaphore 上限）。
  final int concurrency;

  /// 连续合成失败达到此数后停止本轮朗读（默认 3）。
  final int maxConsecutiveFailures;

  /// 单句失败时是否「静音占位降级」（C7）：跳过该句但继续朗读剩余句。
  final bool silentPlaceholderOnFailure;

  const NovelHttpTtsConfig({
    this.enabled = false,
    this.urlTemplate = '',
    this.defaultVoice = '',
    this.voiceByRole = const <String, String>{},
    this.concurrency = 2,
    this.maxConsecutiveFailures = 3,
    this.silentPlaceholderOnFailure = true,
  });

  NovelHttpTtsConfig copyWith({
    bool? enabled,
    String? urlTemplate,
    String? defaultVoice,
    Map<String, String>? voiceByRole,
    int? concurrency,
    int? maxConsecutiveFailures,
    bool? silentPlaceholderOnFailure,
  }) {
    return NovelHttpTtsConfig(
      enabled: enabled ?? this.enabled,
      urlTemplate: urlTemplate ?? this.urlTemplate,
      defaultVoice: defaultVoice ?? this.defaultVoice,
      voiceByRole: voiceByRole ?? this.voiceByRole,
      concurrency: concurrency ?? this.concurrency,
      maxConsecutiveFailures:
          maxConsecutiveFailures ?? this.maxConsecutiveFailures,
      silentPlaceholderOnFailure:
          silentPlaceholderOnFailure ?? this.silentPlaceholderOnFailure,
    );
  }

  /// 按角色解析音色（C5）：命中映射表取专属音色，否则回退默认音色。
  String voiceForRole(String role) {
    if (role.isEmpty) return defaultVoice;
    return voiceByRole[role] ?? defaultVoice;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'enabled': enabled,
        'urlTemplate': urlTemplate,
        'defaultVoice': defaultVoice,
        'voiceByRole': voiceByRole,
        'concurrency': concurrency,
        'maxConsecutiveFailures': maxConsecutiveFailures,
        'silentPlaceholderOnFailure': silentPlaceholderOnFailure,
      };

  factory NovelHttpTtsConfig.fromJson(Map<String, dynamic> json) {
    final rawMap = json['voiceByRole'];
    return NovelHttpTtsConfig(
      enabled: json['enabled'] as bool? ?? false,
      urlTemplate: json['urlTemplate'] as String? ?? '',
      defaultVoice: json['defaultVoice'] as String? ?? '',
      voiceByRole: rawMap is Map<String, dynamic>
          ? rawMap.map((k, v) => MapEntry(k, v.toString()))
          : const <String, String>{},
      concurrency: (json['concurrency'] as num?)?.toInt().clamp(1, 8) ?? 2,
      maxConsecutiveFailures:
          (json['maxConsecutiveFailures'] as num?)?.toInt() ?? 3,
      silentPlaceholderOnFailure:
          json['silentPlaceholderOnFailure'] as bool? ?? true,
    );
  }
}

/// 配置持久化。
class NovelHttpTtsConfigStore {
  NovelHttpTtsConfigStore({PrefsBackend? backend})
      : _backend = backend ?? const SharedPrefsBackend();

  final PrefsBackend _backend;
  static const String key = 'novel_http_tts_config_v1';

  Future<NovelHttpTtsConfig> load() async {
    final raw = await _backend.get(key);
    if (raw == null || raw.isEmpty) return const NovelHttpTtsConfig();
    try {
      return NovelHttpTtsConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on Object {
      return const NovelHttpTtsConfig();
    }
  }

  Future<void> save(NovelHttpTtsConfig config) async {
    await _backend.set(key, jsonEncode(config.toJson()));
  }
}
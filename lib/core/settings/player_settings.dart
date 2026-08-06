/// 播放器默认设置模型（全局默认值，播放时可临时覆盖）。
///
/// 持久化到 SharedPreferences（key: `player_settings_v1`），
/// 复用 [PrefsBackend] 抽象以便测试注入。
library;

import 'dart:convert';

import '../comic/models/reader_preferences.dart';

/// 解码模式。
enum DecodeMode { auto, sw, hw, hwPlus }

/// 音频通道。
enum AudioChannel { auto, stereo, mono }

/// 画面比例。
enum PlayerAspectRatio { defaultRatio, ratio43, ratio169, fill }

/// 播放器锁定方向（项 1：合并旧 playerDefaultOrientation + 锁方向）。
enum PlayerLockOrientation { auto, portrait, landscape }

/// 播放器左右拖动 Seek 区间倍率。
enum SeekMultiplier { half, normal, double }

/// 播放器默认设置。
class PlayerSettings {
  final DecodeMode decodeMode;
  final AudioChannel audioChannel;
  final PlayerAspectRatio aspectRatio;
  final double playbackSpeed;
  final bool autoPlayNext;
  final double subtitleFontSize;
  final PlayerLockOrientation lockOrientation;
  final SeekMultiplier seekMultiplier;
  final bool longPressSpeedUp;
  /// 长按加速时切换到的自定义倍速（默认 2.0x）。
  final double longPressSpeed;
  final double defaultVolume;
  final String screenshotSavePath;
  final double subtitleScale;
  final double subtitleBorderSize;
  final double subtitleShadowOffset;
  final String subtitleColor;
  final String subtitleBorderColor;
  final String subtitleShadowColor;
  final String subtitlePosition;
  final String subtitleAssMode;
  final int subtitleDelayMs;
  final bool subtitleVisible;

  const PlayerSettings({
    this.decodeMode = DecodeMode.auto,
    this.audioChannel = AudioChannel.auto,
    this.aspectRatio = PlayerAspectRatio.defaultRatio,
    this.playbackSpeed = 1.0,
    this.autoPlayNext = true,
    this.subtitleFontSize = 16.0,
    this.lockOrientation = PlayerLockOrientation.landscape,
    this.seekMultiplier = SeekMultiplier.normal,
    this.longPressSpeedUp = true,
    this.longPressSpeed = 2.0,
    this.defaultVolume = 100.0,
    this.screenshotSavePath = '',
    this.subtitleScale = 1.0,
    this.subtitleBorderSize = 1.5,
    this.subtitleShadowOffset = 2.0,
    this.subtitleColor = 'FFFFFF',
    this.subtitleBorderColor = '000000',
    this.subtitleShadowColor = '000000',
    this.subtitlePosition = 'bottom',
    this.subtitleAssMode = 'yes',
    this.subtitleDelayMs = 0,
    this.subtitleVisible = true,
  });

  PlayerSettings copyWith({
    DecodeMode? decodeMode,
    AudioChannel? audioChannel,
    PlayerAspectRatio? aspectRatio,
    double? playbackSpeed,
    bool? autoPlayNext,
    double? subtitleFontSize,
    PlayerLockOrientation? lockOrientation,
    SeekMultiplier? seekMultiplier,
    bool? longPressSpeedUp,
    double? longPressSpeed,
    double? defaultVolume,
    String? screenshotSavePath,
    double? subtitleScale,
    double? subtitleBorderSize,
    double? subtitleShadowOffset,
    String? subtitleColor,
    String? subtitleBorderColor,
    String? subtitleShadowColor,
    String? subtitlePosition,
    String? subtitleAssMode,
    int? subtitleDelayMs,
    bool? subtitleVisible,
  }) =>
      PlayerSettings(
        decodeMode: decodeMode ?? this.decodeMode,
        audioChannel: audioChannel ?? this.audioChannel,
        aspectRatio: aspectRatio ?? this.aspectRatio,
        playbackSpeed: playbackSpeed ?? this.playbackSpeed,
        autoPlayNext: autoPlayNext ?? this.autoPlayNext,
        subtitleFontSize: subtitleFontSize ?? this.subtitleFontSize,
        lockOrientation: lockOrientation ?? this.lockOrientation,
        seekMultiplier: seekMultiplier ?? this.seekMultiplier,
        longPressSpeedUp: longPressSpeedUp ?? this.longPressSpeedUp,
        longPressSpeed: longPressSpeed ?? this.longPressSpeed,
        defaultVolume: defaultVolume ?? this.defaultVolume,
        screenshotSavePath: screenshotSavePath ?? this.screenshotSavePath,
        subtitleScale: subtitleScale ?? this.subtitleScale,
        subtitleBorderSize: subtitleBorderSize ?? this.subtitleBorderSize,
        subtitleShadowOffset:
            subtitleShadowOffset ?? this.subtitleShadowOffset,
        subtitleColor: subtitleColor ?? this.subtitleColor,
        subtitleBorderColor: subtitleBorderColor ?? this.subtitleBorderColor,
        subtitleShadowColor: subtitleShadowColor ?? this.subtitleShadowColor,
        subtitlePosition: subtitlePosition ?? this.subtitlePosition,
        subtitleAssMode: subtitleAssMode ?? this.subtitleAssMode,
        subtitleDelayMs: subtitleDelayMs ?? this.subtitleDelayMs,
        subtitleVisible: subtitleVisible ?? this.subtitleVisible,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'decodeMode': decodeMode.name,
        'audioChannel': audioChannel.name,
        'aspectRatio': aspectRatio.name,
        'playbackSpeed': playbackSpeed,
        'autoPlayNext': autoPlayNext,
        'subtitleFontSize': subtitleFontSize,
        'lockOrientation': lockOrientation.name,
        'seekMultiplier': seekMultiplier.name,
        'longPressSpeedUp': longPressSpeedUp,
        'longPressSpeed': longPressSpeed,
        'defaultVolume': defaultVolume,
        'screenshotSavePath': screenshotSavePath,
        'subtitleScale': subtitleScale,
        'subtitleBorderSize': subtitleBorderSize,
        'subtitleShadowOffset': subtitleShadowOffset,
        'subtitleColor': subtitleColor,
        'subtitleBorderColor': subtitleBorderColor,
        'subtitleShadowColor': subtitleShadowColor,
        'subtitlePosition': subtitlePosition,
        'subtitleAssMode': subtitleAssMode,
        'subtitleDelayMs': subtitleDelayMs,
        'subtitleVisible': subtitleVisible,
      };

  factory PlayerSettings.fromJson(Map<String, dynamic> json) {
    DecodeMode decodeMode = DecodeMode.auto;
    if (json['decodeMode'] is String) {
      decodeMode = DecodeMode.values.firstWhere(
        (e) => e.name == json['decodeMode'],
        orElse: () => DecodeMode.auto,
      );
    }
    AudioChannel audioChannel = AudioChannel.auto;
    if (json['audioChannel'] is String) {
      audioChannel = AudioChannel.values.firstWhere(
        (e) => e.name == json['audioChannel'],
        orElse: () => AudioChannel.auto,
      );
    }
    PlayerAspectRatio aspectRatio = PlayerAspectRatio.defaultRatio;
    if (json['aspectRatio'] is String) {
      aspectRatio = PlayerAspectRatio.values.firstWhere(
        (e) => e.name == json['aspectRatio'],
        orElse: () => PlayerAspectRatio.defaultRatio,
      );
    }
    PlayerLockOrientation lockOrientation = PlayerLockOrientation.auto;
    if (json['lockOrientation'] is String) {
      lockOrientation = PlayerLockOrientation.values.firstWhere(
        (e) => e.name == json['lockOrientation'],
        orElse: () => PlayerLockOrientation.auto,
      );
    }
    SeekMultiplier seekMultiplier = SeekMultiplier.normal;
    if (json['seekMultiplier'] is String) {
      seekMultiplier = SeekMultiplier.values.firstWhere(
        (e) => e.name == json['seekMultiplier'],
        orElse: () => SeekMultiplier.normal,
      );
    }
    return PlayerSettings(
      decodeMode: decodeMode,
      audioChannel: audioChannel,
      aspectRatio: aspectRatio,
      playbackSpeed: (json['playbackSpeed'] as num?)?.toDouble() ?? 1.0,
      autoPlayNext: json['autoPlayNext'] as bool? ?? true,
      subtitleFontSize:
          (json['subtitleFontSize'] as num?)?.toDouble() ?? 16.0,
      lockOrientation: lockOrientation,
      seekMultiplier: seekMultiplier,
      longPressSpeedUp: json['longPressSpeedUp'] as bool? ?? true,
      longPressSpeed:
          (json['longPressSpeed'] as num?)?.toDouble() ?? 2.0,
      defaultVolume:
          (json['defaultVolume'] as num?)?.toDouble() ?? 100.0,
      screenshotSavePath:
          json['screenshotSavePath'] as String? ?? '',
      subtitleScale:
          (json['subtitleScale'] as num?)?.toDouble() ?? 1.0,
      subtitleBorderSize:
          (json['subtitleBorderSize'] as num?)?.toDouble() ?? 1.5,
      subtitleShadowOffset:
          (json['subtitleShadowOffset'] as num?)?.toDouble() ?? 2.0,
      subtitleColor: json['subtitleColor'] as String? ?? 'FFFFFF',
      subtitleBorderColor:
          json['subtitleBorderColor'] as String? ?? '000000',
      subtitleShadowColor:
          json['subtitleShadowColor'] as String? ?? '000000',
      subtitlePosition:
          json['subtitlePosition'] as String? ?? 'bottom',
      subtitleAssMode: json['subtitleAssMode'] as String? ?? 'yes',
      subtitleDelayMs: json['subtitleDelayMs'] as int? ?? 0,
      subtitleVisible: json['subtitleVisible'] as bool? ?? true,
    );
  }
}

/// 播放器设置持久化存储（key: `player_settings_v1`）。
class PlayerSettingsStore {
  static const String _key = 'player_settings_v1';

  final PrefsBackend _backend;

  PlayerSettingsStore({PrefsBackend? backend})
      : _backend = backend ?? const SharedPrefsBackend();

  Future<PlayerSettings> load() async {
    final raw = await _backend.get(_key);
    if (raw == null || raw.isEmpty) return const PlayerSettings();
    try {
      return PlayerSettings.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } on Object {
      return const PlayerSettings();
    }
  }

  Future<void> save(PlayerSettings settings) async {
    await _backend.set(_key, jsonEncode(settings.toJson()));
  }
}

/// 按剧集记忆的播放器设置覆盖（key: `episode_player_settings_v1`）。
///
/// 播放器内弹窗（更多菜单 / 快捷行）修改的音画参数属于「该视频的单独设置」，
/// 只持久化**用户实际改过的字段**；读取时与全局 [PlayerSettings] 合并——
/// 覆盖字段优先，其余字段跟随全局默认。清除覆盖后回到「跟随全局」。
///
/// 值结构：`{"<itemId>": {"decodeMode": "hw", "playbackSpeed": 2.0, ...}}`。
class EpisodePlayerSettingsStore {
  static const String _key = 'episode_player_settings_v1';

  final PrefsBackend _backend;

  EpisodePlayerSettingsStore({PrefsBackend? backend})
      : _backend = backend ?? const SharedPrefsBackend();

  Future<Map<String, dynamic>> _loadAll() async {
    final raw = await _backend.get(_key);
    if (raw == null || raw.isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
    } on Object {
      // 数据损坏时按空处理，不影响播放。
    }
    return <String, dynamic>{};
  }

  /// 读取某剧集已覆盖的字段（无覆盖返回空 Map）。
  Future<Map<String, dynamic>> loadOverrides(String itemId) async {
    final all = await _loadAll();
    final value = all[itemId];
    return value is Map<String, dynamic> ? value : <String, dynamic>{};
  }

  /// 合并全局设置：覆盖字段优先，其余取全局默认值。
  Future<PlayerSettings> loadMerged(
    PlayerSettings global,
    String itemId,
  ) async {
    final overrides = await loadOverrides(itemId);
    if (overrides.isEmpty) return global;
    return PlayerSettings.fromJson(
      <String, dynamic>{...global.toJson(), ...overrides},
    );
  }

  /// 写入某剧集的单个覆盖字段（只存用户实际改过的项）。
  Future<void> setField(String itemId, String field, Object? value) async {
    final all = await _loadAll();
    final overrides =
        all[itemId] is Map<String, dynamic>
            ? all[itemId]! as Map<String, dynamic>
            : <String, dynamic>{};
    overrides[field] = value;
    all[itemId] = overrides;
    await _backend.set(_key, jsonEncode(all));
  }

  /// 清除某剧集全部覆盖，恢复跟随全局默认。
  Future<void> clearOverrides(String itemId) async {
    final all = await _loadAll();
    all.remove(itemId);
    await _backend.set(_key, jsonEncode(all));
  }
}

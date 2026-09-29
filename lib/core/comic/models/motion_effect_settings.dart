/// 漫画阅读器「页面动态效果」设置模型 + 效果目录。
///
/// 应用侧投影 [comic_motion] 引擎的 [EffectConfig]：
/// - 每种效果可独立开关（[effects] 列表，引擎按名字匹配 [EffectKind]）；
/// - 每种效果可调参数（[paramOverrides] 稀疏覆盖，未覆盖键走引擎默认值）；
/// - 全局质量参数（帧率 / 周期 / 渲染分辨率上限）。
///
/// 持久化：经 [ReaderPreferences.toJson] 以嵌套 JSON 存储；「本书单独设置」
/// 的 mergedWithKeys 走 JSON 合并，本模型整体作为一个键参与合并。
library;

import 'package:comic_motion/comic_motion.dart' show EffectConfig;

/// 条漫滚动模式的动态效果渲染时机。
enum MotionWebtoonRenderMode {
  /// 停留渲染：滚动停止约 1 秒后才渲染可见页（省电，默认）。
  dwell,

  /// 实时跟随：视野变化立即切换渲染目标（滚动中也能更快出效果，
  /// CPU / 电量开销更高）。
  follow;
}

/// 漫画动态效果总开关 + 逐效果开关 + 参数覆盖 + 全局质量参数。
///
/// 值对象约定：实例不可变（const 可构造），修改一律走 [copyWith] /
/// [withEffectEnabled] / [withParam] 生成新实例。[effects] /
/// [paramOverrides] 传入后不再做防御性拷贝，内部构造点均传常量或规范列表。
class MotionEffectSettings {
  const MotionEffectSettings({
    this.enabled = false,
    this.effects = defaultEffectNames,
    this.paramOverrides = const {},
    this.fps = defaultFps,
    this.durationSec = defaultDurationSec,
    this.maxDimension = defaultMaxDimension,
    this.webtoonRenderMode = MotionWebtoonRenderMode.dwell,
  });

  /// 主开关。关闭 = 完全静态（零额外开销：不派发渲染任务）。
  final bool enabled;

  /// 启用的效果名（[MotionEffectCatalog.allKinds] 的子集，按目录序）。
  final List<String> effects;

  /// 每效果参数覆盖：效果名 → 参数键 → 值（num / String）。
  /// 稀疏存储：仅存用户显式调过的键，其余走引擎默认。
  final Map<String, Map<String, Object?>> paramOverrides;

  /// 动效帧率（GIF 循环帧率），范围 6–24。
  final int fps;

  /// 单个循环时长（秒），范围 2.0–6.0。整数倍循环保证 GIF 无缝。
  final double durationSec;

  /// 渲染分辨率上限（最长边像素），范围 480–1080。
  final int maxDimension;

  /// 条漫滚动模式的渲染时机（[MotionWebtoonRenderMode.dwell] 省电默认 /
  /// [MotionWebtoonRenderMode.follow] 实时跟随）。仅条漫滚动模式读取。
  final MotionWebtoonRenderMode webtoonRenderMode;

  static const int defaultFps = 12;
  static const double defaultDurationSec = 3.0;
  static const int defaultMaxDimension = 720;

  /// 默认启用的效果（经典氛围三件套）。
  static const List<String> defaultEffectNames = <String>[
    'parallax',
    'breathing',
    'ambient',
  ];

  static List<String> _sanitizeEffects(List<String> raw) {
    final known = MotionEffectCatalog.allKinds.toSet();
    final seen = <String>{};
    for (final name in raw) {
      if (known.contains(name)) seen.add(name);
    }
    // 保持目录顺序（目录序 = 设置页展示序），过滤未知名。
    return MotionEffectCatalog.allKinds
        .where(seen.contains)
        .map((e) => e)
        .toList();
  }

  MotionEffectSettings copyWith({
    bool? enabled,
    List<String>? effects,
    Map<String, Map<String, Object?>>? paramOverrides,
    int? fps,
    double? durationSec,
    int? maxDimension,
    MotionWebtoonRenderMode? webtoonRenderMode,
  }) {
    return MotionEffectSettings(
      enabled: enabled ?? this.enabled,
      effects: effects ?? this.effects,
      paramOverrides: paramOverrides ?? this.paramOverrides,
      fps: fps ?? this.fps,
      durationSec: durationSec ?? this.durationSec,
      maxDimension: maxDimension ?? this.maxDimension,
      webtoonRenderMode: webtoonRenderMode ?? this.webtoonRenderMode,
    );
  }

  /// 单效果开关：on/off 切换 [kind]，其余不变。
  MotionEffectSettings withEffectEnabled(String kind, bool on) {
    final set = effects.toSet();
    if (on) {
      set.add(kind);
    } else {
      set.remove(kind);
    }
    return copyWith(
        effects: MotionEffectCatalog.allKinds.where(set.contains).toList());
  }

  /// 设置某效果某参数的覆盖值（value 为 null = 清除覆盖，回引擎默认）。
  MotionEffectSettings withParam(String kind, String key, num? value) {
    final next = <String, Map<String, Object?>>{
      for (final e in paramOverrides.entries) e.key: Map.of(e.value),
    };
    if (value == null) {
      next[kind]?.remove(key);
      if (next[kind]?.isEmpty ?? false) next.remove(kind);
    } else {
      (next[kind] ??= {})[key] = value;
    }
    return copyWith(paramOverrides: next);
  }

  /// 查询参数当前值：覆盖 > 引擎目录默认。
  num paramValue(MotionEffectSpec spec, MotionParamSpec p) {
    final overridden = paramOverrides[spec.kind]?[p.key];
    if (overridden is num) return overridden;
    return p.def;
  }

  /// 值相等（深比较）：阅读器据此判断「动态效果设置是否真的变了」。
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MotionEffectSettings &&
          enabled == other.enabled &&
          fps == other.fps &&
          durationSec == other.durationSec &&
          maxDimension == other.maxDimension &&
          webtoonRenderMode == other.webtoonRenderMode &&
          _listEquals(effects, other.effects) &&
          _mapEquals(paramOverrides, other.paramOverrides);

  static bool _listEquals(List<String> a, List<String> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _mapEquals(
    Map<String, Map<String, Object?>> a,
    Map<String, Map<String, Object?>> b,
  ) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      final inner = b[e.key];
      if (inner == null || inner.length != e.value.length) return false;
      for (final p in e.value.entries) {
        // num 跨 int/double 数值相等（5 == 5.0）由 Dart == 语义覆盖。
        if (inner[p.key] != p.value) return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        enabled,
        fps,
        durationSec,
        maxDimension,
        webtoonRenderMode,
        Object.hashAll(effects),
        Object.hashAllUnordered(paramOverrides.keys),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'enabled': enabled,
        'effects': effects,
        'paramOverrides': paramOverrides,
        'fps': fps,
        'durationSec': durationSec,
        'maxDimension': maxDimension,
        'webtoonRenderMode': webtoonRenderMode.name,
      };

  factory MotionEffectSettings.fromJson(dynamic raw) {
    if (raw is MotionEffectSettings) return raw;
    if (raw is! Map) return const MotionEffectSettings();
    final j = raw.cast<String, dynamic>();
    final fps = ((j['fps'] as num?)?.toInt() ?? defaultFps).clamp(6, 24);
    final dur = (j['durationSec'] as num?)?.toDouble() ?? defaultDurationSec;
    final dim = ((j['maxDimension'] as num?)?.toInt() ?? defaultMaxDimension)
        .clamp(480, 1080);
    return MotionEffectSettings(
      enabled: j['enabled'] as bool? ?? false,
      effects: _sanitizeEffects(
        (j['effects'] as List?)?.cast<String>().toList() ?? defaultEffectNames,
      ),
      paramOverrides: (j['paramOverrides'] as Map?)?.map(
            (k, v) => MapEntry(
              k as String,
              (v as Map?)?.cast<String, Object?>() ?? <String, Object?>{},
            ),
          ) ??
          const {},
      fps: fps,
      durationSec: dur.clamp(2.0, 6.0),
      maxDimension: dim,
      webtoonRenderMode: j['webtoonRenderMode'] == 'follow'
          ? MotionWebtoonRenderMode.follow
          : MotionWebtoonRenderMode.dwell,
    );
  }

  /// 组装引擎配置（EffectConfig.fromJson 做最终校验与默认值回填）。
  ///
  /// [maxFrames] 随 fps×durationSec 派生并放宽上限，避免长周期被引擎钳短。
  EffectConfig toEffectConfig() => _buildEffectConfig(
        fps: fps,
        durationSec: durationSec,
        maxDimension: maxDimension,
      );

  /// 快速渲染配置（实时跟随模式滚动中用）：降帧 / 缩短周期 / 降分辨率上限
  /// （效果组合与用户参数覆盖保持不变，只压缩渲染成本，出图更快）。
  /// 滚动停止后由 [toEffectConfig] 的完整画质渲染升级替换。
  EffectConfig toFastEffectConfig() => _buildEffectConfig(
        fps: fps > fastFpsCap ? fastFpsCap : fps,
        durationSec:
            durationSec > fastDurationSecCap ? fastDurationSecCap : durationSec,
        maxDimension:
            maxDimension > fastMaxDimensionCap ? fastMaxDimensionCap : maxDimension,
      );

  /// 快速版帧率上限。
  static const int fastFpsCap = 8;

  /// 快速版循环时长上限（秒）。
  static const double fastDurationSecCap = 2.0;

  /// 快速版渲染分辨率上限（最长边像素）。
  static const int fastMaxDimensionCap = 480;

  EffectConfig _buildEffectConfig({
    required int fps,
    required double durationSec,
    required int maxDimension,
  }) {
    // 防御性过滤：直接构造（绕过 fromJson）时可能带未知名，引擎对未知效果
    // 名 fail-fast，这里先按目录过滤；全部无效则回退默认组合。
    final known = MotionEffectCatalog.allKinds.toSet();
    var names = effects.where(known.contains).toList();
    if (names.isEmpty) names = defaultEffectNames;
    final frameCount = (fps * durationSec).ceil();
    final json = <String, dynamic>{
      'effects': names,
      'fps': fps,
      'durationSec': durationSec,
      'maxDimension': maxDimension,
      'maxFrames': frameCount < 2 ? 2 : frameCount + 2,
      'outputFormat': 'gif',
      'depthMode': 'autoLayers',
      'layerCount': 3,
      for (final e in paramOverrides.entries)
        if (names.contains(e.key) && e.value.isNotEmpty) e.key: e.value,
    };
    return EffectConfig.fromJson(json);
  }
}

/// 快速预设：效果开关组合（不携带参数覆盖，应用后参数回引擎默认）。
class MotionEffectPreset {
  const MotionEffectPreset(this.id, this.labelKey, this.effects);

  final String id;
  final String labelKey;
  final List<String> effects;
}

/// 单个数值参数的 UI 描述（滑杆范围 / 步进 / 默认）。
class MotionParamSpec {
  const MotionParamSpec(
    this.key,
    this.labelKey, {
    required this.min,
    required this.max,
    this.step = 0.01,
    this.isInt = false,
    required this.def,
  });

  /// 引擎参数键（EffectConfig 各 Params JSON 键）。
  final String key;

  /// 文案键（通用参数名词表：幅度 / 数量 / 速度…）。
  final String labelKey;

  final double min;
  final double max;

  /// 滑杆步进（isInt 时取整）。
  final double step;

  final bool isInt;

  /// 引擎默认值（未覆盖时显示的值）。
  final num def;

  /// 用户改动是否需要重新渲染才生效（恒 true——参数全部参与离线渲染）。
  bool get affectsRender => true;
}

/// 单个效果的目录条目：名字 / 文案键 / 可调参数表。
class MotionEffectSpec {
  const MotionEffectSpec(
    this.kind,
    this.labelKey, {
    this.params = const [],
  });

  /// 引擎 EffectKind.name。
  final String kind;

  /// 文案键（效果名）。
  final String labelKey;

  final List<MotionParamSpec> params;
}

/// 效果目录：全部 32 种效果按 4 组组织，任何一种都可独立开关。
abstract final class MotionEffectCatalog {
  /// 基础氛围。
  static const String groupAmbient = 'ambient';

  /// 粒子天气。
  static const String groupParticles = 'particles';

  /// 光影明暗。
  static const String groupLight = 'light';

  /// 漫画动势。
  static const String groupManga = 'manga';

  static const List<MotionEffectSpec> specs = <MotionEffectSpec>[
    // ── 基础氛围 ──
    MotionEffectSpec(
      'parallax',
      'motionFxParallax',
      params: [
        MotionParamSpec('amplitude', 'motionParamAmplitude',
            min: 0.002, max: 0.04, def: 0.012),
        MotionParamSpec('periodSec', 'motionParamPeriod',
            min: 2, max: 12, step: 0.5, def: 6),
        MotionParamSpec('verticalRatio', 'motionParamVerticalRatio',
            min: 0, max: 1, def: 0.35),
      ],
    ),
    MotionEffectSpec(
      'breathing',
      'motionFxBreathing',
      params: [
        MotionParamSpec('amplitude', 'motionParamAmplitude',
            min: 0.002, max: 0.02, def: 0.006),
        MotionParamSpec('periodSec', 'motionParamPeriod',
            min: 2, max: 10, step: 0.5, def: 4),
      ],
    ),
    MotionEffectSpec(
      'slowPush',
      'motionFxSlowPush',
      params: [
        MotionParamSpec('pushFrac', 'motionParamPushFrac',
            min: 0.005, max: 0.08, def: 0.035),
      ],
    ),
    MotionEffectSpec(
      'heartbeat',
      'motionFxHeartbeat',
      params: [
        MotionParamSpec('beats', 'motionParamBeats',
            min: 1, max: 6, step: 1, isInt: true, def: 3),
        MotionParamSpec('intensity', 'motionParamIntensity',
            min: 0.005, max: 0.03, def: 0.01),
      ],
    ),
    MotionEffectSpec(
      'toneShift',
      'motionFxToneShift',
      params: [
        MotionParamSpec('shift', 'motionParamShift',
            min: 0.01, max: 0.15, def: 0.05),
      ],
    ),
    MotionEffectSpec(
      'vignette',
      'motionFxVignette',
      params: [
        MotionParamSpec('strength', 'motionParamStrength',
            min: 0.05, max: 0.8, def: 0.3),
      ],
    ),

    // ── 粒子天气 ──
    MotionEffectSpec(
      'ambient',
      'motionFxAmbient',
      params: [
        MotionParamSpec('particleCount', 'motionParamCount',
            min: 10, max: 120, step: 1, isInt: true, def: 40),
        MotionParamSpec('speed', 'motionParamSpeed',
            min: 4, max: 40, step: 1, def: 12),
        MotionParamSpec('opacity', 'motionParamOpacity',
            min: 0.05, max: 0.5, def: 0.16),
      ],
    ),
    MotionEffectSpec('dust', 'motionFxDust'),
    MotionEffectSpec(
      'rain',
      'motionFxRain',
      params: [
        MotionParamSpec('count', 'motionParamCount',
            min: 20, max: 200, step: 1, isInt: true, def: 90),
        MotionParamSpec('angleDeg', 'motionParamAngle',
            min: 0, max: 45, step: 1, def: 12),
        MotionParamSpec('opacity', 'motionParamOpacity',
            min: 0.1, max: 0.8, def: 0.38),
      ],
    ),
    MotionEffectSpec(
      'snow',
      'motionFxSnow',
      params: [
        MotionParamSpec('count', 'motionParamCount',
            min: 20, max: 150, step: 1, isInt: true, def: 64),
        MotionParamSpec('sizePx', 'motionParamSize',
            min: 1, max: 6, def: 2.4),
        MotionParamSpec('opacity', 'motionParamOpacity',
            min: 0.3, max: 1, def: 0.85),
      ],
    ),
    MotionEffectSpec(
      'sakura',
      'motionFxSakura',
      params: [
        MotionParamSpec('count', 'motionParamCount',
            min: 10, max: 80, step: 1, isInt: true, def: 30),
        MotionParamSpec('sizePx', 'motionParamSize',
            min: 2, max: 10, def: 4.2),
        MotionParamSpec('spinTurns', 'motionParamSpin',
            min: 1, max: 4, step: 1, isInt: true, def: 2),
      ],
    ),
    MotionEffectSpec(
      'leaves',
      'motionFxLeaves',
      params: [
        MotionParamSpec('count', 'motionParamCount',
            min: 6, max: 60, step: 1, isInt: true, def: 22),
        MotionParamSpec('sizePx', 'motionParamSize',
            min: 3, max: 14, def: 6.8),
      ],
    ),
    MotionEffectSpec(
      'bubbles',
      'motionFxBubbles',
      params: [
        MotionParamSpec('count', 'motionParamCount',
            min: 6, max: 40, step: 1, isInt: true, def: 18),
        MotionParamSpec('sizePx', 'motionParamSize',
            min: 2, max: 14, def: 6.5),
      ],
    ),
    MotionEffectSpec(
      'fireflies',
      'motionFxFireflies',
      params: [
        MotionParamSpec('count', 'motionParamCount',
            min: 5, max: 60, step: 1, isInt: true, def: 22),
        MotionParamSpec('glowPx', 'motionParamGlow',
            min: 4, max: 30, def: 14),
      ],
    ),
    MotionEffectSpec(
      'embers',
      'motionFxEmbers',
      params: [
        MotionParamSpec('count', 'motionParamCount',
            min: 10, max: 100, step: 1, isInt: true, def: 40),
        MotionParamSpec('glowPx', 'motionParamGlow',
            min: 2, max: 15, def: 6),
      ],
    ),
    MotionEffectSpec(
      'meteors',
      'motionFxMeteors',
      params: [
        MotionParamSpec('count', 'motionParamCount',
            min: 1, max: 12, step: 1, isInt: true, def: 5),
        MotionParamSpec('lengthFrac', 'motionParamLengthFrac',
            min: 0.08, max: 0.4, def: 0.22),
      ],
    ),
    MotionEffectSpec(
      'fog',
      'motionFxFog',
      params: [
        MotionParamSpec('blobs', 'motionParamBlobs',
            min: 3, max: 20, step: 1, isInt: true, def: 8),
        MotionParamSpec('opacity', 'motionParamOpacity',
            min: 0.03, max: 0.3, def: 0.1),
      ],
    ),
    MotionEffectSpec(
      'smoke',
      'motionFxSmoke',
      params: [
        MotionParamSpec('puffs', 'motionParamPuffs',
            min: 6, max: 40, step: 1, isInt: true, def: 16),
        MotionParamSpec('sizePx', 'motionParamSize',
            min: 10, max: 60, def: 26),
        MotionParamSpec('opacity', 'motionParamOpacity',
            min: 0.05, max: 0.4, def: 0.14),
      ],
    ),
    MotionEffectSpec(
      'flame',
      'motionFxFlame',
      params: [
        MotionParamSpec('tongues', 'motionParamTongues',
            min: 6, max: 30, step: 1, isInt: true, def: 14),
        MotionParamSpec('heightFrac', 'motionParamHeightFrac',
            min: 0.05, max: 0.35, def: 0.18),
        MotionParamSpec('opacity', 'motionParamOpacity',
            min: 0.2, max: 1, def: 0.72),
      ],
    ),

    // ── 光影明暗 ──
    MotionEffectSpec(
      'godRays',
      'motionFxGodRays',
      params: [
        MotionParamSpec('count', 'motionParamCount',
            min: 1, max: 8, step: 1, isInt: true, def: 3),
        MotionParamSpec('intensity', 'motionParamIntensity',
            min: 0.05, max: 0.8, def: 0.3),
      ],
    ),
    MotionEffectSpec('lightSweep', 'motionFxLightSweep'),
    MotionEffectSpec(
      'shimmer',
      'motionFxShimmer',
      params: [
        MotionParamSpec('rows', 'motionParamRows',
            min: 4, max: 24, step: 1, isInt: true, def: 10),
        MotionParamSpec('intensity', 'motionParamIntensity',
            min: 0.05, max: 0.5, def: 0.2),
      ],
    ),
    MotionEffectSpec(
      'starlight',
      'motionFxStarlight',
      params: [
        MotionParamSpec('count', 'motionParamCount',
            min: 4, max: 30, step: 1, isInt: true, def: 12),
        MotionParamSpec('intensity', 'motionParamIntensity',
            min: 0.2, max: 1, def: 0.7),
      ],
    ),
    MotionEffectSpec(
      'lightning',
      'motionFxLightning',
      params: [
        MotionParamSpec('strikes', 'motionParamStrikes',
            min: 1, max: 5, step: 1, isInt: true, def: 2),
        MotionParamSpec('flashIntensity', 'motionParamIntensity',
            min: 0.1, max: 0.9, def: 0.45),
      ],
    ),
    MotionEffectSpec(
      'impactFlash',
      'motionFxImpactFlash',
      params: [
        MotionParamSpec('flashes', 'motionParamFlashes',
            min: 1, max: 5, step: 1, isInt: true, def: 2),
        MotionParamSpec('intensity', 'motionParamIntensity',
            min: 0.1, max: 0.9, def: 0.5),
      ],
    ),

    // ── 漫画动势 ──
    MotionEffectSpec(
      'speedLines',
      'motionFxSpeedLines',
      params: [
        MotionParamSpec('count', 'motionParamCount',
            min: 12, max: 96, step: 1, isInt: true, def: 48),
        MotionParamSpec('intensity', 'motionParamIntensity',
            min: 0.1, max: 1, def: 0.5),
        MotionParamSpec('pulses', 'motionParamPulses',
            min: 1, max: 8, step: 1, isInt: true, def: 4),
      ],
    ),
    MotionEffectSpec(
      'focusLines',
      'motionFxFocusLines',
      params: [
        MotionParamSpec('lines', 'motionParamLines',
            min: 12, max: 64, step: 1, isInt: true, def: 28),
        MotionParamSpec('opacity', 'motionParamOpacity',
            min: 0.1, max: 0.8, def: 0.34),
      ],
    ),
    MotionEffectSpec(
      'screenTone',
      'motionFxScreenTone',
      params: [
        MotionParamSpec('spacingPx', 'motionParamSpacing',
            min: 4, max: 16, def: 8),
        MotionParamSpec('density', 'motionParamDensity',
            min: 0.1, max: 0.7, def: 0.34),
        MotionParamSpec('opacity', 'motionParamOpacity',
            min: 0.05, max: 0.4, def: 0.16),
      ],
    ),
    MotionEffectSpec(
      'mangaShake',
      'motionFxMangaShake',
      params: [
        MotionParamSpec('shakes', 'motionParamShakes',
            min: 2, max: 12, step: 1, isInt: true, def: 6),
        MotionParamSpec('amplitude', 'motionParamAmplitude',
            min: 0.002, max: 0.02, def: 0.006),
      ],
    ),
    MotionEffectSpec(
      'impactRings',
      'motionFxImpactRings',
      params: [
        MotionParamSpec('rings', 'motionParamRings',
            min: 1, max: 6, step: 1, isInt: true, def: 3),
      ],
    ),
    MotionEffectSpec(
      'brushStreak',
      'motionFxBrushStreak',
      params: [
        MotionParamSpec('streaks', 'motionParamStreaks',
            min: 4, max: 24, step: 1, isInt: true, def: 12),
        MotionParamSpec('lengthFrac', 'motionParamLengthFrac',
            min: 0.15, max: 0.7, def: 0.42),
        MotionParamSpec('opacity', 'motionParamOpacity',
            min: 0.1, max: 0.8, def: 0.4),
      ],
    ),
    MotionEffectSpec('moodScript', 'motionFxMoodScript'),
  ];

  /// 引擎全部效果名（目录序）。
  static List<String> get allKinds =>
      specs.map((s) => s.kind).toList(growable: false);

  /// 按名字查条目。
  static MotionEffectSpec? specOf(String kind) {
    for (final s in specs) {
      if (s.kind == kind) return s;
    }
    return null;
  }

  /// 分组展示顺序：组键 → 组内条目。
  static Map<String, List<MotionEffectSpec>> get grouped {
    final map = <String, List<MotionEffectSpec>>{
      groupAmbient: [],
      groupParticles: [],
      groupLight: [],
      groupManga: [],
    };
    const assign = <String, List<String>>{
      groupAmbient: [
        'parallax',
        'breathing',
        'slowPush',
        'heartbeat',
        'toneShift',
        'vignette',
      ],
      groupParticles: [
        'ambient',
        'dust',
        'rain',
        'snow',
        'sakura',
        'leaves',
        'bubbles',
        'fireflies',
        'embers',
        'meteors',
        'fog',
        'smoke',
        'flame',
      ],
      groupLight: [
        'godRays',
        'lightSweep',
        'shimmer',
        'starlight',
        'lightning',
        'impactFlash',
      ],
      groupManga: [
        'speedLines',
        'focusLines',
        'screenTone',
        'mangaShake',
        'impactRings',
        'brushStreak',
        'moodScript',
      ],
    };
    for (final e in assign.entries) {
      for (final kind in e.value) {
        final spec = specOf(kind);
        if (spec != null) map[e.key]!.add(spec);
      }
    }
    return map;
  }

  /// 快速预设（应用后效果开关=预设组合，参数回引擎默认）。
  static const List<MotionEffectPreset> presets = <MotionEffectPreset>[
    MotionEffectPreset(
        'classic', 'motionPresetClassic', ['parallax', 'breathing', 'ambient']),
    MotionEffectPreset('sakura', 'motionPresetSakura',
        ['parallax', 'breathing', 'sakura', 'godRays']),
    MotionEffectPreset(
        'nightRain', 'motionPresetNightRain', ['rain', 'fog', 'lightning']),
    MotionEffectPreset('starryNight', 'motionPresetStarryNight',
        ['starlight', 'fireflies', 'vignette']),
    MotionEffectPreset('battle', 'motionPresetBattle',
        ['speedLines', 'impactFlash', 'mangaShake']),
  ];
}

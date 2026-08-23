import 'dart:convert';

import 'package:hive/hive.dart';

/// 单视频字幕记忆（F-22）。
///
/// 按视频 URL（去掉 fragment）为 key，持久化该视频的：外部字幕列表、
/// 激活轨道、样式（字号 / 缩放 / 边框 / 阴影 / 颜色 / 位置 / ASS 覆盖）、
/// 偏移与可见性。打开同一视频时自动恢复，切换视频互不干扰。
///
/// 值以 JSON 字符串存储，避免为嵌套结构注册 Hive adapter。
class SubtitleMemory {
  const SubtitleMemory({
    this.externalSubtitleUris = const <String>[],
    this.activeTrackId,
    this.visible = false,
    this.delayMs = 0,
    this.fontSize = 28.0,
    this.scale = 1.0,
    this.borderSize = 1.5,
    this.shadowOffset = 2.0,
    this.color = 'FFFFFF',
    this.borderColor = '000000',
    this.shadowColor = '000000',
    this.position = 'bottom',
    this.assMode = 'yes',
  });

  final List<String> externalSubtitleUris;
  final String? activeTrackId;
  final bool visible;
  final int delayMs;
  final double fontSize;
  final double scale;
  final double borderSize;
  final double shadowOffset;
  final String color;
  final String borderColor;
  final String shadowColor;
  final String position;
  final String assMode;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'externalSubtitleUris': externalSubtitleUris,
        'activeTrackId': activeTrackId,
        'visible': visible,
        'delayMs': delayMs,
        'fontSize': fontSize,
        'scale': scale,
        'borderSize': borderSize,
        'shadowOffset': shadowOffset,
        'color': color,
        'borderColor': borderColor,
        'shadowColor': shadowColor,
        'position': position,
        'assMode': assMode,
      };

  factory SubtitleMemory.fromJson(Map<String, dynamic> json) {
    T? asT<T>(String key) => json[key] is T ? json[key] as T : null;
    List<String> asStrList(String key) {
      final v = json[key];
      if (v is List) return v.whereType<String>().toList();
      return const <String>[];
    }

    return SubtitleMemory(
      externalSubtitleUris: asStrList('externalSubtitleUris'),
      activeTrackId: asT<String>('activeTrackId'),
      visible: asT<bool>('visible') ?? false,
      delayMs: asT<int>('delayMs') ?? 0,
      fontSize: (asT<num>('fontSize') ?? 28.0).toDouble(),
      scale: (asT<num>('scale') ?? 1.0).toDouble(),
      borderSize: (asT<num>('borderSize') ?? 1.5).toDouble(),
      shadowOffset: (asT<num>('shadowOffset') ?? 2.0).toDouble(),
      color: asT<String>('color') ?? 'FFFFFF',
      borderColor: asT<String>('borderColor') ?? '000000',
      shadowColor: asT<String>('shadowColor') ?? '000000',
      position: asT<String>('position') ?? 'bottom',
      assMode: asT<String>('assMode') ?? 'yes',
    );
  }
}

/// 字幕记忆存储（Hive box: [boxName]）。
///
/// 新增 box 已在 [kStorageBoxNames] 注册，splash 冷启动与云同步自动覆盖。
class SubtitleMemoryStore {
  static const String boxName = 'subtitle_memory';

  Box? _box;

  Future<Box> _ensure() async {
    _box ??= await Hive.openBox(boxName);
    return _box!;
  }

  /// 取稳定 key：去掉 fragment（`#...`），保留 path + query。
  ///
  /// 带鉴权 token 的 m3u8 链接若 token 每次变化则无法稳定匹配（属预期），
  /// 本地文件路径则稳定。
  static String keyFor(String url) => url.split('#').first;

  Future<SubtitleMemory?> load(String url) async {
    try {
      final box = await _ensure();
      final raw = box.get(keyFor(url));
      if (raw is String) {
        return SubtitleMemory.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
      }
    } on Object {
      // 读取失败不影响播放。
    }
    return null;
  }

  Future<void> save(String url, SubtitleMemory memory) async {
    try {
      final box = await _ensure();
      await box.put(keyFor(url), jsonEncode(memory.toJson()));
    } on Object {
      // 写入失败不影响播放。
    }
  }
}

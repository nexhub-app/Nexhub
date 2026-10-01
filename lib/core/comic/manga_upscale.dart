/// 漫画图片超分（实时 GPU 后处理）。
///
/// 技术路线（用户确认）：GPU 实时 shader，不落盘、无新增原生依赖。
/// Flutter 的 [ui.FragmentProgram] 是单趟后处理，无法承载 Anime4K 那类多趟
/// CNN；因此本实现采用「Catmull-Rom 双三次重采样 + RCAS 风格对比度自适应
/// 锐化」，见 `assets/shaders/manga_upscale.frag`——放大时线条更锐、抑制网点
/// 振铃，且只在放大（目标尺寸 > 源尺寸）时介入，缩小显示交回默认过滤。
///
/// 三条硬约束（阅读器集成时必须遵守）：
/// 1. **纹理尺寸上限**：GPU 纹理边长有上限（移动端常见 4096/8192），超长条漫
///    单图（数千 px 高）绑定 sampler 会失败或整页空白，因此超过
///    [kMangaUpscaleMaxTextureSide] 的页面直接回退普通渲染；
/// 2. **Web 平台**：FragmentProgram 在 Web 上不可用，[isSupported] 恒 false；
/// 3. **失败静默降级**：shader 资源缺失 / 编译失败时 [program] 为 null，
///    调用方回退普通图片渲染，绝不让超分开关导致页面打不开。
library;

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// 超分档位（阅读器偏好持久化值）。
enum MangaUpscaleMode {
  /// 关闭（默认；与历史行为完全一致）。
  off,

  /// 高清重采样：仅 Catmull-Rom 双三次放大，无额外锐化（最省 GPU）。
  resample,

  /// 超分：双三次放大 + 对比度自适应锐化（默认推荐档）。
  sharpen;

  String l10nKey() => switch (this) {
        MangaUpscaleMode.off => 'readerUpscaleOff',
        MangaUpscaleMode.resample => 'readerUpscaleResample',
        MangaUpscaleMode.sharpen => 'readerUpscaleSharpen',
      };

  /// 是否启用 shader 渲染路径。
  bool get enabled => this != MangaUpscaleMode.off;

  /// shader `uMode` 取值：0 = 仅重采样，1 = 加重锐化。
  double get shaderMode =>
      this == MangaUpscaleMode.sharpen ? 1.0 : 0.0;
}

/// 解析超分档位（容错：非法字符串回退 [MangaUpscaleMode.off]）。
MangaUpscaleMode parseMangaUpscaleMode(Object? raw) {
  if (raw is String) {
    return MangaUpscaleMode.values.firstWhere(
      (MangaUpscaleMode e) => e.name == raw,
      orElse: () => MangaUpscaleMode.off,
    );
  }
  return MangaUpscaleMode.off;
}

/// GPU 纹理边长上限（超过则回退普通渲染，避免超长条漫绑定失败整页空白）。
const int kMangaUpscaleMaxTextureSide = 8192;

/// 锐化强度（`uSharp`）：0.6 在漫画线条上锐度明显、网点不炸。
const double kMangaUpscaleSharpenAmount = 0.6;

/// 超分 shader 服务：懒加载 + 单例缓存 FragmentProgram。
class MangaUpscaleShader {
  MangaUpscaleShader._();

  /// 资源键：必须是**完整相对路径**（与 pubspec `shaders:` 中声明的路径一致）。
  /// 构建后资产注册在 `assets/shaders/manga_upscale.frag` 键下（可用
  /// `AssetManifest` 复核）；写成省略 `assets/` 前缀的 `shaders/...` 会在
  /// 运行时抛 "Asset not found" 并静默回退，超分开关形同虚设。
  static const String assetKey = 'assets/shaders/manga_upscale.frag';

  static ui.FragmentProgram? _program;
  static bool _loadTried = false;
  static bool _loadFailed = false;

  /// 当前平台是否可能支持（Web 不支持 FragmentProgram）。
  static bool get isSupported => !kIsWeb;

  /// 释放 shader 实例（widget 销毁时调用；下次使用自动重建）。
  static void disposeShader(ui.FragmentShader shader) {
    try {
      // Flutter 3.32 起 Shader 不再提供公开 dispose（引擎自动回收），
      // 此处保留动态调用以兼容旧版本，调用失败即忽略。
      // ignore: avoid_dynamic_calls
      (shader as dynamic).dispose();
    } on Object {
      // 已释放 / 引擎不支持时忽略。
    }
  }

  /// 加载 FragmentProgram（失败返回 null，且本次进程不再重试）。
  static Future<ui.FragmentProgram?> _ensureProgram() async {
    if (_program != null) return _program;
    if (_loadFailed) return null;
    if (!_loadTried) {
      _loadTried = true;
      try {
        _program = await ui.FragmentProgram.fromAsset(assetKey);
      } on Object {
        // 资源缺失 / 平台不支持：标记失败，调用方回退普通渲染。
        _loadFailed = true;
        _program = null;
      }
    }
    return _program;
  }

  /// 创建一次性的 [ui.FragmentShader]；不可用时返回 null。
  static Future<ui.FragmentShader?> createShader() async {
    if (!isSupported) return null;
    final ui.FragmentProgram? program = await _ensureProgram();
    if (program == null) return null;
    try {
      return program.fragmentShader();
    } on Object {
      return null;
    }
  }

  /// 预加载（阅读器进入时调用，避免首帧同步等待资源）。
  static Future<void> warmUp() async {
    if (!isSupported) return;
    await _ensureProgram();
  }

  /// 源图是否适合走 shader 路径：尺寸在纹理上限内。
  static bool fitsTextureLimit(int width, int height) =>
      width > 0 &&
      height > 0 &&
      width <= kMangaUpscaleMaxTextureSide &&
      height <= kMangaUpscaleMaxTextureSide;
}

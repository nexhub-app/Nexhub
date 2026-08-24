/// Anime4K 超分辨率 shader 目录服务（F-7）。
///
/// 通过 mpv `glsl-shaders` 属性注入 Anime4K（MIT，bloc97）GLSL 用户 shader，
/// 两档预设沿用官方 Mode A 组合：
/// - 效率档（Mode A Fast）：Restore_CNN_M + Upscale_CNN_x2_M + 自动降采样链；
/// - 质量档（Mode A HQ）：Restore_CNN_VL + Upscale_CNN_x2_VL + 自动降采样链。
///
/// 资产包内的 .glsl 无法被 libmpv 直接读取（Android 上位于 APK 内），首次使用
/// 时部署到应用支持目录；以版本标记整体失效重拷——更新内置 shader 时递增
/// [deployVersion] 即可强制全量重写。
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../settings/player_settings.dart';

/// 内置 shader 的部署版本（改变即强制重拷全部文件）。
const int kAnime4kDeployVersion = 1;

/// 档位 → 预设文件（顺序即 mpv 加载顺序，与官方 Mode A 一致）。
const Map<UpscaleShaderMode, List<String>> kAnime4kPresetFiles =
    <UpscaleShaderMode, List<String>>{
  UpscaleShaderMode.performance: <String>[
    'Anime4K_Clamp_Highlights.glsl',
    'Anime4K_Restore_CNN_M.glsl',
    'Anime4K_Upscale_CNN_x2_M.glsl',
    'Anime4K_AutoDownscalePre_x2.glsl',
    'Anime4K_AutoDownscalePre_x4.glsl',
    'Anime4K_Upscale_CNN_x2_S.glsl',
  ],
  UpscaleShaderMode.quality: <String>[
    'Anime4K_Clamp_Highlights.glsl',
    'Anime4K_Restore_CNN_VL.glsl',
    'Anime4K_Upscale_CNN_x2_VL.glsl',
    'Anime4K_AutoDownscalePre_x2.glsl',
    'Anime4K_AutoDownscalePre_x4.glsl',
    'Anime4K_Upscale_CNN_x2_S.glsl',
  ],
};

/// Anime4K shader 部署与 mpv `glsl-shaders` 取值。
class Anime4kShaderCatalog {
  Anime4kShaderCatalog._();

  static const String _assetDir = 'assets/shaders/anime4k';
  static const String _deployDirName = 'anime4k_shaders';
  static const String _versionMarker = '.version';

  /// 返回可直接赋给 mpv `glsl-shaders` 的值：
  /// - [UpscaleShaderMode.off] 或部署失败：空字符串（清空已加载 shader）；
  /// - 其余：按平台分隔符（Windows `;`，其余 `:`）拼接的部署后绝对路径。
  static Future<String> mpvShaderList(UpscaleShaderMode mode) async {
    if (mode == UpscaleShaderMode.off) return '';
    try {
      final paths = await _ensureDeployed(mode);
      final sep = Platform.isWindows ? ';' : ':';
      return paths.join(sep);
    } on Object {
      // 无文件系统（Web）或资产读取失败：等价关闭。
      return '';
    }
  }

  /// 部署 [mode] 预设到应用支持目录并返回各文件绝对路径。
  ///
  /// 版本标记仍有效且文件存在时跳过拷贝；任一缺失（或版本变更）时按需重写。
  static Future<List<String>> _ensureDeployed(UpscaleShaderMode mode) async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, _deployDirName));
    final marker = File(p.join(dir.path, _versionMarker));
    bool upToDate = false;
    try {
      upToDate = await marker.exists() &&
          (await marker.readAsString()).trim() ==
              '$kAnime4kDeployVersion';
    } on Object {
      upToDate = false;
    }
    final paths = <String>[];
    for (final name in kAnime4kPresetFiles[mode]!) {
      final file = File(p.join(dir.path, name));
      if (!upToDate || !await file.exists()) {
        final data = await rootBundle.load('$_assetDir/$name');
        await dir.create(recursive: true);
        await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
      }
      paths.add(file.path);
    }
    if (!upToDate) {
      // 标记写失败不影响本次使用，下次会重拷。
      try {
        await marker.writeAsString('$kAnime4kDeployVersion', flush: true);
      } on Object {
        // 忽略。
      }
    }
    return paths;
  }
}

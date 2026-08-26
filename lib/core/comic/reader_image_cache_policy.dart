/// 漫画阅读器 Flutter 图片缓存预算（P3 资源/内存）。
///
/// 进入阅读器时按设备物理内存上调 `imageCache.maximumSizeBytes`
/// （<3GB 维持默认 100MB / 3–6GB 200MB / ≥6GB 500MB），退出时恢复默认，
/// 让大内存设备在长条漫连续滚动下多驻留已解码位图、减少重复解码卡顿，
/// 同时不挤占低端机。磁盘缓存的管理入口见高级设置「图片缓存」。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';

/// 默认预算（字节）：与 Flutter 引擎默认值一致（100MB）。
const int kComicImageCacheDefaultBytes = 100 << 20;

/// 按设备物理内存解析阅读器期间的图片缓存预算。
///
/// [totalMemBytes] 为 null（非 Android / 探测失败）时返回默认值。
int resolveComicImageCacheBytes(int? totalMemBytes) {
  if (totalMemBytes == null || totalMemBytes <= 0) {
    return kComicImageCacheDefaultBytes;
  }
  if (totalMemBytes < 3 << 30) return kComicImageCacheDefaultBytes;
  if (totalMemBytes < 6 << 30) return 200 << 20;
  return 500 << 20;
}

/// 探测设备物理内存总量；仅 Android 读 `/proc/meminfo`，其余平台返回 null。
Future<int?> probeDeviceTotalMemBytes() async {
  if (kIsWeb || !Platform.isAndroid) return null;
  try {
    final meminfo = await File('/proc/meminfo').readAsString();
    final match =
        RegExp(r'MemTotal:\s+(\d+)\s+kB').firstMatch(meminfo);
    final totalKb = match == null ? 0 : int.tryParse(match.group(1)!) ?? 0;
    return totalKb > 0 ? totalKb << 10 : null;
  } on Object {
    // 读取失败按未知设备处理。
    return null;
  }
}

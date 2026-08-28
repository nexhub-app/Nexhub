/// demuxer 缓存降级策略。
///
/// 移动网络或低内存设备自动把 mpv demuxer 前向缓存从 1500MiB 降到 2MiB，
/// 避免计费流量下后台大量拉流、低端机上 demux 缓存挤占前台内存。
/// 网络变化时由播放器侧重新 resolve 并应用。
library;

import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// demuxer 缓存档位。
enum DemuxerCacheProfile {
  /// 标准档：大预算，长视频拖动顺滑（默认）。
  standard(maxBytes: 1500 * 1024 * 1024, maxBackBytes: 750 * 1024 * 1024),

  /// 低内存档：移动网络 / 低内存设备降级，几乎不驻留 demux 缓存。
  low(maxBytes: 2 * 1024 * 1024, maxBackBytes: 1024 * 1024);

  const DemuxerCacheProfile({required this.maxBytes, required this.maxBackBytes});

  /// 前向缓存预算（字节，mpv `demuxer-max-bytes`）。
  final int maxBytes;

  /// 后向缓存预算（字节，mpv `demuxer-max-back-bytes`）。
  final int maxBackBytes;
}

/// 缓存策略解析器：按网络与设备内存决定档位。
class DemuxerCachePolicyResolver {
  DemuxerCachePolicyResolver({Connectivity? connectivity})
      : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  bool? _cachedLowMemoryDevice;

  /// 当前网络 / 设备条件下的推荐档位。
  Future<DemuxerCacheProfile> resolve() async {
    final metered = await isMeteredNetwork();
    if (metered) return DemuxerCacheProfile.low;
    if (await isLowMemoryDevice()) return DemuxerCacheProfile.low;
    return DemuxerCacheProfile.standard;
  }

  /// 是否处于计费网络（蜂窝）。
  Future<bool> isMeteredNetwork() async {
    try {
      final results = await _connectivity.checkConnectivity();
      // connectivity_plus 3.x 起蜂窝枚举名为 mobile（cellular 已废弃/移除）。
      return results.contains(ConnectivityResult.mobile);
    } on Object {
      // 平台插件不可用时按非计费处理，保持默认大缓存。
      return false;
    }
  }

  /// 是否为低内存设备（阈值 3GB 物理内存）。
  ///
  /// Android 读 `/proc/meminfo`；其余平台无轻量通道，返回 false
  /// （桌面端内存普遍充裕，false 正是期望值）。
  Future<bool> isLowMemoryDevice() async {
    final cached = _cachedLowMemoryDevice;
    if (cached != null) return cached;
    var low = false;
    if (!kIsWeb && Platform.isAndroid) {
      try {
        final meminfo = await File('/proc/meminfo').readAsString();
        final match =
            RegExp(r'MemTotal:\s+(\d+)\s+kB').firstMatch(meminfo);
        final totalKb = match == null ? 0 : int.tryParse(match.group(1)!) ?? 0;
        low = totalKb > 0 && totalKb < 3 * 1024 * 1024;
      } on Object {
        // 读取失败按常规设备处理。
        low = false;
      }
    }
    _cachedLowMemoryDevice = low;
    return low;
  }

  /// 网络变化流（播放器侧订阅，变化时重新 resolve 并应用档位）。
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      _connectivity.onConnectivityChanged;
}

/// 小说阅读中预下载配置（X-4 跨类型对齐：漫画「自动下载」/ 播放器「>80% 预解析」）。
///
/// 独立轻量存储（SharedPreferences 直接读写，不并入庞大的
/// [NovelReaderPreferences]）：阅读进度越过阈值后后台预下载后续 N 章正文，
/// 离线阅读/快速切章时直接命中缓存。
library;

import 'package:shared_preferences/shared_preferences.dart';

/// 预下载配置（不可变快照）。
class NovelPreDownloadPreferences {
  /// 总开关（默认关闭，设置页开启）。
  final bool enabled;

  /// 触发阈值（当前章阅读进度百分比，1–99，默认 80）。
  final int thresholdPercent;

  /// 预下载后续章节数（1–10，默认 3）。
  final int count;

  const NovelPreDownloadPreferences({
    this.enabled = false,
    this.thresholdPercent = 80,
    this.count = 3,
  });

  NovelPreDownloadPreferences copyWith({
    bool? enabled,
    int? thresholdPercent,
    int? count,
  }) =>
      NovelPreDownloadPreferences(
        enabled: enabled ?? this.enabled,
        thresholdPercent: thresholdPercent ?? this.thresholdPercent,
        count: count ?? this.count,
      );

  static const String _kEnabled = 'novel_predownload_enabled';
  static const String _kThreshold = 'novel_predownload_threshold';
  static const String _kCount = 'novel_predownload_count';

  /// 读取当前配置（缺省返回默认值）。
  static Future<NovelPreDownloadPreferences> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return NovelPreDownloadPreferences(
        enabled: prefs.getBool(_kEnabled) ?? false,
        thresholdPercent:
            (prefs.getInt(_kThreshold) ?? 80).clamp(1, 99),
        count: (prefs.getInt(_kCount) ?? 3).clamp(1, 10),
      );
    } on Object {
      return const NovelPreDownloadPreferences();
    }
  }

  /// 持久化整份配置。
  static Future<void> save(NovelPreDownloadPreferences prefs) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool(_kEnabled, prefs.enabled);
      await sp.setInt(_kThreshold, prefs.thresholdPercent);
      await sp.setInt(_kCount, prefs.count);
    } on Object {
      // 写入失败不影响阅读。
    }
  }
}
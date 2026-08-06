/// 下载设置（最大同时下载数 / 线程数 / 路径 / 下载器类型 / 读后自动删 / 预下载）。
///
/// 持久化到 shared_preferences，遵循 [PrefsBackend] 抽象（可注入内存后端测试）。
library;

import 'dart:convert';

import '../../core/comic/models/reader_preferences.dart';

/// 下载器类型：内置 / 外置。
enum DownloaderType { internal, external }

/// 下载设置数据模型。
class DownloadSettings {
  /// 最大同时下载数（1-10）。
  final int maxConcurrent;

  /// 下载线程数（1-16）。
  final int threadCount;

  /// 下载路径。
  final String downloadPath;

  /// 下载器类型。
  final DownloaderType downloaderType;

  /// 仅 WiFi 下载：开启后未连接 WiFi 时不启动下载，挂起等待。
  final bool wifiOnly;

  /// 读后自动删除：看完/读完该内容后删除其已下载文件。
  final bool autoDeleteAfterRead;

  /// 自动删除的排除分类（收藏分组 id 列表）：命中其中任一分类的内容不删。
  final List<String> autoDeleteExcludeGroupIds;

  /// 预下载后续内容数（0 = 关闭）。
  final int preDownloadCount;

  const DownloadSettings({
    this.maxConcurrent = 3,
    this.threadCount = 4,
    this.downloadPath = 'D:/Downloads',
    this.downloaderType = DownloaderType.internal,
    this.wifiOnly = false,
    this.autoDeleteAfterRead = false,
    this.autoDeleteExcludeGroupIds = const <String>[],
    this.preDownloadCount = 0,
  });

  const DownloadSettings.defaults()
      : maxConcurrent = 3,
        threadCount = 4,
        downloadPath = 'D:/Downloads',
        downloaderType = DownloaderType.internal,
        wifiOnly = false,
        autoDeleteAfterRead = false,
        autoDeleteExcludeGroupIds = const <String>[],
        preDownloadCount = 0;

  /// 内容（以其所属的收藏分组 id 列表表示）是否命中排除分类。
  /// 未收藏 / 无分组（列表为空）时不受排除。
  bool isExcludedFromAutoDeleteGroups(Iterable<String> groupIds) =>
      groupIds.any(autoDeleteExcludeGroupIds.contains);

  DownloadSettings copyWith({
    int? maxConcurrent,
    int? threadCount,
    String? downloadPath,
    DownloaderType? downloaderType,
    bool? wifiOnly,
    bool? autoDeleteAfterRead,
    List<String>? autoDeleteExcludeGroupIds,
    int? preDownloadCount,
  }) =>
      DownloadSettings(
        maxConcurrent: maxConcurrent ?? this.maxConcurrent,
        threadCount: threadCount ?? this.threadCount,
        downloadPath: downloadPath ?? this.downloadPath,
        downloaderType: downloaderType ?? this.downloaderType,
        wifiOnly: wifiOnly ?? this.wifiOnly,
        autoDeleteAfterRead:
            autoDeleteAfterRead ?? this.autoDeleteAfterRead,
        autoDeleteExcludeGroupIds:
            autoDeleteExcludeGroupIds ?? this.autoDeleteExcludeGroupIds,
        preDownloadCount: preDownloadCount ?? this.preDownloadCount,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'maxConcurrent': maxConcurrent,
        'threadCount': threadCount,
        'downloadPath': downloadPath,
        'downloaderType': downloaderType.name,
        'wifiOnly': wifiOnly,
        'autoDeleteAfterRead': autoDeleteAfterRead,
        'autoDeleteExcludeGroupIds': autoDeleteExcludeGroupIds,
        'preDownloadCount': preDownloadCount,
      };

  factory DownloadSettings.fromJson(Map<String, dynamic> json) =>
      DownloadSettings(
        maxConcurrent: json['maxConcurrent'] as int? ?? 3,
        threadCount: json['threadCount'] as int? ?? 4,
        downloadPath: json['downloadPath'] as String? ?? 'D:/Downloads',
        wifiOnly: json['wifiOnly'] as bool? ?? false,
        downloaderType: DownloaderType.values.firstWhere(
          (e) => e.name == json['downloaderType'],
          orElse: () => DownloaderType.internal,
        ),
        autoDeleteAfterRead: json['autoDeleteAfterRead'] as bool? ?? false,
        autoDeleteExcludeGroupIds: (json['autoDeleteExcludeGroupIds']
                    as List<dynamic>?)
                ?.map((e) => e as String)
                .toList() ??
            const <String>[],
        preDownloadCount: json['preDownloadCount'] as int? ?? 0,
      );

  String toJsonString() => jsonEncode(toJson());

  static DownloadSettings fromJsonString(String raw) =>
      DownloadSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
}

/// 下载设置持久化存储（键 `download_settings`）。
class DownloadSettingsStore {
  static const String _key = 'download_settings';

  final PrefsBackend _backend;

  DownloadSettingsStore({PrefsBackend? backend})
      : _backend = backend ?? const SharedPrefsBackend();

  Future<DownloadSettings> load() async {
    final raw = await _backend.get(_key);
    if (raw == null || raw.isEmpty) return const DownloadSettings.defaults();
    try {
      return DownloadSettings.fromJsonString(raw);
    } on Object {
      return const DownloadSettings.defaults();
    }
  }

  Future<void> save(DownloadSettings settings) async {
    await _backend.set(_key, settings.toJsonString());
  }
}

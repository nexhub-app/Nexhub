/// 媒体服务器播放设置（A2 码率档位；全局默认，per-server 覆盖留二期）。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../comic/models/reader_preferences.dart';

/// 码率档位。
///
/// - [auto]：高值协商 + 允许转码，交服务器决策；
/// - [original]：强制直连（极大值；服务器只能直连，需转码则报错）；
/// - 具体档位：按该值协商，允许转码。
enum MediaServerBitrateTier {
  auto(200000000),
  original(999999999),
  m20(20000000),
  m10(10000000),
  m8(8000000),
  m4(4000000),
  m2(2000000),
  m1(1000000),
  p720(4000000);

  const MediaServerBitrateTier(this.maxBitrate);

  /// PlaybackInfo 的 MaxStreamingBitrate 取值。
  final int maxBitrate;
}

/// 媒体服务器播放设置 store（全应用单例，SharedPreferences 持久化）。
class MediaServerPlaybackSettings extends ChangeNotifier {
  MediaServerPlaybackSettings({PrefsBackend? backend})
      : _backend = backend ?? const SharedPrefsBackend();

  static const String _key = 'media_server_playback_settings_v1';

  final PrefsBackend _backend;

  static MediaServerPlaybackSettings? _instance;
  static MediaServerPlaybackSettings get instance {
    _instance ??= MediaServerPlaybackSettings();
    if (!_instance!._loaded) {
      _instance!.load();
    }
    return _instance!;
  }

  MediaServerBitrateTier _tier = MediaServerBitrateTier.auto;
  bool _loaded = false;

  List<String> _searchHistory = <String>[];

  MediaServerBitrateTier get tier => _tier;

  /// G3：服务器内搜索历史（最近 10 条，可清空）。
  List<String> get searchHistory => List.unmodifiable(_searchHistory);

  /// 冷启动恢复（幂等； GeneralSettingsStore 同款防竞态约定）。
  Future<void> load() async {
    if (_loaded) return;
    final raw = await _backend.get(_key);
    if (raw != null && raw.isNotEmpty) {
      try {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        final name = j['tier'] as String?;
        _tier = MediaServerBitrateTier.values.firstWhere(
          (t) => t.name == name,
          orElse: () => MediaServerBitrateTier.auto,
        );
        final hist = j['searchHistory'];
        if (hist is List) {
          _searchHistory = hist.whereType<String>().toList();
        }
      } on Object {
        // 损坏数据回落默认档。
        _tier = MediaServerBitrateTier.auto;
        _searchHistory = <String>[];
      }
    }
    _loaded = true;
    notifyListeners();
  }

  /// 设置档位并持久化（切换后由播放器重新协商开流）。
  Future<void> setTier(MediaServerBitrateTier tier) async {
    if (tier == _tier) return;
    _tier = tier;
    notifyListeners();
    await _persist();
  }

  /// G3：记录搜索词（去重置顶，最多 10 条）。
  Future<void> addSearchHistory(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;
    _searchHistory
      ..remove(q)
      ..insert(0, q);
    if (_searchHistory.length > 10) {
      _searchHistory.removeRange(10, _searchHistory.length);
    }
    notifyListeners();
    await _persist();
  }

  /// G3：清空搜索历史。
  Future<void> clearSearchHistory() async {
    if (_searchHistory.isEmpty) return;
    _searchHistory = <String>[];
    notifyListeners();
    await _persist();
  }

  Future<void> _persist() async {
    await _backend.set(
      _key,
      jsonEncode(<String, dynamic>{
        'tier': _tier.name,
        'searchHistory': _searchHistory,
      }),
    );
  }
}

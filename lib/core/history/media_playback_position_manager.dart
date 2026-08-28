/// 影视播放位置持久化管理器（P8.1.2 §廿一 续读进度跨章节恢复）。
///
/// 按 `contentId:episodeIndex` 存储播放位置（毫秒），并记录每个内容
/// 最后播放的剧集索引，用于详情页「续看」入口。持久化到 Hive box
/// `media_playback_position`。
library;

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

/// 影视播放位置持久化管理器——使用 Hive box `media_playback_position`。
///
/// key = `pos:$contentId:$episodeIndex`，value = int（播放位置毫秒）。
/// key = `last_ep:$contentId`，value = int（最后播放剧集索引）。
class MediaPlaybackPositionManager extends ChangeNotifier {
  MediaPlaybackPositionManager({Box<dynamic>? box}) : _box = box;

  /// Hive box 名。
  static const String boxName = 'media_playback_position';

  /// 每部作品保留的剧集位置记录上限：长篇连载剧集上千时，
  /// 无上限的 put-only 存储会无限膨胀；按最近使用顺序裁剪最旧的记录。
  static const int maxRecordsPerContent = 50;

  final Box<dynamic>? _box;

  /// 内存缓存：`contentId:episodeIndex` → 播放位置毫秒。
  final Map<String, int> _positions = {};

  /// 内存缓存：contentId → 最后播放剧集索引。
  final Map<String, int> _lastEpisodes = {};

  /// 每部作品的剧集键（`contentId:episodeIndex`）最近使用顺序，最新在前。
  /// 供 [savePosition] 超限裁剪最旧记录；首次保存时从既有键惰性构建。
  final Map<String, List<String>> _recentKeys = {};

  Future<void> init() async {
    final box = await _openBox();
    for (final key in box.keys) {
      if (key is! String) continue;
      final raw = box.get(key);
      if (raw is! int) continue;
      if (key.startsWith('pos:')) {
        _positions[key.substring(4)] = raw;
      } else if (key.startsWith('last_ep:')) {
        _lastEpisodes[key.substring(8)] = raw;
      }
    }
    notifyListeners();
  }

  Future<Box<dynamic>> _openBox() async {
    if (_box != null) return _box;
    if (Hive.isBoxOpen(boxName)) return Hive.box(boxName);
    return Hive.openBox(boxName);
  }

  /// 列出某作品现有的全部剧集键（`contentId:episodeIndex`）。
  /// contentId 内部不含 `:`，按首个冒号切分（episodeIndex 为整数）。
  List<String> _keysOf(String contentId) {
    return _positions.keys
        .where((k) => k.startsWith('$contentId:'))
        .toList();
  }

  /// 保存播放位置。
  Future<void> savePosition(
    String contentId, int episodeIndex, int positionMs) async {
    final k = '$contentId:$episodeIndex';
    _positions[k] = positionMs;
    _lastEpisodes[contentId] = episodeIndex;
    final box = await _openBox();
    await box.put('pos:$k', positionMs);
    await box.put('last_ep:$contentId', episodeIndex);
    await _pruneRecords(contentId);
    notifyListeners();
  }

  /// 超限裁剪：把本作品的剧集键按最近使用排序（当前保存项置顶，
  /// 其余沿用既有 MRU 顺序，首次调用时按剧集号排序兜底），超出
  /// [maxRecordsPerContent] 的最旧记录从内存与 Hive 中删除。
  Future<void> _pruneRecords(String contentId) async {
    var recent = _recentKeys[contentId];
    if (recent == null) {
      // 惰性构建：既有键（含历史遗留）按剧集号升序作为初始顺序。
      final existing = _keysOf(contentId)
        ..sort((a, b) {
          final ai = int.tryParse(a.substring(a.indexOf(':') + 1)) ?? 0;
          final bi = int.tryParse(b.substring(b.indexOf(':') + 1)) ?? 0;
          return ai.compareTo(bi);
        });
      recent = existing.reversed.toList(growable: true);
    }
    final current = '$contentId:${_lastEpisodes[contentId]}';
    recent
      ..removeWhere((k) => !_positions.containsKey(k))
      ..remove(current)
      ..insert(0, current);
    if (recent.length <= maxRecordsPerContent) {
      _recentKeys[contentId] = recent;
      return;
    }
    final toRemove = recent.sublist(maxRecordsPerContent);
    recent.length = maxRecordsPerContent;
    _recentKeys[contentId] = recent;
    final box = await _openBox();
    for (final k in toRemove) {
      _positions.remove(k);
      await box.delete('pos:$k');
    }
  }

  /// 获取播放位置（毫秒），无记录返回 0。
  int getPosition(String contentId, int episodeIndex) {
    return _positions['$contentId:$episodeIndex'] ?? 0;
  }

  /// 获取最后播放的剧集索引，无记录返回 -1。
  int getLastEpisode(String contentId) {
    return _lastEpisodes[contentId] ?? -1;
  }

  /// 清除某集的播放位置（播完或手动清除时调用）。
  Future<void> clearPosition(String contentId, int episodeIndex) async {
    final k = '$contentId:$episodeIndex';
    _positions.remove(k);
    final box = await _openBox();
    await box.delete('pos:$k');
    notifyListeners();
  }

  /// 清除某内容的全部播放位置记录。
  Future<void> clearContent(String contentId) async {
    final keysToRemove = _positions.keys
        .where((k) => k.startsWith('$contentId:'))
        .toList();
    for (final k in keysToRemove) {
      _positions.remove(k);
    }
    _lastEpisodes.remove(contentId);
    _recentKeys.remove(contentId);
    final box = await _openBox();
    for (final k in keysToRemove) {
      await box.delete('pos:$k');
    }
    await box.delete('last_ep:$contentId');
    notifyListeners();
  }
}

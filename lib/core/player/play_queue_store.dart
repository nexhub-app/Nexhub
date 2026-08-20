import 'dart:convert';

import '../comic/models/reader_preferences.dart';
import '../models/plugin_config.dart';

/// 播放队列中的单条作品记录（可序列化，跨作品连播与启动恢复共用）。
///
/// 与「源即插件」架构一致：仅保存作品的身份与起始集信息，
/// 具体剧集列表在真正播放时由对应源的解析器重新抓取，不在此硬编码。
class QueuedWork {
  final String sourceId;
  final String itemId;
  final String title;
  final String? coverUrl;
  final SourceType sourceType;
  final String? detailUrl;

  /// 本地/直连视频：无源可重抓剧集，入队时携带文件路径，连播时直接重开播放页。
  final String? localUri;
  final String? directUrl;

  /// 起始集标识：优先按 [episodeId] 在重新抓取的剧集列表里定位，
  /// 找不到时回退到 [episodeIndex]，再不行从头开始。
  final String? episodeId;
  final String? episodeTitle;
  final int episodeIndex;

  const QueuedWork({
    required this.sourceId,
    required this.itemId,
    required this.title,
    this.coverUrl,
    this.sourceType = SourceType.animeSource,
    this.detailUrl,
    this.localUri,
    this.directUrl,
    this.episodeId,
    this.episodeTitle,
    this.episodeIndex = 0,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'sourceId': sourceId,
        'itemId': itemId,
        'title': title,
        'coverUrl': coverUrl,
        'sourceType': sourceType.apiName,
        'detailUrl': detailUrl,
        'localUri': localUri,
        'directUrl': directUrl,
        'episodeId': episodeId,
        'episodeTitle': episodeTitle,
        'episodeIndex': episodeIndex,
      };

  factory QueuedWork.fromJson(Map<String, dynamic> json) {
    final SourceType? st = SourceType.parse(json['sourceType'] as String?);
    return QueuedWork(
      sourceId: (json['sourceId'] as String?) ?? '',
      itemId: (json['itemId'] as String?) ?? '',
      title: (json['title'] as String?) ?? '',
      coverUrl: json['coverUrl'] as String?,
      sourceType: st ?? SourceType.animeSource,
      detailUrl: json['detailUrl'] as String?,
      localUri: json['localUri'] as String?,
      directUrl: json['directUrl'] as String?,
      episodeId: json['episodeId'] as String?,
      episodeTitle: json['episodeTitle'] as String?,
      episodeIndex: (json['episodeIndex'] as int?) ?? 0,
    );
  }
}

/// 跨作品播放队列持久化（SharedPreferences）。
///
/// 两条数据：
/// - `play_queue_v1`：待播队列（有序，不含当前播放中的作品）。
/// - `play_queue_current_v1`：当前/最近播放的作品，用于启动恢复「继续上次」。
///
/// 复用 [PrefsBackend] 抽象，便于测试注入内存实现。
class PlayQueueStore {
  static const String _queueKey = 'play_queue_v1';
  static const String _currentKey = 'play_queue_current_v1';

  final PrefsBackend _backend;

  PlayQueueStore({PrefsBackend? backend})
      : _backend = backend ?? const SharedPrefsBackend();

  Future<List<QueuedWork>> getQueue() async {
    final String? raw = await _backend.get(_queueKey);
    if (raw == null || raw.isEmpty) return <QueuedWork>[];
    try {
      final List<dynamic> list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => QueuedWork.fromJson(e as Map<String, dynamic>))
          .toList();
    } on Object {
      return <QueuedWork>[];
    }
  }

  Future<void> setQueue(List<QueuedWork> queue) async {
    await _backend.set(
      _queueKey,
      jsonEncode(queue.map((e) => e.toJson()).toList()),
    );
  }

  /// 追加到队尾；同 itemId 已存在则不再重复加入。
  Future<void> add(QueuedWork w) async {
    final List<QueuedWork> q = await getQueue();
    if (q.any((e) => e.itemId == w.itemId)) return;
    q.add(w);
    await setQueue(q);
  }

  /// 插入队首（「下一部播放」）。
  Future<void> insertNext(QueuedWork w) async {
    final List<QueuedWork> q = await getQueue();
    q.removeWhere((e) => e.itemId == w.itemId);
    q.insert(0, w);
    await setQueue(q);
  }

  Future<void> removeAt(int index) async {
    final List<QueuedWork> q = await getQueue();
    if (index < 0 || index >= q.length) return;
    q.removeAt(index);
    await setQueue(q);
  }

  Future<void> move(int from, int to) async {
    final List<QueuedWork> q = await getQueue();
    if (from < 0 ||
        from >= q.length ||
        to < 0 ||
        to >= q.length ||
        from == to) {
      return;
    }
    final QueuedWork item = q.removeAt(from);
    q.insert(to, item);
    await setQueue(q);
  }

  Future<void> clear() async {
    await _backend.set(_queueKey, jsonEncode(<dynamic>[]));
  }

  Future<QueuedWork?> getCurrent() async {
    final String? raw = await _backend.get(_currentKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return QueuedWork.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on Object {
      return null;
    }
  }

  Future<void> setCurrent(QueuedWork? w) async {
    if (w == null) {
      await _backend.set(_currentKey, '');
      return;
    }
    await _backend.set(_currentKey, jsonEncode(w.toJson()));
  }
}

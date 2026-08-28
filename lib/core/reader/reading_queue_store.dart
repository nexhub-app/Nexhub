/// 跨作品待读队列（X-2 跨类型对齐：小说 / 漫画）。
///
/// 复用播放器  `PlayQueueStore` 的持久化模式（SharedPreferences + 身份存储）：
/// 仅保存作品的身份与起始章信息，具体章节列表在打开时由对应源的解析器
/// 重新抓取（`fetchNovelChapters` / `fetchChapters`），不在此硬编码目录。
library;

import 'dart:convert';

import '../comic/models/reader_preferences.dart'
    show PrefsBackend, SharedPrefsBackend;
import '../models/plugin_config.dart' show SourceType;

/// 待读队列中的单条作品记录（可序列化）。
class QueuedReading {
  /// 模块类型：小说（novelSource）或漫画（mangaSource）。
  final SourceType sourceType;

  /// 源 ID（书籍所属书源；本地作品为空串）。
  final String sourceId;

  /// 作品 ID（书架收藏/历史/队列去重的唯一标识）。
  final String itemId;

  /// 作品标题。
  final String title;

  final String? coverUrl;
  final String? detailUrl;

  /// 打开时定位的起始章索引（恢复最近阅读进度时由阅读器自己校准）。
  final int initialChapterIndex;

  /// 本地模式：本地文件路径（localPath + localKind，透传给打开辅助）。
  final String? localPath;
  final String? localKind;

  /// 入队/更新时间（毫秒）。
  final int updatedAt;

  const QueuedReading({
    required this.sourceType,
    required this.sourceId,
    required this.itemId,
    required this.title,
    this.coverUrl,
    this.detailUrl,
    this.initialChapterIndex = 0,
    this.localPath,
    this.localKind,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'sourceType': sourceType.apiName,
        'sourceId': sourceId,
        'itemId': itemId,
        'title': title,
        'coverUrl': coverUrl,
        'detailUrl': detailUrl,
        'initialChapterIndex': initialChapterIndex,
        'localPath': localPath,
        'localKind': localKind,
        'updatedAt': updatedAt,
      };

  factory QueuedReading.fromJson(Map<String, dynamic> json) {
    final SourceType? st = SourceType.parse(json['sourceType'] as String?);
    return QueuedReading(
      sourceType: st ?? SourceType.novelSource,
      sourceId: (json['sourceId'] as String?) ?? '',
      itemId: (json['itemId'] as String?) ?? '',
      title: (json['title'] as String?) ?? '',
      coverUrl: json['coverUrl'] as String?,
      detailUrl: json['detailUrl'] as String?,
      initialChapterIndex: (json['initialChapterIndex'] as num?)?.toInt() ?? 0,
      localPath: json['localPath'] as String?,
      localKind: json['localKind'] as String?,
      updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 跨作品待读队列持久化（SharedPreferences）。
///
/// 两条数据：
/// - `reading_queue_v1`：待读队列（有序，不含当前在读的作品）。
/// - `reading_queue_current_v1`：当前/最近在读的作品，用于「恢复最近队列」。
///
/// 复用 [PrefsBackend] 抽象，便于测试注入内存实现（同 [PlayQueueStore]）。
class ReadingQueueStore {
  static const String _queueKey = 'reading_queue_v1';
  static const String _currentKey = 'reading_queue_current_v1';

  final PrefsBackend _backend;

  ReadingQueueStore({PrefsBackend? backend})
      : _backend = backend ?? const SharedPrefsBackend();

  Future<List<QueuedReading>> getQueue() async {
    final String? raw = await _backend.get(_queueKey);
    if (raw == null || raw.isEmpty) return <QueuedReading>[];
    try {
      final List<dynamic> list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => QueuedReading.fromJson(e as Map<String, dynamic>))
          .toList();
    } on Object {
      return <QueuedReading>[];
    }
  }

  Future<void> setQueue(List<QueuedReading> queue) async {
    await _backend.set(
      _queueKey,
      jsonEncode(queue.map((e) => e.toJson()).toList()),
    );
  }

  /// 追加到队尾；同 itemId 已存在则刷新其时间但不重复加入。
  Future<void> add(QueuedReading w) async {
    final List<QueuedReading> q = await getQueue();
    if (q.any((e) => e.itemId == w.itemId)) return;
    q.add(w);
    await setQueue(q);
  }

  /// 插入队首（「下一部读」）。
  Future<void> insertNext(QueuedReading w) async {
    final List<QueuedReading> q = await getQueue();
    q.removeWhere((e) => e.itemId == w.itemId);
    q.insert(0, w);
    await setQueue(q);
  }

  Future<void> removeAt(int index) async {
    final List<QueuedReading> q = await getQueue();
    if (index < 0 || index >= q.length) return;
    q.removeAt(index);
    await setQueue(q);
  }

  /// 打开某一项后自动移出队列（读完即完成）；返回被移除项。
  Future<QueuedReading?> take(int index) async {
    final List<QueuedReading> q = await getQueue();
    if (index < 0 || index >= q.length) return null;
    final QueuedReading w = q.removeAt(index);
    await setQueue(q);
    return w;
  }

  /// 按作品 ID 移出队列（无则忽略）。
  Future<void> removeByItemId(String itemId) async {
    final List<QueuedReading> q = await getQueue();
    final int before = q.length;
    q.removeWhere((e) => e.itemId == itemId);
    if (q.length != before) await setQueue(q);
  }

  Future<void> clear() async {
    await _backend.set(_queueKey, jsonEncode(<dynamic>[]));
  }

  Future<QueuedReading?> getCurrent() async {
    final String? raw = await _backend.get(_currentKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return QueuedReading.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on Object {
      return null;
    }
  }

  Future<void> setCurrent(QueuedReading? w) async {
    if (w == null) {
      await _backend.set(_currentKey, '');
      return;
    }
    await _backend.set(_currentKey, jsonEncode(w.toJson()));
  }
}
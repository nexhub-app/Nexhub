/// 进行中会话记录器（短生命）。
///
/// 用法（详情页 / 阅读器在生命周期里）：
///   final recorder = ReadingSessionRecorder.instance;
///   recorder.begin(workId, sourceId, StatsMediaType.comic);
///   ... tick() 由 UI 周期性调用或进度保存时调用 ...
///   recorder.tick(workId, ...);
///   recorder.commit(workId, ...);   // 用户离开/暂停/切集
///
/// 持久化：进行中状态每秒级被 tick 写入 SharedPreferences `reading_session_state_v1`，
/// 下次 begin 时如果发现旧快照且时间戳未超过 24 小时，会复活"之前
/// 未提交但仍在进行中"的会话（杀进程 / 后台切换丢失保护）。
///
/// 提交时机：commit 时把"自上次 commit 起的累计时长（按 lastTickAtMs - tick 时刻
/// 时间差）"作为 delta 写入 [StatsRepository.recordSession]，随后清掉快照。
///
/// ⚠️ 本类不强制要求 box 已打开；所有写入都用 try-catch 兜底，
/// Reader/Player 退出时不会因为统计失败而崩溃。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'stats_models.dart';
import 'stats_repository.dart';

/// 默认 tick 间隔（两次 tick 之间的最大容差）。
const Duration kDefaultTickInterval = Duration(seconds: 5);

/// 进行中会话超过该阈值但仍未 commit，视为僵尸，在 begin 时主动丢弃，避免
/// 长期累加错误数据。
const Duration kSessionStaleThreshold = Duration(hours: 24);

class ReadingSessionRecorder extends ChangeNotifier {
  ReadingSessionRecorder._();
  static final ReadingSessionRecorder instance = ReadingSessionRecorder._();

  static const String _prefsKey = 'reading_session_state_v1';

  /// 当前活跃会话：key = `<type>|<sourceId?|<workId>`。
  final Map<String, ReadingSessionSnapshot> _active = {};

  bool _loaded = false;

  /// 初始化：从 SharedPreferences 恢复历史快照。启动早期调用即可，
  /// box 是否打开不强制要求。
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final entry in decoded.entries) {
        try {
          final snap = ReadingSessionSnapshot.fromJson(
            Map<String, dynamic>.from(entry.value as Map),
          );
          // 丢弃过期快照（>24h 未 commit 视为已结束）。
          if (snap.startedAtMs == 0 ||
              now - snap.lastTickAtMs >
                  kSessionStaleThreshold.inMilliseconds) {
            continue;
          }
          _active[entry.key as String] = snap;
        } catch (_) {
          // 跳过损坏条目
        }
      }
    } on Object {
      // best-effort
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = <String, dynamic>{
        for (final e in _active.entries) e.key: e.value.toJson(),
      };
      await prefs.setString(_prefsKey, jsonEncode(data));
    } on Object {
      // best-effort
    }
  }

  /// 开始一个会话：若已有同 key 的快照则覆盖（视为新一段开始）。
  Future<void> begin({
    required String workId,
    required String? sourceId,
    required StatsMediaType type,
    String? lastChapterTitle,
    String? title,
    String? coverUrl,
  }) async {
    if (!_loaded) await load();
    final now = DateTime.now().millisecondsSinceEpoch;
    final snap = ReadingSessionSnapshot(
      workId: workId,
      sourceId: sourceId,
      type: type,
      title: title,
      coverUrl: coverUrl,
      startedAtMs: now,
      accumulatedSec: 0,
      lastTickAtMs: now,
      lastChapterTitle: lastChapterTitle,
    );
    _active[snap.prefsKey] = snap;
    await _persist();
    notifyListeners();
  }

  /// 心跳：刷新 lastTickAtMs，并把"自上次 tick 至 now"的秒数累加到 accumulated。
  /// 通常由阅读器周期性调用（每 5s 左右）。
  Future<void> tick({
    required String workId,
    required String? sourceId,
    required StatsMediaType type,
    String? lastChapterTitle,
    Duration minStep = kDefaultTickInterval,
  }) async {
    if (!_loaded) await load();
    final key = '${type.storageKey}|${sourceId ?? ''}|$workId';
    final snap = _active[key];
    if (snap == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final delta = now - snap.lastTickAtMs;
    if (delta <= 0) return;
    // 防止设备休眠后大跨度累加（如锁屏 6h 突然 tick）。
    if (delta > Duration(minutes: 5).inMilliseconds) {
      // 先 commit 上一个跨度（保证数据不丢），再以 now 开始新一段。
      final cappedDelta = Duration(minutes: 5).inMilliseconds;
      _active[key] = snap.copyWith(
        accumulatedSec: snap.accumulatedSec + (cappedDelta ~/ 1000),
        lastTickAtMs: now,
        lastChapterTitle: lastChapterTitle ?? snap.lastChapterTitle,
      );
    } else {
      _active[key] = snap.copyWith(
        accumulatedSec: snap.accumulatedSec + (delta ~/ 1000),
        lastTickAtMs: now,
        lastChapterTitle: lastChapterTitle ?? snap.lastChapterTitle,
      );
    }
    await _persist();
  }

  /// 提交：把"自上次 tick 至 now"的时长 + accumulated 一起作为 delta
  /// 写入 [StatsRepository.recordSession]，随后清掉快照。
  ///
  /// [source] 标识来源（媒体/漫画/小说）。
  /// 返回实际提交的总秒数（便于上层显示「本次观看 X 分钟」）。
  Future<int> commit({
    required String workId,
    required String? sourceId,
    required StatsMediaType type,
    String? lastChapterTitle,
    String? title,
    String? coverUrl,
    SessionSource source = SessionSource.manual,
  }) async {
    if (!_loaded) await load();
    final key = '${type.storageKey}|${sourceId ?? ''}|$workId';
    final snap = _active[key];
    if (snap == null) return 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    var accumulated = snap.accumulatedSec;
    final dt = now - snap.lastTickAtMs;
    if (dt > 0) {
      // commit 时再做一次 tick 累积（防止最后一次 tick 缺失的尾段丢失）。
      if (dt <= Duration(minutes: 5).inMilliseconds) {
        accumulated += dt ~/ 1000;
      } else {
        accumulated += Duration(minutes: 5).inSeconds;
      }
    }
    _active.remove(key);
    await _persist();
    notifyListeners();
    if (accumulated <= 0) return 0;
    try {
      await StatsRepository.instance.recordSession(SessionDelta(
        workId: workId,
        sourceId: sourceId,
        type: type,
        title: title ?? snap.title,
        coverUrl: coverUrl ?? snap.coverUrl,
        durationSec: accumulated,
        committedAtMs: now,
        lastChapterTitle: lastChapterTitle ?? snap.lastChapterTitle,
        source: source,
      ));
    } catch (_) {
      // best-effort
    }
    return accumulated;
  }

  /// 放弃某个进行中会话（不写入统计，常见于调试）。
  Future<void> discard({
    required String workId,
    required String? sourceId,
    required StatsMediaType type,
  }) async {
    if (!_loaded) await load();
    final key = '${type.storageKey}|${sourceId ?? ''}|$workId';
    if (_active.remove(key) != null) {
      await _persist();
      notifyListeners();
    }
  }

  /// 是否有进行中会话（仅统计测试 / 调试用）。
  bool isActive({
    required String workId,
    required String? sourceId,
    required StatsMediaType type,
  }) {
    final key = '${type.storageKey}|${sourceId ?? ''}|$workId';
    return _active.containsKey(key);
  }

  /// 当前活跃 key 数（仅调试）。
  int get activeCount => _active.length;
}

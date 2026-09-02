/// RSS 更新检测器（文档 §10.2 + 16.13 RSS 更新通知）。
///
/// 定期轮询已订阅的 RSS 源，对比上次记录的最新条目标题，
/// 检测到新条目时通过 [ChangeNotifier] 驱动 UI 显示未读数 badge，
/// 并在启用时发送 OS 系统通知（P2-3，见 [RssNotificationService]）。
///
/// 设计说明：
/// - 仅前台轮询（Timer.periodic），不引入 workmanager。
/// - OS 通知经 [RssNotificationService]（flutter_local_notifications）发送，
///   **平台降级**：Web/Windows 无官方后端，自动跳过、仅保留应用内未读 badge。
/// - 持久化每条 feed 的 lastItemTitle + lastCheckedAt + newCount，
///   key = `rss_feed_states_v1`；系统通知开关存于 `rss_update_settings_v1`。
library;

import 'dart:async';
import 'dart:convert';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';

import '../comic/models/reader_preferences.dart';
import 'rss_article_store.dart';
import 'rss_feed.dart';
import 'rss_manager.dart';
import 'rss_notification_service.dart';

/// 单条 RSS 订阅源的检测状态。
class RssFeedState {
  /// 最新已记录的条目标题（用于去重对比，保留向后兼容旧数据）。
  final String? lastItemTitle;

  /// 上次检测时已见条目的稳定键集合（优先用 [seenKeys]，[lastItemTitle] 仅旧数据）。
  final List<String> seenKeys;

  /// 上次检测时间（毫秒时间戳）。
  final int? lastCheckedAt;

  /// 未读新条目数（用户查看后清零）。
  final int newCount;

  const RssFeedState({
    this.lastItemTitle,
    this.seenKeys = const <String>[],
    this.lastCheckedAt,
    this.newCount = 0,
  });

  RssFeedState copyWith({
    String? lastItemTitle,
    List<String>? seenKeys,
    int? lastCheckedAt,
    int? newCount,
  }) =>
      RssFeedState(
        lastItemTitle: lastItemTitle ?? this.lastItemTitle,
        seenKeys: seenKeys ?? this.seenKeys,
        lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
        newCount: newCount ?? this.newCount,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'lastItemTitle': lastItemTitle,
        'seenKeys': seenKeys,
        'lastCheckedAt': lastCheckedAt,
        'newCount': newCount,
      };

  factory RssFeedState.fromJson(Map<String, dynamic> json) => RssFeedState(
        lastItemTitle: json['lastItemTitle'] as String?,
        seenKeys: (json['seenKeys'] as List<dynamic>?)
                ?.map((e) => e as String)
                .toList() ??
            const <String>[],
        lastCheckedAt: json['lastCheckedAt'] as int?,
        newCount: json['newCount'] as int? ?? 0,
      );
}

/// 轮询间隔预设。
enum RssUpdateInterval {
  minutes15,
  minutes30,
  hour1,
  hours2,
  hours4;

  Duration get duration => switch (this) {
        RssUpdateInterval.minutes15 => const Duration(minutes: 15),
        RssUpdateInterval.minutes30 => const Duration(minutes: 30),
        RssUpdateInterval.hour1 => const Duration(hours: 1),
        RssUpdateInterval.hours2 => const Duration(hours: 2),
        RssUpdateInterval.hours4 => const Duration(hours: 4),
      };

  String get l10nKey => switch (this) {
        RssUpdateInterval.minutes15 => 'interval15m',
        RssUpdateInterval.minutes30 => 'interval30m',
        RssUpdateInterval.hour1 => 'interval1h',
        RssUpdateInterval.hours2 => 'interval2h',
        RssUpdateInterval.hours4 => 'interval4h',
      };
}

/// RSS 更新检测器——全应用单例（Provider 注入）。
class RssUpdateChecker extends ChangeNotifier {
  RssUpdateChecker({
    required this.rssManager,
    PrefsBackend? backend,
  }) : _backend = backend ?? const SharedPrefsBackend();

  final RssManager rssManager;
  final PrefsBackend _backend;

  static const String _stateKey = 'rss_feed_states_v1';
  static const String _settingsKey = 'rss_update_settings_v1';

  final Map<String, RssFeedState> _states = {};
  bool _enabled = false;
  RssUpdateInterval _interval = RssUpdateInterval.hour1;
  bool _systemNotification = false;

  /// 标题关键词自动已读：刷新时命中任一关键词的新文章不计入未读数，
  /// 并同步在文章库标记已读（信息降噪，关键词为空 = 功能关闭）。
  List<String> _autoReadKeywords = const <String>[];
  Timer? _timer;
  StreamSubscription<BatteryState>? _batterySub;

  /// 是否启用更新检测。
  bool get enabled => _enabled;

  /// 是否在支持的平台发 OS 系统通知（P2-3）。Windows/Web 无后端，实际不发送。
  bool get systemNotification => _systemNotification;

  /// 当前轮询间隔。
  RssUpdateInterval get interval => _interval;

  /// 自动已读关键词（只读快照）。
  List<String> get autoReadKeywords => List.unmodifiable(_autoReadKeywords);

  /// 标题是否命中自动已读关键词（大小写不敏感的包含匹配）。
  bool matchesAutoRead(String? title) {
    if (title == null || title.isEmpty || _autoReadKeywords.isEmpty) {
      return false;
    }
    final t = title.toLowerCase();
    for (final k in _autoReadKeywords) {
      if (k.isNotEmpty && t.contains(k.toLowerCase())) return true;
    }
    return false;
  }

  /// 设置自动已读关键词（自动去空白、去空项；空列表 = 关闭）。
  Future<void> setAutoReadKeywords(List<String> keywords) async {
    _autoReadKeywords = keywords
        .map((k) => k.trim())
        .where((k) => k.isNotEmpty)
        .toList(growable: false);
    await _saveSettings();
    notifyListeners();
  }

  /// 所有 feed 的状态（只读）。
  Map<String, RssFeedState> get states => Map.unmodifiable(_states);

  /// 某条 feed 的未读数。
  int newCountFor(String feedId) => _states[feedId]?.newCount ?? 0;

  /// 总未读数（所有 feed 之和）。
  int get totalNewCount => _states.values.fold(0, (sum, s) => sum + s.newCount);

  /// 新条目检测回调（由 UI 层订阅以触发 SnackBar / badge）。
  VoidCallback? onNewItemsDetected;

  /// 初始化：加载持久化状态 + 设置 + 若启用则启动定时器。
  Future<void> init() async {
    await _loadStates();
    await _loadSettings();
    if (_enabled) {
      _startTimer();
      _setupBatteryCheck();
      // 打开应用即检查一次（触发条件：打开应用），不等首个周期。
      unawaited(checkAllFeeds());
    }
    notifyListeners();
  }

  /// 设置启用状态。
  Future<void> setEnabled(bool value) async {
    _enabled = value;
    if (value) {
      _startTimer();
      _setupBatteryCheck();
    } else {
      _stopTimer();
      await _teardownBatteryCheck();
    }
    await _saveSettings();
    notifyListeners();
  }

  /// 充电时自动检测开关（触发条件：充电）。
  bool _chargeCheck = false;
  bool get chargeCheck => _chargeCheck;

  /// 设置充电时自动检测。
  Future<void> setChargeCheck(bool value) async {
    _chargeCheck = value;
    if (_enabled) {
      if (value) {
        _setupBatteryCheck();
      } else {
        await _teardownBatteryCheck();
      }
    }
    await _saveSettings();
    notifyListeners();
  }

  /// 订阅电池状态：进入充电状态即触发一次全量检测。
  void _setupBatteryCheck() {
    if (!_chargeCheck) return;
    _batterySub ??= Battery().onBatteryStateChanged.listen((BatteryState s) {
      if (s == BatteryState.charging || s == BatteryState.full) {
        unawaited(checkAllFeeds());
      }
    });
  }

  Future<void> _teardownBatteryCheck() async {
    await _batterySub?.cancel();
    _batterySub = null;
  }

  /// 设置轮询间隔。
  Future<void> setInterval(RssUpdateInterval value) async {
    _interval = value;
    if (_enabled) {
      _stopTimer();
      _startTimer();
    }
    await _saveSettings();
    notifyListeners();
  }

  /// 设置是否发送 OS 系统通知（P2-3）。开启时请求权限（Android 13+）。
  Future<void> setSystemNotification(bool value) async {
    _systemNotification = value;
    if (value) {
      await RssNotificationService.instance.requestPermission();
    }
    await _saveSettings();
    notifyListeners();
  }

  /// 标记某条 feed 的未读数清零（用户查看后调用）。
  Future<void> markRead(String feedId) async {
    final s = _states[feedId];
    if (s == null || s.newCount == 0) return;
    _states[feedId] = s.copyWith(newCount: 0);
    await _saveStates();
    notifyListeners();
  }

  /// 立即执行一次检测（忽略定时器）。
  Future<void> checkAllFeeds() async {
    final before = totalNewCount;
    for (final feed in rssManager.feeds) {
      await _checkFeed(feed);
    }
    await _saveStates();
    notifyListeners();
    // 聚合发一条 OS 通知（P2-3）：仅统计新增未读数，避免每条 feed 各弹一条。
    if (_systemNotification) {
      final delta = totalNewCount - before;
      if (delta > 0) {
        await RssNotificationService.instance.showNewArticles(count: delta);
      }
    }
  }

  /// 检测单条 feed 的新条目。
  ///
  /// 以条目的稳定键（[RssItem.url]，缺失时回退标题）判断新条目，避免标题
  /// 变更/重排导致误判（B7）。从列表顶部往下数，遇到第一个已在「已见集合」
  /// 中的键即停止，之前的都算新；若整个列表都是新键（源正常轮换旧条目），
  /// 限制新条目上限，避免每次刷新把全部标为新造成未读刷屏。
  Future<void> _checkFeed(RssFeed feed) async {
    try {
      final parsed = await rssManager.fetchFeed(feed);
      final items = parsed.items;
      if (items.isEmpty) return;

      // 新内容拉取后写入本地缓存（列表/详情优先读缓存，断网/慢网也能秒开；
      // 详情页手动刷新才绕过缓存重新抓取）。
      try {
        await RssArticleStore.instance.cacheFeed(feed.id, items);
      } on Object {
        // 缓存写入失败不影响本次检测。
      }

      String itemKey(RssItem i) => i.url.isNotEmpty ? i.url : i.title;
      final currentKeys = items.map(itemKey).toList();
      final prevState = _states[feed.id];
      final prevSeen = prevState?.seenKeys ?? const <String>[];

      // 首次记录：不报新条目，仅记录当前已见键集合
      if (prevSeen.isEmpty && prevState?.lastItemTitle == null) {
        _states[feed.id] = RssFeedState(
          lastItemTitle: items.first.title,
          seenKeys: currentKeys,
          lastCheckedAt: DateTime.now().millisecondsSinceEpoch,
          newCount: 0,
        );
        return;
      }

      // 计算新条目数：从顶部往下，遇到第一个已见键即停止。
      // 命中自动已读关键词的条目不计入未读，并同步标记文章库已读。
      final prevSeenSet = Set<String>.from(prevSeen);
      int newCount = 0;
      for (final item in items) {
        if (prevSeenSet.contains(itemKey(item))) break;
        if (matchesAutoRead(item.title)) {
          unawaited(RssArticleStore.instance.markRead(feed.id, item));
          continue;
        }
        newCount++;
      }

      // 防止轮换/全量更新导致未读刷屏：新条目上限为列表长度的一半（至少 1）。
      const int kMaxNewRatio = 2;
      final int cap = (currentKeys.length / kMaxNewRatio).ceil();
      if (newCount > cap) newCount = cap;

      final prevNewCount = prevState?.newCount ?? 0;
      // 合并已见集合（保留上限，避免无限增长）。
      final mergedSeen = <String>{
        ...prevSeenSet,
        ...currentKeys,
      };
      final trimmedSeen =
          mergedSeen.length > 500 ? currentKeys : mergedSeen.toList();

      _states[feed.id] = RssFeedState(
        lastItemTitle: items.first.title,
        seenKeys: trimmedSeen,
        lastCheckedAt: DateTime.now().millisecondsSinceEpoch,
        newCount: prevNewCount + newCount,
      );

      if (newCount > 0) {
        onNewItemsDetected?.call();
      }
    } catch (_) {
      // 网络错误等忽略，下次再试
    }
  }

  void _startTimer() {
    _stopTimer();
    _timer = Timer.periodic(_interval.duration, (_) => checkAllFeeds());
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _loadStates() async {
    final raw = await _backend.get(_stateKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      _states.clear();
      for (final entry in map.entries) {
        _states[entry.key] =
            RssFeedState.fromJson(entry.value as Map<String, dynamic>);
      }
    } catch (_) {
      // 损坏数据忽略
    }
  }

  Future<void> _saveStates() async {
    final map = <String, dynamic>{};
    for (final entry in _states.entries) {
      map[entry.key] = entry.value.toJson();
    }
    await _backend.set(_stateKey, jsonEncode(map));
  }

  Future<void> _loadSettings() async {
    final raw = await _backend.get(_settingsKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      _enabled = map['enabled'] as bool? ?? false;
      _systemNotification = map['systemNotification'] as bool? ?? false;
      final intervalIndex = map['interval'] as int? ?? 2;
      _interval = RssUpdateInterval.values.elementAtOrNull(intervalIndex) ??
          RssUpdateInterval.hour1;
      _autoReadKeywords =
          (map['autoReadKeywords'] as List<dynamic>? ?? const [])
              .whereType<String>()
              .toList(growable: false);
      _chargeCheck = map['chargeCheck'] as bool? ?? false;
    } catch (_) {
      // 损坏数据忽略
    }
  }

  Future<void> _saveSettings() async {
    final map = <String, dynamic>{
      'enabled': _enabled,
      'systemNotification': _systemNotification,
      'interval': _interval.index,
      'autoReadKeywords': _autoReadKeywords,
      'chargeCheck': _chargeCheck,
    };
    await _backend.set(_settingsKey, jsonEncode(map));
  }

  @override
  void dispose() {
    _stopTimer();
    _teardownBatteryCheck();
    super.dispose();
  }
}

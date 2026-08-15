/// 自动云同步调度器。
///
/// 历史包袱：`CloudSyncConfig.autoSync + frequency + nextSyncTimestamp` 配置
/// 字段齐全，但全库没有任何 Timer 触发它，开关在 UI 上像"假装可用"。
/// 本类把真正的定时器接上：每 60 秒读一次 `nextSyncTimestamp`，到点调用
/// `CloudSyncService.syncNow()`。
///
/// 限制：
/// - 仅在前台 / 最近应用 / 系统未杀进程时有效。杀进程后需要重新启动 App
///   才恢复。Android 上要更严格的"后台也跑"得用 workmanager / job scheduler；
///   本类保持简单，复杂后台任务留作后续工作。
/// - 重复启动是 no-op；同进程内只有一个 Timer 实例。
library;

import 'dart:async';

import 'cloud_sync_service.dart';

class AutoSyncScheduler {
  AutoSyncScheduler._();
  static final AutoSyncScheduler instance = AutoSyncScheduler._();

  Timer? _timer;
  bool _running = false;
  CloudSyncService? _service;

  /// Tick 间隔（默认 60s）。改小更精确但耗电。
  static const Duration kTickInterval = Duration(seconds: 60);

  bool get isRunning => _running;

  /// 启动调度器。`service` 必须是已 `init()` 过的实例（否则取不到 config）。
  ///
  /// 通常在 [SplashScreen] 的 init 末尾、CloudSyncService.init 之后调用：
  ///   final svc = CloudSyncService();
  ///   await svc.init();
  ///   AutoSyncScheduler.instance.start(svc);
  Future<void> start(CloudSyncService service) async {
    if (_running) return;
    _service = service;
    _running = true;
    // 启动时立即检查一次（用户在配置好自动备份后重启 / 错过窗口时尽快补跑）。
    unawaited(_check());
    _timer = Timer.periodic(kTickInterval, (_) => _check());
  }

  /// 停止调度器（通常不需要调用；调试 / 单测使用）。
  void stop() {
    _timer?.cancel();
    _timer = null;
    _running = false;
  }

  Future<void> _check() async {
    final svc = _service;
    if (svc == null) return;
    try {
      final cfg = svc.config;
      if (!cfg.autoSync) return;
      if (cfg.frequency == SyncFrequency.manual) return;
      final next = cfg.nextSyncTimestamp;
      if (next == null) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now < next) return;
      await svc.syncNow();
    } on Object {
      // 单次失败不应打断下次 tick：silent drop。
    }
  }

  /// 立即触发一次 tick 检查（测试 / 用户手动点击"立即检查"按钮时使用）。
  Future<void> tickNow() => _check();
}

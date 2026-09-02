/// RSS 更新系统通知（OS 通知，P2-3）。
///
/// 封装 `flutter_local_notifications`：在支持的平台（Android / iOS / Linux / macOS）
/// 上发送 RSS 更新 OS 通知；**平台降级**——Web 与 Windows 无官方后端，跳过 OS 通知、
/// 仅保留应用内未读 badge（与 `RssUpdateChecker` 既有「不依赖 flutter_local_notifications」
/// 的设计一致，避免 Windows 上初始化崩溃）。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// RSS 更新系统通知服务（单例）。
class RssNotificationService {
  RssNotificationService._();
  static final RssNotificationService instance = RssNotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  /// Web 与 Windows 无 flutter_local_notifications 后端，跳过 OS 通知。
  bool get _supported => !kIsWeb && !Platform.isWindows;

  /// 初始化通知插件与 Android 通知渠道。无后端平台安全跳过。
  Future<void> init() async {
    if (!_supported || _initialized) return;
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(),
      macOS: DarwinInitializationSettings(),
      linux: LinuxInitializationSettings(defaultActionName: '打开'),
    );
    try {
      await _plugin.initialize(settings);
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(
            const AndroidNotificationChannel(
              'rss_updates',
              'RSS 更新',
              description: 'RSS 订阅源有新内容时通知',
              importance: Importance.defaultImportance,
            ),
          );
      _initialized = true;
    } catch (e, st) {
      debugPrint('RssNotificationService.init failed: $e\n$st');
    }
  }

  /// 请求通知权限（Android 13+ 显式请求；iOS/macOS 在初始化时已触发）。
  /// 返回是否获权；无后端平台返回 false。
  Future<bool> requestPermission() async {
    if (!_supported) return false;
    try {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      final granted = await android?.requestNotificationsPermission();
      return granted ?? true;
    } catch (e, st) {
      debugPrint('RssNotificationService.requestPermission failed: $e\n$st');
      return false;
    }
  }

  /// 显示一条聚合的 RSS 更新通知。count<=0 或无后端/未初始化时安全跳过。
  Future<void> showNewArticles({required int count}) async {
    if (!_supported || !_initialized || count <= 0) return;
    final body = count == 1 ? '1 条新内容' : '$count 条新内容';
    try {
      await _plugin.show(
        1001,
        'RSS 更新',
        body,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'rss_updates',
            'RSS 更新',
            channelDescription: 'RSS 订阅源有新内容时通知',
          ),
          iOS: DarwinNotificationDetails(),
          macOS: DarwinNotificationDetails(),
          linux: LinuxNotificationDetails(),
        ),
      );
    } catch (e, st) {
      debugPrint('RssNotificationService.showNewArticles failed: $e\n$st');
    }
  }
}

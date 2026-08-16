import 'dart:async';
import 'package:flutter/services.dart';

import 'app_log.dart';

/// Native volume key interception using Android onKeyDown.
/// Prevents the system volume dialog from appearing and fully consumes
/// the key event at the native level (unlike flutter_volume_controller
/// which can't prevent the system dialog on all devices).
class VolumeKeyListener {
  static const _controlChannel = MethodChannel('nexhub/volume_control');
  static const _eventChannel = EventChannel('nexhub/volume_events');

  StreamSubscription<dynamic>? _subscription;

  /// Start listening for volume key events.
  /// [onVolumeDown] called when volume down key is pressed.
  /// [onVolumeUp] called when volume up key is pressed.
  Future<void> start({
    required VoidCallback onVolumeDown,
    required VoidCallback onVolumeUp,
  }) async {
    try {
      // Bug1 修复：先取消旧订阅再新建，避免 _syncVolumeKey 因任意偏好变化重复挂载时
      // 产生多个原生监听，导致一次按键触发多次翻页。
      await _subscription?.cancel();
      // 先订阅事件流（触发原生 EventChannel.onListen → 设置 volumeEventSink），
      // 再开启原生拦截：保证按键到达时原生 EventSink 已就绪，事件不会被丢弃
      // （此前先 enable 后订阅，实机存在 enable 与事件通道订阅的竞态）。
      _subscription = _eventChannel.receiveBroadcastStream().listen((event) {
        if (event == 'volume_down') {
          onVolumeDown();
        } else if (event == 'volume_up') {
          onVolumeUp();
        }
      });
      await _controlChannel.invokeMethod<void>('enableInterception');
    } on Object catch (e) {
      AppLog.instance.e('[音量键] 监听启动失败: $e');
      rethrow;
    }
  }

  /// Stop listening. The system will handle volume keys normally.
  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    try {
      await _controlChannel.invokeMethod<void>('disableInterception');
    } on Object {
      // Ignore if channel not yet registered.
    }
  }
}

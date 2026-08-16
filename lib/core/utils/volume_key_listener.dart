import 'dart:async';
import 'package:flutter/services.dart';

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
    await _controlChannel.invokeMethod<void>('enableInterception');
    // 取消旧的订阅再新建，避免 _syncVolumeKey 因任意偏好变化重复挂载时
    // 产生多个原生监听，导致一次按键触发多次翻页。
    await _subscription?.cancel();
    _subscription = _eventChannel.receiveBroadcastStream().listen((event) {
      if (event == 'volume_down') {
        onVolumeDown();
      } else if (event == 'volume_up') {
        onVolumeUp();
      }
    });
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

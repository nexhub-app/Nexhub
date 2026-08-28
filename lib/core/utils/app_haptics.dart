/// 统一触觉反馈工具 —— 修复「手机上感受不到震动」。
///
/// Flutter 自带的 [HapticFeedback] 在 Android 上依赖系统「触摸反馈/触感」
/// 设置，部分机型默认关闭或厂商屏蔽后完全无感。本工具在 Android 上改走
/// 原生 `nexhub/haptic` MethodChannel（MainActivity 内直接调 Vibrator 震动，
/// 不依赖系统触感设置）；非 Android 平台回退到 [HapticFeedback]（桌面端
/// 通常无震动但调用安全）。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 触觉反馈入口。语义与 [HapticFeedback] 对齐：
/// - [selectionClick] / [light]：轻触（开关、列表项、导航）；
/// - [medium]：中等（下载/安装、删除等确认类）；
/// - [heavy]：重（破坏性操作、长按）。
class AppHaptics {
  AppHaptics._();

  static const MethodChannel _channel = MethodChannel('nexhub/haptic');

  /// Android 走原生 Vibrator（无系统触感设置依赖）；其他平台回退系统 API。
  static bool get _useNative =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// 轻反馈：按钮、开关切换、导航点击。
  static Future<void> selectionClick() => _fire(
      intensity: 0,
      duration: 25,
      pulses: 1,
      fallback: HapticFeedback.selectionClick);

  /// 轻冲击。
  static Future<void> light() => _fire(
      intensity: 0,
      duration: 35,
      pulses: 1,
      fallback: HapticFeedback.lightImpact);

  /// 中等冲击：下载/安装、删除确认（双脉冲更易感知）。
  static Future<void> medium() => _fire(
      intensity: 1,
      duration: 70,
      pulses: 2,
      fallback: HapticFeedback.mediumImpact);

  /// 重冲击：破坏性操作、长按（双脉冲）。
  static Future<void> heavy() => _fire(
      intensity: 2,
      duration: 120,
      pulses: 2,
      fallback: HapticFeedback.heavyImpact);

  static Future<void> _fire({
    required int intensity,
    required int duration,
    required int pulses,
    required Future<void> Function() fallback,
  }) async {
    if (_useNative) {
      try {
        await _channel.invokeMethod<void>('vibrate', <String, int>{
          'intensity': intensity,
          'duration': duration,
          'pulses': pulses,
        });
        return;
      } on PlatformException {
        // 原生通道失败（低版本/厂商限制）：回退系统反馈。
      } on MissingPluginException {
        // 未实现原生通道（如桌面调试构建）：回退。
      }
    }
    await fallback();
  }
}

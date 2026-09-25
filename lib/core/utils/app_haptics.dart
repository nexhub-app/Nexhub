/// 统一触觉反馈工具 —— 按 Material Design 3 官方触感规范提供语义化震动。
///
/// Flutter 自带的 [HapticFeedback] 在 Android 上依赖系统「触摸反馈/触感」
/// 设置，部分机型默认关闭或厂商屏蔽后完全无感。本工具在 Android 上改走
/// 原生 `nexhub/haptic` MethodChannel：MainActivity 直接调 Vibrator 播放
/// **官方触感原语**（API 31+ 用 `VibrationEffect.Composition` 的
/// PRIMITIVE_TICK/CLICK/THUD 组合；API 29+ 用 `createPredefined` 的
/// EFFECT_TICK/CLICK/HEAVY_CLICK/DOUBLE_CLICK——即 Google 官方触感指南
/// 指定的平台效果，由厂商电机驱动调校，而非自定义振幅波形），不依赖系统
/// 触感设置；非 Android 平台回退到 [HapticFeedback]（桌面端通常无震动但
/// 调用安全）。
///
/// MD3 模式 → 用途对照（m3.material.io/foundations/designing-haptics）：
/// - [tick]：离散刻度/单选（滑块分档、分段按钮、导航项、筛选 chip）；
/// - [click]：点按确认（按钮、列表项、FAB）；
/// - [toggleOn] / [toggleOff]：开关、复选框（开强关弱）；
/// - [thunk]：重按（长按开始、拖拽拿起、破坏性操作确认）；
/// - [confirm]：任务成功（下载完成、导入成功，上行双击）；
/// - [reject]：任务失败/操作被拒（下行重击）；
/// - [gestureThreshold]：手势越阈（下拉刷新触发）。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 触觉反馈入口。各方法即 MD3 官方触感模式，原生端一一映射到官方原语。
class AppHaptics {
  AppHaptics._();

  static const MethodChannel _channel = MethodChannel('nexhub/haptic');

  /// Android 走原生 Vibrator（无系统触感设置依赖）；其他平台回退系统 API。
  static bool get _useNative =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  // ──  MD3 官方触感模式 ────────────────────────────────────────────

  /// MD3「Tick」：轻刻度反馈。离散值变化与单选：滑块分档、分段按钮、
  /// 底部导航切换、筛选 chip 选中、翻页。
  static Future<void> tick() =>
      _fire(effect: 'tick', fallback: HapticFeedback.selectionClick);

  /// MD3「Click」：点按确认。按钮、列表项、图标按钮等常规点按。
  static Future<void> click() =>
      _fire(effect: 'click', fallback: HapticFeedback.lightImpact);

  /// MD3「Toggle on」：开关/复选框切换到开启。比关闭略强。
  static Future<void> toggleOn() =>
      _fire(effect: 'toggleOn', fallback: HapticFeedback.selectionClick);

  /// MD3「Toggle off」：开关/复选框切换到关闭。比开启略弱。
  static Future<void> toggleOff() =>
      _fire(effect: 'toggleOff', fallback: HapticFeedback.selectionClick);

  /// MD3「Thunk」：重击。长按菜单开始、拖拽拿起（重排序）、破坏性操作确认。
  static Future<void> thunk() =>
      _fire(effect: 'thunk', fallback: HapticFeedback.heavyImpact);

  /// MD3「Confirm」：任务成功确认。下载/安装完成、导入/保存成功（上行双击）。
  static Future<void> confirm() =>
      _fire(effect: 'confirm', fallback: HapticFeedback.mediumImpact);

  /// MD3「Reject」：任务失败/操作被拒。下载失败、校验不通过等错误场景。
  static Future<void> reject() =>
      _fire(effect: 'reject', fallback: HapticFeedback.heavyImpact);

  /// MD3「Gesture threshold」：手势越过触发阈值。下拉刷新开始刷新的一刻。
  static Future<void> gestureThreshold() =>
      _fire(effect: 'gestureThreshold', fallback: HapticFeedback.lightImpact);

  // ──  旧语义兼容（既有调用点渐进迁移到上方 MD3 模式）──────────────

  /// 通用点按/导航反馈 → MD3 [click]。
  static Future<void> selectionClick() => click();

  /// 轻反馈 → MD3 [tick]。
  static Future<void> light() => tick();

  /// 确认类动作 → MD3 [confirm]。
  static Future<void> medium() => confirm();

  /// 重反馈（长按/破坏性）→ MD3 [thunk]。
  static Future<void> heavy() => thunk();

  static Future<void> _fire({
    required String effect,
    required Future<void> Function() fallback,
  }) async {
    if (_useNative) {
      try {
        await _channel
            .invokeMethod<void>('effect', <String, String>{'effect': effect});
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

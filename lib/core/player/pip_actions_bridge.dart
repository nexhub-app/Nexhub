import 'package:flutter/services.dart';

/// 系统 PiP 窗口动作桥（F-23）。
///
/// Android O+ 支持在系统画中画窗口内注册自定义动作按钮（[android.app.RemoteAction]）。
/// floating 包只提供进出 PiP、不支持窗口动作，故应用原生侧（MainActivity）扩展了
/// 独立通道：
/// - MethodChannel `nexhub/pip`：[setActions] 把「播放/暂停、弹幕、快进」动作列表
///   下发到原生，原生构建 RemoteAction 并刷新 [android.app.PictureInPictureParams]；
/// - EventChannel `nexhub/pip_events`：[actionStream] 接收原生回传的动作点击
///   （形如 `action:play_pause`）。
///
/// 其他平台（iOS / 桌面 / Web）无原生实现，所有调用安全降级为 no-op，不影响
/// PiP 基础进出（该能力仅 Android 有）。
class PipActionsBridge {
  PipActionsBridge._();

  /// 单例（原生侧通道 handler 在 MainActivity 注册一次，全局共享）。
  static final PipActionsBridge instance = PipActionsBridge._();

  static const MethodChannel _method = MethodChannel('nexhub/pip');
  static const EventChannel _event = EventChannel('nexhub/pip_events');

  /// 动作点击事件流。原生回传形如 `action:<id>`，[setActions] 中的 `id` 对应。
  late final Stream<String> actionStream =
      _event.receiveBroadcastStream().cast<String>();

  /// 下发 PiP 窗口动作列表。[actions] 每项为 `{id, title, icon}`，
  /// `icon` ∈ play / pause / danmaku / forward（原生映射到 drawable 资源）。
  ///
  /// 进入 PiP 前调用一次；播放 / 暂停状态变化后再次调用以同步按钮图标
  /// （原生经 [setPictureInPictureParams] 动态刷新，PiP 窗口内即时生效）。
  Future<void> setActions(List<Map<String, String>> actions) async {
    try {
      await _method.invokeMethod<void>('setActions', <String, Object>{
        'actions': actions,
      });
    } on Object {
      // 非 Android 平台无原生实现，忽略（PiP 本体也只在 Android 可用）。
    }
  }

  /// 清空 PiP 窗口动作（退出播放器时调用，避免残留动作描述）。
  Future<void> clearActions() async {
    try {
      await _method.invokeMethod<void>('clearActions');
    } on Object {
      // 同上，忽略。
    }
  }
}
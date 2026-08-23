/// 桌面真 PiP 窗口控制器（F-24）。
///
/// 使用 [desktop_multi_window] 包创建第二个 Flutter 窗口作为画中画，
/// 配合 [window_manager] 设置置顶 + 固定宽高比 + 无边框。
///
/// 架构：
/// 1. 主窗口调用 [enterDesktopPip] 创建 PiP 窗口，传入播放参数（JSON 编码）；
/// 2. PiP 窗口是一个独立 Flutter 引擎（windowArgument = 'pip'），运行
///    [DesktopPipScreen] 纯视频 UI；
/// 3. 窗口间通过 [WindowMethodChannel] 双向通信（位置同步、播放控制）；
/// 4. 退出 PiP 时调用 [exitDesktopPip] 关闭子窗口，主窗口恢复控制层。
///
/// 仅桌面平台（Windows/macOS/Linux）生效；移动端/Web 静默降级。
// ignore_for_file: unused_element

import 'dart:convert';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

/// 桌面 PiP 窗口通道名称。
const String _pipChannelName = 'nexhub/desktop_pip';

/// 桌面 PiP 控制器单例。
class DesktopPipController {
  DesktopPipController._();
  static final DesktopPipController instance = DesktopPipController._();

  /// 当前 PiP 窗口控制器（非空时表示 PiP 窗口已打开）。
  WindowController? _pipWindow;

  /// 当前是否处于桌面 PiP 模式。
  bool get isInDesktopPip => _pipWindow != null;

  /// 主窗口向 PiP 窗口发送消息的通道。
  WindowMethodChannel? _channel;

  /// 主窗口收到 PiP 窗口回传消息的 handler。
  void Function(Map<String, dynamic>)? _onMessage;

  /// 进入桌面 PiP。
  ///
  /// [videoUrl] 正在播放的视频地址。
  /// [position] 当前播放位置（毫秒）。
  /// [onMessage] 接收 PiP 窗口回传消息的回调。
  Future<bool> enterDesktopPip({
    required String videoUrl,
    required int position,
    required void Function(Map<String, dynamic>) onMessage,
  }) async {
    if (_pipWindow != null) return false; // 已在 PiP 中
    if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) {
      return false; // 非桌面平台降级
    }

    final args = jsonEncode(<String, dynamic>{
      'url': videoUrl,
      'position': position,
    });

    _onMessage = onMessage;

    try {
      _pipWindow = await WindowController.create(
        WindowConfiguration(arguments: 'pip'),
      );

      // 设置双向通道接收 PiP 窗口消息。
      _channel = WindowMethodChannel(_pipChannelName,
          mode: ChannelMode.bidirectional);
      await _channel!.setMethodCallHandler((call) async {
        _onMessage?.call(<String, dynamic>{
          'method': call.method,
          'arguments': call.arguments,
        });
      });

      // 初始化 PiP 窗口：传入播放参数。
      await _pipWindow!.invokeMethod('init', args);
      await _pipWindow!.show();
      return true;
    } on Object {
      _pipWindow = null;
      return false;
    }
  }

  /// 退出桌面 PiP，关闭子窗口。
  Future<void> exitDesktopPip() async {
    // 向 PiP 窗口发送关闭通知。
    try {
      await _channel?.invokeMethod('exit');
    } on Object {
      // 窗口可能已关闭，忽略。
    }
    await _channel?.setMethodCallHandler(null);
    _channel = null;
    _pipWindow = null;
    _onMessage = null;
  }

  /// 向 PiP 窗口发送消息（如位置更新、播放/暂停状态）。
  Future<void> sendMessage(Map<String, dynamic> msg) async {
    if (_pipWindow == null) return;
    try {
      await _channel?.invokeMethod('message', jsonEncode(msg));
    } on Object {
      // 窗口可能已关闭，忽略。
    }
  }
}

/// 桌面 PiP 窗口 UI（运行在独立 Flutter 引擎中）。
///
/// 仅显示视频画面 + 关闭按钮，无边框、置顶、固定宽高比。
/// 由 [DesktopPipController] 创建，通过 [WindowMethodChannel] 与主窗口通信。
class DesktopPipScreen extends StatefulWidget {
  const DesktopPipScreen({super.key});

  @override
  State<DesktopPipScreen> createState() => _DesktopPipScreenState();
}

class _DesktopPipScreenState extends State<DesktopPipScreen> {
  WindowController? _controller;
  String _videoUrl = '';
  int _initialPosition = 0;
  WindowMethodChannel? _channel;

  @override
  void initState() {
    super.initState();
    _initPipWindow();
  }

  Future<void> _initPipWindow() async {
    // 获取当前窗口控制器。
    _controller = await WindowController.fromCurrentEngine();

    // 设置窗口为置顶 + 无边框 + 固定宽高比（16:9）。
    await windowManager.setAlwaysOnTop(true);
    await windowManager.setSize(const Size(480, 270));
    await windowManager.setMinimumSize(const Size(320, 180));
    await windowManager.setMaximumSize(const Size(960, 540));
    await windowManager.setTitle('');
    // 无边框窗口（Windows 上需额外配置）。
    await windowManager.setTitleBarStyle(TitleBarStyle.hidden);

    // 设置通道接收主窗口消息。
    _channel = WindowMethodChannel(_pipChannelName,
        mode: ChannelMode.bidirectional);
    await _channel!.setMethodCallHandler(_handleMessage);

    // 读取启动参数（主窗口传入）。
    final args = _controller!.arguments;
    if (args == 'pip') {
      // 等待主窗口通过 invokeMethod('init', ...) 传入播放参数。
      _controller!.setWindowMethodHandler((call) async {
        if (call.method == 'init') {
          final data = jsonDecode(call.arguments as String)
              as Map<String, dynamic>;
          if (mounted) {
            setState(() {
              _videoUrl = data['url'] as String? ?? '';
              _initialPosition = data['position'] as int? ?? 0;
            });
          }
        } else if (call.method == 'message') {
          // 处理主窗口发来的消息。
        }
        return null;
      });
    }
  }

  Future<dynamic> _handleMessage(MethodCall call) async {
    switch (call.method) {
      case 'exit':
        // 主窗口要求关闭 PiP。
        await windowManager.close();
        break;
      case 'message':
        // 处理主窗口消息（位置更新等）。
        break;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 视频画面占位（实际需通过主窗口共享视频渲染纹理）。
          // 由于 Flutter 多窗口无法共享 Player 纹理，PiP 窗口需重新
          // 创建 Player 实例，通过 URL 重新打开视频。
          // 此处用 Container 占位，实际视频渲染由调用方通过
          // MethodChannel 传输纹理 ID 或使用独立 Player 实例。
          Center(
            child: _videoUrl.isNotEmpty
                ? const Center(
                    child: Text(
                      'PiP\n(视频渲染需独立 Player)',
                      style: TextStyle(color: Colors.white, fontSize: 16),
                      textAlign: TextAlign.center,
                    ),
                  )
                : const Center(
                    child: CircularProgressIndicator(color: Colors.white),
                  ),
          ),
          // 关闭按钮（右上角）。
          Positioned(
            top: 8,
            right: 8,
            child: GestureDetector(
              onTap: () async {
                // 通知主窗口退出 PiP。
                try {
                  await _channel?.invokeMethod('exit');
                } on Object {
                  // 忽略。
                }
                await windowManager.close();
              },
              child: Container(
                width: 32,
                height: 32,
                decoration: const BoxDecoration(
                  color: Colors.black54,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.close, color: Colors.white, size: 20),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
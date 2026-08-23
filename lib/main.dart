import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';
import 'core/network/runtime/nexhub_http_overrides.dart';
import 'core/debug/crash_log.dart';
import 'core/utils/app_log.dart';
import 'features/splash/splash_screen.dart';
import 'core/player/audio_playback_service.dart';
import 'core/theme/app_tokens.dart';

/// Entry point: defers all initialization to [SplashScreen] so the user sees
/// a branded splash while Hive boxes, sources, and managers come online.
void main() {
  // 全局兜底：把「构建期 / 异步」未捕获异常显示到屏幕上，避免 release 下整屏黑屏
  // 却无任何提示。渲染错误时不再是纯黑，而是给出可读的错误详情，便于定位根因。
  runZonedGuarded<void>(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // 全局统一 edge-to-edge（手势条区域透明）：与阅读器 / 播放器退出全屏后的
    // 还原状态保持一致，修复「退出全屏后底栏被系统手势条遮挡」。Android 15+
    // 强制 edge-to-edge，此处提前统一，避免进出全屏时系统 UI 模式跳变。
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

    // 全局网络覆盖：接管所有 dart:io HttpClient 派生流量（散落的独立
    // Dio/HttpClient、cached_network_image、下载器、云同步等）。此时用默认
    // 网络档案，真实配置在 splash 加载 NetworkConfigService 后即时生效。
    HttpOverrides.global = NexHubHttpOverrides();

    // 全局异常落盘：Flutter 框架错误（构建 / 布局 / 断言）写入崩溃日志，
    // 供「设置 → 高级 → 崩溃日志」查看。presentError 保留默认控制台输出。
    FlutterError.onError = (FlutterErrorDetails details) {
      unawaited(CrashLog.record(
        'Flutter 错误',
        details.exceptionAsString(),
        stack: details.stack,
      ));
      // 同步进运行日志缓冲（设置 → 高级 → 运行日志 可看）。
      AppLog.instance.e('Flutter 错误: ${details.exceptionAsString()}');
      FlutterError.presentError(details);
    };

    // 构建期异常可视化：任何 widget build 抛错时，展示错误文本而非黑屏。
    ErrorWidget.builder = (FlutterErrorDetails details) {
      FlutterError.presentError(details);
      return Directionality(
        textDirection: TextDirection.ltr,
        child: Container(
          color: const Color(0xFF141414),
          alignment: Alignment.center,
          padding: const EdgeInsets.all(AppTokens.spaceXl),
          child: SingleChildScrollView(
            child: Text(
              'UI 构建出错，请把下面这段发我：\n\n'
              '${details.exceptionAsString()}\n\n${details.stack}',
              style: const TextStyle(
                color: Color(0xFFFF6B6B),
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
        ),
      );
    };

    // 必须在创建任何 media_kit [Player] 之前初始化原生内核（libmpv）。
    // 该调用幂等，所有平台均可安全调用；缺失会导致 "MediaKit.ensureInitialized
    // must be called before using any API" 异常。
    // 兜底：若原生内核加载失败（如 Windows 桌面 mpv 原生库缺失或损坏，常见为
    // 构建时该原生库下载为 0 字节），绝不因此让整个应用崩溃黑屏——仅视频播放
    // 不可用，浏览 / 阅读等核心功能仍应正常启动。失败原因打到终端便于排查。
    try {
      MediaKit.ensureInitialized();
    } catch (e, st) {
      debugPrint('MediaKit.ensureInitialized failed: $e\n$st');
    }

    // 桌面端窗口控制（全屏 / F11）必须在 runApp 之前完成初始化——这是
    // window_manager 的硬性要求。若改到运行期（如阅读器 initState）再调
    // ensureInitialized，其原生侧会在已运行的消息循环中重挂窗口钩子，与 Flutter
    // 渲染管道相互等待，表现为「进入 / 退出阅读器画面完全冻结，只有手动 resize
    // 窗口才能恢复」，且此后 setFullScreen / isFullScreen 全部失效（F11、Esc 无反应）。
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      try {
        await windowManager.ensureInitialized();
      } catch (e, st) {
        debugPrint('windowManager.ensureInitialized failed: $e\n$st');
      }
    }

    // F-25：后台播放 + 系统媒体通知（audio_service / audio_session）。
    // 幂等初始化：注册平台媒体会话与音频打断/拔耳机处理。失败不影响前台播放，
    // 仅无后台通知栏。必须在 runApp 之前完成平台侧注册。
    try {
      await AudioPlaybackService.instance.initialize();
    } on Object catch (e, st) {
      debugPrint('AudioPlaybackService.initialize failed: $e\n$st');
    }

    runApp(const SplashScreen());
  }, (Object error, StackTrace stack) {
    unawaited(CrashLog.record('未捕获异常', error.toString(), stack: stack));
    // 同步进运行日志（设置 → 高级 → 运行日志），避免该异常只在崩溃日志里、
    // 用户从运行日志排查时看不到。
    AppLog.instance.eWithStack('未捕获异常', error, stack);
    debugPrint('Uncaught zone error: $error\n$stack');
  });
}

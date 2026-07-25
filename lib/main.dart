import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'features/splash/splash_screen.dart';

/// Entry point: defers all initialization to [SplashScreen] so the user sees
/// a branded splash while Hive boxes, sources, and managers come online.
void main() {
  // 全局兜底：把「构建期 / 异步」未捕获异常显示到屏幕上，避免 release 下整屏黑屏
  // 却无任何提示。渲染错误时不再是纯黑，而是给出可读的错误详情，便于定位根因。
  runZonedGuarded<void>(() {
    WidgetsFlutterBinding.ensureInitialized();

    // 构建期异常可视化：任何 widget build 抛错时，展示错误文本而非黑屏。
    ErrorWidget.builder = (FlutterErrorDetails details) {
      FlutterError.presentError(details);
      return Directionality(
        textDirection: TextDirection.ltr,
        child: Container(
          color: const Color(0xFF141414),
          alignment: Alignment.center,
          padding: const EdgeInsets.all(24),
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

    // 必须在创建任何 media_kit [Player] 之前初始化原生内核（libmpv / fvp 桥接）。
    // 该调用幂等，所有平台均可安全调用；缺失会导致 "MediaKit.ensureInitialized
    // must be called before using any API" 异常。
    // 兜底：若原生内核加载失败（如 Windows 桌面 mpv/fvp 原生库缺失或损坏，常见为
    // 构建时该原生库下载为 0 字节），绝不因此让整个应用崩溃黑屏——仅视频播放
    // 不可用，浏览 / 阅读等核心功能仍应正常启动。失败原因打到终端便于排查。
    try {
      MediaKit.ensureInitialized();
    } catch (e, st) {
      debugPrint('MediaKit.ensureInitialized failed: $e\n$st');
    }

    runApp(const SplashScreen());
  }, (Object error, StackTrace stack) {
    debugPrint('Uncaught zone error: $error\n$stack');
  });
}

/// 桌面端横向滚动增强（在线浏览源栏 / 分类 TabBar / 首页海报行 / 周期表
/// 星期条共用，亦可推广到其他横向区域）。
///
/// 两个桌面端痛点：
/// 1. Flutter 默认 [ScrollBehavior] 的 dragDevices 只含触控类设备，电脑端
///    鼠标左键按住拖不动横向列表 —— 用 [ScrollConfiguration] 放行
///    mouse / trackpad / stylus 解决；
/// 2. 横向 scrollable 只消费滚轮的 dx 分量，鼠标竖向滚轮（dy）在横排上
///    无效 —— [DesktopHorizontalScroll] 把 dy 转为横向 offset。
///
/// 滚轮 dy 通过 [GestureBinding.pointerSignalResolver] 注册（first-wins）：
/// 横排抢占后外层纵向页面同事件的滚动回调不再执行，避免横纵双轴联动；
/// 横排无可滚动余量（maxScrollExtent <= 0）时不注册，滚轮仍滚动外层页面。
/// 触控板 dx（横扫）不在此处理，交给框架对横向 scrollable 的原生消费，
/// 避免与框架重复滚动。
library;

import 'package:flutter/gestures.dart'
    show GestureBinding, PointerDeviceKind, PointerScrollEvent;
import 'package:material_ui/material_ui.dart';

/// 允许鼠标 / 触控板 / 触控笔拖动横向滚动的 [ScrollBehavior]。
///
/// 无 controller 可接管的横向区域（如 [TabBar]）可单独取用：
/// `ScrollConfiguration(behavior: desktopHorizontalDragBehavior(context), child: ...)`
ScrollBehavior desktopHorizontalDragBehavior(BuildContext context) {
  return ScrollConfiguration.of(context).copyWith(
    dragDevices: <PointerDeviceKind>{
      PointerDeviceKind.touch,
      PointerDeviceKind.mouse,
      PointerDeviceKind.trackpad,
      PointerDeviceKind.stylus,
    },
  );
}

/// 横向滚动区域封装：鼠标拖动（[desktopHorizontalDragBehavior]）+ 竖向
/// 滚轮转横向滚动（见文件头注释）。
///
/// [builder] 内创建的 scrollable（SingleChildScrollView / ListView 等）
/// 必须使用传入的 [ScrollController]，滚轮转换才生效。
class DesktopHorizontalScroll extends StatefulWidget {
  const DesktopHorizontalScroll({super.key, required this.builder});

  final Widget Function(BuildContext context, ScrollController controller)
      builder;

  @override
  State<DesktopHorizontalScroll> createState() =>
      _DesktopHorizontalScrollState();
}

class _DesktopHorizontalScrollState extends State<DesktopHorizontalScroll> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: (signal) {
        if (signal is! PointerScrollEvent || !_controller.hasClients) return;
        // 触控板 dx（横扫）由框架原生消费，这里只接管竖向滚轮 dy。
        final double delta = signal.scrollDelta.dy;
        if (delta == 0) return;
        // 内容不超宽时无需抢占滚轮，留给外层纵向页面滚动。
        if (_controller.position.maxScrollExtent <= 0) return;
        // resolver first-wins：注册后外层纵向 scrollable 的同事件回调
        // 不再执行，滚轮只滚横向，避免横纵双轴联动。
        GestureBinding.instance.pointerSignalResolver.register(signal, (event) {
          if (!_controller.hasClients) return;
          _controller.jumpTo(
            (_controller.offset + delta).clamp(
              0.0,
              _controller.position.maxScrollExtent,
            ),
          );
        });
      },
      child: ScrollConfiguration(
        behavior: desktopHorizontalDragBehavior(context),
        child: widget.builder(context, _controller),
      ),
    );
  }
}

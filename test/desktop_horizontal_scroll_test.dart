/// DesktopHorizontalScroll 行为测试（电脑端横向滚动增强）。
///
/// 覆盖三点：
/// 1. 鼠标左键按住拖动可横向滚动（dragDevices 放行 mouse）；
/// 2. 竖向滚轮 dy 转为横向 offset（含 clamp）；
/// 3. 内容不超宽（maxScrollExtent <= 0）时滚轮不抢占，外层纵向照常滚动。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nexhub/core/widgets/desktop_horizontal_scroll.dart';

/// 可横向滚动的桌面增强区域：viewport 200x100，内容 [contentWidth] 宽。
Widget _horizontalHarness({double contentWidth = 800}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 200,
          height: 100,
          child: DesktopHorizontalScroll(
            builder: (context, controller) => SingleChildScrollView(
              controller: controller,
              scrollDirection: Axis.horizontal,
              child: SizedBox(width: contentWidth, height: 60),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('鼠标左键按住拖动可横向滚动（dragDevices 放行 mouse）',
      (WidgetTester tester) async {
    await tester.pumpWidget(_horizontalHarness());

    // mouse 按下 → 左移 150px → 断言跟手位移 → 抬起。
    final gesture = await tester.startGesture(
      const Offset(400, 300),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(-150, 0));
    await tester.pump();

    final ScrollPosition position =
        tester.state<ScrollableState>(find.byType(Scrollable)).position;
    expect(position.pixels, 150, reason: 'mouse 拖动应驱动横向 offset');

    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('竖向滚轮 dy 转为横向 offset', (WidgetTester tester) async {
    await tester.pumpWidget(_horizontalHarness());

    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(const Offset(400, 300)));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 120)));
    await tester.pump();

    final ScrollPosition position =
        tester.state<ScrollableState>(find.byType(Scrollable)).position;
    expect(position.pixels, 120, reason: '滚轮 dy=120 应转为横向 offset');
  });

  testWidgets('滚轮 dy 超出 maxScrollExtent 时 clamp 到边界',
      (WidgetTester tester) async {
    await tester.pumpWidget(_horizontalHarness());

    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(const Offset(400, 300)));
    // maxScrollExtent = 800 - 200 = 600，滚 900 应停在 600。
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 900)));
    await tester.pump();

    final ScrollPosition position =
        tester.state<ScrollableState>(find.byType(Scrollable)).position;
    expect(position.pixels, 600, reason: '应 clamp 到 maxScrollExtent');
  });

  testWidgets('内容不超宽时滚轮不抢占，外层纵向照常滚动',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 200,
            height: 400,
            child: SingleChildScrollView(
              child: SizedBox(
                // 横向内容 100 < viewport 200：maxScrollExtent = 0。
                width: 100,
                height: 600,
                child: DesktopHorizontalScroll(
                  builder: (context, controller) => SingleChildScrollView(
                    controller: controller,
                    scrollDirection: Axis.horizontal,
                    child: const SizedBox(width: 100, height: 50),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(const Offset(100, 200)));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 100)));
    await tester.pump();

    final ScrollPosition outer =
        tester.state<ScrollableState>(find.byType(Scrollable).first).position;
    expect(outer.pixels, 100, reason: '外层纵向应收到滚轮事件');
  });
}

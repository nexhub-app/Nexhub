import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/comic/models/reader_preferences.dart';
import 'package:nexhub/features/manga/presentation/reader_tap_zones.dart';

/// Bug3 双击缩放三态消失修复测试：手势交互态（scale ≠ 1.0，含缩小 0.5x 与放大 2x）
/// 下，双击第一击不派发翻页（否则 _resetZoom 会把 0.5x 缩放态清掉，三态 0.5→2 失效），
/// 第二击正常触发 onZoom / onZoomAt。
void main() {
  Widget build({
    required bool interactive,
    required List<String> calls,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: ReaderTapZones(
          layout: ReaderTapZoneLayout.leftRight,
          tapZoneInvert: TapZoneInvert.none,
          isVertical: false,
          isWebtoon: false,
          isRTL: false,
          onPrev: () => calls.add('prev'),
          onNext: () => calls.add('next'),
          onToggleUi: () => calls.add('toggle'),
          onZoom: () => calls.add('zoom'),
          onZoomAt: (pos) => calls.add('zoomAt'),
          onUndoPageTurn: (next) => calls.add('undo:$next'),
          isZoomed: () => false,
          isZoomInteractive: () => interactive,
        ),
      ),
    );
  }

  // 双击两击落在 leftRight 布局的 next 热区（x > 0.55 屏宽）。
  const Offset nextTap = Offset(700, 600);

  Future<void> doubleTap(WidgetTester tester) async {
    await tester.tapAt(nextTap);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(nextTap);
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('缩小态（scale=0.5，interactive=true）：第一击不派发翻页，第二击触发缩放',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    final List<String> calls = <String>[];
    await tester.pumpWidget(build(interactive: true, calls: calls));

    // 第一击：落在 next 热区但不派发翻页（也不 toggle）。
    await tester.tapAt(nextTap);
    await tester.pump(const Duration(milliseconds: 50));
    expect(calls, isEmpty,
        reason: '缩小态下第一击必须不派发导航，否则翻页会把 0.5x 缩放态清掉');

    // 第二击（双击窗口内）：触发定点缩放，且不派发翻页。
    await tester.tapAt(nextTap);
    await tester.pump(const Duration(milliseconds: 50));
    expect(calls, contains('zoomAt'));
    expect(calls, isNot(contains('next')));
    expect(calls, isNot(contains('prev')));
    expect(calls, isNot(contains('toggle')));
  });

  testWidgets('放大态（scale=2.0，interactive=true）：第一击不派发翻页，第二击触发缩放',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    final List<String> calls = <String>[];
    await tester.pumpWidget(build(interactive: true, calls: calls));

    await tester.tapAt(nextTap);
    await tester.pump(const Duration(milliseconds: 50));
    expect(calls, isEmpty);

    await tester.tapAt(nextTap);
    await tester.pump(const Duration(milliseconds: 50));
    expect(calls, contains('zoomAt'));
    expect(calls, isNot(contains('next')));
    expect(calls, isNot(contains('prev')));
    expect(calls, isNot(contains('toggle')));
  });

  testWidgets('未缩放（scale=1.0，interactive=false）：第一击正常派发 next', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    final List<String> calls = <String>[];
    await tester.pumpWidget(build(interactive: false, calls: calls));

    await tester.tapAt(nextTap);
    await tester.pump(const Duration(milliseconds: 50));
    expect(calls, contains('next'));
  });

  testWidgets('交互态单点（仅一击）：不导航、不缩放，仅记录（双击第二击才能触发缩放）',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    final List<String> calls = <String>[];
    await tester.pumpWidget(build(interactive: true, calls: calls));

    // 双击完成后，紧接的一次单击（落在同一位置、时间已超出双击窗口）不应误触发。
    await doubleTap(tester);
    expect(calls, contains('zoomAt'));
    calls.clear();

    // 窗口外的一次单击（pump 超过双击窗口）→ 交互态下不派发任何动作。
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tapAt(nextTap);
    await tester.pump(const Duration(milliseconds: 50));
    expect(calls, isEmpty);
  });
}

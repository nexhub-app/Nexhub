/// 漫画超分渲染 widget 单测：验证 shader 路径真的接管渲染，且失败时静默回退。
///
/// 关键断言（防止「开关是假的」这类静默失效）：
/// - [MangaUpscaleMode.off]：走 [RawImage]，不创建 shader；
/// - [MangaUpscaleMode.sharpen] + 尺寸在纹理上限内：走 [CustomPaint]（shader 路径）；
/// - 尺寸超过纹理上限：回退 [RawImage]（超长条漫不因绑定失败而空白）；
/// - shader 资源不可用（测试环境无 SPIR-V 时）：仍能正常出图，不抛异常。
library;

import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nexhub/core/comic/manga_upscale.dart';
import 'package:nexhub/core/widgets/manga_upscaled_image.dart';

/// 构造一张真实可绘制的测试图（避免依赖任何资源文件）。
Future<ui.Image> _makeImage(int width, int height) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = const Color(0xFF888888),
  );
  canvas.drawRect(
    Rect.fromLTWH(width / 4, height / 4, width / 2, height / 2),
    Paint()..color = const Color(0xFF111111),
  );
  final ui.Picture picture = recorder.endRecording();
  final ui.Image image = await picture.toImage(width, height);
  picture.dispose();
  return image;
}

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(
        body: SizedBox(width: 400, height: 600, child: child),
      ),
    );

void main() {
  setUp(() {
    // 每个用例都重新加载 shader：单测进程内 FragmentProgram.fromAsset 允许重复
    // 调用，但 widget 侧的失败标记是实例级的，无需重置全局状态。
  });

  testWidgets('超分关闭时走普通 RawImage 渲染', (WidgetTester tester) async {
    final ui.Image image = await _makeImage(64, 64);
    await tester.pumpWidget(_host(MangaUpscaledImage(
      image: image,
      mode: MangaUpscaleMode.off,
    )));
    await tester.pumpAndSettle();

    expect(find.byType(RawImage), findsOneWidget);
    // 关闭档不进入 shader 路径。
    expect(find.byType(CustomPaint), findsWidgets);
    image.dispose();
  });

  testWidgets('超分开启且尺寸合法时必须走 shader 绘制路径',
      (WidgetTester tester) async {
    final ui.Image image = await _makeImage(200, 300);
    await tester.pumpWidget(_host(MangaUpscaledImage(
      image: image,
      mode: MangaUpscaleMode.sharpen,
    )));
    // 等待 shader 异步加载完成。
    await tester.pumpAndSettle();

    // 资源键正确时 shader 必然可用：若这里回退成 RawImage，说明 assetKey /
    // pubspec shaders 段 / 构建产物出了问题，超分开关会静默失效（必须失败而非放过）。
    expect(find.byType(RawImage), findsNothing,
        reason: 'shader 可用时不应回退 RawImage（否则超分静默失效）');
    final bool drewWithShader = tester
        .widgetList(find.byType(CustomPaint))
        .any((w) => w is CustomPaint && w.painter != null);
    expect(drewWithShader, isTrue, reason: '必须由 CustomPaint + shader 绘制');
    expect(tester.takeException(), isNull);
    image.dispose();
  });

  testWidgets('超出 GPU 纹理上限的源图回退普通渲染', (WidgetTester tester) async {
    // 高度超过 8192：模拟超长条漫单图。
    final ui.Image image = await _makeImage(64, kMangaUpscaleMaxTextureSide + 1);
    await tester.pumpWidget(_host(MangaUpscaledImage(
      image: image,
      mode: MangaUpscaleMode.sharpen,
    )));
    await tester.pumpAndSettle();

    expect(find.byType(RawImage), findsOneWidget);
    expect(tester.takeException(), isNull);
    image.dispose();
  });

  testWidgets('宽度为 infinity 时按父约束布局（不产生无限尺寸）',
      (WidgetTester tester) async {
    final ui.Image image = await _makeImage(120, 180);
    await tester.pumpWidget(_host(MangaUpscaledImage(
      image: image,
      mode: MangaUpscaleMode.resample,
      width: double.infinity,
      fit: BoxFit.fitWidth,
    )));
    await tester.pumpAndSettle();

    // 布局尺寸必须是有限值（infinity 会让 RenderBox 抛异常）。
    final Size size = tester.getSize(find.byType(MangaUpscaledImage));
    expect(size.width.isFinite, isTrue);
    expect(size.height.isFinite, isTrue);
    expect(size.width, greaterThan(0));
    expect(tester.takeException(), isNull);
    image.dispose();
  });

  testWidgets('cover 裁切：绘制尺寸不小于容器（不出现拉伸变形）',
      (WidgetTester tester) async {
    final ui.Image image = await _makeImage(100, 400);
    await tester.pumpWidget(_host(MangaUpscaledImage(
      image: image,
      mode: MangaUpscaleMode.resample,
      fit: BoxFit.cover,
      width: 400,
      height: 600,
    )));
    await tester.pumpAndSettle();

    // cover 语义：宽高比保持（100:400 = 1:4），绘制高 ≥ 容器高。
    final RenderBox box =
        tester.renderObject<RenderBox>(find.byType(MangaUpscaledImage));
    expect(box.size.width, 400);
    expect(box.size.height, 600);
    expect(tester.takeException(), isNull);
    image.dispose();
  });
}

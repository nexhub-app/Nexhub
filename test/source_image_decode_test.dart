/// 阅读器超分集成单测：验证 `SourceImage.onImageDecoded` 这条「解码后接管绘制」
/// 的链路真的把位图交出来，且不破坏 SourceImage 既有的占位/回调语义。
///
/// 这是防止「开关接了但永远走不到」类静默失效的关键测试：用真实临时图片文件
/// 走本地分支（无需网络与磁盘缓存），断言：
/// - onImageDecoded 收到可绘制位图，尺寸符合预期；
/// - onImageInfo 收到自然尺寸；
/// - 文件不存在时静默占位，不误报解码、不抛异常。
///
/// 注意：真实文件解码是**真正异步的 IO**，在 widget 测试的 fake-async 时区里
/// 不会自行完成，必须包在 [WidgetTester.runAsync] 内并给它让出时间。
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nexhub/core/widgets/source_image.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// 生成一张 PNG 字节（[width]×[height]）。
Future<Uint8List> _pngBytes({int width = 64, int height = 32}) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = const Color(0xFF2255AA),
  );
  final ui.Picture picture = recorder.endRecording();
  final ui.Image image = await picture.toImage(width, height);
  final ByteData? data = await image.toByteData(format: ui.ImageByteFormat.png);
  picture.dispose();
  image.dispose();
  return data!.buffer.asUint8List();
}

Widget _host(
  String path, {
  void Function(ui.Image)? onDecoded,
  void Function(double, double)? onInfo,
  VoidCallback? onLoaded,
  int? decodeCapWidthPx,
}) =>
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SourceImage(
            url: path,
            fit: BoxFit.none,
            decodeCapWidthPx: decodeCapWidthPx,
            placeholder: const SizedBox(width: 64, height: 32),
            onImageDecoded: onDecoded,
            onImageInfo: onInfo,
            onLoadComplete: onLoaded,
          ),
        ),
      ),
    );

void main() {
  late Directory tmp;
  late String imagePath;

  setUpAll(() async {
    // SourceImage.buildHeaders 会经 HttpFetcher 读 SharedPreferences（默认 UA /
    // Cookie 版本）。widget 测试无原生插件，必须注入内存实现，否则抛
    // MissingPluginException（与本用例要验证的超分链路无关）。
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmp = await Directory.systemTemp.createTemp('nexhub_upscale_test_');
    imagePath = p.join(tmp.path, 'page.png');
    await File(imagePath).writeAsBytes(await _pngBytes(width: 64, height: 32));
  });

  tearDownAll(() async {
    try {
      await tmp.delete(recursive: true);
    } on Object {
      // 忽略清理失败。
    }
  });

  testWidgets('本地图片解码后回传位图与自然尺寸', (WidgetTester tester) async {
    ui.Image? decoded;
    double? infoW;
    double? infoH;
    int loaded = 0;

    await tester.runAsync(() async {
      await tester.pumpWidget(_host(
        imagePath,
        onDecoded: (ui.Image image) => decoded = image,
        onInfo: (double w, double h) {
          infoW = w;
          infoH = h;
        },
        onLoaded: () => loaded++,
      ));
      // 给真实文件读取 + 解码让出时间，再泵一帧呈现结果。
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
    });

    // 超分接管点：必须真的拿到位图（否则开关形同虚设）。
    expect(decoded, isNotNull, reason: 'onImageDecoded 必须回传已解码位图');
    expect(decoded!.width, 64);
    expect(decoded!.height, 32);

    // 自然尺寸回调仍然工作（条漫占位/夹取依赖它）。
    expect(infoW, 64);
    expect(infoH, 32);
    expect(tester.takeException(), isNull);

    decoded!.dispose();
  });

  testWidgets('文件不存在时静默占位：不回传位图、不抛异常',
      (WidgetTester tester) async {
    ui.Image? decoded;
    await tester.runAsync(() async {
      await tester.pumpWidget(_host(
        p.join(tmp.path, 'missing.png'),
        onDecoded: (ui.Image image) => decoded = image,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pump();
    });

    expect(decoded, isNull, reason: '缺图不得误报解码成功');
    expect(tester.takeException(), isNull);
  });

  testWidgets('解码限幅（decodeCapWidthPx）下仍能回传位图',
      (WidgetTester tester) async {
    ui.Image? decoded;
    await tester.runAsync(() async {
      await tester.pumpWidget(_host(
        imagePath,
        decodeCapWidthPx: 32,
        onDecoded: (ui.Image image) => decoded = image,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
    });

    expect(decoded, isNotNull);
    // 限幅：宽被下采样到 32（高按比例 16），证明回传的是「实际显示用」位图。
    expect(decoded!.width, 32);
    expect(decoded!.height, 16);
    expect(tester.takeException(), isNull);
    decoded!.dispose();
  });
}

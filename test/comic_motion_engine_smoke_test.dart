// 引擎冒烟：真 comic_motion 后台 isolate 渲染管线（小图、小配置），
// 验证 vendored 包路径依赖 + processBytesInBackground 字节进出契约。
// MotionGifView 用同一份产物做挂载冒烟（解码 / 占位 / 无异常）。
import 'dart:typed_data';

import 'package:comic_motion/comic_motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/comic/models/motion_effect_settings.dart';
import 'package:comic_motion_flutter/comic_motion_flutter.dart'
    show MotionGifView;

/// 生成 64×64 的测试 PNG（两段渐变，保证深度分层有内容可切）。
Uint8List _tinyPng() {
  final img = RgbaImage(width: 64, height: 64);
  for (var y = 0; y < 64; y++) {
    for (var x = 0; x < 64; x++) {
      final i = (y * 64 + x) * 4;
      img.data[i] = (x * 4) & 0xff; // R 横向渐变
      img.data[i + 1] = (y * 4) & 0xff; // G 纵向渐变
      img.data[i + 2] = 128;
      img.data[i + 3] = 255;
    }
  }
  return Uint8List.fromList(ImageIO.encodePngFrame(img));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('processBytesInBackground：bytes 进 GIF 出（应用默认配置投影）', () async {
    final png = _tinyPng();
    final config = const MotionEffectSettings(enabled: true)
        .copyWith(fps: 6, durationSec: 2.0, maxDimension: 480)
        .toEffectConfig();
    final result = await processBytesInBackground(
      input: png,
      config: config,
      includeFirstFrame: true,
      timeout: const Duration(seconds: 120),
    );
    expect(result.gifBytes, isNotNull);
    expect(result.gifBytes!.lengthInBytes, greaterThan(0));
    expect(result.firstFramePng, isNotNull);
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('MotionGifView：占位静帧挂载无异常', (tester) async {
    final png = _tinyPng();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MotionGifView(
            gifBytes: png, // 非 GIF 字节也会走「解码失败 → 保持占位」路径
            firstFramePng: png,
            width: 100,
            height: 100,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
  });
}

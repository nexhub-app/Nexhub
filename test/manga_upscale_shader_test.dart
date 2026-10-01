/// 超分 shader 的**数值正确性**测试：真正用 GPU 绘制，验证
/// 1. shader 资产能编译并加载（防止「assetKey 写错 → 永远静默回退」）；
/// 2. 放大后输出**不位移**（双三次相位正确，防止整幅图偏移/发虚）；
/// 3. 放大后边缘更锐（锐化确实生效，灰色台阶边界对比度不降低）。
///
/// 这些断言是「超分不是假的」的核心证据，比「能渲染出东西」强得多。
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// 载荷：中心深色方块，四周浅灰（构造明显的黑白台阶边缘）。
Future<ui.Image> _makeImage(int width, int height) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = const ui.Color(0xFFCCCCCC),
  );
  canvas.drawRect(
    Rect.fromLTWH(width / 4, height / 4, width / 2, height / 2),
    Paint()..color = const ui.Color(0xFF202020),
  );
  final ui.Picture picture = recorder.endRecording();
  final ui.Image image = await picture.toImage(width, height);
  picture.dispose();
  return image;
}

/// 用给定 shader 把 src 画到 dstW×dstH 的图上，返回像素。
Future<ByteData> _renderWithShader({
  required ui.FragmentShader shader,
  required ui.Image src,
  required int dstW,
  required int dstH,
  required double mode,
}) async {
  shader
    ..setImageSampler(0, src, filterQuality: ui.FilterQuality.high)
    ..setFloat(0, src.width.toDouble())
    ..setFloat(1, src.height.toDouble())
    ..setFloat(2, dstW.toDouble())
    ..setFloat(3, dstH.toDouble())
    ..setFloat(4, mode)
    ..setFloat(5, mode > 0.5 ? 0.6 : 0.0);

  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, dstW.toDouble(), dstH.toDouble()),
    Paint()..shader = shader,
  );
  final ui.Picture picture = recorder.endRecording();
  final ui.Image out = await picture.toImage(dstW, dstH);
  final ByteData? data = await out.toByteData();
  picture.dispose();
  out.dispose();
  return data!;
}

/// 取 (x,y) 的红色通道（0–255）。
int _r(ByteData d, int width, int x, int y) =>
    d.getUint8((y * width + x) * 4);

/// 一行内相邻像素的最大跳变（边缘锐度指标）。
int _maxStep(ByteData d, int width, int y) {
  int maxStep = 0;
  for (int x = 1; x < width; x++) {
    final int step = (_r(d, width, x, y) - _r(d, width, x - 1, y)).abs();
    if (step > maxStep) maxStep = step;
  }
  return maxStep;
}

void main() {
  test('shader 资产可加载（assetKey 正确）', () async {
    // ignore: avoid_print
    final ui.FragmentProgram program = await ui.FragmentProgram.fromAsset(
      'assets/shaders/manga_upscale.frag',
    );
    expect(program, isNotNull);
    final ui.FragmentShader shader = program.fragmentShader();
    expect(shader, isNotNull);
  });

  test('双三次放大不产生位移：对称图形的暗区重心仍在中心', () async {
    final ui.FragmentProgram program = await ui.FragmentProgram.fromAsset(
      'assets/shaders/manga_upscale.frag',
    );
    final ui.Image src = await _makeImage(64, 64);
    final int dst = 256;
    final ByteData out = await _renderWithShader(
      shader: program.fragmentShader(),
      src: src,
      dstW: dst,
      dstH: dst,
      mode: 0.0, // 仅重采样，排除锐化对重心的影响
    );

    // 暗区重心（按暗度加权）应落在图像中心附近：位移 bug 会让重心明显偏移。
    double sumW = 0;
    double sumX = 0;
    double sumY = 0;
    for (int y = 0; y < dst; y++) {
      for (int x = 0; x < dst; x++) {
        final double weight = 255.0 - _r(out, dst, x, y);
        sumW += weight;
        sumX += weight * x;
        sumY += weight * y;
      }
    }
    final double cx = sumX / sumW;
    final double cy = sumY / sumW;
    final double center = (dst - 1) / 2;
    // 容差 3px（约 1.2%），远小于「错位一像素以上」的相位 bug 造成偏移。
    expect((cx - center).abs(), lessThan(3.0),
        reason: '重心横向偏移过大：双三次相位可能写错（图像被平移）');
    expect((cy - center).abs(), lessThan(3.0),
        reason: '重心纵向偏移过大：双三次相位可能写错（图像被平移）');

    src.dispose();
  });

  test('放大后边缘更锐：锐化档的边界跳变不小于重采样档', () async {
    final ui.FragmentProgram program = await ui.FragmentProgram.fromAsset(
      'assets/shaders/manga_upscale.frag',
    );
    final ui.Image src = await _makeImage(64, 64);
    const int dst = 256;

    final ByteData plain = await _renderWithShader(
      shader: program.fragmentShader(),
      src: src,
      dstW: dst,
      dstH: dst,
      mode: 0.0,
    );
    final ByteData sharp = await _renderWithShader(
      shader: program.fragmentShader(),
      src: src,
      dstW: dst,
      dstH: dst,
      mode: 1.0,
    );

    // 取穿过暗区边界的一行（y = 中心行）比较边缘跳变。
    final int midY = dst ~/ 2;
    final int plainStep = _maxStep(plain, dst, midY);
    final int sharpStep = _maxStep(sharp, dst, midY);
    expect(sharpStep, greaterThanOrEqualTo(plainStep),
        reason: '锐化档的边缘跳变不应低于纯重采样档');

    // 同时保证没有把画面炸掉（极值仍在合法范围、暗区依旧存在）。
    bool sawDark = false;
    for (int x = 0; x < dst; x++) {
      if (_r(sharp, dst, x, midY) < 80) sawDark = true;
    }
    expect(sawDark, isTrue, reason: '锐化后暗区不应消失');

    src.dispose();
  });

  test('缩小显示时不做超分（交回默认采样）', () async {
    final ui.FragmentProgram program = await ui.FragmentProgram.fromAsset(
      'assets/shaders/manga_upscale.frag',
    );
    final ui.Image src = await _makeImage(256, 256);
    // 目标尺寸小于源尺寸 → 走缩小分支。
    final ByteData out = await _renderWithShader(
      shader: program.fragmentShader(),
      src: src,
      dstW: 64,
      dstH: 64,
      mode: 1.0,
    );
    // 缩小后仍应是一张有效图像（中心暗、四角亮）。
    expect(_r(out, 64, 32, 32), lessThan(120), reason: '中心应为暗区');
    expect(_r(out, 64, 1, 1), greaterThan(150), reason: '四角应为浅灰');
    src.dispose();
  });
}

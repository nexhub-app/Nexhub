/// AI 视觉请求的图片预处理工具（B6：从漫画翻译控制器迁出，静态可单测）。
///
/// 职责：
/// - [decodeSize]：微缩解码（targetWidth=16）拿图片自然尺寸，极廉价；
/// - [resizeToLimit]：超大图长边下采样后重编码 PNG，控制视觉请求体积。
///
/// 解码器（Codec）生命周期全部包进 try/finally 释放——原实现在「原图解码 →
/// 缩略再解码」路径上漏释放缩略 Codec，大图高频翻译存在资源泄漏。
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart' show Size;

/// 图片解码 / 缩放工具。
class AiImageResizer {
  AiImageResizer._();

  /// 解码图片自然像素尺寸；解码失败返回 [Size.zero]。
  ///
  /// 优先解析图片头部（PNG IHDR / JPEG SOFn / GIF / WEBP VP8X-VP8-VP8L）——
  /// 零解码成本且得到**自然尺寸**；若用 `targetWidth:16` 微缩解码，得到的
  /// 是缩略尺寸而非自然尺寸（宽高比虽一致，绝对像素错，BoxFit.none 与
  /// 覆盖层坐标映射会偏）。头部不识别时回退全量解码。
  static Future<Size> decodeSize(Uint8List bytes) async {
    final header = _parseHeaderSize(bytes);
    if (header != null) return header;
    ui.Codec? codec;
    try {
      codec = await ui.instantiateImageCodec(bytes, allowUpscaling: false);
      final ui.FrameInfo frame = await codec.getNextFrame();
      final Size size =
          Size(frame.image.width.toDouble(), frame.image.height.toDouble());
      frame.image.dispose();
      return size;
    } on Object {
      return Size.zero;
    } finally {
      codec?.dispose();
    }
  }

  /// 从文件头解析图片自然宽高；无法识别返回 null。
  static Size? _parseHeaderSize(Uint8List b) {
    if (b.length < 24) return null;
    // PNG：89 50 4E 47，IHDR 宽高在 16/20 偏移（大端 4 字节）。
    if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
      if (b.length < 24) return null;
      final w = (b[16] << 24) | (b[17] << 16) | (b[18] << 8) | b[19];
      final h = (b[20] << 24) | (b[21] << 16) | (b[22] << 8) | b[23];
      return _positive(w, h);
    }
    // JPEG：FF D8 起始，扫描 SOFn 段（C0–CF，排除 C4/C8/CC）。
    if (b[0] == 0xFF && b[1] == 0xD8) {
      var i = 2;
      while (i + 9 < b.length) {
        if (b[i] != 0xFF) {
          i++;
          continue;
        }
        final marker = b[i + 1];
        if (marker >= 0xC0 &&
            marker <= 0xCF &&
            marker != 0xC4 &&
            marker != 0xC8 &&
            marker != 0xCC) {
          final h = (b[i + 5] << 8) | b[i + 6];
          final w = (b[i + 7] << 8) | b[i + 8];
          return _positive(w, h);
        }
        if (marker == 0xD8 || (marker >= 0xD0 && marker <= 0xD7)) {
          i += 2;
          continue;
        }
        final len = (b[i + 2] << 8) | b[i + 3];
        if (len < 2) return null;
        i += 2 + len;
      }
      return null;
    }
    // GIF87a/89a：逻辑屏幕描述符在 6–9（小端 2 字节）。
    if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) {
      final w = b[6] | (b[7] << 8);
      final h = b[8] | (b[9] << 8);
      return _positive(w, h);
    }
    // WEBP：RIFF....WEBP，随后 VP8X / VP8 / VP8L 三种子块。
    if (b.length > 30 &&
        b[0] == 0x52 &&
        b[1] == 0x49 &&
        b[2] == 0x46 &&
        b[3] == 0x46 &&
        b[8] == 0x57 &&
        b[9] == 0x45 &&
        b[10] == 0x42 &&
        b[11] == 0x50) {
      final fourcc = String.fromCharCodes(b.sublist(12, 16));
      if (fourcc == 'VP8X') {
        // 扩展格式：画布宽高各 24 位（值-1）在 24/27 偏移。
        final w = 1 + (b[24] | (b[25] << 8) | (b[26] << 16));
        final h = 1 + (b[27] | (b[28] << 8) | (b[29] << 16));
        return _positive(w, h);
      }
      if (fourcc == 'VP8 ') {
        // 有损：20 起帧头 3 字节 + 同步码 9D 01 2A + 14 位宽高。
        if (b[23] == 0x9D && b[24] == 0x01 && b[25] == 0x2A) {
          final w = (b[26] | (b[27] << 8)) & 0x3FFF;
          final h = (b[28] | (b[29] << 8)) & 0x3FFF;
          return _positive(w, h);
        }
        return null;
      }
      if (fourcc == 'VP8L') {
        // 无损：21 处签名 0x2F，随后 14 位宽-1 / 14 位高-1 打包。
        if (b[21] == 0x2F) {
          final bits =
              b[22] | (b[23] << 8) | (b[24] << 16) | (b[25] << 24);
          final w = (bits & 0x3FFF) + 1;
          final h = ((bits >> 14) & 0x3FFF) + 1;
          return _positive(w, h);
        }
        return null;
      }
    }
    return null;
  }

  static Size? _positive(int w, int h) {
    if (w <= 0 || h <= 0) return null;
    return Size(w.toDouble(), h.toDouble());
  }

  /// 把图片长边压到 [maxSide] 并重编码 PNG；解码/编码失败返回 null
  ///（调用方回退发送原始字节）。
  static Future<Uint8List?> resizeToLimit(
    Uint8List bytes, {
    int maxSide = 1600,
  }) async {
    ui.Codec? codec;
    ui.Image? frameImage;
    ui.Image? smallImage;
    try {
      codec = await ui.instantiateImageCodec(bytes, allowUpscaling: false);
      final ui.FrameInfo frame = await codec.getNextFrame();
      frameImage = frame.image;
      final int w = frameImage.width;
      final int h = frameImage.height;
      final int longSide = w > h ? w : h;
      if (longSide > maxSide) {
        final double ratio = maxSide / longSide;
        // 重新按目标尺寸解码（instantiateImageCodec 自带下采样，质量优于
        // drawImage 缩放）。
        ui.Codec? small;
        try {
          small = await ui.instantiateImageCodec(
            bytes,
            targetWidth: (w * ratio).round(),
            targetHeight: (h * ratio).round(),
            allowUpscaling: false,
          );
          final ui.FrameInfo smallFrame = await small.getNextFrame();
          smallImage = smallFrame.image;
        } finally {
          small?.dispose();
        }
      }
      final ui.Image toEncode = smallImage ?? frameImage;
      final ByteData? data = await toEncode.toByteData(
        format: ui.ImageByteFormat.png,
      );
      return data?.buffer.asUint8List();
    } on Object {
      return null;
    } finally {
      smallImage?.dispose();
      frameImage?.dispose();
      codec?.dispose();
    }
  }
}

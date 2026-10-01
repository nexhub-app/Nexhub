/// 漫画页超分渲染 widget：把已解码的 [ui.Image] 经 FragmentShader 绘制。
///
/// 分工与生命周期：
/// - **下载 / 缓存**由 [SourceImage]（或其等价 provider）负责，命中同一
///   NexImageCacheManager 磁盘缓存与防盗链头；本 widget 只接管「已解码图像 →
///   屏幕」这一段，因此超分开关不产生任何额外网络请求。
/// - **[ui.Image] 的所有权在调用方**（阅读器的加载门 `_UpscaleSourceGate` 持有
///   [ImageInfo] 并负责 dispose）。本 widget 只读绘制，绝不 dispose 传入的图，
///   避免与 Flutter 图片缓存的双重释放。
///
/// 尺寸语义与 [Image] 对齐（fitWidth / fitHeight / contain / cover / none /
/// fill）：cover 用「放大到覆盖尺寸 + ClipRect 裁切」实现，保证 shader 的 uv
/// 映射始终覆盖整张源图。
library;

import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../comic/manga_upscale.dart';

/// 用超分 shader 渲染一页漫画图（[MangaUpscaleMode.off] 时等价 [RawImage]）。
class MangaUpscaledImage extends StatefulWidget {
  const MangaUpscaledImage({
    super.key,
    required this.image,
    required this.mode,
    this.fit = BoxFit.fitWidth,
    this.width,
    this.height,
    this.alignment = Alignment.center,
  });

  /// 已解码的源图（所有权归调用方，本 widget 不释放）。
  final ui.Image image;

  /// 超分档位。
  final MangaUpscaleMode mode;

  final BoxFit fit;

  /// 显式宽度（阅读器传 `double.infinity` 表示「由父约束决定」，此处忽略）。
  final double? width;
  final double? height;
  final Alignment alignment;

  @override
  State<MangaUpscaledImage> createState() => _MangaUpscaledImageState();
}

class _MangaUpscaledImageState extends State<MangaUpscaledImage> {
  ui.FragmentShader? _shader;
  bool _ready = false;
  bool _failed = false;
  bool _warned = false;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void didUpdateWidget(covariant MangaUpscaledImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 关闭超分时释放 shader，重新开启时再按需创建（避免常驻 GPU 资源）。
    if (oldWidget.mode != widget.mode) {
      if (widget.mode.enabled) {
        _prepare();
      } else {
        _release();
      }
    }
  }

  Future<void> _prepare() async {
    if (!widget.mode.enabled || _ready || _failed) return;
    final ui.FragmentShader? shader = await MangaUpscaleShader.createShader();
    if (!mounted) {
      if (shader != null) MangaUpscaleShader.disposeShader(shader);
      return;
    }
    if (shader == null) {
      // 资源缺失 / 平台不支持：静默回退普通渲染（首次记录一次日志）。
      if (!_warned) {
        _warned = true;
        debugPrint('[MangaUpscale] shader 不可用，回退普通渲染');
      }
      _failed = true;
      return;
    }
    setState(() {
      _shader = shader;
      _ready = true;
    });
  }

  void _release() {
    final ui.FragmentShader? s = _shader;
    if (s != null) MangaUpscaleShader.disposeShader(s);
    _shader = null;
    _ready = false;
  }

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  /// 显式宽高（忽略 infinity：阅读器用 infinity 表示「交给约束」）。
  double? get _w => (widget.width != null && widget.width!.isFinite)
      ? widget.width
      : null;
  double? get _h => (widget.height != null && widget.height!.isFinite)
      ? widget.height
      : null;

  /// [Image] 在无约束流布局下的宽度上限（与 Flutter 惯例一致）。
  static const double _kUnboundedMaxWidth = 100000.0;

  @override
  Widget build(BuildContext context) {
    final ui.Image img = widget.image;
    final ui.FragmentShader? shader = _shader;
    final bool use = _ready &&
        shader != null &&
        widget.mode.enabled &&
        MangaUpscaleShader.fitsTextureLimit(img.width, img.height);

    if (!use) {
      // 普通渲染（关闭超分 / 纹理超限 / shader 不可用）。
      return RawImage(
        image: img,
        fit: widget.fit,
        width: _w,
        height: _h,
        alignment: widget.alignment,
        filterQuality: widget.mode.enabled
            ? FilterQuality.high
            : FilterQuality.medium,
      );
    }

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        // 条漫里父级给的宽度有限；无界（极端滚动布局）时取有限上限，
        // 避免 Size.infinity 进入布局与 shader uniform。
        final BoxConstraints safe = c.maxWidth.isFinite
            ? c
            : c.copyWith(maxWidth: _kUnboundedMaxWidth);
        final _UpscaleGeometry geo = _UpscaleGeometry.resolve(
          constraints: safe,
          imageWidth: img.width.toDouble(),
          imageHeight: img.height.toDouble(),
          fit: widget.fit,
          width: _w,
          height: _h,
        );
        final Widget painted = SizedBox(
          width: geo.paintSize.width,
          height: geo.paintSize.height,
          child: CustomPaint(
            size: geo.paintSize,
            painter: _UpscalePainter(
              shader: shader,
              image: img,
              mode: widget.mode,
              dstSize: geo.paintSize,
            ),
          ),
        );
        // 封面裁切：cover 的绘制尺寸大于容器，用 ClipRect + OverflowBox 对齐。
        final Widget sized = geo.clips
            ? ClipRect(
                child: OverflowBox(
                  minWidth: geo.paintSize.width,
                  maxWidth: geo.paintSize.width,
                  minHeight: geo.paintSize.height,
                  maxHeight: geo.paintSize.height,
                  alignment: widget.alignment,
                  child: painted,
                ),
              )
            : painted;
        return Align(
          alignment: widget.alignment,
          child: SizedBox(
            width: geo.boxSize.width,
            height: geo.boxSize.height,
            child: sized,
          ),
        );
      },
    );
  }
}

/// 超分绘制的几何解算（与 [Image] 的 [BoxFit] 语义对齐）。
class _UpscaleGeometry {
  const _UpscaleGeometry({
    required this.boxSize,
    required this.paintSize,
    required this.clips,
  });

  /// 在父约束下占用的布局尺寸。
  final Size boxSize;

  /// 实际绘制（shader 目标）尺寸；cover 时可能大于 [boxSize]。
  final Size paintSize;

  /// 是否需要裁切（cover）。
  final bool clips;

  static _UpscaleGeometry resolve({
    required BoxConstraints constraints,
    required double imageWidth,
    required double imageHeight,
    required BoxFit fit,
    required double? width,
    required double? height,
  }) {
    final double iw = imageWidth <= 0 ? 1 : imageWidth;
    final double ih = imageHeight <= 0 ? 1 : imageHeight;
    final double ar = iw / ih;

    // 显式宽高（至少给一个）：按显式值布局，另一个按比例推导。
    if (width != null || height != null) {
      final double w = width ?? (height! * ar);
      final double h = height ?? (width! / ar);
      final Size s = Size(w, h);
      return _UpscaleGeometry(boxSize: s, paintSize: s, clips: false);
    }

    final bool boundedW = constraints.maxWidth.isFinite;
    final bool boundedH = constraints.maxHeight.isFinite;

    // 无约束：按原图像素 1:1 逻辑像素。
    if (!boundedW && !boundedH) {
      final Size s = Size(iw, ih);
      return _UpscaleGeometry(boxSize: s, paintSize: s, clips: false);
    }
    // 条漫（宽受限、高无界）：宽撑满、高度按比例。
    if (boundedW && !boundedH) {
      final double w = constraints.maxWidth;
      final Size s = Size(w, w / ar);
      return _UpscaleGeometry(boxSize: s, paintSize: s, clips: false);
    }
    // 高受限、宽无界：高度撑满、宽度按比例。
    if (!boundedW && boundedH) {
      final double h = constraints.maxHeight;
      final Size s = Size(h * ar, h);
      return _UpscaleGeometry(boxSize: s, paintSize: s, clips: false);
    }

    final double aw = constraints.maxWidth;
    final double ah = constraints.maxHeight;
    switch (fit) {
      case BoxFit.cover:
        final double scale = (aw / iw) > (ah / ih) ? (aw / iw) : (ah / ih);
        return _UpscaleGeometry(
          boxSize: Size(aw, ah),
          paintSize: Size(iw * scale, ih * scale),
          clips: true,
        );
      case BoxFit.fill:
        return _UpscaleGeometry(
          boxSize: Size(aw, ah),
          paintSize: Size(aw, ah),
          clips: false,
        );
      case BoxFit.none:
        return _UpscaleGeometry(
          boxSize: Size(iw, ih),
          paintSize: Size(iw, ih),
          clips: false,
        );
      case BoxFit.fitHeight:
        final double w = ah * ar;
        final Size s = w <= aw ? Size(w, ah) : Size(aw, aw / ar);
        return _UpscaleGeometry(boxSize: s, paintSize: s, clips: false);
      case BoxFit.fitWidth:
        final double h = aw / ar;
        final Size s = h <= ah ? Size(aw, h) : Size(ah * ar, ah);
        return _UpscaleGeometry(boxSize: s, paintSize: s, clips: false);
      case BoxFit.scaleDown:
      case BoxFit.contain:
        final double byW = aw / ar;
        final Size s;
        if (byW <= ah) {
          s = fit == BoxFit.scaleDown && aw > iw ? Size(iw, ih) : Size(aw, byW);
        } else {
          s = Size(ah * ar, ah);
        }
        return _UpscaleGeometry(boxSize: s, paintSize: s, clips: false);
    }
  }
}

/// 把超分 shader 铺满目标矩形（uniform / sampler 按当前帧尺寸绑定）。
class _UpscalePainter extends CustomPainter {
  _UpscalePainter({
    required this.shader,
    required this.image,
    required this.mode,
    required this.dstSize,
  });

  final ui.FragmentShader shader;
  final ui.Image image;
  final MangaUpscaleMode mode;
  final Size dstSize;

  @override
  void paint(Canvas canvas, Size size) {
    // uniform 顺序必须与 .frag 声明顺序一致：
    // 0/1 = uSrcSize, 2/3 = uDstSize, 4 = uMode, 5 = uSharp。
    shader
      // 采样必须开高质量过滤：双三次与 RCAS 的抽头数学建立在平滑采样上
      // （默认 FilterQuality.none 为最近邻，会退化成块状放大）。
      ..setImageSampler(0, image, filterQuality: FilterQuality.high)
      ..setFloat(0, image.width.toDouble())
      ..setFloat(1, image.height.toDouble())
      ..setFloat(2, dstSize.width)
      ..setFloat(3, dstSize.height)
      ..setFloat(4, mode.shaderMode)
      ..setFloat(
        5,
        mode == MangaUpscaleMode.sharpen ? kMangaUpscaleSharpenAmount : 0.0,
      );
    final Paint paint = Paint()
      ..shader = shader
      ..isAntiAlias = true;
    canvas.drawRect(Offset.zero & size, paint);
  }

  @override
  bool shouldRepaint(covariant _UpscalePainter oldDelegate) =>
      !identical(oldDelegate.shader, shader) ||
      !identical(oldDelegate.image, image) ||
      oldDelegate.mode != mode ||
      oldDelegate.dstSize != dstSize;
}

/// 漫画页翻译覆盖层（漫画翻译功能）。
///
/// 把 [ComicPageTranslationState] 里的千分比坐标区域渲染到图片显示矩形上：
/// - 坐标映射：由视口尺寸 + 图片宽高比 + 阅读器适配模式（fitWidth / fitHeight /
///   original / 裁边 cover）推导「图片实际显示矩形」，再按千分比插值定位每个
///   气泡框——与阅读器的 [MangaPageImage] 显示逻辑保持一致；
/// - 覆盖层整体包在 IgnorePointer 内（由调用方包裹），不遮挡阅读器手势；
/// - 加载中 / 失败态显示小徽标（失败可重试），不出现在覆盖层外的任何位置。
library;

import 'package:flutter/material.dart';

import '../../../core/ai/backfill_layout.dart';
import '../../../core/ai/vision_translation_client.dart' show VisionTextSegment;
import '../../../core/comic/models/reader_preferences.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../generated/app_localizations.dart';
import 'comic_translation_controller.dart';

/// 计算图片在视口内的实际显示矩形（与 MangaPageImage 的 fit 逻辑对齐）。
///
/// [aspect] 为图片宽高比（w/h）；[naturalSize] 仅在 `original`（BoxFit.none）
/// 模式下作为像素尺寸使用。
Rect layoutImageDisplayRect({
  required Size viewport,
  required double aspect,
  required ReaderInitialZoom zoom,
  required bool cropEdge,
  Size naturalSize = Size.zero,
}) {
  if (aspect <= 0 || viewport.isEmpty) return Rect.zero;
  final double vw = viewport.width;
  final double vh = viewport.height;
  double w;
  double h;
  if (cropEdge) {
    // BoxFit.cover：等比放大到完全覆盖视口，居中裁掉溢出——
    // 即「按宽适配」与「按高适配」两种结果中取覆盖视口的那一种。
    final double hByWidth = vw / aspect;
    if (hByWidth >= vh) {
      w = vw;
      h = hByWidth;
    } else {
      w = vh * aspect;
      h = vh;
    }
  } else {
    switch (zoom) {
      case ReaderInitialZoom.fitWidth:
        w = vw;
        h = vw / aspect;
        break;
      case ReaderInitialZoom.fitHeight:
        h = vh;
        w = vh * aspect;
        break;
      case ReaderInitialZoom.original:
        // BoxFit.none：按自然像素尺寸显示（不缩放）；未知尺寸回退按宽适配。
        w = naturalSize.width <= 0 ? vw : naturalSize.width;
        h = naturalSize.height <= 0 ? w / aspect : naturalSize.height;
        break;
    }
  }
  final double left = (vw - w) / 2;
  final double top = (vh - h) / 2;
  return Rect.fromLTWH(left, top, w, h);
}

/// 单页翻译覆盖层。空闲态返回 zero-size 占位，不占布局空间。
class ComicTranslationOverlay extends StatelessWidget {
  final ComicPageTranslationState state;
  final ReaderInitialZoom zoom;
  final bool cropEdge;

  /// 重试回调（错误态徽标点击）。为 null 时错误徽标不可点。
  final VoidCallback? onRetry;

  /// F7 排版回填：true 时以「气泡内回填」渲染（描边文字 + bbox 宽度
  /// 换行 + 字号自适应），false 时为半透明覆盖层模式。
  final bool backfill;

  const ComicTranslationOverlay({
    super.key,
    required this.state,
    required this.zoom,
    this.cropEdge = false,
    this.onRetry,
    this.backfill = false,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final children = <Widget>[];

    switch (state.status) {
      case ComicPageTranslationStatus.idle:
        return const SizedBox.shrink();
      case ComicPageTranslationStatus.loading:
        children.add(_badge(Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(strokeWidth: 1.6),
            ),
            const SizedBox(width: 6),
            Text(l10n.comicTranslateLoading,
                style: const TextStyle(fontSize: 11)),
          ],
        )));
        break;
      case ComicPageTranslationStatus.error:
        children.add(_badge(Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(l10n.comicTranslateFailed,
                style: const TextStyle(fontSize: 11)),
            if (onRetry != null) ...<Widget>[
              const SizedBox(width: 4),
              InkWell(
                onTap: onRetry,
                borderRadius: BorderRadius.circular(10),
                child: const Padding(
                  padding: EdgeInsets.all(3),
                  child: Icon(Icons.refresh, size: 14),
                ),
              ),
            ],
          ],
        )));
        break;
      case ComicPageTranslationStatus.done:
        final data = state.data;
        if (data != null &&
            data.segments.isNotEmpty &&
            state.naturalSize != Size.zero) {
          children.add(_buildSegments(data.segments));
        }
        break;
    }

    return Stack(children: children);
  }

  Widget _buildSegments(List<VisionTextSegment> segments) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final viewport = Size(constraints.maxWidth, constraints.maxHeight);
        final natural = state.naturalSize;
        final aspect = natural.width / natural.height;
        final rect = layoutImageDisplayRect(
          viewport: viewport,
          aspect: aspect,
          zoom: zoom,
          cropEdge: cropEdge,
          naturalSize: natural,
        );
        if (rect.isEmpty) return const SizedBox.shrink();
        return Stack(
          children: <Widget>[
            for (final seg in segments)
              if (seg.hasBbox) _bubble(rect, seg),
          ],
        );
      },
    );
  }

  Widget _bubble(Rect displayRect, VisionTextSegment seg) {
    int clampPct(int v) => v.clamp(0, 1000);
    final double x1 = clampPct(seg.x1 ?? 0) / 1000;
    final double y1 = clampPct(seg.y1 ?? 0) / 1000;
    final double x2 = clampPct(seg.x2 ?? 0) / 1000;
    final double y2 = clampPct(seg.y2 ?? 0) / 1000;
    final Rect box = Rect.fromLTRB(
      displayRect.left + displayRect.width * x1,
      displayRect.top + displayRect.height * y1,
      displayRect.left + displayRect.width * x2,
      displayRect.top + displayRect.height * y2,
    );
    // 过小/异常框直接丢弃（AI 偶发返回噪声框）。
    if (box.width < 12 || box.height < 10) return const SizedBox.shrink();
    final String text = seg.translation.isNotEmpty ? seg.translation : seg.text;
    if (text.isEmpty) return const SizedBox.shrink();
    if (backfill) return _bubbleBackfill(box, text, seg);
    return Positioned(
      left: box.left,
      top: box.top,
      width: box.width,
      height: box.height,
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.82),
          borderRadius: BorderRadius.circular(3),
        ),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            text,
            textAlign: TextAlign.center,
            maxLines: 12,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              height: 1.18,
            ),
          ),
        ),
      ),
    );
  }

  /// F7 气泡内回填渲染：不铺底色，描边文字保证任意气泡底色可读；
  /// 按 bbox 宽度换行、字号自适应（竖排页降级横排居中，产品说明见文档）。
  Widget _bubbleBackfill(Rect box, String text, VisionTextSegment seg) {
    final result = BackfillLayout.layout(
      text: text,
      boxW: box.width - 4,
      boxH: box.height - 4,
    );
    return Positioned(
      left: box.left,
      top: box.top,
      width: box.width,
      height: box.height,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final line in result.lines)
              FittedBox(
                fit: BoxFit.scaleDown,
                child: _StrokeText(line, result.fontSize),
              ),
          ],
        ),
      ),
    );
  }

  /// 底部居中小徽标（加载中 / 失败）。
  Widget _badge(Widget child) {
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.only(bottom: AppTokens.spaceLg),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(14),
          ),
          child: DefaultTextStyle(
            style: const TextStyle(color: Colors.white70, fontSize: 11),
            child: IconTheme.merge(
              data: const IconThemeData(color: Colors.white70, size: 14),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

/// 描边文字：黑描边 + 白字（叠两层），任意气泡底色上均可读。
class _StrokeText extends StatelessWidget {
  final String text;
  final double fontSize;

  const _StrokeText(this.text, this.fontSize);

  @override
  Widget build(BuildContext context) {
    final outline = Text(
      text,
      style: TextStyle(
        fontSize: fontSize,
        height: 1.18,
        foreground: Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = fontSize / 7.5
          ..strokeJoin = StrokeJoin.round
          ..color = const Color(0xF2000000),
      ),
    );
    return Stack(
      alignment: Alignment.center,
      children: <Widget>[
        outline,
        Text(
          text,
          style: TextStyle(
            fontSize: fontSize,
            height: 1.18,
            color: Colors.white,
          ),
        ),
      ],
    );
  }
}

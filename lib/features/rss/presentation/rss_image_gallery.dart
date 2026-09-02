/// RSS 文章内图片全屏查看器（B2 图片查看器：点击放大 + 多图滑动画廊）。
///
/// 用 Flutter 内置 [InteractiveViewer] + [PageView] 实现，零额外依赖
/// （替代 photo_view 包，避免引入新依赖带来的 pubspec.lock 变动风险）。
/// 图片走 [SourceImage]，带上**文章页** Referer，防盗链站点也能正常加载。
library;

import 'package:flutter/material.dart';

import '../../../core/widgets/source_image.dart';

/// 全屏图片画廊：左右滑动切换文章内所有图片，双指缩放/拖拽平移。
class RssImageGallery extends StatefulWidget {
  final List<String> images;
  final int initialIndex;
  /// 文章页地址，作为图片请求的 Referer（防盗链校验用）。
  final String? pageUrl;

  const RssImageGallery({
    super.key,
    required this.images,
    this.initialIndex = 0,
    this.pageUrl,
  });

  @override
  State<RssImageGallery> createState() => _RssImageGalleryState();
}

class _RssImageGalleryState extends State<RssImageGallery> {
  late final PageController _pageController;
  late int _current;

  @override
  void initState() {
    super.initState();
    _current = widget.initialIndex.clamp(0, widget.images.length - 1);
    _pageController = PageController(initialPage: _current);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black.withValues(alpha: 0.55),
        foregroundColor: Colors.white,
        title: Text('${_current + 1} / ${widget.images.length}'),
        elevation: 0,
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      body: PageView.builder(
        controller: _pageController,
        itemCount: widget.images.length,
        onPageChanged: (int i) => setState(() => _current = i),
        itemBuilder: (BuildContext context, int i) {
          return InteractiveViewer(
            minScale: 0.5,
            maxScale: 4.0,
            child: Center(
              child: SourceImage(
                url: widget.images[i],
                fit: BoxFit.contain,
                refererOverride: widget.pageUrl,
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 设置页 Hero 轮播 —— 可左右滑动的背景图。
///
/// 支持网络 URL 与本地文件路径；空列表时显示优雅渐变占位；
/// 单张图片时不渲染指示点。多张时自动启用 `PageView` 横向分页。
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../../../../core/theme/app_tokens.dart';
import '../../../../core/widgets/app_animations.dart';

/// 设置页 Hero 轮播。
///
/// [imageUrls] 为空时显示渐变占位；为单张时不渲染指示点；
/// 多张时启用 [PageView] 横向滑动 + 圆点指示。
class HeroCarousel extends StatefulWidget {
  final List<String> imageUrls;
  final double height;
  final BorderRadius borderRadius;
  final bool autoPlay;
  final Duration autoPlayInterval;

  const HeroCarousel({
    super.key,
    required this.imageUrls,
    this.height = 200,
    this.borderRadius = const BorderRadius.all(
      Radius.circular(AppTokens.radiusLg),
    ),
    this.autoPlay = false,
    this.autoPlayInterval = const Duration(seconds: 5),
  });

  @override
  State<HeroCarousel> createState() => _HeroCarouselState();
}

class _HeroCarouselState extends State<HeroCarousel> {
  late final PageController _pageController;
  int _currentPage = 0;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _onPageChanged(int page) {
    setState(() => _currentPage = page);
  }

  bool _isLocalPath(String url) {
    return url.startsWith('/') ||
        (Platform.isWindows && url.contains(':\\')) ||
        url.startsWith('file://');
  }

  ImageProvider _imageProvider(String url) {
    if (_isLocalPath(url)) {
      final String path =
          url.startsWith('file://') ? url.substring(7) : url;
      return FileImage(File(path));
    }
    return NetworkImage(url);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final urls = widget.imageUrls;

    // 空占位：渐变 + 几何装饰
    if (urls.isEmpty) {
      return _HeroFrame(
        height: widget.height,
        borderRadius: widget.borderRadius,
        child: ClipRRect(
          borderRadius: widget.borderRadius,
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[
                  scheme.primaryContainer,
                  scheme.tertiaryContainer,
                ],
              ),
            ),
            child: Center(
              child: Icon(
                Icons.image_outlined,
                size: 48,
                color: scheme.onPrimaryContainer.withValues(alpha: 0.4),
              ),
            ),
          ),
        ),
      );
    }

    // 单张：直接显示
    if (urls.length == 1) {
      return _HeroFrame(
        height: widget.height,
        borderRadius: widget.borderRadius,
        child: ClipRRect(
          borderRadius: widget.borderRadius,
          child: Image(
            image: _imageProvider(urls.first),
            fit: BoxFit.cover,
            width: double.infinity,
            errorBuilder: (_, __, ___) =>
                _ErrorPlaceholder(scheme: scheme),
          ),
        ),
      );
    }

    // 多张：PageView + 指示点
    return _HeroFrame(
      height: widget.height,
      borderRadius: widget.borderRadius,
      child: ClipRRect(
        borderRadius: widget.borderRadius,
        child: Stack(
          children: <Widget>[
            PageView.builder(
              controller: _pageController,
              onPageChanged: _onPageChanged,
              itemCount: urls.length,
              itemBuilder: (BuildContext context, int index) {
                return Image(
                  image: _imageProvider(urls[index]),
                  fit: BoxFit.cover,
                  width: double.infinity,
                  errorBuilder: (_, __, ___) =>
                      _ErrorPlaceholder(scheme: scheme),
                );
              },
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: AppTokens.spaceSm,
              child: Center(
                child: _PageIndicator(
                  count: urls.length,
                  current: _currentPage,
                  scheme: scheme,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeroFrame extends StatelessWidget {
  final double height;
  final BorderRadius borderRadius;
  final Widget child;

  const _HeroFrame({
    required this.height,
    required this.borderRadius,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: Entrance(
        index: 0,
        onceKey: 'hero_carousel',
        offset: 6,
        fromScale: 0.99,
        duration: AppTokens.durBase,
        child: child,
      ),
    );
  }
}

class _PageIndicator extends StatelessWidget {
  final int count;
  final int current;
  final ColorScheme scheme;

  const _PageIndicator({
    required this.count,
    required this.current,
    required this.scheme,
  });

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTokens.spaceSm,
        vertical: AppTokens.spaceXxs,
      ),
      decoration: BoxDecoration(
        color: scheme.shadow.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(AppTokens.radiusFull),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (int i = 0; i < count; i++) ...<Widget>[
            if (i > 0) const SizedBox(width: AppTokens.spaceXs),
            AnimatedContainer(
              duration: AppTokens.durBase,
              curve: AppCurves.smooth,
              width: i == current ? 16 : 6,
              height: 6,
              decoration: BoxDecoration(
                color: i == current
                    ? Colors.white
                    : Colors.white.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(AppTokens.radiusFull),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ErrorPlaceholder extends StatelessWidget {
  final ColorScheme scheme;
  const _ErrorPlaceholder({required this.scheme});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: scheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.broken_image_outlined,
          size: 40,
          color: scheme.onSurfaceVariant.withValues(alpha: 0.4),
        ),
      ),
    );
  }
}
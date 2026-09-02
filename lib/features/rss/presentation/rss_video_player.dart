/// RSS 文章内视频播放器（B4 视频播放：enclosure 视频 + iframe 嵌入视频）。
///
/// 用 [InAppWebView] 加载视频地址：直链（.mp4 等）浏览器原生可播；
/// 嵌入视频（YouTube / B 站等 iframe 的 src）加载该地址即可播放。
/// 应用内播放，不再只能「甩给系统外部播放器」。
library;

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// 全屏视频播放页：用 InAppWebView 内嵌加载视频地址。
class RssVideoPlayer extends StatelessWidget {
  final String url;
  final String? title;

  const RssVideoPlayer({super.key, required this.url, this.title});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title ?? 'Video'),
      ),
      body: InAppWebView(
        initialUrlRequest: URLRequest(url: WebUri(url)),
      ),
    );
  }
}

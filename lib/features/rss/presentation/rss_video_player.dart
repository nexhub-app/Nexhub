/// RSS 文章内视频播放器（B4 视频播放：enclosure 直链视频）。
///
/// 仅处理**直链媒体**（.mp4/.webm/.m3u8 等可独立解码的地址），用 media_kit
/// 原生内核播放，与播客播放器同路（代理注入 + Referer/UA + 超时判失败兜底）。
///
/// 嵌入页视频（YouTube / B 站等 iframe 的页面地址）**不再由本页内嵌
/// InAppWebView 加载**——桌面端（尤其 Windows WebView2 实现尚不成熟）内嵌
/// WebView 极易白屏，表现为「视频完全播不了」。这类地址由调用方
/// （browse_article_detail_screen._openVideo）改路由到应用内置浏览器
/// [HttpBrowserScreen]：它带外部回退，且和应用其它浏览功能同一套链路。
///
/// mpv 属性注入注意：`Player` 刚创建即 `await setProperty` 在部分平台存在
/// 等待内核就绪的时序风险（此前直链视频 0 进度失败的疑点之一），故代理 /
/// 网络属性一律 fire-and-forget，`Player.open` 立即执行。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/media/media_kit_network.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/utils/app_haptics.dart';
import '../../../core/utils/app_log.dart';
import '../../browser/presentation/http_browser_screen.dart';

/// 判断视频地址是否为可原生解码的直链媒体（按路径后缀，忽略 query）。
/// 非直链（嵌入页）由调用方路由到内置浏览器。
bool isDirectMediaUrl(String url) {
  final Uri? u = Uri.tryParse(url);
  final String path = (u?.path ?? url).toLowerCase();
  return const <String>[
    '.mp4',
    '.webm',
    '.mkv',
    '.mov',
    '.avi',
    '.flv',
    '.ts',
    '.m4v',
    '.m3u8',
    '.mpd',
    '.ogg',
    '.ogv',
  ].any(path.endsWith);
}

/// 全屏直链视频播放页（media_kit 原生）。
class RssVideoPlayer extends StatefulWidget {
  final String url;
  final String? title;

  /// 视频所在页面地址（防盗链 Referer 用）。
  final String? pageUrl;

  const RssVideoPlayer({
    super.key,
    required this.url,
    this.title,
    this.pageUrl,
  });

  @override
  State<RssVideoPlayer> createState() => _RssVideoPlayerState();
}

class _RssVideoPlayerState extends State<RssVideoPlayer> {
  /// 与播客播放器同款兜底：部分失败（防盗链/302/冷门编码）不抛 error，
  /// 只表现为永远停在 0 进度，须按超时判失败。
  static const Duration _loadTimeout = Duration(seconds: 20);

  late final Player _player;
  late final VideoController _controller;
  bool _failed = false;
  Timer? _loadTimer;
  StreamSubscription<String>? _errorSub;
  StreamSubscription<Duration>? _durSub;

  @override
  void initState() {
    super.initState();
    MediaKit.ensureInitialized();
    _player = Player();
    _controller = VideoController(_player);
    _durSub = _player.stream.duration.listen((Duration d) {
      if (!mounted) return;
      if (d > Duration.zero) {
        _loadTimer?.cancel();
        _loadTimer = null;
        if (_failed) setState(() => _failed = false);
      }
    });
    _errorSub = _player.stream.error.listen((String message) {
      AppLog.instance.w('RSS 视频内核报错: ${widget.url} — $message');
      if (!mounted) return;
      _loadTimer?.cancel();
      _loadTimer = null;
      setState(() => _failed = true);
    });
    unawaited(_open());
  }

  Future<void> _open() async {
    if (mounted) setState(() => _failed = false);
    // fire-and-forget：Player 刚创建时 await setProperty 有内核未就绪的
    // 时序风险，绝不能阻塞 open（否则表现为永远 0 进度 → 超时判失败）。
    unawaited(applyAppProxyToPlayer(_player));
    unawaited(_setNetworkTimeout());
    _player.open(
      Media(
        widget.url,
        httpHeaders: buildMediaHeaders(
          pageUrl: widget.pageUrl,
          mediaUrl: widget.url,
        ),
      ),
      play: true,
    );
    _loadTimer?.cancel();
    _loadTimer = Timer(_loadTimeout, () {
      if (!mounted) return;
      if (_player.state.duration > Duration.zero || _player.state.playing) {
        return;
      }
      AppLog.instance.w('RSS 视频加载超时(20s 无时长未起播): ${widget.url}');
      setState(() => _failed = true);
    });
  }

  /// 松散网络下放宽 mpv 网络超时（与影视播放器 MediaKitBackend 同值）。
  Future<void> _setNetworkTimeout() async {
    final Object? platform = _player.platform;
    if (platform is! NativePlayer) return;
    try {
      await platform.setProperty('network-timeout', '60');
    } on Object {
      // 注入失败不阻塞播放。
    }
  }

  @override
  void dispose() {
    _loadTimer?.cancel();
    _errorSub?.cancel();
    _durSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title ?? 'Video'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.share_outlined),
            tooltip: l10n.share,
            onPressed: () => unawaited(
              Share.share('${widget.title ?? ''}\n${widget.url}'),
            ),
          ),
        ],
      ),
      body: ColoredBox(
        color: Colors.black,
        child: Stack(
          alignment: Alignment.center,
          children: <Widget>[
            Video(controller: _controller),
            if (_failed) _buildFailure(context, l10n),
          ],
        ),
      ),
    );
  }

  Widget _buildFailure(BuildContext context, AppLocalizations l10n) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.all(AppTokens.spaceLg),
      padding: const EdgeInsets.all(AppTokens.spaceMd),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.error_outline, size: 18, color: scheme.error),
              const SizedBox(width: AppTokens.spaceXs),
              Text(l10n.rssVideoFailed,
                  style: Theme.of(context).textTheme.bodyMedium),
            ],
          ),
          const SizedBox(height: AppTokens.spaceSm),
          // 三条出路：重试（内核路径）、内置浏览器（误判/页面型地址）、
          // 外部打开（编码/DRM 等内核不支持的场景）。
          Wrap(
            spacing: AppTokens.spaceXs,
            runSpacing: AppTokens.spaceXs,
            alignment: WrapAlignment.center,
            children: <Widget>[
              TextButton.icon(
                onPressed: () {
                  AppHaptics.light();
                  unawaited(_open());
                },
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(l10n.retry),
              ),
              TextButton.icon(
                onPressed: () => unawaited(_openInAppBrowser(context)),
                icon: const Icon(Icons.language_outlined, size: 18),
                label: Text(l10n.rssOpenInBrowser),
              ),
              TextButton.icon(
                onPressed: () => unawaited(_openExternally(context)),
                icon: const Icon(Icons.open_in_new_outlined, size: 18),
                label: Text(l10n.rssOpenExternally),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _openInAppBrowser(BuildContext context) async {
    if (!context.mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => HttpBrowserScreen(initialUrl: widget.url),
      ),
    );
  }

  Future<void> _openExternally(BuildContext context) async {
    final Uri? uri = Uri.tryParse(widget.url);
    if (uri == null) return;
    final AppLocalizations l10n = AppLocalizations.of(context);
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on Object {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.loadFailed)),
        );
      }
    }
  }
}

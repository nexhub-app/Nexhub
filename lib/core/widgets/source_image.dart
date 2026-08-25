import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';

import '../models/plugin_config.dart';
import '../theme/app_tokens.dart';
import '../scraper/http_fetcher.dart';
import '../local/local_content_manager.dart' show isAndroidSafUri;
import '../local/saf_bridge.dart' show resolveSafUri;

/// 统一源图片 widget：按源配置注入防盗链 headers，带缓存、失败重试、圆角、Hero。
///
/// 替代裸 `Image.network`：漫画源 / 影视源封面常因防盗链返回 403，必须携带
/// `Referer` / `User-Agent` / `Cookie` 等头才能正常加载（见 PluginConfig.antiHotlinking
/// 与 PluginConfig.site）。本地文件路径走 [Image.file]。
class SourceImage extends StatelessWidget {
  final String? url;
  final PluginConfig? source;
  final double? width;
  final double? height;
  final BoxFit fit;
  final String? heroTag;
  final double? radius;
  final Widget? placeholder;
  final bool enableRetry;

  /// 图片成功解码后回调（一次）。条漫阅读器借此在图片加载完成后移除占位高度，
  /// 避免 ConstrainedBox(minHeight) 在真实图高偏小时残留空白带（割裂感）。
  final VoidCallback? onLoadComplete;

  /// 图片自然尺寸回调（一次）：解码完成后回传原始像素宽高。
  /// 条漫阅读器借此缓存「真实图片高度」，未加载项也能用真实高度估算占位
  /// （L3 体验项：占位高 / 纵向平移夹取均基于真实高度，经验值仅兜底）。
  final void Function(double width, double height)? onImageInfo;

  const SourceImage({
    super.key,
    required this.url,
    this.source,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.heroTag,
    this.radius,
    this.placeholder,
    this.enableRetry = true,
    this.onLoadComplete,
    this.onImageInfo,
  });

  bool get _isHttp =>
      url != null &&
      (url!.startsWith('http://') || url!.startsWith('https://'));

  /// 合并防盗链 headers：antiHotlinking.headers 起手 → site.headers →
  /// Referer / User-Agent / Cookie 字段（后者优先覆盖同名键）。
  Map<String, String>? _buildHeaders() {
    final ah = source?.antiHotlinking;
    final site = source?.site;
    final ahHeaders = ah?.headers;
    final siteHeaders = site?.headers;
    final referer = ah?.referer;
    // UA 兜底：部分 CDN（如 baozimh 家族 6wm.top）无 UA 直接 403，而部分源
    // 的 site.userAgent 未配置。此时回退到 HttpFetcher 的浏览器 UA，保证
    // 图片请求与页面/API 请求的指纹一致（不写死任何站点）。
    final String? siteUa = site?.userAgent;
    final ua = (siteUa != null && siteUa.isNotEmpty)
        ? siteUa
        : HttpFetcher.instance.userAgentForUrl(url ?? '');
    final cookies = site?.cookies;
    final hasFields = (siteHeaders != null && siteHeaders.isNotEmpty) ||
        (ahHeaders != null && ahHeaders.isNotEmpty) ||
        (referer != null && referer.isNotEmpty) ||
        (ua != null && ua.isNotEmpty) ||
        (cookies != null && cookies.isNotEmpty);
    if (!hasFields) return null;
    final Map<String, String> m = <String, String>{};
    if (ahHeaders != null) m.addAll(ahHeaders);
    if (siteHeaders != null) m.addAll(siteHeaders);
    if (referer != null && referer.isNotEmpty) {
      m['Referer'] = referer;
    }
    if (ua != null && ua.isNotEmpty) {
      m['User-Agent'] = ua;
    }
    if (cookies != null && cookies.isNotEmpty) {
      m['Cookie'] = cookies;
    }
    // 注入验证回灌的会话 Cookie：_guard 等反爬系统对图片同样校验会话，
    // 缺 Cookie 时封面图请求会被拦（403/空）导致「没有封面」。HttpFetcher
    // 在 WebView 过验证后已写入共享 jar，此处按域名取出回带。
    final synced = HttpFetcher.instance.cookieHeaderForUrl(url);
    if (synced != null && synced.isNotEmpty) {
      final existing = m['Cookie'];
      m['Cookie'] = (existing != null && existing.isNotEmpty)
          ? '$existing; $synced'
          : synced;
    }
    // 默认补同源 Referer：大量站（含幻梦ACG）防盗链要求，缺失即 403。
    if (!m.containsKey('Referer')) {
      final String? rawUrl = url;
      if (rawUrl != null) {
        try {
          m['Referer'] = Uri.parse(rawUrl).origin;
        } catch (_) {
          // 非法 URL 忽略 Referer。
        }
      }
    }
    return m;
  }

  Widget _defaultPlaceholder(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      width: width,
      height: height,
      color: scheme.surfaceContainerHighest,
      child: Icon(
        Icons.image_outlined,
        color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final String? u = url;
    final double? r = radius;
    // 监听 Cookie 版本流：验证回灌 Cookie 后立刻用含版本的新 cacheKey 重取
    // 之前因缺 Cookie 而加载失败的封面（满足「回灌后自动刷新封面」）。
    final Widget clipped = StreamBuilder<int>(
      stream: HttpFetcher.instance.cookieVersionStream,
      initialData: HttpFetcher.instance.cookieVersion,
      builder: (ctx, snap) {
        final int version = snap.data ?? HttpFetcher.instance.cookieVersion;
        final Widget core;
        if (u == null || u.isEmpty) {
          core = placeholder ?? _defaultPlaceholder(context);
        } else if (_isHttp) {
          core = _RetryableNetworkImage(
            url: u,
            headers: _buildHeaders(),
            cookieVersion: version,
            width: width,
            height: height,
            fit: fit,
            placeholder: placeholder ?? _defaultPlaceholder(context),
            enableRetry: enableRetry,
            onLoadComplete: onLoadComplete,
            onImageInfo: onImageInfo,
          );
        } else {
          core = _SafOrLocalImage(
            uriOrPath: u,
            width: width,
            height: height,
            fit: fit,
            placeholder: placeholder ?? _defaultPlaceholder(context),
            onLoadComplete: onLoadComplete,
            onImageInfo: onImageInfo,
          );
        }
        return r == null
            ? core
            : ClipRRect(borderRadius: BorderRadius.circular(r), child: core);
      },
    );
    return heroTag == null ? clipped : Hero(tag: heroTag!, child: clipped);
  }
}

/// 带指数退避重试的网络图片（最多 3 次：1s / 2s / 4s）。
class _RetryableNetworkImage extends StatefulWidget {
  final String url;
  final Map<String, String>? headers;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Widget placeholder;
  final bool enableRetry;
  final int cookieVersion;
  final VoidCallback? onLoadComplete;
  final void Function(double width, double height)? onImageInfo;

  const _RetryableNetworkImage({
    required this.url,
    this.headers,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    required this.placeholder,
    this.enableRetry = true,
    this.cookieVersion = 0,
    this.onLoadComplete,
    this.onImageInfo,
  });

  @override
  State<_RetryableNetworkImage> createState() => _RetryableNetworkImageState();
}

class _RetryableNetworkImageState extends State<_RetryableNetworkImage> {
  static const int _maxRetries = 3;
  static const List<Duration> _backoff = <Duration>[
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
  ];

  int _retryKey = 0;
  int _retryCount = 0;
  bool _retrying = false;
  Timer? _timer;
  bool _notified = false;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _retry() {
    if (!widget.enableRetry || _retrying || _retryCount >= _maxRetries) return;
    setState(() => _retrying = true);
    _timer = Timer(_backoff[_retryCount], () {
      if (!mounted) return;
      setState(() {
        _retrying = false;
        _retryCount += 1;
        _retryKey += 1;
      });
    });
  }

  // 图片成功解码后通知一次（帧后触发，避免在 build 期 setState）。
  void _notifyLoaded() {
    if (_notified) return;
    _notified = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.onLoadComplete?.call());
  }

  @override
  Widget build(BuildContext context) {
    return CachedNetworkImage(
      key: ValueKey<String>('${widget.url}-$_retryKey-${widget.cookieVersion}'),
      imageUrl: widget.url,
      httpHeaders: widget.headers,
      cacheKey: '${widget.url}#v${widget.cookieVersion}',
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      placeholder: (c, u) => widget.placeholder,
      errorWidget: (c, u, e) {
        _notifyLoaded();
        return _buildError(context);
      },
      imageBuilder: (ctx, provider) {
        _notifyLoaded();
        // 回传自然尺寸（缓存命中，无重复下载）：供条漫占位/夹取基于真实高度估算。
        final ImageStream stream = provider.resolve(const ImageConfiguration());
        ImageStreamListener? listener;
        listener = ImageStreamListener(
          (ImageInfo info, bool _) {
            widget.onImageInfo
                ?.call(info.image.width.toDouble(), info.image.height.toDouble());
            stream.removeListener(listener!);
          },
          onError: (Object error, StackTrace? stackTrace) =>
              stream.removeListener(listener!),
        );
        stream.addListener(listener!);
        return Image(
          image: provider,
          width: widget.width,
          height: widget.height,
          fit: widget.fit,
        );
      },
    );
  }

  Widget _buildError(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final AppLocalizations l10n = AppLocalizations.of(context);
    final bool exhausted = _retryCount >= _maxRetries;
    return Semantics(
      label: l10n.imageLoadFailed,
      child: Container(
        width: widget.width,
        height: widget.height,
        color: scheme.surfaceContainerHighest,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.broken_image, color: scheme.onSurfaceVariant),
            if (widget.enableRetry) ...<Widget>[
              const SizedBox(height: AppTokens.spaceXs),
              if (_retrying)
                SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: scheme.primary,
                  ),
                )
              else if (!exhausted)
                TextButton.icon(
                  onPressed: _retry,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: Text(l10n.retry),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 本地文件图片：补齐与网络图一致的「解码完成通知（onLoadComplete）」。
///
/// 原因：条漫阅读器对未加载 item 预留 `ConstrainedBox(minHeight: 屏宽×1.5)` 占位，
/// 必须在图片真正解码后移除该约束（令 showRealHeight=true），否则真实图高偏小时
/// 图片下方残留空白带（图片之间的缝隙）。网络图走 [_RetryableNetworkImage] 在
/// imageBuilder 内已通知；本地图此前走裸 `Image.file` 漏掉了通知，导致本地条漫
/// 永久保留占位 → 出现缝隙。此处用 loadingBuilder 在加载完成时（loadingProgress
/// 变 null）触发一次通知，与网络图行为对齐。
class _LocalFileImage extends StatefulWidget {
  final File file;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Widget placeholder;
  final VoidCallback? onLoadComplete;
  final void Function(double width, double height)? onImageInfo;

  const _LocalFileImage({
    required this.file,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    required this.placeholder,
    this.onLoadComplete,
    this.onImageInfo,
  });

  @override
  State<_LocalFileImage> createState() => _LocalFileImageState();
}

class _LocalFileImageState extends State<_LocalFileImage> {
  bool _notified = false;

  void _notifyLoaded() {
    if (_notified) return;
    _notified = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.onLoadComplete?.call());
  }

  @override
  Widget build(BuildContext context) {
    // 回传自然尺寸（文件已在本机，解码开销极小）：供条漫占位/夹取基于真实高度估算。
    final ImageStream stream = FileImage(widget.file).resolve(
      const ImageConfiguration(),
    );
    ImageStreamListener? listener;
    listener = ImageStreamListener(
      (ImageInfo info, bool _) {
        widget.onImageInfo
            ?.call(info.image.width.toDouble(), info.image.height.toDouble());
        stream.removeListener(listener!);
      },
      onError: (Object error, StackTrace? stackTrace) =>
          stream.removeListener(listener!),
    );
    stream.addListener(listener!);
    return Image.file(
      widget.file,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      errorBuilder: (c, e, s) => widget.placeholder,
      frameBuilder: (c, child, frame, wasSynchronouslyLoaded) {
        if (frame != null || wasSynchronouslyLoaded) {
          _notifyLoaded();
          return child;
        }
        return widget.placeholder;
      },
    );
  }
}

/// 本地/SAF 图片：先把 URI 解析为可读的本地文件路径，再交给 [_LocalFileImage]。
///
/// 为什么需要它：本地图片有两种来源——
/// - 真实文件路径（桌面 / 非 SAF）：[Image.file] 直接可读；
/// - Android SAF content://（或下载编码 `<treeUri>␟<rel>`）：[Image.file] 读不了，
///   必须先经 [resolveSafUri] 落到应用私有缓存。
///
/// 此前 [gatherSafImages] 在「打开漫画」时把整本图片逐张拷贝到缓存，图片多则卡
/// 1~2s。改为**此处逐张懒解析**：只有真正要显示的图片（阅读器当前可见的几张）才
/// 触发拷贝，进入阅读器即刻可见，整本图片数不再影响打开速度。非 SAF 路径直接透传。
class _SafOrLocalImage extends StatefulWidget {
  final String uriOrPath;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Widget placeholder;
  final VoidCallback? onLoadComplete;
  final void Function(double width, double height)? onImageInfo;

  const _SafOrLocalImage({
    required this.uriOrPath,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    required this.placeholder,
    this.onLoadComplete,
    this.onImageInfo,
  });

  @override
  State<_SafOrLocalImage> createState() => _SafOrLocalImageState();
}

class _SafOrLocalImageState extends State<_SafOrLocalImage> {
  String? _resolved;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    // 非 SAF 路径（真实文件路径）直接可用，无需异步拷贝。
    if (!isAndroidSafUri(widget.uriOrPath)) {
      if (mounted) setState(() => _resolved = widget.uriOrPath);
      return;
    }
    try {
      final String r = await resolveSafUri(widget.uriOrPath);
      if (mounted) setState(() => _resolved = r);
    } on Object catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) return widget.placeholder;
    if (_resolved == null) return widget.placeholder;
    return _LocalFileImage(
      file: File(_resolved!),
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      placeholder: widget.placeholder,
      onLoadComplete: widget.onLoadComplete,
      onImageInfo: widget.onImageInfo,
    );
  }
}

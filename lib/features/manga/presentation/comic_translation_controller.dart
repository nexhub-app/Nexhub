/// 漫画页翻译控制器（漫画翻译功能的大脑）。
///
/// 职责：
/// - 持有「翻译开关」与逐页翻译状态（按图片 URL 索引），翻页时由阅读器
///   调用 [ensureTranslated] 触发当前页翻译；
/// - 图片获取：本地路径直接读文件；网络 URL 走 [DefaultCacheManager]
///   （命中磁盘缓存零流量，未命中带防盗链 headers 下载）；
/// - 图片预处理：超过上限时经 dart:ui 解码下采样再编码，控制请求体积；
/// - 调用 [VisionTranslationClient]（视觉模型一次完成 OCR + 翻译），
///   结果经 [ComicTranslationManager] 持久化（`comicId|章|页|语言` 键）。
///
/// 状态以 [Listenable]（ChangeNotifier）暴露，[MangaPageImage] 内嵌的
/// 覆盖层监听后按千分比坐标把译文渲染到原图对应位置上。
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Size;
// flutter_cache_manager 是 cached_network_image 的传递依赖，此处直接使用
// 其 DefaultCacheManager 复用阅读器同款图片磁盘缓存（同 URL 不重复下载）。
// ignore: depend_on_referenced_packages
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../../../core/ai/vision_translation_client.dart';
import '../../../core/comic/comic_translation_manager.dart';
import '../../../core/models/plugin_config.dart';
import '../../../core/scraper/http_fetcher.dart';
import '../../novel/domain/novel_summary_service.dart';
import '../../novel/domain/novel_summary_settings.dart';

/// 单页翻译状态。
enum ComicPageTranslationStatus { idle, loading, done, error }

class ComicPageTranslationState {
  final ComicPageTranslationStatus status;
  final ComicPageTranslation? data;

  /// 图片自然尺寸（像素）：OCR 解码 / 缓存命中后的微缩解码获得，
  /// 覆盖层据此把千分比坐标映射到实际显示矩形。
  final Size naturalSize;
  final String? error;

  const ComicPageTranslationState({
    this.status = ComicPageTranslationStatus.idle,
    this.data,
    this.naturalSize = Size.zero,
    this.error,
  });

  ComicPageTranslationState copyWith({
    ComicPageTranslationStatus? status,
    ComicPageTranslation? data,
    Size? naturalSize,
    String? error,
  }) =>
      ComicPageTranslationState(
        status: status ?? this.status,
        data: data ?? this.data,
        naturalSize: naturalSize ?? this.naturalSize,
        error: error,
      );
}

class ComicTranslationController extends ChangeNotifier {
  ComicTranslationController({
    required this.comicId,
    PluginConfig? source,
    ComicTranslationManager? manager,
    VisionTranslationClient? client,
  })  : _source = source,
        _manager = manager ?? ComicTranslationManager(),
        _client = client ?? VisionTranslationClient();

  /// 请求图片长边上限（像素）：视觉模型对超大图会截断细节，
  /// 长边压到 1600 在识别精度与请求体积（token / 流量）间取得平衡。
  static const int _kMaxSide = 1600;

  /// 原始字节直接发送的上限：超过才走解码下采样（绝大多数漫画页 < 4MB）。
  static const int _kDirectSendLimitBytes = 6 * 1024 * 1024;

  final String comicId;
  final ComicTranslationManager _manager;
  final VisionTranslationClient _client;

  /// 网络图下载防盗链 headers 所需的源配置（阅读器异步加载源后补传）。
  PluginConfig? get source => _source;
  PluginConfig? _source;

  /// 阅读器加载到源配置后更新（initState 时源尚未就绪）。
  void updateSource(PluginConfig? s) => _source = s;

  bool _enabled = false;
  bool _langLoaded = false;
  String _targetLang = 'zh';

  /// 按图片 URL 索引的翻译状态（覆盖层据此渲染）。
  final Map<String, ComicPageTranslationState> _states =
      <String, ComicPageTranslationState>{};

  /// 进行中的请求（防同页重复触发）。
  final Set<String> _inFlight = <String>{};

  bool get enabled => _enabled;

  ComicPageTranslationState stateFor(String url) =>
      _states[url] ?? const ComicPageTranslationState();

  /// 开关翻译。开启时读取目标语言配置（一次），由阅读器随后对当前页
  /// 调用 [ensureTranslated]。
  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    if (value && !_langLoaded) {
      _targetLang = await NovelSummarySettings.instance
          .getComicTranslationTargetLanguage();
      _langLoaded = true;
    }
    notifyListeners();
  }

  /// 确保某页已翻译：缓存命中直接回填状态；否则发起 OCR+翻译。
  Future<void> ensureTranslated(
    String url, {
    required String chapterKey,
    required int pageIndex,
  }) async {
    if (!_enabled || url.isEmpty) return;
    final existing = _states[url];
    if (existing != null &&
        (existing.status == ComicPageTranslationStatus.loading ||
            existing.status == ComicPageTranslationStatus.done)) {
      return;
    }
    if (_inFlight.contains(url)) return;
    _inFlight.add(url);
    _states[url] =
        (existing ?? const ComicPageTranslationState()).copyWith(
      status: ComicPageTranslationStatus.loading,
      error: null,
    );
    notifyListeners();
    try {
      await _manager.init();
      final cached = await _manager.load(
        comicId: comicId,
        chapterKey: chapterKey,
        pageIndex: pageIndex,
        lang: _targetLang,
      );
      if (cached != null) {
        _states[url] = ComicPageTranslationState(
          status: ComicPageTranslationStatus.done,
          data: cached,
          naturalSize: existing?.naturalSize ?? Size.zero,
        );
        // 空页缓存无解码机会，仍需补自然尺寸（供覆盖层坐标映射）。
        if (_states[url]!.naturalSize == Size.zero) {
          unawaited(() async {
            final Size size;
            try {
              size = await _decodeSize(await _loadImageBytes(url));
            } on Object {
              return;
            }
            if (size == Size.zero) return;
            final s = _states[url];
            if (s == null ||
                s.status != ComicPageTranslationStatus.done) {
              return;
            }
            _states[url] = s.copyWith(naturalSize: size);
            notifyListeners();
          }());
        }
        return;
      }
      final result = await _translatePage(url);
      final translation = ComicPageTranslation(
        imageUrl: url,
        lang: _targetLang,
        segments: result.segments,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
      _states[url] = ComicPageTranslationState(
        status: ComicPageTranslationStatus.done,
        data: translation,
        naturalSize: result.naturalSize,
      );
      // 空结果（无文字页）同样缓存，避免翻回来重复请求。
      await _manager.save(
        comicId: comicId,
        chapterKey: chapterKey,
        pageIndex: pageIndex,
        lang: _targetLang,
        translation: translation,
      );
    } on Object catch (e) {
      _states[url] = (_states[url] ?? const ComicPageTranslationState())
          .copyWith(
        status: ComicPageTranslationStatus.error,
        error: e.toString(),
      );
    } finally {
      _inFlight.remove(url);
      notifyListeners();
    }
  }

  /// 重试某页（错误态覆盖层的重试按钮）。
  Future<void> retry(
    String url, {
    required String chapterKey,
    required int pageIndex,
  }) async {
    _states.remove(url);
    notifyListeners();
    await ensureTranslated(url, chapterKey: chapterKey, pageIndex: pageIndex);
  }

  Future<({List<VisionTextSegment> segments, Size naturalSize})>
      _translatePage(String url) async {
    final settings = NovelSummarySettings.instance;
    final NovelSummaryConfig cfg = await settings.getComicTranslationConfig();
    if (cfg.baseUrl.trim().isEmpty) {
      throw Exception('未配置 AI 接口：请先在 设置 → AI 配置 中填写通用接口'
          '或漫画翻译专用接口（需支持视觉的模型）');
    }
    final lang = _langLoaded
        ? _targetLang
        : await settings.getComicTranslationTargetLanguage();
    _targetLang = lang;
    _langLoaded = true;

    final bytes = await _loadImageBytes(url);
    final (sendBytes, mime, natural) = await _prepareImage(bytes, url);
    final segments = await _client.recognizeImage(
      config: AiEndpointConfig(
        baseUrl: cfg.baseUrl,
        apiKey: cfg.apiKey,
        model: cfg.model,
      ),
      imageBytes: sendBytes,
      mimeType: mime,
      systemPrompt: VisionTranslationClient.mangaSystemPrompt(lang),
      maxSide: _kMaxSide,
    );
    return (segments: segments, naturalSize: natural);
  }

  /// 取图片字节：网络 URL 走缓存管理器（含防盗链 headers），本地路径直读。
  Future<Uint8List> _loadImageBytes(String url) async {
    if (url.startsWith('http://') || url.startsWith('https://')) {
      final File file = await DefaultCacheManager().getSingleFile(
        url,
        headers: _buildHeaders(url),
      );
      return file.readAsBytes();
    }
    final File f = File(url);
    return f.readAsBytes();
  }

  /// 与 [SourceImage] 一致的防盗链 headers（antiHotlinking → site →
  /// Referer / UA / Cookie），保证 OCR 拉图与阅读器显示同一指纹。
  Map<String, String>? _buildHeaders(String url) {
    final ah = source?.antiHotlinking;
    final site = source?.site;
    final ahHeaders = ah?.headers;
    final siteHeaders = site?.headers;
    final referer = ah?.referer;
    final siteUa = site?.userAgent;
    final ua = (siteUa != null && siteUa.isNotEmpty)
        ? siteUa
        : HttpFetcher.instance.userAgentForUrl(url);
    final cookies = site?.cookies;
    final bool hasFields =
        (siteHeaders != null && siteHeaders.isNotEmpty) ||
            (ahHeaders != null && ahHeaders.isNotEmpty) ||
            (referer != null && referer.isNotEmpty) ||
            ua.isNotEmpty ||
            (cookies != null && cookies.isNotEmpty);
    if (!hasFields) return null;
    final Map<String, String> m = <String, String>{};
    if (ahHeaders != null) m.addAll(ahHeaders);
    if (siteHeaders != null) m.addAll(siteHeaders);
    if (referer != null && referer.isNotEmpty) m['Referer'] = referer;
    if (ua.isNotEmpty) m['User-Agent'] = ua;
    if (cookies != null && cookies.isNotEmpty) m['Cookie'] = cookies;
    return m;
  }

  /// 图片预处理：从已取到的字节解码自然尺寸；超过直接发送上限时
  /// 解码下采样到 [maxSide] 并重编码 PNG。返回 (发送字节, mime, 自然尺寸)。
  Future<(Uint8List, String, Size)> _prepareImage(
    Uint8List bytes,
    String url,
  ) async {
    // 微缩解码（targetWidth=16 极廉价）拿自然尺寸，供覆盖层坐标映射。
    final natural = await _decodeSize(bytes);
    if (bytes.lengthInBytes <= _kDirectSendLimitBytes) {
      final mime = _guessMime(url);
      return (bytes, mime, natural);
    }
    // 超大图：解码 → 长边压到 maxSide → PNG 重编码。
    final Uint8List? resized = await _resizeImageBytes(bytes);
    if (resized != null) return (resized, 'image/png', natural);
    return (bytes, _guessMime(url), natural);
  }

  Future<Size> _decodeSize(Uint8List bytes) async {
    try {
      final ui.Codec codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: 16,
        allowUpscaling: false,
      );
      final ui.FrameInfo frame = await codec.getNextFrame();
      final Size size =
          Size(frame.image.width.toDouble(), frame.image.height.toDouble());
      frame.image.dispose();
      codec.dispose();
      return size;
    } on Object {
      return Size.zero;
    }
  }

  Future<Uint8List?> _resizeImageBytes(
    Uint8List bytes, {
    int maxSide = _kMaxSide,
  }) async {
    try {
      final ui.Codec codec = await ui.instantiateImageCodec(
        bytes,
        allowUpscaling: false,
      );
      final ui.FrameInfo frame = await codec.getNextFrame();
      final int w = frame.image.width;
      final int h = frame.image.height;
      final int longSide = w > h ? w : h;
      ui.Image toEncode = frame.image;
      if (longSide > maxSide) {
        final double ratio = maxSide / longSide;
        final int tw = (w * ratio).round();
        final int th = (h * ratio).round();
        final ui.Codec small = await ui.instantiateImageCodec(
          bytes,
          targetWidth: tw,
          targetHeight: th,
          allowUpscaling: false,
        );
        final ui.FrameInfo smallFrame = await small.getNextFrame();
        toEncode = smallFrame.image;
      }
      final ByteData? data = await toEncode.toByteData(
        format: ui.ImageByteFormat.png,
      );
      final Uint8List? out = data?.buffer.asUint8List();
      if (toEncode != frame.image) toEncode.dispose();
      frame.image.dispose();
      codec.dispose();
      return out;
    } on Object {
      return null;
    }
  }

  static String _guessMime(String url) {
    final lower = url.toLowerCase().split('?').first;
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    return 'image/jpeg';
  }
}

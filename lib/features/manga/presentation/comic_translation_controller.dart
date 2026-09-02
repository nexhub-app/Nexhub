/// 漫画页翻译控制器（漫画翻译功能的大脑）。
///
/// 职责：
/// - 持有「翻译开关」与逐页翻译状态（按图片 URL 索引），翻页时由阅读器
///   调用 [ensureTranslated] 触发当前页翻译；
/// - 图片获取：本地路径直接读文件；网络 URL 走 [NexImageCacheManager]
///   （命中磁盘缓存零流量，未命中带防盗链 headers 下载）；
/// - 图片预处理：超过上限时经 [AiImageResizer] 下采样再编码，控制请求体积；
/// - 调用 [VisionTranslationClient]（视觉模型一次完成 OCR + 翻译），
///   结果经 [ComicTranslationManager] 持久化（`comicId|章|页|语言` 键）；
/// - **并发信号量**（B2）：快速连续翻页时网络请求并发上限 2，防止瞬时打爆
///   接口限流；缓存命中路径不占槽位；
/// - 错误归一化（B7）：catch 处统一转 [TranslationException] 可读文案，
///   原始异常细节仅入 [AppLog]。
///
/// 状态以 [Listenable]（ChangeNotifier）暴露，[MangaPageImage] 内嵌的
/// 覆盖层监听后按千分比坐标把译文渲染到原图对应位置上。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Size;
// NexImageCacheManager 复用阅读器同款图片磁盘缓存（同 URL 不重复下载）。
import 'package:nexhub/core/network/dio_image_file_service.dart';

import '../../../core/ai/endpoint_router.dart';
import '../../../core/ai/glossary_manager.dart';
import '../../../core/ai/image_resizer.dart';
import '../../../core/ai/prompt_builder.dart';
import '../../../core/ai/translation_exception.dart';
import '../../../core/ai/translation_options_store.dart';
import '../../../core/ai/vision_translation_client.dart';
import '../../../core/comic/comic_translation_manager.dart';
import '../../../core/models/plugin_config.dart';
import '../../../core/scraper/http_fetcher.dart';
import '../../../core/utils/app_log.dart';
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
    GlossaryManager? glossary,
    TranslationOptionsStore? options,
  })  : _source = source,
        _manager = manager ?? ComicTranslationManager(),
        _client = client ?? VisionTranslationClient(),
        _glossary = glossary ?? GlossaryManager(),
        _options = options ?? TranslationOptionsStore();

  /// 请求图片长边上限（像素）：视觉模型对超大图会截断细节，
  /// 长边压到 1600 在识别精度与请求体积（token / 流量）间取得平衡。
  static const int _kMaxSide = 1600;

  /// 原始字节直接发送的上限：超过才走解码下采样（绝大多数漫画页 < 4MB）。
  static const int _kDirectSendLimitBytes = 6 * 1024 * 1024;

  /// 全局并发上限（B2）：快速连续翻页时在途视觉请求最多 2 个，
  /// 避免瞬时并发触发上游 429/限流。缓存命中不占槽位。
  static const int _kMaxConcurrent = 2;

  final String comicId;
  final ComicTranslationManager _manager;
  final VisionTranslationClient _client;
  final GlossaryManager _glossary;
  final TranslationOptionsStore _options;

  /// 术语表生效条目（F1，会话内加载一次；语言回落主目标语言）。
  List<GlossaryEntry>? _glossaryEntries;

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

  // ── 并发信号量（B2）──
  int _active = 0;
  final List<void Function()> _waiters = <void Function()>[];

  bool get enabled => _enabled;

  ComicPageTranslationState stateFor(String url) =>
      _states[url] ?? const ComicPageTranslationState();

  /// 轻量信号量：并发达到 [_kMaxConcurrent] 时排队等待，槽位释放按
  /// 先到先得唤醒。仅网络请求段使用；缓存命中不经过此门。
  Future<T> _withSlot<T>(Future<T> Function() task) async {
    while (_active >= _kMaxConcurrent) {
      final completer = Completer<void>();
      _waiters.add(completer.complete);
      await completer.future;
    }
    _active++;
    try {
      return await task();
    } finally {
      _active--;
      if (_waiters.isNotEmpty) _waiters.removeAt(0)();
    }
  }

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

  /// 确保某页已翻译：缓存命中直接回填状态（不占并发槽位）；否则经
  /// 信号量排队发起 OCR+翻译。
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
          unawaited(_fillNaturalSize(url));
        }
        return;
      }
      // 网络请求段受并发信号量约束（B2）。
      final result =
          await _withSlot(() => _translatePage(url, chapterKey, pageIndex));
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
      await _saveTranslation(chapterKey, pageIndex, translation);
    } on Object catch (e) {
      // B7：用户可见文案归一化，原始细节仅入日志。
      AppLog.instance.w('[漫画翻译] 页面翻译失败 url=$url: $e');
      _states[url] = (_states[url] ?? const ComicPageTranslationState())
          .copyWith(
        status: ComicPageTranslationStatus.error,
        error: TranslationException.from(e).message,
      );
    } finally {
      _inFlight.remove(url);
      notifyListeners();
    }
  }

  Future<void> _saveTranslation(
    String chapterKey,
    int pageIndex,
    ComicPageTranslation translation,
  ) async {
    try {
      await _manager.save(
        comicId: comicId,
        chapterKey: chapterKey,
        pageIndex: pageIndex,
        lang: _targetLang,
        translation: translation,
      );
      // B5：保存后惰性裁剪缓存容量。
      unawaited(_manager.trimToLimit(ComicTranslationManager.defaultMaxEntries));
    } on Object {
      // 缓存写失败不影响显示。
    }
  }

  /// 缓存命中路径补自然尺寸（微缩解码极廉价；失败静默保持 zero）。
  Future<void> _fillNaturalSize(String url) async {
    Size size = Size.zero;
    try {
      size = await AiImageResizer.decodeSize(await _loadImageBytes(url));
    } on Object {
      return;
    }
    if (size == Size.zero) return;
    final s = _states[url];
    if (s == null || s.status != ComicPageTranslationStatus.done) return;
    _states[url] = s.copyWith(naturalSize: size);
    notifyListeners();
  }

  /// 重试某页（错误态覆盖层的重试按钮）；重试同样受并发信号量约束。
  Future<void> retry(
    String url, {
    required String chapterKey,
    required int pageIndex,
  }) async {
    _states.remove(url);
    notifyListeners();
    await ensureTranslated(url, chapterKey: chapterKey, pageIndex: pageIndex);
  }

  /// F2：前一页已译短摘要——读上一页缓存（跨会话可用），把识别原文拼成
  /// 1–2 句（截断 160 字符封顶）；无上一页/缓存时返回 null。
  Future<String?> _prevPageSummary(String chapterKey, int pageIndex) async {
    if (pageIndex <= 0) return null;
    try {
      final prev = await _manager.load(
        comicId: comicId,
        chapterKey: chapterKey,
        pageIndex: pageIndex - 1,
        lang: _targetLang,
      );
      final buf = StringBuffer();
      for (final s in prev?.segments ?? const <VisionTextSegment>[]) {
        final t = s.text.trim();
        if (t.isEmpty) continue;
        if (buf.isNotEmpty) buf.write('；');
        buf.write(t);
        if (buf.length >= 160) break;
      }
      final s = buf.toString();
      if (s.isEmpty) return null;
      return s.length > 160 ? s.substring(0, 160) : s;
    } on Object {
      return null;
    }
  }

  Future<({List<VisionTextSegment> segments, Size naturalSize})>
      _translatePage(String url, String chapterKey, int pageIndex) async {
    final settings = NovelSummarySettings.instance;
    final List<NovelSummaryConfig> endpointCfgs =
        await settings.getComicTranslationEndpoints();
    final endpoints = <AiEndpointConfig>[
      for (final c in endpointCfgs)
        if (c.baseUrl.trim().isNotEmpty)
          AiEndpointConfig(baseUrl: c.baseUrl, apiKey: c.apiKey, model: c.model),
    ];
    if (endpoints.isEmpty) {
      throw const TranslationException('未配置 AI 接口：请先在 设置 → AI 配置 中填写'
          '通用接口或漫画翻译专用接口（需支持视觉的模型）');
    }
    final lang = _langLoaded
        ? _targetLang
        : await settings.getComicTranslationTargetLanguage();
    _targetLang = lang;
    _langLoaded = true;

    // F1/F8：术语表（作品级回落全局；语言回落主目标语言）+ 风格预设。
    try {
      final master =
          await settings.getTranslationTargetLanguage();
      _glossaryEntries ??= await _glossary.effectiveEntriesWithFallback(
          comicId, lang, master);
    } on Object {
      _glossaryEntries ??= const <GlossaryEntry>[];
    }
    final glossary = _glossaryEntries ?? const <GlossaryEntry>[];
    String style = TranslationStyle.standard.name;
    try {
      style = (await _options.effectiveStyle(comicId)).name;
    } on Object {
      // 风格读取失败按标准风格。
    }
    final systemPrompt = PromptBuilder.mangaSystemPrompt(
      lang: lang,
      glossary: glossary,
      style: TranslationStyle.fromStorage(style),
      prevPageSummary: await _prevPageSummary(chapterKey, pageIndex),
    );

    final bytes = await _loadImageBytes(url);
    final natural = await AiImageResizer.decodeSize(bytes);
    Uint8List sendBytes = bytes;
    String mime = _guessMime(url);
    if (bytes.lengthInBytes > _kDirectSendLimitBytes) {
      // 超大图：下采样重编码（B6：codec 释放已收口在 AiImageResizer）。
      final Uint8List? resized =
          await AiImageResizer.resizeToLimit(bytes, maxSide: _kMaxSide);
      if (resized != null) {
        sendBytes = resized;
        mime = 'image/png';
      }
    }
    final segments = await AiEndpointRouter.execute<List<VisionTextSegment>>(
      endpoints,
      (cfg) => _client.recognizeImage(
        config: cfg,
        imageBytes: sendBytes,
        mimeType: mime,
        systemPrompt: systemPrompt,
        maxSide: _kMaxSide,
      ),
    );
    // F1：术语冲突检测（仅日志，不阻断显示）。
    if (glossary.isNotEmpty && segments.isNotEmpty) {
      try {
        for (final w in GlossaryManager.detectConflicts(
          glossary,
          <String>[for (final s in segments) s.text],
          <String>[for (final s in segments) s.translation],
        )) {
          AppLog.instance.w('[漫画翻译][术语冲突] $w');
        }
      } on Object {
        // 检测失败不影响主流程。
      }
    }
    return (segments: segments, naturalSize: natural);
  }

  /// 取图片字节：网络 URL 走缓存管理器（含防盗链 headers），本地路径直读。
  Future<Uint8List> _loadImageBytes(String url) async {
    if (url.startsWith('http://') || url.startsWith('https://')) {
      // 与 SourceImage 同一缓存（nexCachedImageData）：DefaultCacheManager
      // 的 HttpClient 启动早期创建后不随网络档案更新（僵化直连）。
      final File file = await NexImageCacheManager.instance.getSingleFile(
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

  static String _guessMime(String url) {
    final lower = url.toLowerCase().split('?').first;
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    return 'image/jpeg';
  }
}

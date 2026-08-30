/// 视频字幕实时翻译控制器（视频实时翻译功能）。
///
/// 两条文字来源：
/// 1. **字幕轨转写**：按播放进度节流读取 mpv `sub-text` 属性（当前字幕文本，
///    内置轨 / 外挂 srt/ass 均适用），文本变化即送 AI 翻译；
/// 2. **画面 OCR 兜底**（可选开关）：**仅当无字幕轨**（B8）时，按间隔对当前帧
///    （`Player.screenshot()`）做视觉 OCR+翻译——无字幕资源的外源视频
///    也能获得"实时"翻译（延迟取决于识别间隔，默认 4s）。
///
/// 稳定性护栏：
/// - **OCR 防重入**（B1）：视觉请求耗时长，`_ocrInFlight` 独立飞行标记，
///   上一次未返回前跳过新 tick，异常路径也必须复位；
/// - **单句重试**（B4）：瞬时网络抖动按指数退避重试（最多 3 次尝试），
///   不再一次失败即丢句；
/// - **错误归一化**（B7）：用户可见文案经 [TranslationException] 归一化，
///   原始异常细节仅入 [AppLog]；
/// - **缓存容量上限**（B5）：译文按 `lang|md5(原文)` 持久化到 Hive box
///   `subtitle_translations`，save 后惰性裁剪到上限，防止磁盘无限膨胀。
/// 翻译接口走 [VisionTranslationClient]（OpenAI 兼容 chat/completions），
/// 配置读取 [NovelSummarySettings] 的视频翻译功能级配置（留空回落通用）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ai/glossary_manager.dart';
import '../ai/prompt_builder.dart';
import '../ai/translation_exception.dart';
import '../ai/translation_options_store.dart';
import '../ai/vision_translation_client.dart';
import '../utils/app_log.dart';
import '../../features/novel/domain/novel_summary_service.dart';
import '../../features/novel/domain/novel_summary_settings.dart';

/// 译文可见状态（覆盖层渲染依据）。
class SubtitleTranslationState {
  /// 当前句原文（来自字幕轨或 OCR）。
  final String? sourceText;

  /// 当前句译文（翻译中为 null，显示上一句直至新译文就绪）。
  final String? translatedText;

  /// 是否正在翻译当前句。
  final bool translating;

  /// 最近一次错误（供 UI 提示；翻译失败不阻断播放）。
  final String? error;

  const SubtitleTranslationState({
    this.sourceText,
    this.translatedText,
    this.translating = false,
    this.error,
  });

  /// 是否有可展示内容。
  bool get hasContent =>
      (translatedText != null && translatedText!.trim().isNotEmpty) ||
      (sourceText != null && sourceText!.trim().isNotEmpty);
}

class SubtitleTranslationController extends ChangeNotifier {
  SubtitleTranslationController({
    VisionTranslationClient? client,
    GlossaryManager? glossary,
    TranslationOptionsStore? options,
  })  : _client = client ?? VisionTranslationClient(),
        _glossary = glossary ?? GlossaryManager(),
        _options = options ?? TranslationOptionsStore();

  /// mpv `sub-text` 轮询节流（位置回调 4-10Hz，属性读取无需每帧）。
  static const Duration _kPollInterval = Duration(milliseconds: 600);

  /// OCR 兜底的取帧间隔（秒）。视觉请求较重，过密会显著增加流量/费用。
  static const int _kOcrIntervalSec = 4;

  /// 单句翻译超时（同字幕等待翻译超时后重发）。
  static const Duration _kTranslateTimeout = Duration(seconds: 45);

  /// 单句翻译最大尝试次数（B4：首次 + 2 次重试，指数退避 500ms / 1s）。
  static const int _kMaxAttempts = 3;

  static const String _kBoxName = 'subtitle_translations';

  /// 译文缓存条数上限（B5）。
  static const int defaultMaxEntries = 5000;

  // ── 偏好持久化（SharedPreferences，与截图目录等轻量键同款做法）──
  static const String _kPrefEnabled = 'subtitle_translation_enabled_v1';
  static const String _kPrefShowOriginal =
      'subtitle_translation_show_original_v1';
  static const String _kPrefOcrFallback = 'subtitle_translation_ocr_fallback_v1';

  final VisionTranslationClient _client;

  /// 播放器控制器（attach 后可用；用于读 mpv 属性与截图）。
  dynamic _playerController;
  bool _attached = false;
  StreamSubscription<dynamic>? _tracksSub;

  bool _enabled = false;
  bool _showOriginal = false;
  bool _ocrFallback = false;
  bool _prefsLoaded = false;

  /// 是否存在字幕轨（B8）：attach 与轨道变化时经 `track-list` 检测。
  /// 有字幕轨时 OCR 兜底不启用（句间间隙不做无意义识别）。
  bool _hasSubtitleTrack = false;

  String _targetLang = 'zh';
  bool _langLoaded = false;

  SubtitleTranslationState _state = const SubtitleTranslationState();

  /// 上次轮询到的字幕原文（去重：文本没变不重复翻译）。
  String _lastPolledText = '';

  DateTime _lastPollAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastOcrAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// OCR 视觉请求飞行标记（B1）：与字幕翻译的 [_inFlightText] 独立，
  /// 防止耗时的视觉请求被 4s tick 重复并发。
  bool _ocrInFlight = false;

  /// 进行中的翻译任务对应的原文（新句到来时排队，完成后立刻处理队首）。
  String? _inFlightText;
  String? _queuedText;

  // ── F1/F8：术语表 + 提示词选项；F2：会话内前文历史 ──
  final GlossaryManager _glossary;
  final TranslationOptionsStore _options;

  /// 会话内最近 N 句 {原文, 译文}（F2）：随请求注入为对话历史，
  /// 超预算按 FIFO 淘汰、优先保留较新句。
  final List<TranslationContextPair> _history = <TranslationContextPair>[];

  /// 历史注入预算：最多 6 句、总字符（原文+译文）不超过 2400
  /// （约 1200 token，汉字按 2 字符/token 估算）。
  static const int _kHistoryMaxPairs = 6;
  static const int _kHistoryMaxChars = 2400;

  /// 术语表生效条目（会话内加载一次；语言回落主目标语言）。
  List<GlossaryEntry>? _glossaryEntries;

  /// 会话内译文缓存（lang|原文 → 译文）；Hive 为跨会话持久层。
  final Map<String, String> _memoryCache = <String, String>{};
  Box<dynamic>? _box;
  bool _boxInitTried = false;

  SubtitleTranslationState get state => _state;
  bool get enabled => _enabled;
  bool get showOriginal => _showOriginal;
  bool get ocrFallback => _ocrFallback;

  /// 时钟注入点（测试用）：onPositionTick 的节流/间隔判断全部经此取时，
  /// 单测可注入可控时钟模拟「4s 间隔已过」。
  @visibleForTesting
  DateTime Function() clock = DateTime.now;

  /// 当前视频是否有字幕轨（B8；attach 前为 false）。
  bool get hasSubtitleTrack => _hasSubtitleTrack;

  /// 绑定播放器控制器并恢复持久化开关（视频翻译开关跨会话记忆）。
  Future<void> attach(dynamic playerController) async {
    _playerController = playerController;
    _attached = true;
    await _loadPrefs();
    unawaited(_detectSubtitleTrack());
    // 轨道变化（加载完成 / 手动换轨 / 换集）时重测字幕轨存在性（B8）。
    try {
      _tracksSub?.cancel();
      _tracksSub = playerController.tracksStream.listen(
        (dynamic _) => unawaited(_detectSubtitleTrack()),
        onError: (Object _) {},
      );
    } on Object {
      // 测试假件 / 无流环境：静默跳过订阅。
    }
    if (_enabled) {
      // 记忆为开启：进入播放页即恢复翻译。
      await _ensureLang();
      notifyListeners();
    }
  }

  void detach() {
    _attached = false;
    _playerController = null;
    _tracksSub?.cancel();
    _tracksSub = null;
    _hasSubtitleTrack = false;
    _history.clear(); // F2：离开播放页清空会话上下文。
    _resetState();
  }

  /// 检测当前媒体是否存在字幕轨（B8）。
  ///
  /// mpv `track-list` 经 media_kit getProperty 返回 JSON 字符串（也可能
  /// 直接是 List，视实现而定），两形态都兼容；属性不可用按「无字幕轨」
  /// 处理（OCR 兜底保持可用）。
  Future<void> _detectSubtitleTrack() async {
    final dynamic c = _playerController;
    if (c == null || !_attached) return;
    try {
      final dynamic raw = await c.backend.getProperty('track-list');
      final list = _asTrackList(raw);
      _hasSubtitleTrack =
          list.any((t) => (t as Map?)?['type'] == 'sub');
    } on Object {
      _hasSubtitleTrack = false;
    }
  }

  static List<dynamic> _asTrackList(dynamic raw) {
    if (raw is List) return raw;
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) return decoded;
      } on Object {
        // 非 JSON 字符串按空轨处理。
      }
    }
    return const <dynamic>[];
  }

  Future<void> _loadPrefs() async {
    if (_prefsLoaded) return;
    _prefsLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getString(_kPrefEnabled) == '1';
      _showOriginal = prefs.getString(_kPrefShowOriginal) == '1';
      _ocrFallback = prefs.getString(_kPrefOcrFallback) == '1';
    } on Object {
      // 读取失败按默认关闭处理。
    }
  }

  Future<void> _savePref(String key, bool v) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, v ? '1' : '0');
    } on Object {
      // 写入失败不影响功能。
    }
  }

  /// 开关实时翻译（字幕面板 / 播放器菜单入口）。
  Future<void> setEnabled(bool v) async {
    if (_enabled == v) return;
    _enabled = v;
    await _savePref(_kPrefEnabled, v);
    if (v) {
      await _ensureLang();
      // 开启后立刻轮询一次（不等下一个位置事件）。
      await _pollSubtitle(force: true);
    } else {
      _resetState();
    }
    notifyListeners();
  }

  Future<void> setShowOriginal(bool v) async {
    _showOriginal = v;
    await _savePref(_kPrefShowOriginal, v);
    notifyListeners();
  }

  Future<void> setOcrFallback(bool v) async {
    _ocrFallback = v;
    await _savePref(_kPrefOcrFallback, v);
    if (v && _enabled) {
      await _ensureLang();
      await _detectSubtitleTrack();
      // 无字幕轨才立即做一次 OCR（B8：有轨时不做）。
      if (!_hasSubtitleTrack) {
        await _maybeOcrTick(force: true);
      }
    }
    notifyListeners();
  }

  Future<void> _ensureLang() async {
    if (_langLoaded) return;
    _targetLang =
        await NovelSummarySettings.instance.getMediaTranslationTargetLanguage();
    _langLoaded = true;
    // F1：术语表（全局表为主；字幕无作品身份）按会话加载一次。
    try {
      final master = await NovelSummarySettings.instance
          .getTranslationTargetLanguage();
      _glossaryEntries = await _glossary.effectiveEntriesWithFallback(
        GlossaryManager.globalWorkId,
        _targetLang,
        master,
      );
    } on Object {
      _glossaryEntries = const <GlossaryEntry>[];
    }
  }

  /// 播放进度回调（由播放页 [_onPositionChanged] 每帧转发）：
  /// 节流轮询 mpv 当前字幕文本；**无字幕轨**且开启 OCR 兜底时按间隔取帧识别。
  void onPositionTick(Duration position) {
    if (!_enabled || !_attached) return;
    final now = clock();
    if (now.difference(_lastPollAt) >= _kPollInterval) {
      _lastPollAt = now;
      unawaited(_pollSubtitle());
    }
    // B8：仅无字幕轨（`_lastPolledText` 为空且无 sub 轨）才走 OCR 兜底，
    // 有轨视频的句间间隙不做无意义识别。
    if (_ocrFallback &&
        !_hasSubtitleTrack &&
        _lastPolledText.isEmpty &&
        !_ocrInFlight &&
        now.difference(_lastOcrAt).inSeconds >= _kOcrIntervalSec) {
      _lastOcrAt = now;
      unawaited(_maybeOcrTick());
    }
  }

  /// 轮询 mpv `sub-text`：文本变化时触发翻译。
  Future<void> _pollSubtitle({bool force = false}) async {
    final dynamic c = _playerController;
    if (c == null) return;
    String? text;
    try {
      text = await c.backend.getProperty('sub-text');
    } on Object {
      return; // 属性不可用（Web / 无字幕轨），静默跳过。
    }
    final trimmed = (text ?? '').trim();
    // mpv 偶发返回 ASS 内联标记，剥离基础标签。
    final clean = _stripAssTags(trimmed);
    if (clean == _lastPolledText && !force) return;
    _lastPolledText = clean;
    if (clean.isEmpty) {
      // 字幕间隙：保留上一句显示至自然消失（不清空，避免闪烁）。
      return;
    }
    unawaited(_translateSentence(clean));
  }

  /// OCR 兜底：截取当前帧送视觉模型识别+翻译（B1：防重入）。
  Future<void> _maybeOcrTick({bool force = false}) async {
    final dynamic c = _playerController;
    if (c == null) return;
    if (!force && _ocrInFlight) return; // 上一次 OCR 未返回则跳过
    if (!force && _inFlightText != null) return;
    _ocrInFlight = true;
    try {
      final Uint8List? frame = await c.player.screenshot();
      if (frame == null || frame.isEmpty) return;
      final cfg = await _resolveConfig();
      if (cfg == null) {
        throw const TranslationException('未配置 AI 接口：请先在 设置 → AI 配置 中填写'
            '通用接口或视频翻译专用接口');
      }
      await _ensureLang();
      final segments = await _client.recognizeImage(
        config: cfg,
        imageBytes: frame,
        mimeType: 'image/png',
        systemPrompt: PromptBuilder.videoOcrSystemPrompt(
          lang: _targetLang,
          glossary: _glossaryEntries ?? const <GlossaryEntry>[],
          style: await _options.effectiveStyle(null),
        ),
      );
      if (!_enabled) return;
      if (segments.isEmpty) return;
      final buf = StringBuffer();
      for (final s in segments) {
        final t = s.translation.isNotEmpty ? s.translation : s.text;
        if (t.isEmpty) continue;
        if (buf.isNotEmpty) buf.write('\n');
        buf.write(t);
      }
      final sourceBuf = StringBuffer();
      for (final s in segments) {
        if (s.text.isEmpty) continue;
        if (sourceBuf.isNotEmpty) sourceBuf.write('\n');
        sourceBuf.write(s.text);
      }
      final combined = buf.toString().trim();
      if (combined.isEmpty) return;
      // 与上一帧识别结果相同则跳过（静止画面 / 停顿）。
      if (combined == _state.translatedText) return;
      _state = SubtitleTranslationState(
        sourceText: sourceBuf.toString(),
        translatedText: combined,
        translating: false,
      );
      notifyListeners();
    } on Object catch (e) {
      // B7：归一化文案，原始细节入日志；OCR 失败不打断播放，
      // 仅在从未有过结果时提示一次。
      AppLog.instance.w('[字幕翻译] 画面 OCR 失败: $e');
      if (_state.translatedText == null) {
        _state = SubtitleTranslationState(
            error: TranslationException.from(e).message);
        notifyListeners();
      }
    } finally {
      _ocrInFlight = false;
    }
  }

  /// 翻译一句（去重 / 缓存 / 排队 / 重试）。
  Future<void> _translateSentence(String text) async {
    if (text.isEmpty) return;
    await _ensureLang();
    // 1) 会话缓存。
    final memKey = '$_targetLang|$text';
    final cachedMem = _memoryCache[memKey];
    if (cachedMem != null) {
      _state = SubtitleTranslationState(
          sourceText: text, translatedText: cachedMem);
      notifyListeners();
      return;
    }
    // 2) Hive 持久缓存。
    final cachedDisk = await _loadCached(text);
    if (cachedDisk != null) {
      _memoryCache[memKey] = cachedDisk;
      _state = SubtitleTranslationState(
          sourceText: text, translatedText: cachedDisk);
      notifyListeners();
      return;
    }
    // 3) 排队（同一时刻仅一个请求；新句到来覆盖未开始的排队项）。
    if (_inFlightText != null) {
      _queuedText = text;
      _state = SubtitleTranslationState(
        sourceText: text,
        translatedText: _state.translatedText,
        translating: true,
      );
      notifyListeners();
      return;
    }
    _inFlightText = text;
    _state = SubtitleTranslationState(
      sourceText: text,
      translatedText: _state.translatedText,
      translating: true,
    );
    notifyListeners();
    try {
      final cfg = await _resolveConfig();
      if (cfg == null) {
        throw const TranslationException('未配置 AI 接口：请先在 设置 → AI 配置 中填写'
            '通用接口或视频翻译专用接口');
      }
      // B4：指数退避重试，瞬时抖动不再丢句；重试期间 UI 保持「翻译中」。
      // F1/F8：system prompt 经 PromptBuilder 组装（术语表 + 风格 + CoT），
      // F2：注入最近几句对话历史；轻量格式默认开启（省 token，失败自动
      // 回退编号协议）。
      final glossary = _glossaryEntries ?? const <GlossaryEntry>[];
      final lightweight = await _options.getSubtitleLightweight();
      final system = PromptBuilder.subtitleSystemPrompt(
        lang: _targetLang,
        glossary: glossary,
        style: await _options.effectiveStyle(null),
        lightweight: lightweight,
        cot: await _options.getCotEnabled(),
      );
      final result = await _translateWithRetry(
        () => _client.translateBatch(
          config: cfg,
          targetLang: _targetLang,
          texts: <String>[text],
          history: List<TranslationContextPair>.of(_history),
          lightweight: lightweight,
          systemPrompt: system,
        ),
      );
      final translated = result.first.trim();
      // F1：术语冲突检测（仅日志）。
      if (glossary.isNotEmpty) {
        try {
          for (final w in GlossaryManager.detectConflicts(
              glossary, <String>[text], <String>[translated])) {
            AppLog.instance.w('[字幕翻译][术语冲突] $w');
          }
        } on Object {
          // 检测失败不影响主流程。
        }
      }
      // F2：成功句入历史（FIFO + 字符预算淘汰）。
      _appendToHistory(text, translated);
      _memoryCache[memKey] = translated;
      await _saveCached(text, translated);
      if (!_enabled) return;
      // 翻译期间用户已翻到新句：仅当仍是当前句时更新显示。
      if (_lastPolledText == text) {
        _state = SubtitleTranslationState(
            sourceText: text, translatedText: translated);
      }
    } on Object catch (e) {
      AppLog.instance.w('[字幕翻译] 单句翻译失败: $e');
      if (_lastPolledText == text) {
        _state = SubtitleTranslationState(
          sourceText: text,
          translatedText: _state.translatedText,
          error: TranslationException.from(e).message,
        );
      }
    } finally {
      _inFlightText = null;
      notifyListeners();
      // 处理排队中的下一句。
      final next = _queuedText;
      if (next != null && _enabled) {
        _queuedText = null;
        unawaited(_translateSentence(next));
      }
    }
  }

  /// F2：成功句入会话历史——最多 [_kHistoryMaxPairs] 句，总字符超预算时
  /// 从最旧开始淘汰（优先保留较新句）。
  void _appendToHistory(String source, String translation) {
    _history.removeWhere((p) => p.source == source);
    _history.add((source: source, translation: translation));
    while (_history.length > _kHistoryMaxPairs) {
      _history.removeAt(0);
    }
    var chars = 0;
    for (final p in _history) {
      chars += p.source.length + p.translation.length;
    }
    while (chars > _kHistoryMaxChars && _history.length > 1) {
      final dropped = _history.removeAt(0);
      chars -= dropped.source.length + dropped.translation.length;
    }
  }

  /// 带指数退避的重试（B4）：最多 [_kMaxAttempts] 次尝试，
  /// 间隔 500ms / 1s；全部失败抛最后一次异常（由调用方归一化展示）。
  Future<List<String>> _translateWithRetry(
    Future<List<String>> Function() send,
  ) async {
    for (var i = 0; i < _kMaxAttempts; i++) {
      try {
        return await send().timeout(_kTranslateTimeout);
      } on Object {
        if (i == _kMaxAttempts - 1) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 500 * (1 << i)));
      }
    }
    throw StateError('unreachable');
  }

  /// 解析视频翻译接口配置（功能级留空回落通用；未配置返回 null）。
  Future<AiEndpointConfig?> _resolveConfig() async {
    final NovelSummaryConfig cfg =
        await NovelSummarySettings.instance.getMediaTranslationConfig();
    if (cfg.baseUrl.trim().isEmpty) return null;
    return AiEndpointConfig(
      baseUrl: cfg.baseUrl,
      apiKey: cfg.apiKey,
      model: cfg.model,
    );
  }

  void _resetState() {
    _lastPolledText = '';
    _queuedText = null;
    _inFlightText = null;
    _state = const SubtitleTranslationState();
    notifyListeners();
  }

  // ─────────────────── Hive 持久缓存（B5：带容量上限）───────────────────

  Future<Box<dynamic>?> _ensureBox() async {
    if (_box != null) return _box;
    if (_boxInitTried) return _box;
    _boxInitTried = true;
    try {
      if (Hive.isBoxOpen(_kBoxName)) {
        _box = Hive.box(_kBoxName);
      } else {
        _box = await Hive.openBox(_kBoxName);
      }
    } on Object {
      // Hive 未初始化（测试环境）时静默降级为纯会话缓存。
    }
    return _box;
  }

  static String _cacheKey(String lang, String text) {
    final digest = md5.convert(utf8.encode(text)).toString();
    return '$lang|$digest';
  }

  Future<String?> _loadCached(String text) async {
    final box = await _ensureBox();
    if (box == null) return null;
    try {
      final raw = box.get(_cacheKey(_targetLang, text));
      if (raw is! String || raw.isEmpty) return null;
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final v = decoded['t'] as String?;
      return (v == null || v.isEmpty) ? null : v;
    } on Object {
      return null;
    }
  }

  Future<void> _saveCached(String text, String translated) async {
    final box = await _ensureBox();
    if (box == null) return;
    try {
      await box.put(
        _cacheKey(_targetLang, text),
        jsonEncode(<String, dynamic>{
          't': translated,
          'ts': DateTime.now().millisecondsSinceEpoch,
        }),
      );
      // B5：保存后惰性裁剪。
      await trimCache(defaultMaxEntries);
    } on Object {
      // 缓存写失败不影响显示。
    }
  }

  /// 当前缓存条数（B5，设置页展示用；box 未打开返回 0）。
  int cacheCount() => Hive.isBoxOpen(_kBoxName) ? Hive.box(_kBoxName).length : 0;

  /// 容量裁剪（B5）：按保存时间戳升序淘汰最旧条目，返回删除条数。
  Future<int> trimCache(int maxEntries) async {
    if (maxEntries <= 0) return 0;
    final box = await _ensureBox();
    if (box == null || box.length <= maxEntries) return 0;
    final entries = <(String, int)>[];
    for (final key in box.keys) {
      if (key is! String) continue;
      final raw = box.get(key);
      int ts = 0;
      if (raw is String && raw.isNotEmpty) {
        try {
          ts = (jsonDecode(raw) as Map<String, dynamic>)['ts'] as int? ?? 0;
        } on Object {
          ts = 0;
        }
      }
      entries.add((key, ts));
    }
    if (entries.length <= maxEntries) return 0;
    entries.sort((a, b) => a.$2.compareTo(b.$2));
    final victims =
        entries.take(entries.length - maxEntries).map((e) => e.$1).toList();
    await box.deleteAll(victims);
    return victims.length;
  }

  /// 清空全部译文缓存（B5 设置页「清除翻译缓存」入口）。返回删除条数。
  Future<int> clearCache() async {
    final box = await _ensureBox();
    if (box == null) return 0;
    final n = box.length;
    await box.clear();
    _memoryCache.clear();
    return n;
  }

  /// 剥离 ASS 内联标签（{\...}）与 HTML 标签。
  static String _stripAssTags(String s) {
    if (s.isEmpty) return s;
    var out = s.replaceAll(RegExp(r'\{\\[^}]*\}'), '');
    out = out.replaceAll(RegExp(r'<[^>]+>'), ' ');
    return out.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}

/// 视频字幕实时翻译控制器（视频实时翻译功能）。
///
/// 两条文字来源：
/// 1. **字幕轨转写**：按播放进度节流读取 mpv `sub-text` 属性（当前字幕文本，
///    内置轨 / 外挂 srt/ass 均适用），文本变化即送 AI 翻译；
/// 2. **画面 OCR 兜底**（可选开关）：无字幕轨时，按间隔对当前帧
///    （`Player.screenshot()`）做视觉 OCR+翻译——无字幕资源的外源视频
///    也能获得"实时"翻译（延迟取决于识别间隔，默认 4s）。
///
/// 译文按 `lang|md5(原文)` 持久化到 Hive box `subtitle_translations`
/// （JSON 字符串，免 TypeAdapter），跨集/跨次观看命中缓存零延迟。
/// 翻译接口走 [VisionTranslationClient]（OpenAI 兼容 chat/completions），
/// 配置读取 [NovelSummarySettings] 的视频翻译功能级配置（留空回落通用）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ai/vision_translation_client.dart';
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
  SubtitleTranslationController({VisionTranslationClient? client})
      : _client = client ?? VisionTranslationClient();

  /// mpv `sub-text` 轮询节流（位置回调 4-10Hz，属性读取无需每帧）。
  static const Duration _kPollInterval = Duration(milliseconds: 600);

  /// OCR 兜底的取帧间隔（秒）。视觉请求较重，过密会显著增加流量/费用。
  static const int _kOcrIntervalSec = 4;

  /// 同字幕等待翻译超时后重发（AI 卡死自愈）。
  static const Duration _kTranslateTimeout = Duration(seconds: 45);

  static const String _kBoxName = 'subtitle_translations';

  // ── 偏好持久化（SharedPreferences，与截图目录等轻量键同款做法）──
  static const String _kPrefEnabled = 'subtitle_translation_enabled_v1';
  static const String _kPrefShowOriginal = 'subtitle_translation_show_original_v1';
  static const String _kPrefOcrFallback = 'subtitle_translation_ocr_fallback_v1';

  final VisionTranslationClient _client;

  /// 播放器控制器（attach 后可用；用于读 mpv 属性与截图）。
  dynamic _playerController;
  bool _attached = false;

  bool _enabled = false;
  bool _showOriginal = false;
  bool _ocrFallback = false;
  bool _prefsLoaded = false;

  String _targetLang = 'zh';
  bool _langLoaded = false;

  SubtitleTranslationState _state = const SubtitleTranslationState();

  /// 上次轮询到的字幕原文（去重：文本没变不重复翻译）。
  String _lastPolledText = '';

  DateTime _lastPollAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastOcrAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 进行中的翻译任务对应的原文（新句到来时排队，完成后立刻处理队首）。
  String? _inFlightText;
  String? _queuedText;

  /// 会话内译文缓存（lang|原文 → 译文）；Hive 为跨会话持久层。
  final Map<String, String> _memoryCache = <String, String>{};
  Box<dynamic>? _box;
  bool _boxInitTried = false;

  SubtitleTranslationState get state => _state;
  bool get enabled => _enabled;
  bool get showOriginal => _showOriginal;
  bool get ocrFallback => _ocrFallback;

  /// 绑定播放器控制器并恢复持久化开关（视频翻译开关跨会话记忆）。
  Future<void> attach(dynamic playerController) async {
    _playerController = playerController;
    _attached = true;
    await _loadPrefs();
    if (_enabled) {
      // 记忆为开启：进入播放页即恢复翻译。
      await _ensureLang();
      notifyListeners();
    }
  }

  void detach() {
    _attached = false;
    _playerController = null;
    _resetState();
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
      // 立即做一次 OCR（不等间隔）。
      await _maybeOcrTick(force: true);
    }
    notifyListeners();
  }

  Future<void> _ensureLang() async {
    if (_langLoaded) return;
    _targetLang =
        await NovelSummarySettings.instance.getMediaTranslationTargetLanguage();
    _langLoaded = true;
  }

  /// 播放进度回调（由播放页 [_onPositionChanged] 每帧转发）：
  /// 节流轮询 mpv 当前字幕文本；无字幕且开启 OCR 兜底时按间隔取帧识别。
  void onPositionTick(Duration position) {
    if (!_enabled || !_attached) return;
    final now = DateTime.now();
    if (now.difference(_lastPollAt) >= _kPollInterval) {
      _lastPollAt = now;
      unawaited(_pollSubtitle());
    }
    if (_ocrFallback &&
        _lastPolledText.isEmpty &&
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

  /// OCR 兜底：截取当前帧送视觉模型识别+翻译。
  Future<void> _maybeOcrTick({bool force = false}) async {
    final dynamic c = _playerController;
    if (c == null) return;
    if (!force && _inFlightText != null) return;
    try {
      final Uint8List? frame = await c.player.screenshot();
      if (frame == null || frame.isEmpty) return;
      final cfg = await _resolveConfig();
      if (cfg == null) return;
      await _ensureLang();
      final segments = await _client.recognizeImage(
        config: cfg,
        imageBytes: frame,
        mimeType: 'image/png',
        systemPrompt: VisionTranslationClient.videoOcrSystemPrompt(_targetLang),
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
      // OCR 失败静默（不打断播放）；仅在开启且从未有过结果时提示一次。
      if (_state.translatedText == null) {
        _state = SubtitleTranslationState(error: e.toString());
        notifyListeners();
      }
    }
  }

  /// 翻译一句（去重 / 缓存 / 排队）。
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
        throw Exception('未配置 AI 接口：请先在 设置 → AI 配置 中填写通用接口'
            '或视频翻译专用接口');
      }
      final result = await _client
          .translateBatch(
            config: cfg,
            targetLang: _targetLang,
            texts: <String>[text],
          )
          .timeout(_kTranslateTimeout);
      final translated = result.first.trim();
      _memoryCache[memKey] = translated;
      await _saveCached(text, translated);
      if (!_enabled) return;
      // 翻译期间用户已翻到新句：仅当仍是当前句时更新显示。
      if (_lastPolledText == text) {
        _state = SubtitleTranslationState(
            sourceText: text, translatedText: translated);
      }
    } on Object catch (e) {
      if (_lastPolledText == text) {
        _state = SubtitleTranslationState(
          sourceText: text,
          translatedText: _state.translatedText,
          error: e.toString(),
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

  // ─────────────────── Hive 持久缓存 ───────────────────

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
        jsonEncode(<String, dynamic>{'t': translated}),
      );
    } on Object {
      // 缓存写失败不影响显示。
    }
  }

  /// 剥离 ASS 内联标签（{\...}）与 HTML 标签。
  static String _stripAssTags(String s) {
    if (s.isEmpty) return s;
    var out = s.replaceAll(RegExp(r'\{\\[^}]*\}'), '');
    out = out.replaceAll(RegExp(r'<[^>]+>'), ' ');
    return out.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}

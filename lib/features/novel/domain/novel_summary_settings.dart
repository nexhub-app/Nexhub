import 'package:shared_preferences/shared_preferences.dart';

import 'novel_summary_service.dart';

/// 阅读速览（章节内容总结）的本地设置。
///
/// 从「单一配置」升级为「通用 + 功能级独立接口」的层级结构（需求：统一管理 AI 配置）：
/// - **通用配置**（default）：所有 AI 功能共享的兜底 baseUrl/apiKey/model；
/// - **功能级覆盖**：章节速览 / AI 配图 / 双语翻译 / 漫画翻译 / 视频字幕翻译
///   各自可配置独立接口（baseUrl/apiKey/model），某项留空时回落到通用配置。
///
/// 底层走 SharedPreferences（与现有弹幕凭据一致；API 密钥明文存本机，不外发）。
/// 旧的 `novel_overview_api_*` 键继续作为「通用配置」的存储，保证已有配置平滑迁移。
class NovelSummarySettings {
  static final NovelSummarySettings instance = NovelSummarySettings._();
  NovelSummarySettings._();

  // ── 通用配置（旧键保留，语义升级为 default）──
  static const String _kMode = 'novel_overview_mode_v1';
  static const String _kBase = 'novel_overview_api_base_v1';
  static const String _kKey = 'novel_overview_api_key_v1';
  static const String _kModel = 'novel_overview_api_model_v1';

  // ── 章节速览功能级接口（空 = 回落通用）──
  static const String _kSummaryBase = 'novel_summary_api_base_v1';
  static const String _kSummaryKey = 'novel_summary_api_key_v1';
  static const String _kSummaryModel = 'novel_summary_api_model_v1';

  // ── AI 配图功能级接口与选项 ──
  static const String _kIllBase = 'novel_illustration_api_base_v1';
  static const String _kIllKey = 'novel_illustration_api_key_v1';
  static const String _kIllModel = 'novel_illustration_api_model_v1';
  static const String _kIllModelName = 'novel_illustration_model_v1';
  static const String _kIllSize = 'novel_illustration_size_v1';

  // ── 双语/段落翻译功能级接口与选项 ──
  static const String _kTrBase = 'novel_translation_api_base_v1';
  static const String _kTrKey = 'novel_translation_api_key_v1';
  static const String _kTrModel = 'novel_translation_api_model_v1';
  static const String _kTrLang = 'novel_translation_lang_v1';
  static const String _kTrBatch = 'novel_translation_batch_v1';

  // ── 漫画翻译功能级接口与选项（视觉模型，留空回落通用）──
  static const String _kComicBase = 'comic_translation_api_base_v1';
  static const String _kComicKey = 'comic_translation_api_key_v1';
  static const String _kComicModel = 'comic_translation_api_model_v1';
  static const String _kComicLang = 'comic_translation_lang_v1';

  // ── 视频字幕翻译功能级接口与选项（留空回落通用）──
  static const String _kMediaBase = 'media_translation_api_base_v1';
  static const String _kMediaKey = 'media_translation_api_key_v1';
  static const String _kMediaModel = 'media_translation_api_model_v1';
  static const String _kMediaLang = 'media_translation_lang_v1';

  // ─────────────────── 速览模式 ───────────────────

  Future<NovelOverviewMode> getMode() async {
    final p = await SharedPreferences.getInstance();
    final v = p.getString(_kMode);
    return v == 'api' ? NovelOverviewMode.api : NovelOverviewMode.local;
  }

  Future<void> setMode(NovelOverviewMode mode) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kMode, mode == NovelOverviewMode.api ? 'api' : 'local');
  }

  // ─────────────────── 通用配置（默认兜底）───────────────────

  Future<NovelSummaryConfig> getDefaultConfig() async {
    final p = await SharedPreferences.getInstance();
    return _readConfig(p, _kBase, _kKey, _kModel);
  }

  /// 兼容别名：通用（默认）配置。
  Future<NovelSummaryConfig> getConfig() => getDefaultConfig();

  Future<void> setDefaultConfig(NovelSummaryConfig cfg) async {
    final p = await SharedPreferences.getInstance();
    await _writeConfig(p, _kBase, _kKey, _kModel, cfg);
  }

  /// 兼容别名：写通用（默认）配置。
  Future<void> saveConfig(NovelSummaryConfig cfg) => setDefaultConfig(cfg);

  // ─────────────────── 章节速览接口 ───────────────────

  /// 速览功能级配置；baseUrl 为空时回落通用配置。
  Future<NovelSummaryConfig> getSummaryConfig() async {
    final p = await SharedPreferences.getInstance();
    final specific = _readConfig(p, _kSummaryBase, _kSummaryKey, _kSummaryModel);
    if (specific.baseUrl.trim().isNotEmpty) return specific;
    return _readConfig(p, _kBase, _kKey, _kModel);
  }

  Future<void> saveSummaryConfig(NovelSummaryConfig cfg) async {
    final p = await SharedPreferences.getInstance();
    await _writeConfig(p, _kSummaryBase, _kSummaryKey, _kSummaryModel, cfg);
  }

  // ─────────────────── AI 配图接口与选项 ───────────────────

  /// 配图功能级配置；baseUrl 为空时回落通用配置。
  Future<NovelSummaryConfig> getIllustrationConfig() async {
    final p = await SharedPreferences.getInstance();
    final specific = _readConfig(p, _kIllBase, _kIllKey, _kIllModel);
    if (specific.baseUrl.trim().isNotEmpty) return specific;
    return _readConfig(p, _kBase, _kKey, _kModel);
  }

  Future<void> saveIllustrationConfig(NovelSummaryConfig cfg) async {
    final p = await SharedPreferences.getInstance();
    await _writeConfig(p, _kIllBase, _kIllKey, _kIllModel, cfg);
  }

  /// 配图生图模型（功能级；空 = 不发送 model 字段，由服务端默认）。
  Future<String> getIllustrationModel() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_kIllModelName) ?? '';
  }

  Future<void> saveIllustrationModel(String model) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kIllModelName, model.trim());
  }

  /// 配图尺寸（如 1024x1024）。
  Future<String> getIllustrationSize() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_kIllSize) ?? '1024x1024';
  }

  Future<void> saveIllustrationSize(String size) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kIllSize, size.trim().isEmpty ? '1024x1024' : size.trim());
  }

  // ─────────────────── 翻译接口与选项 ───────────────────

  /// 翻译功能级配置；baseUrl 为空时回落通用配置。
  Future<NovelSummaryConfig> getTranslationConfig() async {
    final p = await SharedPreferences.getInstance();
    final specific = _readConfig(p, _kTrBase, _kTrKey, _kTrModel);
    if (specific.baseUrl.trim().isNotEmpty) return specific;
    return _readConfig(p, _kBase, _kKey, _kModel);
  }

  Future<void> saveTranslationConfig(NovelSummaryConfig cfg) async {
    final p = await SharedPreferences.getInstance();
    await _writeConfig(p, _kTrBase, _kTrKey, _kTrModel, cfg);
  }

  /// 翻译目标语言（提示词用语，默认中文）。
  Future<String> getTranslationTargetLanguage() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_kTrLang) ?? '中文';
  }

  Future<void> saveTranslationTargetLanguage(String lang) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kTrLang, lang.trim().isEmpty ? '中文' : lang.trim());
  }

  /// 翻译分块大小（段/块，默认 12）。
  Future<int> getTranslationBatchSize() async {
    final p = await SharedPreferences.getInstance();
    return p.getInt(_kTrBatch) ?? 12;
  }

  Future<void> saveTranslationBatchSize(int size) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kTrBatch, size <= 0 ? 12 : size);
  }

  // ─────────────────── 漫画翻译接口 ───────────────────

  /// 漫画翻译功能级配置（视觉模型）；baseUrl 为空时回落通用配置。
  Future<NovelSummaryConfig> getComicTranslationConfig() async {
    final p = await SharedPreferences.getInstance();
    final specific = _readConfig(p, _kComicBase, _kComicKey, _kComicModel);
    if (specific.baseUrl.trim().isNotEmpty) return specific;
    return _readConfig(p, _kBase, _kKey, _kModel);
  }

  Future<void> saveComicTranslationConfig(NovelSummaryConfig cfg) async {
    final p = await SharedPreferences.getInstance();
    await _writeConfig(p, _kComicBase, _kComicKey, _kComicModel, cfg);
  }

  /// 漫画翻译目标语言（提示词用语；空回落小说翻译的目标语言）。
  Future<String> getComicTranslationTargetLanguage() async {
    final p = await SharedPreferences.getInstance();
    final v = p.getString(_kComicLang);
    if (v != null && v.trim().isNotEmpty) return v.trim();
    return getTranslationTargetLanguage();
  }

  Future<void> saveComicTranslationTargetLanguage(String lang) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kComicLang, lang.trim());
  }

  // ─────────────────── 视频字幕翻译接口 ───────────────────

  /// 视频字幕翻译功能级配置；baseUrl 为空时回落通用配置。
  Future<NovelSummaryConfig> getMediaTranslationConfig() async {
    final p = await SharedPreferences.getInstance();
    final specific = _readConfig(p, _kMediaBase, _kMediaKey, _kMediaModel);
    if (specific.baseUrl.trim().isNotEmpty) return specific;
    return _readConfig(p, _kBase, _kKey, _kModel);
  }

  Future<void> saveMediaTranslationConfig(NovelSummaryConfig cfg) async {
    final p = await SharedPreferences.getInstance();
    await _writeConfig(p, _kMediaBase, _kMediaKey, _kMediaModel, cfg);
  }

  /// 视频字幕翻译目标语言（提示词用语；空回落小说翻译的目标语言）。
  Future<String> getMediaTranslationTargetLanguage() async {
    final p = await SharedPreferences.getInstance();
    final v = p.getString(_kMediaLang);
    if (v != null && v.trim().isNotEmpty) return v.trim();
    return getTranslationTargetLanguage();
  }

  Future<void> saveMediaTranslationTargetLanguage(String lang) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kMediaLang, lang.trim());
  }

  // ─────────────────── 内部工具 ───────────────────

  static NovelSummaryConfig _readConfig(
    SharedPreferences p,
    String baseKey,
    String keyKey,
    String modelKey,
  ) =>
      NovelSummaryConfig(
        baseUrl: p.getString(baseKey) ?? '',
        apiKey: p.getString(keyKey) ?? '',
        model: p.getString(modelKey) ?? '',
      );

  static Future<void> _writeConfig(
    SharedPreferences p,
    String baseKey,
    String keyKey,
    String modelKey,
    NovelSummaryConfig cfg,
  ) async {
    await p.setString(baseKey, cfg.baseUrl);
    await p.setString(keyKey, cfg.apiKey);
    await p.setString(modelKey, cfg.model);
  }
}

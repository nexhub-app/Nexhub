/// AI 配置页：统一管理 AI 接口与智能功能配置。
///
/// 层级结构（需求：统一管理 AI 的配置）：
/// - **通用 API 配置**：所有 AI 功能的兜底 baseUrl/apiKey/model；
/// - **章节速览**：速览方式（离线 / 云端 AI）+ 独立接口（留空回落通用）；
/// - **AI 配图**：章节配图独立接口 + 生图模型与尺寸（留空回落通用）；
/// - **双语/段落翻译**：翻译独立接口 + 目标语言 + 分块大小（留空回落通用）；
/// - **漫画翻译**：视觉 OCR+翻译独立接口 + 目标语言（留空回落通用）；
/// - **视频字幕翻译**：实时字幕翻译独立接口 + 目标语言（留空回落通用）。
///
/// 存储走 [NovelSummarySettings]（SharedPreferences），与阅读器速览面板、
/// 配图 / 翻译服务共享同一份配置。页面 body 用 [SettingsAutoScroll] 包裹，
/// 供设置搜索以 `ai.*` / `translation.*` 滚动定位到具体卡片。
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:nexhub/core/ai/prompt_builder.dart';
import 'package:nexhub/core/ai/translation_options_store.dart';
import 'package:nexhub/core/theme/app_tokens.dart';
import 'package:nexhub/core/widgets/app_animations.dart';
import 'package:nexhub/core/widgets/app_alert_dialog.dart';
import 'package:nexhub/core/comic/comic_translation_manager.dart';
import 'package:nexhub/core/novel/novel_translation_manager.dart';
import 'package:nexhub/core/player/subtitle_translation_controller.dart';
import '../../novel/domain/novel_summary_service.dart';
import '../../novel/domain/novel_summary_settings.dart';
import 'translation_glossary_screen.dart';
import 'translation_review_screen.dart';
import 'widgets/settings_widgets.dart';
import 'widgets/settings_search_target.dart';

/// AI 配图尺寸档位。
const List<String> _kIllustrationSizes = <String>[
  '512x512',
  '768x768',
  '1024x1024',
  '1536x1536',
];

class SettingsAiScreen extends StatefulWidget {
  const SettingsAiScreen({super.key});

  @override
  State<SettingsAiScreen> createState() => _SettingsAiScreenState();
}

class _SettingsAiScreenState extends State<SettingsAiScreen> {
  final NovelSummarySettings _settings = NovelSummarySettings.instance;

  // 通用配置
  final _commonBaseCtrl = TextEditingController();
  final _commonKeyCtrl = TextEditingController();
  final _commonModelCtrl = TextEditingController();

  // 章节速览
  final _summaryBaseCtrl = TextEditingController();
  final _summaryKeyCtrl = TextEditingController();
  final _summaryModelCtrl = TextEditingController();
  NovelOverviewMode _summaryMode = NovelOverviewMode.local;

  // AI 配图
  final _illBaseCtrl = TextEditingController();
  final _illKeyCtrl = TextEditingController();
  final _illModelCtrl = TextEditingController();
  final _illModelNameCtrl = TextEditingController();
  String _illSize = '1024x1024';

  // 双语/段落翻译
  final _trBaseCtrl = TextEditingController();
  final _trKeyCtrl = TextEditingController();
  final _trModelCtrl = TextEditingController();
  final _trLangCtrl = TextEditingController();
  double _trBatch = 12;
  TranslationStyle _trStyle = TranslationStyle.standard;
  bool _trCot = false;
  bool _trSubtitleLightweight = true;
  bool _trPolish = false;
  String _trExportLayout = 'translationFirst';

  final TranslationOptionsStore _trOptions = TranslationOptionsStore();

  bool _comicImporting = false;

  // F9 备用端点（主接口故障时自动切换；留空 = 不启用）。
  final _trBaseBakCtrl = TextEditingController();
  final _trKeyBakCtrl = TextEditingController();
  final _trModelBakCtrl = TextEditingController();
  final _comicBaseBakCtrl = TextEditingController();
  final _comicKeyBakCtrl = TextEditingController();
  final _comicModelBakCtrl = TextEditingController();
  final _mediaBaseBakCtrl = TextEditingController();
  final _mediaKeyBakCtrl = TextEditingController();
  final _mediaModelBakCtrl = TextEditingController();

  // 漫画翻译（视觉 OCR+翻译）
  final _comicBaseCtrl = TextEditingController();
  final _comicKeyCtrl = TextEditingController();
  final _comicModelCtrl = TextEditingController();
  final _comicLangCtrl = TextEditingController();

  // 视频字幕翻译
  final _mediaBaseCtrl = TextEditingController();
  final _mediaKeyCtrl = TextEditingController();
  final _mediaModelCtrl = TextEditingController();
  final _mediaLangCtrl = TextEditingController();

  // 翻译缓存（B5）：三个 box 的当前条数（清除后刷新）。
  int _novelCacheCount = 0;
  int _comicCacheCount = 0;
  int _subtitleCacheCount = 0;
  bool _clearingCache = false;

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 刷新三个翻译缓存的条数展示（B5）。
  void _refreshCacheCounts() {
    _novelCacheCount = NovelTranslationManager().count();
    _comicCacheCount = ComicTranslationManager().count();
    _subtitleCacheCount = SubtitleTranslationController().cacheCount();
  }

  /// 一键清空三个翻译缓存（B5，二次确认后执行）。
  Future<void> _clearTranslationCaches(AppLocalizations l10n) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AppAlertDialog(
        title: Text(l10n.translationCacheClear),
        content: Text(l10n.translationCacheClearConfirm),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.confirm),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _clearingCache = true);
    try {
      await NovelTranslationManager().clearAll();
      await ComicTranslationManager().clearAll();
      await SubtitleTranslationController().clearCache();
      if (!mounted) return;
      setState(_refreshCacheCounts);
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.translationCacheCleared)),
      );
    } finally {
      if (mounted) setState(() => _clearingCache = false);
    }
  }

  /// F10：导出全部漫画翻译缓存为 translations.json 并分享。
  Future<void> _exportComicTranslations(AppLocalizations l10n) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final json = await ComicTranslationManager().exportJson();
      final dir = await getApplicationDocumentsDirectory();
      final file = File(
          '$dir/nexhub/translations_comic_${DateTime.now().millisecondsSinceEpoch}.json');
      await file.create(recursive: true);
      await file.writeAsString(json);
      await Share.shareXFiles(<XFile>[XFile(file.path)]);
    } on Object catch (e) {
      messenger?.showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    }
  }

  /// F10：导入漫画翻译缓存（合并：已存在键跳过；导入后命中缓存不再请求）。
  Future<void> _importComicTranslations(AppLocalizations l10n) async {
    if (_comicImporting) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['json', 'txt'],
    );
    final path = result?.files.single.path;
    if (path == null || !mounted) return;
    setState(() => _comicImporting = true);
    try {
      final raw = await File(path).readAsString();
      final (imported, skipped) =
          await ComicTranslationManager().importJson(raw);
      if (!mounted) return;
      messenger?.showSnackBar(
        SnackBar(content: Text(l10n.comicTranslationImportOk(imported, skipped))),
      );
    } on Object {
      if (!mounted) return;
      messenger?.showSnackBar(
        SnackBar(content: Text(l10n.comicTranslationImportFail)),
      );
    } finally {
      if (mounted) setState(() => _comicImporting = false);
    }
  }

  Future<void> _load() async {
    final defaultCfg = await _settings.getDefaultConfig();
    final summaryCfg = await _settings.getSummaryConfig();
    // 只回显速览「功能级」填写的内容：与通用一致时留空（表示未单独配置）。
    final sBase =
        summaryCfg.baseUrl == defaultCfg.baseUrl ? '' : summaryCfg.baseUrl;
    final sKey =
        summaryCfg.apiKey == defaultCfg.apiKey ? '' : summaryCfg.apiKey;
    final sModel = summaryCfg.model == defaultCfg.model ? '' : summaryCfg.model;
    final illCfg = await _settings.getIllustrationConfig();
    final iBase = illCfg.baseUrl == defaultCfg.baseUrl ? '' : illCfg.baseUrl;
    final iKey = illCfg.apiKey == defaultCfg.apiKey ? '' : illCfg.apiKey;
    final iModel = illCfg.model == defaultCfg.model ? '' : illCfg.model;
    final mode = await _settings.getMode();
    final trCfg = await _settings.getTranslationConfig();
    final tBase = trCfg.baseUrl == defaultCfg.baseUrl ? '' : trCfg.baseUrl;
    final tKey = trCfg.apiKey == defaultCfg.apiKey ? '' : trCfg.apiKey;
    final tModel = trCfg.model == defaultCfg.model ? '' : trCfg.model;
    final trLang = await _settings.getTranslationTargetLanguage();
    final trBatch = await _settings.getTranslationBatchSize();
    final trStyle = await _trOptions.getStyle();
    final trCot = await _trOptions.getCotEnabled();
    final trLightweight = await _trOptions.getSubtitleLightweight();
    final trPolish = await _trOptions.getPolishEnabled();
    final trExportLayout = await _trOptions.getNovelExportLayout();
    // 漫画翻译 / 视频翻译：同样只回显功能级填写内容（与通用一致时留空）。
    final comicCfg = await _settings.getComicTranslationConfig();
    final cBase = comicCfg.baseUrl == defaultCfg.baseUrl ? '' : comicCfg.baseUrl;
    final cKey = comicCfg.apiKey == defaultCfg.apiKey ? '' : comicCfg.apiKey;
    final cModel = comicCfg.model == defaultCfg.model ? '' : comicCfg.model;
    final comicLang = await _settings.getComicTranslationTargetLanguage();
    final mediaCfg = await _settings.getMediaTranslationConfig();
    final mBase = mediaCfg.baseUrl == defaultCfg.baseUrl ? '' : mediaCfg.baseUrl;
    final mKey = mediaCfg.apiKey == defaultCfg.apiKey ? '' : mediaCfg.apiKey;
    final mModel = mediaCfg.model == defaultCfg.model ? '' : mediaCfg.model;
    final mediaLang = await _settings.getMediaTranslationTargetLanguage();
    // F9 备用端点回显（仅回显功能级备用；与主端点相同则留空）。
    final trBak = await _settings.getTranslationBackupConfig();
    final comicBak = await _settings.getComicTranslationBackupConfig();
    final mediaBak = await _settings.getMediaTranslationBackupConfig();

    if (!mounted) return;
    setState(() {
      _commonBaseCtrl.text = defaultCfg.baseUrl;
      _commonKeyCtrl.text = defaultCfg.apiKey;
      _commonModelCtrl.text = defaultCfg.model;
      _refreshCacheCounts();

      _summaryBaseCtrl.text = sBase;
      _summaryKeyCtrl.text = sKey;
      _summaryModelCtrl.text = sModel;
      _summaryMode = mode;

      _illBaseCtrl.text = iBase;
      _illKeyCtrl.text = iKey;
      _illModelCtrl.text = iModel;

      _trBaseCtrl.text = tBase;
      _trKeyCtrl.text = tKey;
      _trModelCtrl.text = tModel;
      _trLangCtrl.text = trLang;
      _trBatch = trBatch.toDouble();
      _trStyle = trStyle;
      _trCot = trCot;
      _trSubtitleLightweight = trLightweight;
      _trPolish = trPolish;
      _trExportLayout = trExportLayout;

      _comicBaseCtrl.text = cBase;
      _comicKeyCtrl.text = cKey;
      _comicModelCtrl.text = cModel;
      _comicLangCtrl.text = comicLang;

      _mediaBaseCtrl.text = mBase;
      _mediaKeyCtrl.text = mKey;
      _mediaModelCtrl.text = mModel;
      _mediaLangCtrl.text = mediaLang;

      _trBaseBakCtrl.text = trBak.baseUrl == trCfg.baseUrl ? '' : trBak.baseUrl;
      _trKeyBakCtrl.text = trBak.apiKey == trCfg.apiKey ? '' : trBak.apiKey;
      _trModelBakCtrl.text = trBak.model == trCfg.model ? '' : trBak.model;
      _comicBaseBakCtrl.text =
          comicBak.baseUrl == comicCfg.baseUrl ? '' : comicBak.baseUrl;
      _comicKeyBakCtrl.text = comicBak.apiKey == comicCfg.apiKey ? '' : comicBak.apiKey;
      _comicModelBakCtrl.text = comicBak.model == comicCfg.model ? '' : comicBak.model;
      _mediaBaseBakCtrl.text = mediaBak.baseUrl == mediaCfg.baseUrl ? '' : mediaBak.baseUrl;
      _mediaKeyBakCtrl.text = mediaBak.apiKey == mediaCfg.apiKey ? '' : mediaBak.apiKey;
      _mediaModelBakCtrl.text = mediaBak.model == mediaCfg.model ? '' : mediaBak.model;
    });
    // 配图模型与尺寸单独加载（避免阻塞首帧）。
    final illModel = await _settings.getIllustrationModel();
    final illSize = await _settings.getIllustrationSize();
    if (!mounted) return;
    setState(() {
      _illModelNameCtrl.text = illModel;
      _illSize = illSize;
    });
  }

  @override
  void dispose() {
    _commonBaseCtrl.dispose();
    _commonKeyCtrl.dispose();
    _commonModelCtrl.dispose();
    _summaryBaseCtrl.dispose();
    _summaryKeyCtrl.dispose();
    _summaryModelCtrl.dispose();
    _illBaseCtrl.dispose();
    _illKeyCtrl.dispose();
    _illModelCtrl.dispose();
    _illModelNameCtrl.dispose();
    _trBaseCtrl.dispose();
    _trKeyCtrl.dispose();
    _trModelCtrl.dispose();
    _trLangCtrl.dispose();
    _comicBaseCtrl.dispose();
    _comicKeyCtrl.dispose();
    _comicModelCtrl.dispose();
    _comicLangCtrl.dispose();
    _mediaBaseCtrl.dispose();
    _mediaKeyCtrl.dispose();
    _mediaModelCtrl.dispose();
    _mediaLangCtrl.dispose();
    _trBaseBakCtrl.dispose();
    _trKeyBakCtrl.dispose();
    _trModelBakCtrl.dispose();
    _comicBaseBakCtrl.dispose();
    _comicKeyBakCtrl.dispose();
    _comicModelBakCtrl.dispose();
    _mediaBaseBakCtrl.dispose();
    _mediaKeyBakCtrl.dispose();
    _mediaModelBakCtrl.dispose();
    super.dispose();
  }

  Future<void> _save(AppLocalizations l10n) async {
    setState(() => _saving = true);
    try {
      await _settings.setDefaultConfig(NovelSummaryConfig(
        baseUrl: _commonBaseCtrl.text.trim(),
        apiKey: _commonKeyCtrl.text.trim(),
        model: _commonModelCtrl.text.trim(),
      ));
      await _settings.saveSummaryConfig(NovelSummaryConfig(
        baseUrl: _summaryBaseCtrl.text.trim(),
        apiKey: _summaryKeyCtrl.text.trim(),
        model: _summaryModelCtrl.text.trim(),
      ));
      await _settings.setMode(_summaryMode);
      await _settings.saveIllustrationConfig(NovelSummaryConfig(
        baseUrl: _illBaseCtrl.text.trim(),
        apiKey: _illKeyCtrl.text.trim(),
        model: _illModelCtrl.text.trim(),
      ));
      await _settings.saveIllustrationModel(_illModelNameCtrl.text.trim());
      await _settings.saveIllustrationSize(_illSize);
      await _settings.saveTranslationConfig(NovelSummaryConfig(
        baseUrl: _trBaseCtrl.text.trim(),
        apiKey: _trKeyCtrl.text.trim(),
        model: _trModelCtrl.text.trim(),
      ));
      await _settings.saveTranslationTargetLanguage(_trLangCtrl.text.trim());
      await _settings.saveTranslationBatchSize(_trBatch.round());
      await _trOptions.setStyle(_trStyle);
      await _trOptions.setCotEnabled(_trCot);
      await _trOptions.setSubtitleLightweight(_trSubtitleLightweight);
      await _trOptions.setPolishEnabled(_trPolish);
      await _trOptions.setNovelExportLayout(_trExportLayout);
      await _settings.saveComicTranslationConfig(NovelSummaryConfig(
        baseUrl: _comicBaseCtrl.text.trim(),
        apiKey: _comicKeyCtrl.text.trim(),
        model: _comicModelCtrl.text.trim(),
      ));
      await _settings.saveComicTranslationTargetLanguage(
          _comicLangCtrl.text.trim());
      await _settings.saveMediaTranslationConfig(NovelSummaryConfig(
        baseUrl: _mediaBaseCtrl.text.trim(),
        apiKey: _mediaKeyCtrl.text.trim(),
        model: _mediaModelCtrl.text.trim(),
      ));
      await _settings.saveMediaTranslationTargetLanguage(
          _mediaLangCtrl.text.trim());
      // F9：备用端点（与主端点相同视为未启用 → 存空）。
      String orEmptyIfSame(String backup, String primary) =>
          backup.trim() == primary.trim() ? '' : backup.trim();
      await _settings.saveTranslationBackupConfig(NovelSummaryConfig(
        baseUrl: orEmptyIfSame(_trBaseBakCtrl.text, _trBaseCtrl.text),
        apiKey: orEmptyIfSame(_trKeyBakCtrl.text, _trKeyCtrl.text),
        model: orEmptyIfSame(_trModelBakCtrl.text, _trModelCtrl.text),
      ));
      await _settings.saveComicTranslationBackupConfig(NovelSummaryConfig(
        baseUrl: orEmptyIfSame(_comicBaseBakCtrl.text, _comicBaseCtrl.text),
        apiKey: orEmptyIfSame(_comicKeyBakCtrl.text, _comicKeyCtrl.text),
        model: orEmptyIfSame(_comicModelBakCtrl.text, _comicModelCtrl.text),
      ));
      await _settings.saveMediaTranslationBackupConfig(NovelSummaryConfig(
        baseUrl: orEmptyIfSame(_mediaBaseBakCtrl.text, _mediaBaseCtrl.text),
        apiKey: orEmptyIfSame(_mediaKeyBakCtrl.text, _mediaKeyCtrl.text),
        model: orEmptyIfSame(_mediaModelBakCtrl.text, _mediaModelCtrl.text),
      ));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.aiSaved)),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AppShrinkTitleScaffold(
      title: Text(l10n.aiSettingsTitle),
      body: SettingsAutoScroll(
        child: ListView(
          padding: const EdgeInsets.all(AppTokens.spaceLg),
          children: <Widget>[
            SettingsCard(
              key: const ValueKey<String>('ai.common'),
              title: l10n.aiCommonApiSection,
              description: l10n.aiCommonApiDesc,
              children: <Widget>[
                _ApiFields(
                  baseCtrl: _commonBaseCtrl,
                  keyCtrl: _commonKeyCtrl,
                  modelCtrl: _commonModelCtrl,
                  baseHint: l10n.aiBaseUrlHint,
                  modelHint: l10n.aiModelHint,
                ),
              ],
            ),
            SettingsCard(
              key: const ValueKey<String>('ai.summary'),
              title: l10n.aiSummarySection,
              description: l10n.aiSummaryDesc,
              children: <Widget>[
                SettingsSegmentedTile<NovelOverviewMode>(
                  title: l10n.aiSummaryMode,
                  segments: <ButtonSegment<NovelOverviewMode>>[
                    ButtonSegment<NovelOverviewMode>(
                      value: NovelOverviewMode.local,
                      label: Text(l10n.overviewModeLocal),
                    ),
                    ButtonSegment<NovelOverviewMode>(
                      value: NovelOverviewMode.api,
                      label: Text(l10n.overviewModeApi),
                    ),
                  ],
                  selected: <NovelOverviewMode>{_summaryMode},
                  onSelectionChanged: (s) =>
                      setState(() => _summaryMode = s.first),
                ),
                const SizedBox(height: AppTokens.spaceSm),
                Text(
                  l10n.aiOverrideHint,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Theme.of(context).colorScheme.outline),
                ),
                const SizedBox(height: AppTokens.spaceSm),
                _ApiFields(
                  baseCtrl: _summaryBaseCtrl,
                  keyCtrl: _summaryKeyCtrl,
                  modelCtrl: _summaryModelCtrl,
                  baseHint: l10n.aiBaseUrlHint,
                  modelHint: l10n.aiModelHint,
                ),
              ],
            ),
            SettingsCard(
              key: const ValueKey<String>('ai.illustration'),
              title: l10n.aiIllustrationSection,
              description: l10n.aiIllustrationDesc,
              children: <Widget>[
                Text(
                  l10n.aiOverrideHint,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Theme.of(context).colorScheme.outline),
                ),
                const SizedBox(height: AppTokens.spaceSm),
                _ApiFields(
                  baseCtrl: _illBaseCtrl,
                  keyCtrl: _illKeyCtrl,
                  modelCtrl: _illModelCtrl,
                  baseHint: l10n.aiBaseUrlHint,
                  modelHint: l10n.aiModelHint,
                ),
                const SizedBox(height: AppTokens.spaceMd),
                TextField(
                  controller: _illModelNameCtrl,
                  decoration: InputDecoration(
                    labelText: l10n.aiIllustrationModel,
                    hintText: l10n.aiIllustrationModelHint,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: AppTokens.spaceMd),
                SettingsChoiceChips<String>(
                  title: l10n.aiIllustrationSize,
                  selected: _illSize,
                  onSelected: (s) => setState(() => _illSize = s),
                  options: <SettingsChoiceChipData<String>>[
                    for (final s in _kIllustrationSizes)
                      SettingsChoiceChipData<String>(value: s, label: s),
                  ],
                ),
              ],
            ),
            SettingsCard(
              key: const ValueKey<String>('translation.api'),
              title: l10n.translationSettingsTitle,
              description: l10n.translationApiDesc,
              children: <Widget>[
                Text(
                  l10n.aiOverrideHint,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Theme.of(context).colorScheme.outline),
                ),
                const SizedBox(height: AppTokens.spaceSm),
                _ApiFields(
                  baseCtrl: _trBaseCtrl,
                  keyCtrl: _trKeyCtrl,
                  modelCtrl: _trModelCtrl,
                  baseHint: l10n.aiBaseUrlHint,
                  modelHint: l10n.aiModelHint,
                ),
                const SizedBox(height: AppTokens.spaceMd),
                TextField(
                  controller: _trLangCtrl,
                  decoration: InputDecoration(
                    labelText: l10n.translationTargetLang,
                    hintText: l10n.translationTargetLangHint,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: AppTokens.spaceMd),
                SettingsSliderTile(
                  key: const ValueKey<String>('ai.translationBatchSize'),
                  label: l10n.translationBatchSize,
                  value: _trBatch,
                  min: 4,
                  max: 40,
                  divisions: 36,
                  display: '${_trBatch.round()}',
                  onChanged: (v) => setState(() => _trBatch = v),
                ),
                Text(
                  l10n.translationBatchHint,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Theme.of(context).colorScheme.outline),
                ),
                const SizedBox(height: AppTokens.spaceMd),
                // F8：翻译风格预设（三个模块共用）。
                SettingsChoiceChips<TranslationStyle>(
                  title: l10n.translationStyle,
                  selected: _trStyle,
                  onSelected: (s) => setState(() => _trStyle = s),
                  options: <SettingsChoiceChipData<TranslationStyle>>[
                    SettingsChoiceChipData<TranslationStyle>(
                      value: TranslationStyle.standard,
                      label: l10n.translationStyleStandard,
                    ),
                    SettingsChoiceChipData<TranslationStyle>(
                      value: TranslationStyle.colloquial,
                      label: l10n.translationStyleColloquial,
                    ),
                    SettingsChoiceChipData<TranslationStyle>(
                      value: TranslationStyle.elegant,
                      label: l10n.translationStyleElegant,
                    ),
                    SettingsChoiceChipData<TranslationStyle>(
                      value: TranslationStyle.internet,
                      label: l10n.translationStyleInternet,
                    ),
                  ],
                ),
                // F8：思维链（CoT）开关——默认关闭控成本。
                SettingsSwitchTile(
                  title: l10n.translationCot,
                  subtitle: l10n.translationCotHint,
                  value: _trCot,
                  onChanged: (v) => setState(() => _trCot = v),
                ),
                // F8：字幕轻量输出（无编号逐行，省 token）。
                SettingsSwitchTile(
                  title: l10n.translationSubtitleLightweight,
                  subtitle: l10n.translationSubtitleLightweightHint,
                  value: _trSubtitleLightweight,
                  onChanged: (v) =>
                      setState(() => _trSubtitleLightweight = v),
                ),
                const SizedBox(height: AppTokens.spaceMd),
                // F1：术语表编辑器入口。
                OutlinedButton.icon(
                  onPressed: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute<void>(
                          builder: (_) => const TranslationGlossaryScreen()),
                    );
                  },
                  icon: const Icon(Icons.menu_book_outlined),
                  label: Text(l10n.glossaryOpen),
                ),
                const SizedBox(height: AppTokens.spaceSm),
                OutlinedButton.icon(
                  onPressed: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute<void>(
                          builder: (_) => const TranslationReviewScreen()),
                    );
                  },
                  icon: const Icon(Icons.fact_check_outlined),
                  label: Text(l10n.reviewOpen),
                ),
                const SizedBox(height: AppTokens.spaceMd),
                // F5：润色功能开关（默认关闭，逐章显式触发控成本）。
                SettingsSwitchTile(
                  title: l10n.translationPolish,
                  subtitle: l10n.translationPolishHint,
                  value: _trPolish,
                  onChanged: (v) => setState(() => _trPolish = v),
                ),
                const SizedBox(height: AppTokens.spaceMd),
                // F10：小说译文附录排版开关。
                SettingsChoiceChips<String>(
                  title: l10n.translationExportLayout,
                  selected: _trExportLayout,
                  onSelected: (s) => setState(() => _trExportLayout = s),
                  options: <SettingsChoiceChipData<String>>[
                    SettingsChoiceChipData<String>(
                      value: 'translationFirst',
                      label: l10n.translationLayoutTranslationFirst,
                    ),
                    SettingsChoiceChipData<String>(
                      value: 'sourceFirst',
                      label: l10n.translationLayoutSourceFirst,
                    ),
                    SettingsChoiceChipData<String>(
                      value: 'bilingual',
                      label: l10n.translationLayoutBilingual,
                    ),
                  ],
                ),
                _BackupFields(
                  baseCtrl: _trBaseBakCtrl,
                  keyCtrl: _trKeyBakCtrl,
                  modelCtrl: _trModelBakCtrl,
                ),
              ],
            ),
            SettingsCard(
              key: const ValueKey<String>('ai.comicTranslation'),
              title: l10n.aiComicTranslationSection,
              description: l10n.aiComicTranslationDesc,
              children: <Widget>[
                Text(
                  l10n.aiOverrideHint,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Theme.of(context).colorScheme.outline),
                ),
                const SizedBox(height: AppTokens.spaceSm),
                _ApiFields(
                  baseCtrl: _comicBaseCtrl,
                  keyCtrl: _comicKeyCtrl,
                  modelCtrl: _comicModelCtrl,
                  baseHint: l10n.aiBaseUrlHint,
                  modelHint: l10n.aiComicModelHint,
                ),
                const SizedBox(height: AppTokens.spaceMd),
                TextField(
                  controller: _comicLangCtrl,
                  decoration: InputDecoration(
                    labelText: l10n.translationTargetLang,
                    hintText: l10n.translationTargetLangHint,
                    border: const OutlineInputBorder(),
                  ),
                ),
                _BackupFields(
                  baseCtrl: _comicBaseBakCtrl,
                  keyCtrl: _comicKeyBakCtrl,
                  modelCtrl: _comicModelBakCtrl,
                ),
                const SizedBox(height: AppTokens.spaceMd),
                // F10：翻译数据导出/导入（跨设备复用，不再重复计费）。
                Wrap(
                  spacing: AppTokens.spaceSm,
                  runSpacing: AppTokens.spaceXs,
                  children: <Widget>[
                    OutlinedButton.icon(
                      onPressed: () => _exportComicTranslations(l10n),
                      icon: const Icon(Icons.ios_share, size: 16),
                      label: Text(l10n.comicTranslationExport),
                    ),
                    OutlinedButton.icon(
                      onPressed: _comicImporting
                          ? null
                          : () => _importComicTranslations(l10n),
                      icon: _comicImporting
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2))
                          : const Icon(Icons.file_download_outlined,
                              size: 16),
                      label: Text(l10n.comicTranslationImport),
                    ),
                  ],
                ),
              ],
            ),
            SettingsCard(
              key: const ValueKey<String>('ai.mediaTranslation'),
              title: l10n.aiMediaTranslationSection,
              description: l10n.aiMediaTranslationDesc,
              children: <Widget>[
                Text(
                  l10n.aiOverrideHint,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Theme.of(context).colorScheme.outline),
                ),
                const SizedBox(height: AppTokens.spaceSm),
                _ApiFields(
                  baseCtrl: _mediaBaseCtrl,
                  keyCtrl: _mediaKeyCtrl,
                  modelCtrl: _mediaModelCtrl,
                  baseHint: l10n.aiBaseUrlHint,
                  modelHint: l10n.aiModelHint,
                ),
                const SizedBox(height: AppTokens.spaceMd),
                TextField(
                  controller: _mediaLangCtrl,
                  decoration: InputDecoration(
                    labelText: l10n.translationTargetLang,
                    hintText: l10n.translationTargetLangHint,
                    border: const OutlineInputBorder(),
                  ),
                ),
                _BackupFields(
                  baseCtrl: _mediaBaseBakCtrl,
                  keyCtrl: _mediaKeyBakCtrl,
                  modelCtrl: _mediaModelBakCtrl,
                ),
              ],
            ),
            SettingsCard(
              key: const ValueKey<String>('translation.cache'),
              title: l10n.translationCacheTitle,
              description: l10n.translationCacheDesc,
              children: <Widget>[
                _cacheCountTile(l10n.translationCacheNovel, _novelCacheCount),
                _cacheCountTile(l10n.translationCacheComic, _comicCacheCount),
                _cacheCountTile(
                    l10n.translationCacheSubtitle, _subtitleCacheCount),
                const SizedBox(height: AppTokens.spaceMd),
                FilledButton.tonalIcon(
                  onPressed: _clearingCache
                      ? null
                      : () => _clearTranslationCaches(l10n),
                  icon: _clearingCache
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child:
                              CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.delete_sweep_outlined),
                  label: Text(l10n.translationCacheClear),
                ),
              ],
            ),
            const SizedBox(height: AppTokens.spaceMd),
            FilledButton.icon(
              onPressed: _saving ? null : () => _save(l10n),
              icon: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.save),
              label: Text(l10n.save),
            ),
            const SizedBox(height: AppTokens.spaceXl),
          ],
        ),
      ),
    );
  }

  /// 缓存条数行（分组名 + 当前条数）。
  Widget _cacheCountTile(String label, int count) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppTokens.spaceXs),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          Text(label),
          Text(
            l10n.translationCacheEntries(count),
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Theme.of(context).colorScheme.outline),
          ),
        ],
      ),
    );
  }
}

/// baseUrl / apiKey / model 三行接口输入组。
class _ApiFields extends StatelessWidget {
  final TextEditingController baseCtrl;
  final TextEditingController keyCtrl;
  final TextEditingController modelCtrl;
  final String baseHint;
  final String modelHint;

  const _ApiFields({
    required this.baseCtrl,
    required this.keyCtrl,
    required this.modelCtrl,
    required this.baseHint,
    required this.modelHint,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        TextField(
          controller: baseCtrl,
          decoration: InputDecoration(
            labelText: l10n.aiBaseUrl,
            hintText: baseHint,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: AppTokens.spaceSm),
        TextField(
          controller: keyCtrl,
          obscureText: true,
          decoration: InputDecoration(
            labelText: l10n.aiApiKey,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: AppTokens.spaceSm),
        TextField(
          controller: modelCtrl,
          decoration: InputDecoration(
            labelText: l10n.aiModel,
            hintText: modelHint,
            border: const OutlineInputBorder(),
          ),
        ),
      ],
    );
  }
}

/// F9 备用接口输入组：默认折叠，展开后填写备用 baseUrl / key / model。
class _BackupFields extends StatefulWidget {
  final TextEditingController baseCtrl;
  final TextEditingController keyCtrl;
  final TextEditingController modelCtrl;

  const _BackupFields({
    required this.baseCtrl,
    required this.keyCtrl,
    required this.modelCtrl,
  });

  @override
  State<_BackupFields> createState() => _BackupFieldsState();
}

class _BackupFieldsState extends State<_BackupFields> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        TextButton.icon(
          onPressed: () => setState(() => _expanded = !_expanded),
          icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more,
              size: 18),
          label: Text(l10n.aiBackupSection,
              style: Theme.of(context).textTheme.labelLarge),
        ),
        AnimatedCrossFade(
          duration: const Duration(milliseconds: 180),
          crossFadeState: _expanded
              ? CrossFadeState.showFirst
              : CrossFadeState.showSecond,
          firstChild: _ApiFields(
            baseCtrl: widget.baseCtrl,
            keyCtrl: widget.keyCtrl,
            modelCtrl: widget.modelCtrl,
            baseHint: l10n.aiBaseUrlHint,
            modelHint: l10n.aiModelHint,
          ),
          secondChild: const SizedBox.shrink(),
        ),
      ],
    );
  }
}

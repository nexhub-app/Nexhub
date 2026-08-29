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

import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:nexhub/core/theme/app_tokens.dart';
import 'package:nexhub/core/widgets/app_animations.dart';
import '../../novel/domain/novel_summary_service.dart';
import '../../novel/domain/novel_summary_settings.dart';
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

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
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

    if (!mounted) return;
    setState(() {
      _commonBaseCtrl.text = defaultCfg.baseUrl;
      _commonKeyCtrl.text = defaultCfg.apiKey;
      _commonModelCtrl.text = defaultCfg.model;

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

      _comicBaseCtrl.text = cBase;
      _comicKeyCtrl.text = cKey;
      _comicModelCtrl.text = cModel;
      _comicLangCtrl.text = comicLang;

      _mediaBaseCtrl.text = mBase;
      _mediaKeyCtrl.text = mKey;
      _mediaModelCtrl.text = mModel;
      _mediaLangCtrl.text = mediaLang;
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

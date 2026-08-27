/// 双语/段落翻译配置页：翻译目标语言、专用接口与分块选项。
///
/// - **翻译接口**：翻译专用 baseUrl/apiKey/model；留空回落通用 AI 配置
///   （见 [SettingsAiScreen] 的「通用 API 配置」）；
/// - **目标语言**：翻译提示词用语（如 中文 / 英文 / 日文）；
/// - **分块大小**：整章一次批量请求失败后按此段数分块重试。
///
/// 存储走 [NovelSummarySettings]（SharedPreferences）。页面 body 用
/// [SettingsAutoScroll] 包裹，供设置搜索以 `translation.*` 滚动定位。
library;

import 'package:flutter/material.dart';
import 'package:nexhub/core/theme/app_tokens.dart';
import 'package:nexhub/core/widgets/app_animations.dart';
import 'package:nexhub/generated/app_localizations.dart';
import '../../novel/domain/novel_summary_service.dart';
import '../../novel/domain/novel_summary_settings.dart';
import 'widgets/settings_widgets.dart';
import 'widgets/settings_search_target.dart';

class SettingsTranslationScreen extends StatefulWidget {
  const SettingsTranslationScreen({super.key});

  @override
  State<SettingsTranslationScreen> createState() =>
      _SettingsTranslationScreenState();
}

class _SettingsTranslationScreenState extends State<SettingsTranslationScreen> {
  final NovelSummarySettings _settings = NovelSummarySettings.instance;

  final _baseCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();
  final _modelCtrl = TextEditingController();
  final _langCtrl = TextEditingController();

  double _batchSize = 12;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final defaultCfg = await _settings.getDefaultConfig();
    final cfg = await _settings.getTranslationConfig();
    // 只回显功能级填写内容：与通用一致时留空。
    final base = cfg.baseUrl == defaultCfg.baseUrl ? '' : cfg.baseUrl;
    final key = cfg.apiKey == defaultCfg.apiKey ? '' : cfg.apiKey;
    final model = cfg.model == defaultCfg.model ? '' : cfg.model;
    final lang = await _settings.getTranslationTargetLanguage();
    final batch = await _settings.getTranslationBatchSize();
    if (!mounted) return;
    setState(() {
      _baseCtrl.text = base;
      _keyCtrl.text = key;
      _modelCtrl.text = model;
      _langCtrl.text = lang;
      _batchSize = batch.toDouble();
    });
  }

  @override
  void dispose() {
    _baseCtrl.dispose();
    _keyCtrl.dispose();
    _modelCtrl.dispose();
    _langCtrl.dispose();
    super.dispose();
  }

  Future<void> _save(AppLocalizations l10n) async {
    setState(() => _saving = true);
    try {
      await _settings.saveTranslationConfig(NovelSummaryConfig(
        baseUrl: _baseCtrl.text.trim(),
        apiKey: _keyCtrl.text.trim(),
        model: _modelCtrl.text.trim(),
      ));
      await _settings.saveTranslationTargetLanguage(_langCtrl.text.trim());
      await _settings.saveTranslationBatchSize(_batchSize.round());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.translationSaved)),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AppShrinkTitleScaffold(
      title: Text(l10n.translationSettingsTitle),
      body: SettingsAutoScroll(
        child: ListView(
          padding: const EdgeInsets.all(AppTokens.spaceLg),
          children: <Widget>[
            SettingsCard(
              key: const ValueKey<String>('translation.api'),
              title: l10n.translationApiSection,
              description: l10n.translationApiDesc,
              children: <Widget>[
                _ApiFields(
                  baseCtrl: _baseCtrl,
                  keyCtrl: _keyCtrl,
                  modelCtrl: _modelCtrl,
                ),
              ],
            ),
            SettingsCard(
              key: const ValueKey<String>('translation.options'),
              title: l10n.translationTargetLang,
              children: <Widget>[
                TextField(
                  controller: _langCtrl,
                  decoration: InputDecoration(
                    labelText: l10n.translationTargetLang,
                    hintText: l10n.translationTargetLangHint,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: AppTokens.spaceMd),
                SettingsSliderTile(
                  label: l10n.translationBatchSize,
                  value: _batchSize,
                  min: 4,
                  max: 40,
                  divisions: 36,
                  display: '${_batchSize.round()}',
                  onChanged: (v) => setState(() => _batchSize = v),
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

  const _ApiFields({
    required this.baseCtrl,
    required this.keyCtrl,
    required this.modelCtrl,
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
            hintText: l10n.aiBaseUrlHint,
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
            hintText: l10n.aiModelHint,
            border: const OutlineInputBorder(),
          ),
        ),
      ],
    );
  }
}

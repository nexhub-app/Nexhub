/// 隐私设置页（D 阶段）。
///
/// 提供：
/// - 隐藏通知内容：应用内通知（RSS 更新未读数等）只显示「新内容」，
///   不显示具体数字，防窥屏。
/// - 全局隐身：随机延迟 + UA 轮换（从设置主页「通用」组迁移至此）。
library;

import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';

import '../../../core/settings/general_settings.dart';
import '../../../core/services/config_loader.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_animations.dart';
import 'widgets/settings_widgets.dart';

class SettingsPrivacyScreen extends StatefulWidget {
  const SettingsPrivacyScreen({super.key});

  @override
  State<SettingsPrivacyScreen> createState() => _SettingsPrivacyScreenState();
}

class _SettingsPrivacyScreenState extends State<SettingsPrivacyScreen> {
  late GeneralSettings _s;

  @override
  void initState() {
    super.initState();
    _s = GeneralSettingsStore.instance.settings;
    if (!GeneralSettingsStore.instance.loaded) {
      GeneralSettingsStore.instance.load().then((s) {
        if (mounted) setState(() => _s = s);
      });
    }
  }

  void _update(GeneralSettings next) {
    setState(() => _s = next);
    GeneralSettingsStore.instance.save(next);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AppShrinkTitleScaffold(
      title: Text(l10n.privacySettingsTitle),
      body: ListView(
        padding: const EdgeInsets.all(AppTokens.spaceMd),
        children: <Widget>[
          SettingsCard(
            title: l10n.privacyNotificationsGroup,
            index: 0,
            children: <Widget>[
              SettingsSwitchTile(
                title: l10n.hideNotificationContent,
                subtitle: l10n.hideNotificationContentHint,
                value: _s.hideNotificationContent,
                onChanged: (v) => _update(
                  _s.copyWith(hideNotificationContent: v),
                ),
              ),
            ],
          ),
          SettingsCard(
            title: l10n.privacyNetworkGroup,
            index: 1,
            children: <Widget>[
              SettingsSwitchTile(
                title: l10n.globalIncognito,
                subtitle: l10n.globalIncognitoHint,
                value: ConfigLoader.instance.isGlobalIncognito,
                onChanged: (v) async {
                  await ConfigLoader.instance.setGlobalIncognito(v);
                  if (mounted) setState(() {});
                },
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppTokens.spaceSm),
            child: Text(
              l10n.privacyPageHint,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

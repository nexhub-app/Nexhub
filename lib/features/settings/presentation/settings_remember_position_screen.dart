/// 记住播放/阅读位置子页 —— 单开关，开启后重新打开会自动跳到上次进度。
///
/// 持久化到 SharedPreferences（key: `general_settings_v1` 中的
/// [GeneralSettings.rememberPosition]，与汇总页共用同一份数据）。
library;

import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';

import '../../../core/settings/general_settings.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_animations.dart';
import 'widgets/settings_widgets.dart';

/// 记住位置设置页。
class SettingsRememberPositionScreen extends StatefulWidget {
  const SettingsRememberPositionScreen({super.key});

  @override
  State<SettingsRememberPositionScreen> createState() =>
      _SettingsRememberPositionScreenState();
}

class _SettingsRememberPositionScreenState
    extends State<SettingsRememberPositionScreen> {
  late GeneralSettings _s;

  @override
  void initState() {
    super.initState();
    final store = GeneralSettingsStore.instance;
    _s = store.settings;
    if (!store.loaded) {
      store.load().then((s) {
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
      title: Text(l10n.rememberPosition),
      body: Entrance(
        offset: 10,
        fromScale: 0.985,
        duration: AppTokens.durBase,
        child: ListView(
          padding: const EdgeInsets.all(AppTokens.spaceLg),
          children: <Widget>[
            SettingsCard(
              title: l10n.rememberPosition,
              children: <Widget>[
                SettingsSwitchTile(
                  title: l10n.rememberPosition,
                  subtitle: l10n.rememberPositionHint,
                  value: _s.rememberPosition,
                  onChanged: (v) => _update(_s.copyWith(rememberPosition: v)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
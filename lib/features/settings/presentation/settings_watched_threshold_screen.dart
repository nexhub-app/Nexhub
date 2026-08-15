/// 播放/阅读已看阈值子页 —— 单滑块设置，进度达到该百分比视为已看。
///
/// 持久化到 SharedPreferences（key: `general_settings_v1` 中的
/// [GeneralSettings.watchedThresholdPercent]，与汇总页共用同一份数据）。
library;

import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';

import '../../../core/settings/general_settings.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_animations.dart';
import 'widgets/settings_widgets.dart';

/// 已看阈值设置页。
class SettingsWatchedThresholdScreen extends StatefulWidget {
  const SettingsWatchedThresholdScreen({super.key});

  @override
  State<SettingsWatchedThresholdScreen> createState() =>
      _SettingsWatchedThresholdScreenState();
}

class _SettingsWatchedThresholdScreenState
    extends State<SettingsWatchedThresholdScreen> {
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
      title: Text(l10n.watchedThreshold),
      body: Entrance(
        offset: 10,
        fromScale: 0.985,
        duration: AppTokens.durBase,
        child: ListView(
          padding: const EdgeInsets.all(AppTokens.spaceLg),
          children: <Widget>[
            SettingsCard(
              title: l10n.watchedThreshold,
              children: <Widget>[
                SettingsSliderTile(
                  label: l10n.watchedThreshold,
                  value: _s.watchedThresholdPercent.toDouble(),
                  min: kWatchedThresholdMin.toDouble(),
                  max: kWatchedThresholdMax.toDouble(),
                  divisions: kWatchedThresholdMax - kWatchedThresholdMin,
                  display:
                      '${_s.watchedThresholdPercent}${l10n.watchedThresholdUnit}',
                  onChanged: (v) => _update(
                    _s.copyWith(watchedThresholdPercent: v.round()),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: AppTokens.spaceXs),
                  child: Text(
                    l10n.watchedThresholdHint,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
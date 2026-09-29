/// RSS 更新通知设置页（文档 + 16.13 RSS 更新通知）。
///
/// 提供：
/// - 启用/禁用 RSS 更新检测开关
/// - 轮询间隔选择（15min/30min/1h/2h/4h）
/// - 立即检测按钮
/// - 总未读数显示
library;

import 'package:material_ui/material_ui.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:provider/provider.dart';

import '../../../core/rss/rss_update_checker.dart';
import '../../../core/settings/general_settings.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/utils/app_haptics.dart';
import '../../../core/widgets/app_glass_bar.dart';
import './widgets/settings_widgets.dart';

class SettingsRssNotificationsScreen extends StatelessWidget {
  const SettingsRssNotificationsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final checker = context.watch<RssUpdateChecker>();

    return Scaffold(
      appBar: AppBar(title: Text(l10n.rssNotificationsTitle)),
      body: ListView(
        padding: context.pageInset(AppTokens.spaceLg),
        children: <Widget>[
          // ── 通知设置（连体组卡，行间发丝分隔线）──
          SettingsGroup(
            header: l10n.rssNotificationsTitle,
            children: <Widget>[
              SettingsTile(
                icon: Icons.notifications_rounded,
                title: l10n.rssNotificationEnabled,
                subtitle: l10n.rssNotificationEnabledSubtitle,
                trailing: Switch(
                  value: checker.enabled,
                  onChanged: (v) {
                    v == true ? AppHaptics.toggleOn() : AppHaptics.toggleOff();
                    checker.setEnabled(v);
                  },
                ),
              ),
              if (checker.enabled) ...<Widget>[
                // ── 轮询间隔 ──
                SettingsTile(
                  icon: Icons.schedule_rounded,
                  title: l10n.rssUpdateInterval,
                  subtitle: _intervalLabel(l10n, checker.interval),
                  onTap: () => _showIntervalPicker(context, checker),
                ),
                // ── 充电时自动检测（触发条件：充电）──
                SettingsTile(
                  icon: Icons.battery_charging_full_rounded,
                  title: l10n.rssChargeCheck,
                  subtitle: l10n.rssChargeCheckSubtitle,
                  trailing: Switch(
                    value: checker.chargeCheck,
                    onChanged: (v) {
                      v == true
                          ? AppHaptics.toggleOn()
                          : AppHaptics.toggleOff();
                      checker.setChargeCheck(v);
                    },
                  ),
                ),
                // ── 系统通知（OS 通知，-3）──
                SettingsTile(
                  icon: Icons.notification_important_rounded,
                  title: l10n.rssSystemNotification,
                  subtitle: l10n.rssSystemNotificationSubtitle,
                  trailing: Switch(
                    value: checker.systemNotification,
                    onChanged: (v) {
                      v == true
                          ? AppHaptics.toggleOn()
                          : AppHaptics.toggleOff();
                      checker.setSystemNotification(v);
                    },
                  ),
                ),
                // ── 立即检测 ──
                SettingsTile(
                  icon: Icons.refresh_rounded,
                  title: l10n.rssCheckNow,
                  // 隐私「隐藏通知内容」开启时只显示中性文案，不暴露具体数量。
                  subtitle: GeneralSettingsStore
                          .instance.settings.hideNotificationContent
                      ? l10n.rssNewContentGeneric
                      : l10n.rssTotalNewCount(checker.totalNewCount),
                  onTap: () async {
                    await checker.checkAllFeeds();
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(l10n.rssCheckDone)),
                      );
                    }
                  },
                ),
                // ── 关键词自动已读（信息降噪）──
                SettingsTile(
                  icon: Icons.auto_delete_rounded,
                  title: l10n.rssAutoReadTitle,
                  subtitle: l10n.rssAutoReadDesc,
                ),
                if (checker.autoReadKeywords.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppTokens.spaceLg,
                      0,
                      AppTokens.spaceLg,
                      AppTokens.spaceSm,
                    ),
                    child: Text(
                      l10n.rssAutoReadEmpty,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppTokens.spaceLg,
                      AppTokens.spaceXs,
                      AppTokens.spaceLg,
                      AppTokens.spaceXs,
                    ),
                    child: Wrap(
                      spacing: AppTokens.spaceSm,
                      runSpacing: AppTokens.spaceXs,
                      children: <Widget>[
                        for (final k in checker.autoReadKeywords)
                          InputChip(
                            label: Text(k),
                            onDeleted: () {
                              AppHaptics.selectionClick();
                              checker.setAutoReadKeywords(
                                checker.autoReadKeywords
                                    .where((e) => e != k)
                                    .toList(),
                              );
                            },
                          ),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppTokens.spaceLg,
                    0,
                    AppTokens.spaceLg,
                    AppTokens.spaceSm,
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: Text(l10n.rssAutoReadAdd),
                      onPressed: () => _promptKeyword(context, checker),
                    ),
                  ),
                ),
              ],
            ],
          ),

          // ── 说明 ──
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTokens.spaceLg,
              AppTokens.spaceMd,
              AppTokens.spaceLg,
              0,
            ),
            child: Text(
              l10n.rssNotificationHint,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
        ],
      ),
    );
  }

  String _intervalLabel(AppLocalizations l10n, RssUpdateInterval interval) {
    switch (interval) {
      case RssUpdateInterval.minutes15:
        return l10n.interval15m;
      case RssUpdateInterval.minutes30:
        return l10n.interval30m;
      case RssUpdateInterval.hour1:
        return l10n.interval1h;
      case RssUpdateInterval.hours2:
        return l10n.interval2h;
      case RssUpdateInterval.hours4:
        return l10n.interval4h;
    }
  }

  /// 输入自动已读关键词（空输入取消）。
  Future<void> _promptKeyword(
    BuildContext context,
    RssUpdateChecker checker,
  ) async {
    final l10n = AppLocalizations.of(context);
    final ctrl = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text(l10n.rssAutoReadAdd),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            hintText: l10n.rssAutoReadHint,
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (v) {
            Navigator.of(dialogCtx).pop();
          },
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: Text(l10n.ok),
          ),
        ],
      ),
    );
    final value = ctrl.text.trim();
    if (value.isEmpty) return;
    final existing = checker.autoReadKeywords;
    if (existing.contains(value)) return;
    await checker.setAutoReadKeywords(<String>[...existing, value]);
  }

  void _showIntervalPicker(
    BuildContext context,
    RssUpdateChecker checker,
  ) {
    final l10n = AppLocalizations.of(context);
    showDialog<void>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(l10n.rssUpdateInterval),
        children: RssUpdateInterval.values.map((i) {
          return SimpleDialogOption(
            onPressed: () {
              checker.setInterval(i);
              Navigator.pop(ctx);
            },
            child: Row(
              children: <Widget>[
                if (checker.interval == i)
                  Icon(
                    Icons.check_rounded,
                    color: Theme.of(context).colorScheme.primary,
                  )
                else
                  const SizedBox(width: AppTokens.spaceXl),
                const SizedBox(width: AppTokens.spaceSm),
                Text(_intervalLabel(l10n, i)),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }
}

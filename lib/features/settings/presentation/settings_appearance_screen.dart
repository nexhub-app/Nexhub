/// 外观与语言汇总页：主题 / 配色 / 启动与显示 / 语言。
///
/// body 使用 SettingsAutoScroll 包裹，使设置搜索可按 ValueKey 精确定位到
/// 具体的「主题」「配色」「启动」「语言」等组；ListView 内的子项在首帧时
/// 即可被 findContextWithValueKey 命中。
library;

import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:provider/provider.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/theme/theme_controller.dart';
import '../../../core/locale/locale_controller.dart';
import '../../../core/settings/general_settings.dart';
import '../../../core/widgets/app_animations.dart';
import '../../../core/widgets/app_list_tile.dart';
import '../../../core/widgets/app_segmented_tabs.dart';
import '../../../core/widgets/app_alert_dialog.dart';
import '../../../core/utils/app_haptics.dart';
import 'package:nexhub/core/navigation/app_page_route.dart';
import './widgets/settings_widgets.dart';
import './widgets/settings_search_target.dart';
import './settings_hero_screen.dart';
import 'package:nexhub/generated/app_localizations.dart';

class SettingsAppearanceScreen extends StatefulWidget {
  const SettingsAppearanceScreen({super.key});

  @override
  State<SettingsAppearanceScreen> createState() =>
      _SettingsAppearanceScreenState();
}

class _SettingsAppearanceScreenState extends State<SettingsAppearanceScreen> {
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

  void _openColorPicker(
      BuildContext context, ThemeController c, AppLocalizations l10n) {
    Color pickerColor = c.seed;
    showDialog(
      context: context,
      builder: (BuildContext ctx) => AppAlertDialog(
        title: Text(l10n.customColor),
        content: SingleChildScrollView(
          child: ColorPicker(
            pickerColor: pickerColor,
            onColorChanged: (Color color) => pickerColor = color,
            enableAlpha: false,
          ),
        ),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(l10n.cancel)),
          OutlinedButton(
            onPressed: () {
              c.setSeed(AppTokens.seedYouthfulPrimary);
              Navigator.pop(ctx);
            },
            child: Text(l10n.restoreDefault),
          ),
          FilledButton(
            onPressed: () {
              c.setSeed(pickerColor);
              Navigator.pop(ctx);
            },
            child: Text(l10n.confirm),
          ),
        ],
      ),
    );
  }

  String _launchLabel(AppLocalizations l10n, LaunchTab t) => switch (t) {
        LaunchTab.browse => l10n.navBrowse,
        LaunchTab.novel => l10n.navNovel,
        LaunchTab.media => l10n.navMedia,
        LaunchTab.comic => l10n.navComic,
        LaunchTab.settings => l10n.navSettings,
      };

  String _dateFormatLabel(AppLocalizations l10n, AppDateFormat d) => switch (d) {
        AppDateFormat.defaultFormat => l10n.dateFormatDefault,
        AppDateFormat.mmddyy => l10n.dateFormatMmDdYy,
        AppDateFormat.ddmmyy => l10n.dateFormatDdMmYy,
        AppDateFormat.yyyymmdd => l10n.dateFormatYyyyMmDd,
        AppDateFormat.ddmmmyyyy => l10n.dateFormatDdMmmYyyy,
        AppDateFormat.mmmdd => l10n.dateFormatMmmDd,
        AppDateFormat.yyyyOnly => l10n.dateFormatYyyy,
      };

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ThemeController controller = context.watch<ThemeController>();
    final LocaleController localeController = context.watch<LocaleController>();
    final scheme = Theme.of(context).colorScheme;

    return AppShrinkTitleScaffold(
      title: Text(l10n.settingsCatAppearance),
      body: SettingsAutoScroll(
        child: Entrance(
          offset: 10,
          fromScale: 0.985,
          duration: AppTokens.durBase,
          child: ListView(
            padding: const EdgeInsets.all(AppTokens.spaceLg),
            children: <Widget>[
              // ── 主题 ──
              SettingsCard(
                key: const ValueKey<String>('appearance.theme'),
                title: l10n.appearanceThemeSection,
                backgroundColor: scheme.surfaceContainerLow,
                children: <Widget>[
                  AppValuePulse(
                    trigger: controller.mode,
                    from: 0.93,
                    child: AppSegmentedTabs<ThemeMode>(
                      selected: <ThemeMode>{controller.mode},
                      onSelectionChanged: (Set<ThemeMode> s) =>
                          controller.setMode(s.first),
                      segments: <ButtonSegment<ThemeMode>>[
                        ButtonSegment<ThemeMode>(
                            value: ThemeMode.light,
                            label: Text(l10n.themeLight),
                            icon: const Icon(Icons.light_mode)),
                        ButtonSegment<ThemeMode>(
                            value: ThemeMode.dark,
                            label: Text(l10n.themeDark),
                            icon: const Icon(Icons.dark_mode)),
                        ButtonSegment<ThemeMode>(
                            value: ThemeMode.system,
                            label: Text(l10n.themeSystem),
                            icon: const Icon(Icons.brightness_auto)),
                      ],
                    ),
                  ),
                  const Divider(height: AppTokens.spaceLg),
                  AppListTile(
                    leading:
                        const SettingsLeadingIcon(icon: Icons.auto_awesome),
                    title: Text(l10n.useMonet),
                    trailing: AppValuePulse(
                      trigger: controller.useMonet,
                      from: 0.94,
                      child: Switch(
                        value: controller.useMonet,
                        onChanged: (_) {
                          AppHaptics.selectionClick();
                          controller.setUseMonet(!controller.useMonet);
                        },
                      ),
                    ),
                  ),
                ],
              ),

              // ── 配色 ──
              SettingsCard(
                key: const ValueKey<String>('appearance.colors'),
                title: l10n.appearanceColorsSection,
                backgroundColor: scheme.surfaceContainerLow,
                children: <Widget>[
                  Wrap(
                    spacing: AppTokens.spaceSm,
                    runSpacing: AppTokens.spaceSm,
                    children: AppTokens.presetSeeds.map((preset) {
                      final Color color = preset.$1;
                      final String name = preset.$2;
                      final bool selected =
                          !controller.useMonet && controller.seed == color;
                      return Tooltip(
                        message: name,
                        child: GestureDetector(
                          onTap: () {
                            controller.setUseMonet(false);
                            controller.setSeed(color);
                          },
                          child: AnimatedContainer(
                            duration: AppTokens.durBase,
                            curve: AppCurves.smooth,
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: color,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: selected
                                    ? scheme.primary
                                    : scheme.outlineVariant,
                                width: selected ? 3 : 1,
                              ),
                            ),
                            child: selected
                                ? Icon(Icons.check,
                                    color:
                                        ThemeData.estimateBrightnessForColor(
                                                    color) ==
                                                Brightness.dark
                                            ? Colors.white
                                            : Colors.black,
                                    size: 20)
                                : null,
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const Divider(height: AppTokens.spaceLg),
                  AppListTile(
                    key: const ValueKey<String>('appearance.customColor'),
                    leading:
                        const SettingsLeadingIcon(icon: Icons.color_lens),
                    title: Text(l10n.customColor),
                    trailing: CircleAvatar(
                        backgroundColor: controller.seed, radius: 14),
                    onTap: () =>
                        _openColorPicker(context, controller, l10n),
                  ),
                ],
              ),

              // ── 背景图（Hero） ──
              SettingsCard(
                key: const ValueKey<String>('appearance.hero'),
                title: l10n.appearanceHeroSection,
                backgroundColor: scheme.surfaceContainerLow,
                children: <Widget>[
                  AppListTile(
                    leading: const SettingsLeadingIcon(icon: Icons.image),
                    title: Text(l10n.heroSettingsTitle),
                    subtitle: Text(l10n.heroEmptyHint),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      AppPageRoute<void>(
                        builder: (_) => const SettingsHeroScreen(),
                      ),
                    ),
                  ),
                ],
              ),

              // ── 启动与显示 ──
              SettingsCard(
                key: const ValueKey<String>('appearance.startup'),
                title: l10n.appearanceStartupSection,
                backgroundColor: scheme.surfaceContainerLow,
                children: <Widget>[
                  AnimatedBuilder(
                    animation: GeneralSettingsStore.instance,
                    builder: (_, __) {
                      _s = GeneralSettingsStore.instance.settings;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            l10n.launchScreenTitle,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          const SizedBox(height: AppTokens.spaceSm),
                          Wrap(
                            spacing: AppTokens.spaceSm,
                            runSpacing: AppTokens.spaceXs,
                            children: LaunchTab.values.map((t) {
                              return ChoiceChip(
                                label: Text(_launchLabel(l10n, t)),
                                selected: _s.launchTab == t,
                                onSelected: (_) =>
                                    _update(_s.copyWith(launchTab: t)),
                              );
                            }).toList(),
                          ),
                          const SizedBox(height: AppTokens.spaceMd),
                          Text(
                            l10n.dateFormatTitle,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          const SizedBox(height: AppTokens.spaceSm),
                          Wrap(
                            spacing: AppTokens.spaceSm,
                            runSpacing: AppTokens.spaceXs,
                            children: AppDateFormat.values.map((d) {
                              return ChoiceChip(
                                label: Text(_dateFormatLabel(l10n, d)),
                                selected: _s.dateFormat == d,
                                onSelected: (_) =>
                                    _update(_s.copyWith(dateFormat: d)),
                              );
                            }).toList(),
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ),

              // ── 语言 ──
              SettingsCard(
                key: const ValueKey<String>('appearance.language'),
                title: l10n.settingsGroupLanguage,
                backgroundColor: scheme.surfaceContainerLow,
                children: <Widget>[
                  AppValuePulse(
                    trigger: localeController.option,
                    from: 0.93,
                    child: AppSegmentedTabs<LocaleOption>(
                      selected: <LocaleOption>{localeController.option},
                      onSelectionChanged: (Set<LocaleOption> s) =>
                          localeController.setOption(s.first),
                      segments: <ButtonSegment<LocaleOption>>[
                        ButtonSegment<LocaleOption>(
                            value: LocaleOption.system,
                            label: Text(l10n.languageFollowSystem),
                            icon: const Icon(Icons.brightness_auto)),
                        ButtonSegment<LocaleOption>(
                            value: LocaleOption.chinese,
                            label: Text(l10n.languageChinese),
                            icon: const Icon(Icons.translate)),
                        ButtonSegment<LocaleOption>(
                            value: LocaleOption.english,
                            label: Text(l10n.languageEnglish),
                            icon: const Icon(Icons.language)),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
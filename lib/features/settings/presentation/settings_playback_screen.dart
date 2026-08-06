import 'package:flutter/material.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_animations.dart';
import '../../../core/widgets/app_list_tile.dart';
import './widgets/settings_widgets.dart';
import '../../../core/widgets/layout_picker_dialog.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:nexhub/core/navigation/app_page_route.dart';
import './settings_player_screen.dart';
import './settings_novel_reader_screen.dart';
import './settings_comic_reader_screen.dart';
import './settings_danmaku_display_screen.dart';
import './settings_watched_threshold_screen.dart';
import './settings_remember_position_screen.dart';

/// 播放与阅读汇总页：5 个模块入口（播放器 / 漫画 / 小说 / 布局 / 弹幕显示）
/// + 播放进度（已看阈值 / 记住位置）子入口。
class SettingsPlaybackScreen extends StatelessWidget {
  const SettingsPlaybackScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AppShrinkTitleScaffold(
      title: Text(l10n.settingsCatPlayback),
      body: Entrance(
        offset: 10,
        fromScale: 0.985,
        duration: AppTokens.durBase,
        child: ListView(
          padding: const EdgeInsets.all(AppTokens.spaceLg),
          children: <Widget>[
            SettingsCard(
              key: const ValueKey<String>('playback_modules'),
              title: l10n.playbackModulesSection,
              children: <Widget>[
                AppListTile(
                  leading:
                      const SettingsLeadingIcon(icon: Icons.play_circle_outline),
                  title: Text(l10n.playerSettingsTitle),
                  subtitle: Text(l10n.playerSettingsDesc),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    AppPageRoute<void>(
                      builder: (_) => const SettingsPlayerScreen(),
                    ),
                  ),
                ),
                AppListTile(
                  leading:
                      const SettingsLeadingIcon(icon: Icons.menu_book_outlined),
                  title: Text(l10n.novelReaderSettingsTitle),
                  subtitle: Text(l10n.novelReaderSettingsDesc),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    AppPageRoute<void>(
                      builder: (_) => const SettingsNovelReaderScreen(),
                    ),
                  ),
                ),
                AppListTile(
                  leading: const SettingsLeadingIcon(
                      icon: Icons.auto_stories_outlined),
                  title: Text(l10n.comicReaderSettingsTitle),
                  subtitle: Text(l10n.comicReaderSettingsDesc),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    AppPageRoute<void>(
                      builder: (_) => const SettingsComicReaderScreen(),
                    ),
                  ),
                ),
                AppListTile(
                  leading: const SettingsLeadingIcon(
                      icon: Icons.view_quilt_outlined),
                  title: Text(l10n.layoutSettings),
                  subtitle: Text(l10n.layoutSettingsDesc),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => showLayoutPickerDialog(context),
                ),
                AppListTile(
                  leading: const SettingsLeadingIcon(
                      icon: Icons.subtitles_outlined),
                  title: Text(l10n.danmakuDisplaySettingsTitle),
                  subtitle: Text(l10n.danmakuDisplaySettingsDesc),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    AppPageRoute<void>(
                      builder: (_) => const SettingsDanmakuDisplayScreen(),
                    ),
                  ),
                ),
              ],
            ),
            SettingsCard(
              key: const ValueKey<String>('playback_progress'),
              title: l10n.playbackProgressGroup,
              children: <Widget>[
                AppListTile(
                  leading: const SettingsLeadingIcon(icon: Icons.percent),
                  title: Text(l10n.watchedThreshold),
                  subtitle: Text(l10n.watchedThresholdHint),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    AppPageRoute<void>(
                      builder: (_) => const SettingsWatchedThresholdScreen(),
                    ),
                  ),
                ),
                AppListTile(
                  leading: const SettingsLeadingIcon(icon: Icons.history),
                  title: Text(l10n.rememberPosition),
                  subtitle: Text(l10n.rememberPositionHint),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    AppPageRoute<void>(
                      builder: (_) => const SettingsRememberPositionScreen(),
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
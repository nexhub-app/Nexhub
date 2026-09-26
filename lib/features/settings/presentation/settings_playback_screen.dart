import 'package:material_ui/material_ui.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_animations.dart';
import './widgets/settings_widgets.dart';
import './widgets/settings_search_target.dart';
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
///
/// 版面：每行一张独立描边小卡（[SettingsTile]），分组小标题（[SettingsGroup]）。
class SettingsPlaybackScreen extends StatelessWidget {
  const SettingsPlaybackScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AppShrinkTitleScaffold(
      title: Text(l10n.settingsCatPlayback),
      body: SettingsAutoScroll(
        child: Entrance(
          offset: 10,
          fromScale: 0.985,
          duration: AppTokens.durBase,
          child: ListView(
            padding: const EdgeInsets.all(AppTokens.spaceLg),
            children: <Widget>[
              SettingsGroup(
                key: const ValueKey<String>('playback_modules'),
                header: l10n.playbackModulesSection,
                children: <Widget>[
                  SettingsTile(
                    key: const ValueKey<String>('playback.player'),
                    icon: Icons.play_circle_rounded,
                    title: l10n.playerSettingsTitle,
                    subtitle: l10n.playerSettingsDesc,
                    onTap: () => Navigator.of(context).push(
                      AppPageRoute<void>(
                        builder: (_) => const SettingsPlayerScreen(),
                      ),
                    ),
                  ),
                  SettingsTile(
                    key: const ValueKey<String>('playback.novel'),
                    icon: Icons.menu_book_rounded,
                    title: l10n.novelReaderSettingsTitle,
                    subtitle: l10n.novelReaderSettingsDesc,
                    onTap: () => Navigator.of(context).push(
                      AppPageRoute<void>(
                        builder: (_) => const SettingsNovelReaderScreen(),
                      ),
                    ),
                  ),
                  SettingsTile(
                    key: const ValueKey<String>('playback.comic'),
                    icon: Icons.auto_stories_rounded,
                    title: l10n.comicReaderSettingsTitle,
                    subtitle: l10n.comicReaderSettingsDesc,
                    onTap: () => Navigator.of(context).push(
                      AppPageRoute<void>(
                        builder: (_) => const SettingsComicReaderScreen(),
                      ),
                    ),
                  ),
                  SettingsTile(
                    key: const ValueKey<String>('playback.layout'),
                    icon: Icons.view_quilt_rounded,
                    title: l10n.layoutSettings,
                    subtitle: l10n.layoutSettingsDesc,
                    onTap: () => showLayoutPickerDialog(context),
                  ),
                  SettingsTile(
                    key: const ValueKey<String>('playback.danmaku'),
                    icon: Icons.subtitles_rounded,
                    title: l10n.danmakuDisplaySettingsTitle,
                    subtitle: l10n.danmakuDisplaySettingsDesc,
                    onTap: () => Navigator.of(context).push(
                      AppPageRoute<void>(
                        builder: (_) => const SettingsDanmakuDisplayScreen(),
                      ),
                    ),
                  ),
                ],
              ),
              SettingsGroup(
                key: const ValueKey<String>('playback_progress'),
                header: l10n.playbackProgressGroup,
                children: <Widget>[
                  SettingsTile(
                    key: const ValueKey<String>('playback.watched'),
                    icon: Icons.percent_rounded,
                    title: l10n.watchedThreshold,
                    subtitle: l10n.watchedThresholdHint,
                    onTap: () => Navigator.of(context).push(
                      AppPageRoute<void>(
                        builder: (_) => const SettingsWatchedThresholdScreen(),
                      ),
                    ),
                  ),
                  SettingsTile(
                    key: const ValueKey<String>('playback.remember'),
                    icon: Icons.history_rounded,
                    title: l10n.rememberPosition,
                    subtitle: l10n.rememberPositionHint,
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
      ),
    );
  }
}

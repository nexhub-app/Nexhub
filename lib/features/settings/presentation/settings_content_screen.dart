import 'package:material_ui/material_ui.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_animations.dart';
import './widgets/settings_widgets.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:nexhub/core/navigation/app_page_route.dart';
import '../../sources/presentation/source_manager_screen.dart';
import '../../home/presentation/browse_web_scrape_screen.dart';
import '../../rss/presentation/rss_feed_list_screen.dart';
import '../../../core/widgets/app_glass_bar.dart';
import './settings_rsshub_screen.dart';
import './settings_rss_notifications_screen.dart';
import './settings_network_screen.dart';
import './settings_ai_screen.dart';

/// 配置与网络汇总页：源管理 / RSS 订阅 / 网页爬取 / AI 配置 / 网络设置入口。
///
/// 版面：每行一张独立描边小卡（[SettingsTile]），行间 4px，见。
class SettingsContentScreen extends StatelessWidget {
  const SettingsContentScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AppShrinkTitleScaffold(
      title: Text(l10n.settingsCatContent),
      body: Entrance(
        offset: 10,
        fromScale: 0.985,
        duration: AppTokens.durBase,
        child: ListView(
          padding: context.pageInset(AppTokens.spaceLg),
          children: <Widget>[
            SettingsGroup(
              header: l10n.settingsCatContent,
              children: <Widget>[
                SettingsTile(
                  icon: Icons.extension_rounded,
                  title: l10n.sourceManagementTitle,
                  subtitle: l10n.sourceManagementDesc,
                  onTap: () => Navigator.of(context).push(
                    AppPageRoute<void>(
                      builder: (_) => const SourceManagerScreen(),
                    ),
                  ),
                ),
                // ── RSS 订阅（全局）：与浏览页同源，显示未绑定模块的全局订阅 ──
                SettingsTile(
                  icon: Icons.rss_feed_rounded,
                  title: l10n.rssFeedListTitle,
                  subtitle: l10n.rssGlobalSubscriptionDesc,
                  onTap: () => Navigator.of(context).push(
                    AppPageRoute<void>(
                      builder: (_) => const RssFeedListScreen(moduleType: null),
                    ),
                  ),
                ),
                SettingsTile(
                  icon: Icons.hub_rounded,
                  title: l10n.rsshubSettingsTitle,
                  subtitle: l10n.rsshubSettingsDesc,
                  onTap: () => Navigator.of(context).push(
                    AppPageRoute<void>(
                      builder: (_) => const SettingsRssHubScreen(),
                    ),
                  ),
                ),
                SettingsTile(
                  icon: Icons.notifications_rounded,
                  title: l10n.rssNotificationsTitle,
                  subtitle: l10n.rssNotificationEnabledSubtitle,
                  onTap: () => Navigator.of(context).push(
                    AppPageRoute<void>(
                      builder: (_) => const SettingsRssNotificationsScreen(),
                    ),
                  ),
                ),
                SettingsTile(
                  icon: Icons.travel_explore_rounded,
                  title: l10n.webScrapeSetting,
                  subtitle: l10n.webScrapeSettingSameAsBrowse,
                  onTap: () => Navigator.of(context).push(
                    AppPageRoute<void>(
                      builder: (_) => const BrowseWebScrapeScreen(),
                    ),
                  ),
                ),
              ],
            ),
            SettingsGroup(
              header: l10n.aiSettingsEntry,
              children: <Widget>[
                SettingsTile(
                  icon: Icons.auto_awesome_rounded,
                  title: l10n.aiSettingsEntry,
                  subtitle: l10n.aiSettingsEntryDesc,
                  onTap: () => Navigator.of(context).push(
                    AppPageRoute<void>(
                      builder: (_) => const SettingsAiScreen(),
                    ),
                  ),
                ),
                SettingsTile(
                  icon: Icons.lan_rounded,
                  title: l10n.networkSettingsTitle,
                  subtitle: l10n.networkSettingsDesc,
                  onTap: () => Navigator.of(context).push(
                    AppPageRoute<void>(
                      builder: (_) => const SettingsNetworkScreen(),
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

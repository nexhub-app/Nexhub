import 'package:flutter/material.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_animations.dart';
import '../../../core/widgets/app_list_tile.dart';
import './widgets/settings_widgets.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:nexhub/core/navigation/app_page_route.dart';
import '../../sources/presentation/source_manager_screen.dart';
import '../../home/presentation/browse_web_scrape_screen.dart';
import '../../rss/presentation/rss_feed_list_screen.dart';
import './settings_rsshub_screen.dart';
import './settings_rss_notifications_screen.dart';
import './settings_network_screen.dart';
import './settings_ai_screen.dart';

/// 配置与网络汇总页：源管理 / RSS 订阅 / 网页爬取 / AI 配置 / 网络设置入口。
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
          padding: const EdgeInsets.all(AppTokens.spaceLg),
          children: <Widget>[
            AppListTile(
              leading: const SettingsLeadingIcon(icon:Icons.extension_outlined),
              title: Text(l10n.sourceManagementTitle),
              subtitle: Text(l10n.sourceManagementDesc),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                AppPageRoute<void>(
                  builder: (_) => const SourceManagerScreen(),
                ),
              ),
            ),
            // ── RSS 订阅（全局）：与浏览页同源，显示未绑定模块的全局订阅 ──
            AppListTile(
              leading: const SettingsLeadingIcon(icon:Icons.rss_feed_outlined),
              title: Text(l10n.rssFeedListTitle),
              subtitle: Text(l10n.rssGlobalSubscriptionDesc),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                AppPageRoute<void>(
                  builder: (_) => const RssFeedListScreen(moduleType: null),
                ),
              ),
            ),
            AppListTile(
              leading: const SettingsLeadingIcon(icon:Icons.hub_outlined),
              title: Text(l10n.rsshubSettingsTitle),
              subtitle: Text(l10n.rsshubSettingsDesc),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                AppPageRoute<void>(
                  builder: (_) => const SettingsRssHubScreen(),
                ),
              ),
            ),
            AppListTile(
              leading: const SettingsLeadingIcon(icon:Icons.notifications_outlined),
              title: Text(l10n.rssNotificationsTitle),
              subtitle: Text(l10n.rssNotificationEnabledSubtitle),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                AppPageRoute<void>(
                  builder: (_) => const SettingsRssNotificationsScreen(),
                ),
              ),
            ),
            AppListTile(
              leading: const SettingsLeadingIcon(icon:Icons.travel_explore),
              title: Text(l10n.webScrapeSetting),
              subtitle: Text(l10n.webScrapeSettingSameAsBrowse),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                AppPageRoute<void>(
                  builder: (_) => const BrowseWebScrapeScreen(),
                ),
              ),
            ),
            AppListTile(
              leading: const SettingsLeadingIcon(icon:Icons.auto_awesome),
              title: Text(l10n.aiSettingsEntry),
              subtitle: Text(l10n.aiSettingsEntryDesc),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                AppPageRoute<void>(
                  builder: (_) => const SettingsAiScreen(),
                ),
              ),
            ),
            AppListTile(
              leading: const SettingsLeadingIcon(icon:Icons.lan_outlined),
              title: Text(l10n.networkSettingsTitle),
              subtitle: Text(l10n.networkSettingsDesc),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                AppPageRoute<void>(
                  builder: (_) => const SettingsNetworkScreen(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

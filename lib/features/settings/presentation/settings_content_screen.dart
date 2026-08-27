import 'package:flutter/material.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_animations.dart';
import '../../../core/widgets/app_list_tile.dart';
import './widgets/settings_widgets.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:nexhub/core/navigation/app_page_route.dart';
import '../../sources/presentation/source_manager_screen.dart';
import '../../home/presentation/browse_web_scrape_screen.dart';
import './settings_network_screen.dart';
import './settings_ai_screen.dart';

/// 配置与网络汇总页：源管理 / 网页爬取 / AI 配置 / 网络设置入口。
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
              leading: const SettingsLeadingIcon(icon:Icons.rss_feed),
              title: Text(l10n.sourceManagementTitle),
              subtitle: Text(l10n.subscriptionManagementDesc),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                AppPageRoute<void>(
                  builder: (_) => const SourceManagerScreen(),
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

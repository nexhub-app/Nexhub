import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_animations.dart';
import '../../../core/widgets/app_list_tile.dart';
import './widgets/settings_widgets.dart';
import '../../../core/services/cloud_sync_service.dart';
import '../../../core/settings/general_settings.dart';
import '../../../core/services/bangumi/bangumi_sync_service.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:nexhub/core/navigation/app_page_route.dart';
import '../../stats/presentation/stats_overview_screen.dart';
import '../../manga/presentation/image_favorite_gallery_screen.dart';
import '../../rss/presentation/rss_favorites_screen.dart';
import './settings_categories_screen.dart';
import './settings_download_screen.dart';
import './settings_import_export_screen.dart';
import './settings_cloud_sync_screen.dart';
import './settings_bangumi_screen.dart';
import './settings_dandanplay_account_screen.dart';
import '../../../core/danmaku/dandanplay_auth.dart';

/// 数据与账户汇总页：统计 / 分类 / 下载 / 备份 / 云同步 / Bangumi。
///
/// 通用设置项（启动界面 / 日期格式 / 已看阈值 / 记住位置 / 年龄限制）
/// 已迁出至对应分类页（外观与语言 / 播放与阅读 / 隐私与安全），
/// 此处不再承载全局偏好。
class SettingsDataScreen extends StatelessWidget {
  const SettingsDataScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AppShrinkTitleScaffold(
      title: Text(l10n.settingsCatData),
      body: Entrance(
        offset: 10,
        fromScale: 0.985,
        duration: AppTokens.durBase,
        child: ListView(
          padding: const EdgeInsets.all(AppTokens.spaceLg),
          children: <Widget>[
            AppListTile(
              leading: const SettingsLeadingIcon(icon:Icons.bar_chart),
              title: Text(l10n.statsOverviewTitle),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                AppPageRoute<void>(
                  builder: (_) => const StatsOverviewScreen(),
                ),
              ),
            ),
            AppListTile(
              leading: const SettingsLeadingIcon(icon:Icons.folder_outlined),
              title: Text(l10n.categoriesManageTitle),
              subtitle: Text(l10n.categoriesManageDesc),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                AppPageRoute<void>(
                  builder: (_) => const SettingsCategoriesScreen(),
                ),
              ),
            ),
            AppListTile(
              leading: const SettingsLeadingIcon(icon:Icons.download),
              title: Text(l10n.downloadManagementTitle),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                AppPageRoute<void>(
                  builder: (_) => const SettingsDownloadScreen(),
                ),
              ),
            ),
            AppListTile(
              leading: const SettingsLeadingIcon(icon:Icons.photo_library_outlined),
              title: Text(l10n.imageFavoriteGalleryTitle),
              subtitle: Text(l10n.imageFavoriteGalleryDesc),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                AppPageRoute<void>(
                  builder: (_) => const ImageFavoriteGalleryScreen(),
                ),
              ),
            ),
            AppListTile(
              leading: const SettingsLeadingIcon(icon:Icons.bookmark_outline),
              title: Text(l10n.rssFavorites),
              subtitle: Text(l10n.rssFavoritesDesc),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                AppPageRoute<void>(
                  builder: (_) => const RssFavoritesScreen(),
                ),
              ),
            ),
            AppListTile(
              leading: const SettingsLeadingIcon(icon:Icons.swap_vert),
              title: Text(l10n.dataImportExport),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                AppPageRoute<void>(
                  builder: (_) => const SettingsImportExportScreen(),
                ),
              ),
            ),
            _CloudSyncTile(
              onTap: () => Navigator.of(context).push(
                AppPageRoute<void>(
                  builder: (_) => const SettingsCloudSyncScreen(),
                ),
              ),
            ),
            _BangumiTile(
              onTap: () => Navigator.of(context).push(
                AppPageRoute<void>(
                  builder: (_) => const SettingsBangumiScreen(),
                ),
              ),
            ),
            _DandanplayTile(
              onTap: () => Navigator.of(context).push(
                AppPageRoute<void>(
                  builder: (_) => const SettingsDandanplayAccountScreen(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CloudSyncTile extends StatelessWidget {
  final VoidCallback onTap;

  const _CloudSyncTile({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Consumer<CloudSyncService>(
      builder: (context, service, _) {
        final config = service.config;
        return AnimatedBuilder(
          animation: GeneralSettingsStore.instance,
          builder: (_, __) {
            String subtitle;
            if (config.url.isEmpty) {
              subtitle = l10n.cloudSyncNotConfigured;
            } else if (config.lastSyncTimestamp == null) {
              subtitle = l10n.cloudSyncNeverSynced;
            } else {
              final dt = DateTime.fromMillisecondsSinceEpoch(
                config.lastSyncTimestamp!,
              );
              final formatted =
                  GeneralSettingsStore.instance.settings.dateFormat.format(
                dt,
                withTime: true,
              );
              subtitle = l10n.cloudSyncLastSyncTime(formatted);
            }
            return AppListTile(
              leading: const SettingsLeadingIcon(icon:Icons.cloud_sync),
              title: Text(l10n.cloudSync),
              subtitle: Text(subtitle),
              trailing: const Icon(Icons.chevron_right),
              onTap: onTap,
            );
          },
        );
      },
    );
  }
}

class _BangumiTile extends StatelessWidget {
  final VoidCallback onTap;

  const _BangumiTile({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Consumer<BangumiSyncService>(
      builder: (context, service, _) {
        return AnimatedBuilder(
          animation: GeneralSettingsStore.instance,
          builder: (_, __) {
            String subtitle;
            if (!service.auth.isLoggedIn) {
              subtitle = l10n.bangumiSettingsSubtitle;
            } else if (service.lastSyncAt == null) {
              subtitle = l10n.bangumiNeverSynced;
            } else {
              final dt = DateTime.fromMillisecondsSinceEpoch(
                service.lastSyncAt!,
              );
              final formatted =
                  GeneralSettingsStore.instance.settings.dateFormat.format(
                dt,
                withTime: true,
              );
              subtitle = l10n.bangumiLastSync(formatted);
            }
            return AppListTile(
              leading: const SettingsLeadingIcon(icon:Icons.live_tv),
              title: Text(l10n.bangumiSettings),
              subtitle: Text(subtitle),
              trailing: const Icon(Icons.chevron_right),
              onTap: onTap,
            );
          },
        );
      },
    );
  }
}

class _DandanplayTile extends StatelessWidget {
  final VoidCallback onTap;

  const _DandanplayTile({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return FutureBuilder<void>(
      future: DandanplayAuth.instance.init(),
      builder: (BuildContext ctx, AsyncSnapshot<void> snap) {
        return AnimatedBuilder(
          animation: DandanplayAuth.instance,
          builder: (_, __) {
            final auth = DandanplayAuth.instance;
            final subtitle = auth.isLoggedIn
                ? l10n.danmakuAccountLoggedInAs(auth.displayName ?? '')
                : l10n.loginStatusLoggedOut;
            return AppListTile(
              leading: const SettingsLeadingIcon(icon: Icons.chat_bubble_outline),
              title: Text(l10n.danmakuAccountSection),
              subtitle: Text(subtitle),
              trailing: const Icon(Icons.chevron_right),
              onTap: onTap,
            );
          },
        );
      },
    );
  }
}
/// 媒体服务器浏览 UI 共享小组件：海报图（带鉴权头与占位）、区块标题、
/// 在线列表 / 源管理中的服务器入口行与配置区块。
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:provider/provider.dart';

import '../../core/navigation/app_page_route.dart';
import '../../core/services/media_server/media_server_auth.dart';
import '../../core/services/media_server/media_server_models.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/utils/app_haptics.dart';
import '../../core/widgets/app_card.dart';
import '../settings/presentation/media_server_add_screen.dart';
import '../settings/presentation/media_server_manage_screen.dart';
import 'media_server_home_screen.dart';

/// 海报图：统一附鉴权头（图片端点鉴权需求以实测为准，带上无害），
/// 加载占位与失败图标兜底。
class MediaServerPoster extends StatelessWidget {
  final String url;
  final Map<String, String> headers;
  final double? width;
  final double? height;
  final BoxFit fit;

  const MediaServerPoster({
    super.key,
    required this.url,
    this.headers = const <String, String>{},
    this.width,
    this.height,
    this.fit = BoxFit.cover,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return CachedNetworkImage(
      imageUrl: url,
      httpHeaders: headers,
      width: width,
      height: height,
      fit: fit,
      fadeInDuration: const Duration(milliseconds: 150),
      placeholder: (_, __) => Container(
        color: scheme.surfaceContainerHigh,
        alignment: Alignment.center,
        child: Icon(Icons.movie_rounded, color: scheme.outline),
      ),
      errorWidget: (_, __, ___) => Container(
        color: scheme.surfaceContainerHigh,
        alignment: Alignment.center,
        child: Icon(Icons.movie_rounded, color: scheme.outline),
      ),
    );
  }
}

/// 区块标题（继续观看 / 最新添加 / 媒体库）。
class MediaServerSectionHeader extends StatelessWidget {
  final String title;

  const MediaServerSectionHeader({super.key, required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(
        left: 2,
        top: AppTokens.spaceLg,
        bottom: AppTokens.spaceSm,
      ),
      child: Text(
        title,
        style: Theme.of(context)
            .textTheme
            .titleMedium
            ?.copyWith(fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// 「在线」tab / 源管理列表中的单台服务器入口行（点击直接浏览该服务器）。
///
/// 未登录的服务器点击后进入重新登录向导；已登录直接进该服务器首页。
class MediaServerBrowseTile extends StatelessWidget {
  final MediaServerInfo server;

  const MediaServerBrowseTile({super.key, required this.server});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final loggedIn = server.loggedIn;
    final subtitle = '${server.baseUrl} · ${server.type.name}'
        '${loggedIn ? '' : ' · ${l10n.mediaServerNotLoggedIn}'}';
    return AppCard(
      onTap: () {
        AppHaptics.selectionClick();
        if (loggedIn) {
          Navigator.of(context).push(
            AppPageRoute<void>(
              builder: (_) =>
                  MediaServerHomeScreen(initialServer: server),
            ),
          );
        } else {
          Navigator.of(context).push(
            AppPageRoute<void>(
              builder: (_) => MediaServerAddScreen(existing: server),
            ),
          );
        }
      },
      padding: EdgeInsets.zero,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppTokens.spaceLg,
          vertical: AppTokens.spaceXs,
        ),
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: scheme.tertiary.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(AppTokens.radiusSm),
          ),
          child:
              Icon(Icons.video_library_rounded, color: scheme.tertiary, size: 22),
        ),
        title: Text(
          server.name,
          style: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(fontWeight: FontWeight.w500),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: AppTokens.spaceXs),
          child: Text(
            subtitle,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        trailing: Icon(Icons.chevron_right_rounded, color: scheme.outline),
      ),
    );
  }
}

/// 「添加 / 管理媒体服务器」行（源管理列表的配置入口）。
class MediaServerManageTile extends StatelessWidget {
  const MediaServerManageTile({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return AppCard(
      onTap: () {
        AppHaptics.selectionClick();
        Navigator.of(context).push(
          AppPageRoute<void>(builder: (_) => const MediaServerManageScreen()),
        );
      },
      padding: EdgeInsets.zero,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppTokens.spaceLg,
          vertical: AppTokens.spaceXs,
        ),
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(AppTokens.radiusSm),
          ),
          child: Icon(Icons.tune_rounded, color: scheme.onSurfaceVariant, size: 22),
        ),
        title: Text(
          l10n.mediaServerManageAction,
          style: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(fontWeight: FontWeight.w500),
        ),
        trailing: Icon(Icons.chevron_right_rounded, color: scheme.outline),
      ),
    );
  }
}

/// 源管理列表顶部的媒体服务器区块：每台服务器一行 + 管理 / 添加行。
class MediaServerSourceSection extends StatelessWidget {
  const MediaServerSourceSection({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<MediaServerAuth>();
    return Column(
      children: <Widget>[
        for (final s in auth.servers)
          Padding(
            padding: const EdgeInsets.only(bottom: AppTokens.spaceSm),
            child: MediaServerBrowseTile(server: s),
          ),
        const MediaServerManageTile(),
      ],
    );
  }
}

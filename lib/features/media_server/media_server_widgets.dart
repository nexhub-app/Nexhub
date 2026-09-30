/// 媒体服务器浏览 UI 共享小组件：海报图（带鉴权头与占位）、区块标题、
/// 在线源列表顶部的固定入口卡片（方案 A）。
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:provider/provider.dart';

import '../../core/navigation/app_page_route.dart';
import '../../core/services/media_server/media_server_auth.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/widgets/app_card.dart';
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

/// 「在线」tab 源列表顶部的固定「媒体服务器」入口卡片（方案 A）。
///
/// 点击进入媒体服务器首页（服务器选择 / 继续观看 / 最新添加 / 媒体库网格）；
/// 尚未连接时由首页引导前往添加。
class MediaServerEntryCard extends StatelessWidget {
  const MediaServerEntryCard({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final auth = context.watch<MediaServerAuth>();
    final connected = auth.servers.where((s) => s.loggedIn).length;
    return AppCard(
      onTap: () => Navigator.of(context).push(
        AppPageRoute<void>(builder: (_) => const MediaServerHomeScreen()),
      ),
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
          child: Icon(Icons.video_library_rounded,
              color: scheme.tertiary, size: 22),
        ),
        title: Text(
          l10n.mediaServerSettings,
          style: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(fontWeight: FontWeight.w500),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: AppTokens.spaceXs),
          child: Text(
            connected > 0
                ? l10n.mediaServerTileConnected('$connected')
                : l10n.mediaServerSettingsSubtitle,
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

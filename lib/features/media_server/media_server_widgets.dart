/// 媒体服务器浏览 UI 共享小组件：海报图（带鉴权头与占位）、区块标题、
/// 在线列表 / 源管理中的服务器入口行与配置区块。
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart'
    show PointerDeviceKind, PointerScrollEvent;
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
import '../settings/presentation/widgets/settings_widgets.dart';
import 'media_server_home_screen.dart';

/// 海报图：统一附鉴权头（图片端点鉴权需求以实测为准，带上无害），
/// 加载占位与失败图标兜底。
class MediaServerPoster extends StatelessWidget {
  final String url;
  final Map<String, String> headers;
  final double? width;
  final double? height;
  final BoxFit fit;

  /// false = 加载失败时静默（透明），供「Backdrop 叠在海报模糊层上」
  /// 的分层头图使用：Backdrop 缺失时露出底层而不显示错误块。
  final bool errorPlaceholder;

  const MediaServerPoster({
    super.key,
    required this.url,
    this.headers = const <String, String>{},
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.errorPlaceholder = true,
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
        color: errorPlaceholder
            ? scheme.surfaceContainerHigh
            : Colors.transparent,
        alignment: Alignment.center,
        child: errorPlaceholder
            ? Icon(Icons.movie_rounded, color: scheme.outline)
            : null,
      ),
      errorWidget: (_, __, ___) => Container(
        color: errorPlaceholder
            ? scheme.surfaceContainerHigh
            : Colors.transparent,
        alignment: Alignment.center,
        child: errorPlaceholder
            ? Icon(Icons.movie_rounded, color: scheme.outline)
            : null,
      ),
    );
  }
}

/// 横排海报容器：桌面端鼠标滚轮 / 拖拽均可横向滚动（对齐源选择条的处理）。
class MediaServerPosterRow extends StatefulWidget {
  final List<Widget> children;

  const MediaServerPosterRow({super.key, required this.children});

  @override
  State<MediaServerPosterRow> createState() => _MediaServerPosterRowState();
}

class _MediaServerPosterRowState extends State<MediaServerPosterRow> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: (signal) {
        // 滚轮（dy）/ 触控板（dx）统一转为横向滚动。
        if (signal is! PointerScrollEvent || !_controller.hasClients) return;
        final delta = signal.scrollDelta.dx != 0
            ? signal.scrollDelta.dx
            : signal.scrollDelta.dy;
        if (delta == 0) return;
        final target = (_controller.offset + delta).clamp(
          0.0,
          _controller.position.maxScrollExtent,
        );
        _controller.jumpTo(target);
      },
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(
          dragDevices: <PointerDeviceKind>{
            PointerDeviceKind.touch,
            PointerDeviceKind.mouse,
            PointerDeviceKind.trackpad,
            PointerDeviceKind.stylus,
          },
        ),
        child: SizedBox(
          height: 210,
          child: ListView(
            controller: _controller,
            scrollDirection: Axis.horizontal,
            children: widget.children,
          ),
        ),
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

/// 源管理列表顶部的媒体服务器区块：设置页同款分组样式，
/// 每台服务器一行 + 管理 / 添加行（同一 [Icons.dns_rounded] 图标）。
class MediaServerSourceSection extends StatelessWidget {
  const MediaServerSourceSection({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final auth = context.watch<MediaServerAuth>();
    return SettingsGroup(
      children: <Widget>[
        for (final s in auth.servers)
          SettingsTile(
            icon: Icons.dns_rounded,
            title: s.name,
            subtitle: s.loggedIn
                ? '${s.baseUrl} · ${s.type.name}'
                : '${s.baseUrl} · ${l10n.mediaServerNotLoggedIn}',
            onTap: () {
              AppHaptics.selectionClick();
              if (s.loggedIn) {
                Navigator.of(context).push(
                  AppPageRoute<void>(
                    builder: (_) => MediaServerHomeScreen(initialServer: s),
                  ),
                );
              } else {
                Navigator.of(context).push(
                  AppPageRoute<void>(
                    builder: (_) => MediaServerAddScreen(existing: s),
                  ),
                );
              }
            },
          ),
        SettingsTile(
          icon: Icons.dns_rounded,
          title: l10n.mediaServerManageAction,
          onTap: () {
            AppHaptics.selectionClick();
            Navigator.of(context).push(
              AppPageRoute<void>(
                builder: (_) => const MediaServerManageScreen(),
              ),
            );
          },
        ),
      ],
    );
  }
}

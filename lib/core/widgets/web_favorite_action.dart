/// 网络收藏（源站书架）共享操作工具。
///
/// 详情页 / 漫画阅读器 / 小说阅读器 / 视频播放器的「收藏」按钮统一调用
/// [showFavoriteSheet]：源未声明 `webFavorite` 时直接走本地收藏（保持原交互）；
/// 源声明后弹出双选项（本地收藏 / 加入网络收藏）。
///
/// 网络收藏完全声明式：app 只负责打开源作者声明的 `addUrl` / `addRoute`
/// （填充 `{id}` `{detailUrl}` `{title}` 占位符），不内置任何站点逻辑。
library;

import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';

import '../models/media_item.dart';
import '../models/plugin_config.dart';
import 'detail_action_utils.dart';

/// 弹出收藏菜单：本地收藏 + 网络收藏（二选一）。
///
/// - 源未声明 `webFavorite`（`hasWebFavoriteAdd` 为 false）→ 直接执行
///   [toggleLocalFavorite]，交互与旧版完全一致；
/// - 源已声明 → 底部菜单提供「本地收藏」「加入网络收藏」两项。
Future<void> showFavoriteSheet({
  required BuildContext context,
  required PluginConfig source,
  required MediaItem item,
  required Future<void> Function() toggleLocalFavorite,
}) async {
  final l10n = AppLocalizations.of(context);
  if (!source.hasWebFavoriteAdd) {
    await toggleLocalFavorite();
    return;
  }
  final scheme = Theme.of(context).colorScheme;
  final choice = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (BuildContext ctx) => SafeArea(
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                leading: Icon(Icons.favorite, color: scheme.primary),
                title: Text(l10n.favoriteLocal),
                subtitle: Text(l10n.favoriteLocalHint),
                onTap: () => Navigator.of(ctx).pop('local'),
              ),
              ListTile(
                leading: Icon(Icons.cloud_done_outlined, color: scheme.primary),
                title: Text(l10n.favoriteWeb),
                subtitle: source.webFavorite?.requireLogin == true
                    ? Text(l10n.favoriteWebRequiresLogin)
                    : Text(l10n.favoriteWebHint),
                onTap: () => Navigator.of(ctx).pop('web'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  if (choice == 'local') {
    await toggleLocalFavorite();
  } else if (choice == 'web') {
    await addWebFavorite(context, source, item);
  }
}

/// 加入源站网络收藏：优先 `addUrl` / `addRoute`（带占位符），否则退化打开收藏页。
Future<void> addWebFavorite(
  BuildContext context,
  PluginConfig source,
  MediaItem item,
) async {
  final url = resolveAddWebFavoriteUrl(source, item);
  if (url.isEmpty) return;
  openInAppBrowser(context, url);
}

/// 计算「加入网络收藏」的目标 URL（声明式，无站点硬编码）。
String resolveAddWebFavoriteUrl(PluginConfig source, MediaItem item) {
  final wf = source.webFavorite;
  if (wf == null) return source.site.baseUrl;

  String? template;
  if (wf.addUrl != null && wf.addUrl!.isNotEmpty) {
    template = wf.addUrl;
  } else if (wf.addRoute != null &&
      wf.addRoute!.isNotEmpty &&
      source.routes.containsKey(wf.addRoute)) {
    template = source.routes[wf.addRoute]!.url;
  }

  if (template != null && template!.isNotEmpty) {
    return _fillPlaceholders(source, template!, item);
  }
  // 未声明「加入」入口：退化打开收藏页，让用户自行操作。
  if (wf.url != null && wf.url!.isNotEmpty) {
    return _resolveAbsoluteUrl(source, wf.url!);
  }
  return source.site.baseUrl;
}

/// 填充 `{id}` / `{detailUrl}` / `{title}` 占位符并解析为绝对地址。
String _fillPlaceholders(PluginConfig source, String template, MediaItem item) {
  final filled = template
      .replaceAll('{id}', item.id)
      .replaceAll('{detailUrl}', item.detailUrl ?? '')
      .replaceAll('{title}', Uri.encodeComponent(item.title));
  return _resolveAbsoluteUrl(source, filled);
}

/// 相对 URL 拼接源站基址；绝对 URL 原样返回。
String _resolveAbsoluteUrl(PluginConfig source, String url) {
  if (url.startsWith('http://') || url.startsWith('https://')) return url;
  final base = source.site.baseUrl;
  if (base.endsWith('/') && url.startsWith('/')) {
    return '${base.substring(0, base.length - 1)}$url';
  }
  if (!base.endsWith('/') && !url.startsWith('/')) return '$base/$url';
  return '$base$url';
}

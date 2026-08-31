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
import '../network/network_config_service.dart';
import '../resolver/script_resolver.dart';
import '../scraper/http_fetcher.dart';
import '../services/config_loader.dart';
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
///
/// 若源声明了 `webFavorite.add`（选夹添加），则弹出文件夹选择并 POST 到源站。
Future<void> addWebFavorite(
  BuildContext context,
  PluginConfig source,
  MediaItem item,
) async {
  final wf = source.webFavorite;
  if (wf == null) {
    openInAppBrowser(context, source.site.baseUrl);
    return;
  }
  // 声明了「选夹添加」→ 弹文件夹选择并 POST；否则退化打开收藏页（原行为）。
  if (wf.add != null) {
    await _addWebFavoriteWithFolder(context, source, item, wf);
    return;
  }
  final url = resolveAddWebFavoriteUrl(source, item);
  if (url.isEmpty) return;
  openInAppBrowser(context, url);
}

/// 选夹添加流程：抓取收藏页解析文件夹列表 → 弹选择 sheet → POST 到源站。
Future<void> _addWebFavoriteWithFolder(
  BuildContext context,
  PluginConfig source,
  MediaItem item,
  WebFavoriteConfig wf,
) async {
  final l10n = AppLocalizations.of(context);
  final add = wf.add!;
  List<WebFavoriteFolder> folders;
  try {
    folders = await fetchWebFavoriteFolders(source);
  } on Object {
    folders = const <WebFavoriteFolder>[];
  }
  if (!context.mounted) return;

  // 第一项为空值占位 = 源站「默认收藏夹」（favcat 空，不加特定夹）。
  final options = <WebFavoriteFolder>[
    const WebFavoriteFolder('', '', ''),
    ...folders,
  ];

  final WebFavoriteFolder? choice = await showModalBottomSheet<WebFavoriteFolder>(
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
                title: Text(l10n.selectFolder),
                subtitle: Text(l10n.favoriteWeb),
              ),
              ...options.map(
                (WebFavoriteFolder f) => ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(
                    f.value.isEmpty ? l10n.webFavoriteDefaultFolder : f.title,
                  ),
                  onTap: () => Navigator.of(ctx).pop(f),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  if (choice == null) return;

  final folderValue = choice.value;
  final target =
      _fillPlaceholders(source, add.url ?? source.site.baseUrl, item, folderValue);
  final fields = <String, String>{};
  add.fields.forEach((k, v) => fields[k] = v.replaceAll('{folder}', folderValue));
  try {
    await HttpFetcher.instance.postForm(
      target,
      data: fields,
      referer: source.site.baseUrl,
      // 同列表抓取：带上源的网络档案，否则源的 IP 钉死 / 免 SNI 不生效。
      net: NetworkConfigService.instance.effectiveFor(source),
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.webFavoriteAdded)));
    }
  } on Object catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${l10n.webFavoriteAddFailed}: $e')),
      );
    }
  }
}

/// 从收藏页 HTML 解析文件夹列表（需源声明 `folders:true` 且提供
/// `parser.overrides.folders` 解析器）。失败返回空列表。
Future<List<WebFavoriteFolder>> fetchWebFavoriteFolders(
  PluginConfig source,
) async {
  final wf = source.webFavorite;
  if (wf == null || !wf.folders) return const <WebFavoriteFolder>[];
  final String baseUrl;
  if (wf.route != null && source.routes.containsKey(wf.route)) {
    baseUrl = _resolveAbsoluteUrl(source, source.routes[wf.route]!.url);
  } else if (wf.url != null && wf.url!.isNotEmpty) {
    baseUrl = _resolveAbsoluteUrl(source, wf.url!);
  } else {
    baseUrl = source.site.baseUrl;
  }
  final html = await HttpFetcher.instance.getHtml(
    baseUrl,
    referer: source.site.baseUrl,
    // 与列表抓取一致：必须带上源的网络档案，否则源的 IP 钉死 / 免 SNI 不生效。
    net: NetworkConfigService.instance.effectiveFor(source),
  );
  if (html.isEmpty) return const <WebFavoriteFolder>[];
  final r = await ScriptResolver().resolveFromHtml(
    source,
    'folders',
    html,
    vars: <String, String>{
      'baseUrl': ConfigLoader.instance.getActiveMirror(source),
      'page': '1',
    },
  );
  if (r is! List) return const <WebFavoriteFolder>[];
  final out = <WebFavoriteFolder>[];
  for (final e in r) {
    if (e is Map) {
      final rawCount = e['count'];
      final int? count = rawCount is int
          ? rawCount
          : (int.tryParse(rawCount?.toString() ?? ''));
      out.add(WebFavoriteFolder(
        (e['title'] ?? '').toString(),
        (e['url'] ?? '').toString(),
        (e['value'] ?? '').toString(),
        count: count,
      ));
    }
  }
  return out;
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

/// 填充 `{id}` / `{detailUrl}` / `{title}` / `{folder}` 占位符并解析为绝对地址。
String _fillPlaceholders(
  PluginConfig source,
  String template,
  MediaItem item, [
  String folder = '',
]) {
  final filled = template
      .replaceAll('{id}', item.id)
      .replaceAll('{detailUrl}', item.detailUrl ?? '')
      .replaceAll('{title}', Uri.encodeComponent(item.title))
      .replaceAll('{folder}', folder);
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

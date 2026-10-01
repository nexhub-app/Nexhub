/// 影视模块搜索结果顶部的媒体服务器聚合段。
///
/// - 查询词变化 400ms 防抖后，并行查所有在线服务器（Movie+Series，Limit 20），
/// 单台失败静默为空，不拖垮搜索主流程；
/// - 全部无结果时不占位；命中条目按服务器分小节横排，点击直达详情页。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:provider/provider.dart';

import '../../core/navigation/app_page_route.dart';
import '../../core/services/media_server/media_server_auth.dart';
import '../../core/services/media_server/media_server_client.dart';
import '../../core/services/media_server/media_server_models.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/utils/app_haptics.dart';
import 'media_server_detail_screen.dart';
import 'media_server_widgets.dart';

class MediaServerSearchSection extends StatefulWidget {
  final String query;

  const MediaServerSearchSection({super.key, required this.query});

  @override
  State<MediaServerSearchSection> createState() =>
      _MediaServerSearchSectionState();
}

class _MediaServerSearchSectionState extends State<MediaServerSearchSection> {
  static const int _limitPerServer = 20;

  Timer? _debounce;
  final List<MediaServerClientBase> _clients = <MediaServerClientBase>[];
  final Map<String, List<ServerMediaItem>> _results =
      <String, List<ServerMediaItem>>{};
  final Map<String, MediaServerInfo> _servers = <String, MediaServerInfo>{};
  List<String> _order = <String>[];
  bool _loading = false;
  String _searchedQuery = '';

  int get _hitCount =>
      _results.values.fold(0, (sum, list) => sum + list.length);

  @override
  void didUpdateWidget(covariant MediaServerSearchSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    final q = widget.query.trim();
    if (q == _searchedQuery) return;
    _debounce?.cancel();
    if (q.isEmpty) {
      setState(() {
        _searchedQuery = '';
        _results.clear();
        _order = <String>[];
        _loading = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 400), () => _search(q));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    for (final c in _clients) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _search(String q) async {
    final auth = context.read<MediaServerAuth>();
    final logged = auth.servers.where((s) => s.loggedIn).toList();
    if (logged.isEmpty) return;
    final deviceId = await auth.deviceId();
    if (!mounted) return;
    // 重建客户端（旧实例在替换后释放）。
    final old = List<MediaServerClientBase>.from(_clients);
    _clients
      ..clear()
      ..addAll(<MediaServerClientBase>[
        for (final s in logged)
          MediaServerClientBase.createServerClient(
            s,
            deviceId: deviceId,
            token: await auth.tokenOf(s.id),
          ),
      ]);
    old
      ..removeWhere((c) => _clients.contains(c))
      ..forEach((c) => c.dispose());
    if (!mounted) return;
    setState(() {
      _loading = true;
      _searchedQuery = q;
      _results.clear();
      _servers
        ..clear()
        ..addEntries(logged.map((s) => MapEntry(s.id, s)));
      _order = logged.map((s) => s.id).toList();
    });
    final entries = await Future.wait(<Future<MapEntry<String, List<ServerMediaItem>>>>[
      for (var i = 0; i < logged.length; i++)
        _clients[i]
            .fetchItems(
              searchTerm: q,
              includeTypes: const <String>['Movie', 'Series'],
              limit: _limitPerServer,
            )
            .then(
              (page) => MapEntry<String, List<ServerMediaItem>>(
                logged[i].id,
                page.items,
              ),
            )
            .catchError((
              Object _,
            ) =>
                MapEntry<String, List<ServerMediaItem>>(
                  logged[i].id,
                  const <ServerMediaItem>[],
                )),
    ]);
    if (!mounted) return;
    // 串台守卫——期间若已发起新查询，丢弃过期结果。
    if (q != _searchedQuery) return;
    setState(() {
      for (final e in entries) {
        _results[e.key] = e.value;
      }
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_searchedQuery.isEmpty || (!_loading && _hitCount == 0)) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppTokens.spaceMd,
            AppTokens.spaceSm,
            AppTokens.spaceMd,
            0,
          ),
          child: Row(
            children: <Widget>[
              Icon(Icons.dns_rounded, size: 16, color: scheme.tertiary),
              const SizedBox(width: AppTokens.spaceXs),
              Text(
                l10n.mediaServerSettings,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 150,
          child: _loading
              ? const Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.all(AppTokens.spaceMd),
                  children: <Widget>[
                    for (final serverId in _order)
                      for (final item in _results[serverId] ??
                          const <ServerMediaItem>[])
                        _SearchHitCard(
                          client: _clientFor(serverId),
                          item: item,
                          serverName: _servers[serverId]?.name ?? '',
                        ),
                  ],
                ),
        ),
      ],
    );
  }

  MediaServerClientBase? _clientFor(String serverId) {
    for (final c in _clients) {
      if (c.info.id == serverId) return c;
    }
    return null;
  }
}

/// 搜索命中卡：小海报 + 标题 + 服务器名，点击直达详情。
class _SearchHitCard extends StatelessWidget {
  final MediaServerClientBase? client;
  final ServerMediaItem item;
  final String serverName;

  const _SearchHitCard({
    required this.client,
    required this.item,
    required this.serverName,
  });

  @override
  Widget build(BuildContext context) {
    final c = client;
    if (c == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return MediaServerPressableScale(
      onTap: () {
        AppHaptics.selectionClick();
        Navigator.of(context).push(
          AppPageRoute<void>(
            builder: (_) => MediaServerDetailScreen(
              client: c,
              itemId: item.seriesId ?? item.id,
            ),
          ),
        );
      },
      child: SizedBox(
        width: 96,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppTokens.radiusSm),
                child: MediaServerPoster(
                  url: c.imageUrl(item.id, maxWidth: 240),
                  headers: c.authHeaders(),
                ),
              ),
            ),
            const SizedBox(height: AppTokens.spaceXs),
            Text(
              item.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: scheme.onSurface),
            ),
            Text(
              serverName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

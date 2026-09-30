/// 媒体服务器首页：继续观看横排 + 最新添加横排 + 媒体库网格。
///
/// - 多服务器：顶部 ChoiceChip 切换（一台时隐藏）；每台一个客户端实例，
///   由本页持有并释放，推入的库浏览 / 详情页不负责释放；
/// - 进度只存服务器：继续观看行点击 → 直连播放并 seek 到服务器进度；
/// - 音乐 / 图片等其他类型库首版隐藏并提示（§2.5 边界：不进本地体系）。
library;

import 'package:material_ui/material_ui.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:provider/provider.dart';

import '../../core/navigation/app_page_route.dart';
import '../../core/services/media_server/media_server_auth.dart';
import '../../core/services/media_server/media_server_client.dart';
import '../../core/services/media_server/media_server_models.dart';
import '../../core/services/media_server/media_server_session.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/utils/app_haptics.dart';
import '../../core/widgets/app_card.dart';
import '../settings/presentation/media_server_manage_screen.dart';
import 'media_server_detail_screen.dart';
import 'media_server_library_screen.dart';
import 'media_server_widgets.dart';

/// 首页一次性加载的三块数据。
class _HomeData {
  final ServerItemPage resume;
  final List<ServerMediaItem> latest;
  final List<ServerLibrary> libraries;

  const _HomeData({
    required this.resume,
    required this.latest,
    required this.libraries,
  });
}

class MediaServerHomeScreen extends StatefulWidget {
  const MediaServerHomeScreen({super.key, this.initialServer});

  /// 从在线列表 / 源管理点入时直接定位到该服务器（多台时仍可页内切换）。
  final MediaServerInfo? initialServer;

  @override
  State<MediaServerHomeScreen> createState() => _MediaServerHomeScreenState();
}

class _MediaServerHomeScreenState extends State<MediaServerHomeScreen> {
  MediaServerClientBase? _client;

  /// 当前激活服务器（多台切换用；null = 尚未选择）。
  MediaServerInfo? _active;
  Future<_HomeData>? _future;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _selectInitial());
  }

  @override
  void dispose() {
    _client?.dispose();
    super.dispose();
  }

  void _selectInitial() {
    if (!mounted) return;
    final auth = context.read<MediaServerAuth>();
    final logged = auth.servers.where((s) => s.loggedIn).toList();
    if (logged.isEmpty) return;
    // 入口指定且仍有效则定位到该服务器，否则回落第一台已登录的。
    final initial = widget.initialServer;
    final target = (initial != null && logged.any((s) => s.id == initial.id))
        ? initial
        : logged.first;
    _switchTo(target);
  }

  void _switchTo(MediaServerInfo server) {
    if (server.id == _active?.id) return;
    setState(() {
      _active = server;
      _future = _loadData(server);
    });
  }

  Future<_HomeData> _loadData(MediaServerInfo info) async {
    final auth = context.read<MediaServerAuth>();
    final token = await auth.tokenOf(info.id);
    final deviceId = await auth.deviceId();
    final client = MediaServerClientBase.createServerClient(
      info,
      deviceId: deviceId,
      token: token,
    );
    final old = _client;
    _client = client;
    old?.dispose();
    final results = await Future.wait(<Future<Object>>[
      client.fetchResume(limit: 20),
      client.fetchLatest(limit: 15),
      client.fetchLibraries(),
    ]);
    return _HomeData(
      resume: results[0] as ServerItemPage,
      latest: results[1] as List<ServerMediaItem>,
      libraries: results[2] as List<ServerLibrary>,
    );
  }

  void _reload() {
    final active = _active;
    if (active == null) return;
    setState(() => _future = _loadData(active));
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final auth = context.watch<MediaServerAuth>();
    final logged = auth.servers.where((s) => s.loggedIn).toList();

    return Scaffold(
      appBar: AppBar(title: Text(l10n.mediaServerSettings)),
      body: logged.isEmpty
          ? _EmptyServers(onAdd: _openManage)
          : _buildBody(context, logged, l10n),
    );
  }

  Widget _buildBody(
    BuildContext context,
    List<MediaServerInfo> logged,
    AppLocalizations l10n,
  ) {
    // 激活服务器失效（被删除 / 登出）时回落到第一台；不在 build 内直接
    // setState，排到帧后再切。
    final active = (_active != null && logged.any((s) => s.id == _active!.id))
        ? _active!
        : logged.first;
    if (active.id != _active?.id) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _switchTo(active));
    }
    return RefreshIndicator(
      onRefresh: () async => _reload(),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(AppTokens.spaceMd),
        children: <Widget>[
          if (logged.length > 1) ...<Widget>[
            _serverSwitcher(logged),
            const SizedBox(height: AppTokens.spaceSm),
          ],
          FutureBuilder<_HomeData>(
            future: _future,
            builder: (context, snap) {
              if (snap.hasError) {
                return _ErrorRetry(
                  message: l10n.mediaServerLoadFailed('${snap.error}'),
                  onRetry: _reload,
                );
              }
              if (!snap.hasData) {
                return const Padding(
                  padding: EdgeInsets.all(AppTokens.spaceXl),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final client = _client;
              if (client == null) return const SizedBox.shrink();
              return _content(context, client, snap.data!, l10n);
            },
          ),
        ],
      ),
    );
  }

  Widget _serverSwitcher(List<MediaServerInfo> logged) {
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: <Widget>[
          for (final s in logged)
            Padding(
              padding: const EdgeInsets.only(right: AppTokens.spaceSm),
              child: ChoiceChip(
                label: Text(s.name),
                selected: s.id == _active?.id,
                onSelected: (_) {
                  AppHaptics.selectionClick();
                  _switchTo(s);
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _content(
    BuildContext context,
    MediaServerClientBase client,
    _HomeData data,
    AppLocalizations l10n,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // ───── 继续观看 ─────
        if (data.resume.items.isNotEmpty) ...<Widget>[
          MediaServerSectionHeader(title: l10n.mediaServerHomeResume),
          _posterRow(
            data.resume.items
                .map((item) => _ResumeCard(
                      client: client,
                      item: item,
                      onPlayed: _reload,
                    ))
                .toList(),
          ),
        ],
        // ───── 最新添加 ─────
        if (data.latest.isNotEmpty) ...<Widget>[
          MediaServerSectionHeader(title: l10n.mediaServerHomeLatest),
          _posterRow(
            data.latest
                .map((item) => _LatestCard(client: client, item: item))
                .toList(),
          ),
        ],
        // ───── 媒体库 ─────
        MediaServerSectionHeader(title: l10n.mediaServerHomeLibraries),
        _LibraryGrid(client: client, libraries: data.libraries),
      ],
    );
  }

  /// 横排海报容器（统一高度）。
  Widget _posterRow(List<Widget> children) {
    return SizedBox(
      height: 210,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: children,
      ),
    );
  }

  Future<void> _openManage() async {
    await Navigator.of(context).push(
      AppPageRoute<void>(
        builder: (_) => const MediaServerManageScreen(),
      ),
    );
    _selectInitial();
  }
}

/// 横排海报卡公共骨架：海报 2:3（可带底部进度条）+ 标题。
class _PosterTile extends StatelessWidget {
  final MediaServerClientBase client;
  final ServerMediaItem item;
  final VoidCallback onTap;

  /// 0~1 的观看进度（继续观看卡用；null = 不显示）。
  final double? progress;

  const _PosterTile({
    required this.client,
    required this.item,
    required this.onTap,
    this.progress,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = (item.seriesName != null && item.seriesName!.isNotEmpty)
        ? item.seriesName!
        : item.name;
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 118,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppTokens.radiusMd),
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    MediaServerPoster(
                      url: client.imageUrl(item.id, maxWidth: 300),
                      headers: client.authHeaders(),
                    ),
                    if (progress != null)
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 3,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppTokens.spaceXs),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurface),
            ),
          ],
        ),
      ),
    );
  }
}

/// 继续观看卡：底部叠加服务器进度条，点击直连播放并 seek。
class _ResumeCard extends StatelessWidget {
  final MediaServerClientBase client;
  final ServerMediaItem item;
  final VoidCallback onPlayed;

  const _ResumeCard({
    required this.client,
    required this.item,
    required this.onPlayed,
  });

  @override
  Widget build(BuildContext context) {
    final ticks = item.userData?.playbackPositionTicks ?? 0;
    final runtime = item.runTimeTicks ?? 0;
    final double? ratio =
        (runtime > 0 && ticks > 0) ? (ticks / runtime).clamp(0.0, 1.0) : null;
    return _PosterTile(
      client: client,
      item: item,
      progress: ratio,
      onTap: () async {
        AppHaptics.selectionClick();
        await openMediaServerPlayer(context, client: client, item: item);
        onPlayed();
      },
    );
  }
}

/// 最新添加卡：点击进详情（集 → 所属剧集详情）。
class _LatestCard extends StatelessWidget {
  final MediaServerClientBase client;
  final ServerMediaItem item;

  const _LatestCard({required this.client, required this.item});

  @override
  Widget build(BuildContext context) {
    return _PosterTile(
      client: client,
      item: item,
      onTap: () {
        AppHaptics.selectionClick();
        final detailId = item.seriesId ?? item.id;
        Navigator.of(context).push(
          AppPageRoute<void>(
            builder: (_) =>
                MediaServerDetailScreen(client: client, itemId: detailId),
          ),
        );
      },
    );
  }
}

/// 媒体库网格：只显示电影 / 剧集库，其余隐藏并提示。
class _LibraryGrid extends StatelessWidget {
  final MediaServerClientBase client;
  final List<ServerLibrary> libraries;

  const _LibraryGrid({required this.client, required this.libraries});

  static const Set<String> _supported = <String>{'movies', 'tvshows'};

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final supported = libraries
        .where((l) =>
            l.collectionType == null || _supported.contains(l.collectionType))
        .toList();
    final hidden = libraries.length - supported.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: AppTokens.spaceSm,
          crossAxisSpacing: AppTokens.spaceSm,
          childAspectRatio: 3.4,
          children: <Widget>[
            for (final lib in supported)
              AppCard(
                onTap: () {
                  AppHaptics.selectionClick();
                  Navigator.of(context).push(
                    AppPageRoute<void>(
                      builder: (_) => MediaServerLibraryScreen(
                        client: client,
                        library: lib,
                      ),
                    ),
                  );
                },
                padding: const EdgeInsets.symmetric(
                  horizontal: AppTokens.spaceMd,
                ),
                child: Row(
                  children: <Widget>[
                    Icon(
                      lib.collectionType == 'tvshows'
                          ? Icons.live_tv_rounded
                          : Icons.movie_rounded,
                      size: 20,
                      color: scheme.tertiary,
                    ),
                    const SizedBox(width: AppTokens.spaceSm),
                    Expanded(
                      child: Text(
                        lib.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
        if (hidden > 0) ...<Widget>[
          const SizedBox(height: AppTokens.spaceSm),
          Text(
            l10n.mediaServerUnsupportedLibraries,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
        ],
      ],
    );
  }
}

/// 加载失败 + 重试。
class _ErrorRetry extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorRetry({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(AppTokens.spaceLg),
      child: Column(
        children: <Widget>[
          Icon(Icons.cloud_off_rounded, color: scheme.outline, size: 40),
          const SizedBox(height: AppTokens.spaceMd),
          Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: AppTokens.spaceMd),
          OutlinedButton(
            onPressed: onRetry,
            child: Text(AppLocalizations.of(context).mediaServerRetry),
          ),
        ],
      ),
    );
  }
}

/// 尚未连接任何服务器。
class _EmptyServers extends StatelessWidget {
  final VoidCallback onAdd;

  const _EmptyServers({required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.spaceXl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.dns_rounded, size: 56, color: scheme.outline),
            const SizedBox(height: AppTokens.spaceMd),
            Text(
              l10n.mediaServerEmptyHint,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: AppTokens.spaceLg),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add_rounded),
              label: Text(l10n.mediaServerGoAdd),
            ),
          ],
        ),
      ),
    );
  }
}

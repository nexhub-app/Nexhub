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
import '../../core/widgets/app_animations.dart';
import '../../core/widgets/app_card.dart';
import '../../core/widgets/app_shimmer.dart';
import '../settings/presentation/media_server_manage_screen.dart';
import 'media_server_detail_screen.dart';
import 'media_server_library_screen.dart';
import 'media_server_widgets.dart';

/// 首页一次性加载的数据块。
class _HomeData {
  final ServerItemPage resume;
  final List<ServerMediaItem> latest;
  final List<ServerLibrary> libraries;

  /// 我的收藏（B1；仅非空渲染，失败静默为空）。
  final List<ServerMediaItem> favorites;

  /// NextUp 追更（B2；仅剧集库服务器请求，空不渲染）。
  final List<ServerMediaItem> nextUp;

  const _HomeData({
    required this.resume,
    required this.latest,
    required this.libraries,
    this.favorites = const <ServerMediaItem>[],
    this.nextUp = const <ServerMediaItem>[],
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
    final libraries = results[2] as List<ServerLibrary>;
    // B 包：收藏 / NextUp（失败静默降级为空，不拖垮首页）。
    var favorites = <ServerMediaItem>[];
    var nextUp = <ServerMediaItem>[];
    try {
      favorites = await client.fetchFavorites(limit: 15);
    } on Object {
      favorites = const <ServerMediaItem>[];
    }
    if (libraries.any((l) => l.collectionType == 'tvshows')) {
      try {
        nextUp = await client.fetchNextUp(limit: 15);
      } on Object {
        nextUp = const <ServerMediaItem>[];
      }
    }
    return _HomeData(
      resume: results[0] as ServerItemPage,
      latest: results[1] as List<ServerMediaItem>,
      libraries: libraries,
      favorites: favorites,
      nextUp: nextUp,
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
          // ── 服务器信息头（C2）：名称 + 类型徽标 + 状态点 + 管理入口 ──
          _ServerHeader(server: active, onManage: _openManage),
          const SizedBox(height: AppTokens.spaceSm),
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
              if (!snap.hasData) return const _HomeSkeleton();
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
          Entrance(
            onceKey: 'ms_home_resume',
            offset: 12,
            child: MediaServerSectionHeader(
              title: l10n.mediaServerHomeResume,
            ),
          ),
          Entrance(
            onceKey: 'ms_home_resume_row',
            offset: 16,
            child: MediaServerPosterRow(
              children: data.resume.items
                  .map((item) => _ResumeCard(
                        client: client,
                        item: item,
                        onPlayed: _reload,
                      ))
                  .toList(),
            ),
          ),
        ],
        // ───── 接下来观看（B2 NextUp，空不渲染）─────
        if (data.nextUp.isNotEmpty) ...<Widget>[
          Entrance(
            onceKey: 'ms_home_nextup',
            offset: 12,
            child: MediaServerSectionHeader(
              title: l10n.mediaServerNextUp,
            ),
          ),
          Entrance(
            onceKey: 'ms_home_nextup_row',
            offset: 16,
            child: MediaServerPosterRow(
              children: data.nextUp
                  .map((item) => _LatestCard(client: client, item: item))
                  .toList(),
            ),
          ),
        ],
        // ───── 最新添加 ─────
        if (data.latest.isNotEmpty) ...<Widget>[
          Entrance(
            onceKey: 'ms_home_latest',
            offset: 12,
            child: MediaServerSectionHeader(
              title: l10n.mediaServerHomeLatest,
            ),
          ),
          Entrance(
            onceKey: 'ms_home_latest_row',
            offset: 16,
            child: MediaServerPosterRow(
              children: data.latest
                  .map((item) => _LatestCard(client: client, item: item))
                  .toList(),
            ),
          ),
        ],
        // ───── 我的收藏（B1，仅非空渲染）─────
        if (data.favorites.isNotEmpty) ...<Widget>[
          Entrance(
            onceKey: 'ms_home_favorites',
            offset: 12,
            child: MediaServerSectionHeader(
              title: l10n.mediaServerFavorites,
            ),
          ),
          Entrance(
            onceKey: 'ms_home_favorites_row',
            offset: 16,
            child: MediaServerPosterRow(
              children: data.favorites
                  .map((item) => _LatestCard(client: client, item: item))
                  .toList(),
            ),
          ),
        ],
        // ───── 媒体库 ─────
        Entrance(
          onceKey: 'ms_home_libraries',
          offset: 12,
          child: MediaServerSectionHeader(
            title: l10n.mediaServerHomeLibraries,
          ),
        ),
        Entrance(
          onceKey: 'ms_home_libraries_grid',
          offset: 16,
          child: _LibraryGrid(client: client, libraries: data.libraries),
        ),
      ],
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

/// 服务器信息头（C2）：激活服务器名称 + 类型徽标 + 状态点 + 管理入口。
/// 探活状态点是 F2 里程碑的占位（已登录显示主色点）。
class _ServerHeader extends StatelessWidget {
  final MediaServerInfo server;
  final VoidCallback onManage;

  const _ServerHeader({required this.server, required this.onManage});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return AppCard(
      padding: EdgeInsets.zero,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppTokens.spaceLg,
          vertical: AppTokens.spaceXs,
        ),
        leading: Stack(
          children: <Widget>[
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: scheme.tertiary.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(AppTokens.radiusSm),
              ),
              child: Icon(Icons.dns_rounded, color: scheme.tertiary, size: 22),
            ),
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: scheme.primary,
                  shape: BoxShape.circle,
                  border: Border.all(color: scheme.surface, width: 1.5),
                ),
              ),
            ),
          ],
        ),
        title: Text(
          server.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(fontWeight: FontWeight.w500),
        ),
        subtitle: Text(
          server.type.name.toUpperCase(),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                letterSpacing: 0.5,
              ),
        ),
        trailing: IconButton(
          icon: const Icon(Icons.settings_rounded),
          tooltip: l10n.mediaServerManageAction,
          onPressed: onManage,
        ),
      ),
    );
  }
}

/// 横排海报卡公共骨架：海报 2:3（可带底部进度条）+ 标题 + 可选副标题。
class _PosterTile extends StatelessWidget {
  final MediaServerClientBase client;
  final ServerMediaItem item;
  final VoidCallback onTap;

  /// 0~1 的观看进度（继续观看卡用；null = 不显示）。
  final double? progress;

  /// 标题下方的副标题（继续观看卡显示剩余时长）。
  final String? subtitle;

  const _PosterTile({
    required this.client,
    required this.item,
    required this.onTap,
    this.progress,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = (item.seriesName != null && item.seriesName!.isNotEmpty)
        ? item.seriesName!
        : item.name;
    return MediaServerPressableScale(
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
                    // 已看徽章（媒体库客户端通行样式：右上角半透明对勾，
                    // 出现带 200ms 缩放过渡）。
                    if (item.userData?.played == true)
                      Positioned(
                        top: 6,
                        right: 6,
                        child: AnimatedScale(
                          scale: 1,
                          duration: const Duration(milliseconds: 200),
                          child: Container(
                            padding: const EdgeInsets.all(2),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.55),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.check_rounded,
                              size: 14,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    if (progress != null)
                      // 服务器进度条：白色轨道 + 主色进度（叠图底部）。
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: ClipRRect(
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(2),
                          ),
                          child: LinearProgressIndicator(
                            value: progress,
                            minHeight: 4,
                            backgroundColor: Colors.white.withValues(
                              alpha: 0.25,
                            ),
                          ),
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
            if (subtitle != null)
              Text(
                subtitle!,
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
    // 剩余时长（C2：Resume 卡片海报缩略 + 剩余分钟）。
    String? subtitle;
    if (runtime > 0 && ticks > 0) {
      final remainingMin =
          ((runtime - ticks) ~/ 10000 ~/ 1000 ~/ 60).clamp(0, 100000);
      if (remainingMin > 0) {
        subtitle = AppLocalizations.of(context)
            .mediaServerRemaining('$remainingMin');
      }
    }
    return _PosterTile(
      client: client,
      item: item,
      progress: ratio,
      subtitle: subtitle,
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

/// 加载骨架（MD3 微光占位）：与真实布局同构——标题条 + 横排海报 + 库格。
class _HomeSkeleton extends StatelessWidget {
  const _HomeSkeleton();

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: 0.7,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const AppShimmer(width: 88, height: 18),
          const SizedBox(height: AppTokens.spaceSm),
          SizedBox(
            height: 210,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: <Widget>[
                for (var i = 0; i < 4; i++)
                  const Padding(
                    padding: EdgeInsets.only(right: AppTokens.spaceSm),
                    child: AppShimmer(
                      width: 118,
                      height: 190,
                      borderRadius: AppTokens.radiusMd,
                      phase: 0.15,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: AppTokens.spaceMd),
          const AppShimmer(width: 88, height: 18, phase: 0.3),
          const SizedBox(height: AppTokens.spaceSm),
          Row(
            children: <Widget>[
              for (var i = 0; i < 3; i++)
                const Padding(
                  padding: EdgeInsets.only(right: AppTokens.spaceSm),
                  child: AppShimmer(
                    width: 118,
                    height: 190,
                    borderRadius: AppTokens.radiusMd,
                    phase: 0.45,
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppTokens.spaceMd),
          const AppShimmer(width: 88, height: 18, phase: 0.6),
          const SizedBox(height: AppTokens.spaceSm),
          Row(
            children: <Widget>[
              for (var i = 0; i < 2; i++)
                Padding(
                  padding: const EdgeInsets.only(right: AppTokens.spaceSm),
                  child: AppShimmer(
                    width: MediaQuery.sizeOf(context).width / 2 - 24,
                    height: 52,
                    borderRadius: AppTokens.radiusMd,
                    phase: 0.75,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

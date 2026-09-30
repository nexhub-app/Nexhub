/// 媒体服务器条目详情页：海报 / 年份 / 简介。
///
/// - 电影 → 播放按钮（有续播位置时给「继续播放」+「从头播放」）；
/// - 剧集 → 季切换 + 集列表（缩略图、时长、已看角标、未看完进度条）→
///   点击集直接播放；返回后刷新已看角标与进度（进度只存服务器）；
/// - 含图形字幕（PGS）的集标注「需转码，暂不支持」。
library;

import 'package:material_ui/material_ui.dart';
import 'package:nexhub/generated/app_localizations.dart';

import '../../core/services/media_server/media_server_client.dart';
import '../../core/services/media_server/media_server_models.dart';
import '../../core/services/media_server/media_server_session.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/utils/app_haptics.dart';
import 'media_server_widgets.dart';

class MediaServerDetailScreen extends StatefulWidget {
  final MediaServerClientBase client;
  final String itemId;

  const MediaServerDetailScreen({
    super.key,
    required this.client,
    required this.itemId,
  });

  @override
  State<MediaServerDetailScreen> createState() =>
      _MediaServerDetailScreenState();
}

class _MediaServerDetailScreenState extends State<MediaServerDetailScreen> {
  ServerMediaItem? _detail;
  Object? _error;
  bool _loading = true;

  /// 剧集：季列表与当前选中季的集列表。
  List<ServerMediaItem>? _seasons;
  String? _selectedSeasonId;
  List<ServerMediaItem>? _episodes;
  Object? _episodesError;
  bool _episodesLoading = false;

  bool get _isSeries => _detail?.type == 'Series';

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await widget.client.fetchItem(widget.itemId);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _loading = false;
      });
      if (detail.type == 'Series') {
        await _loadSeasons();
      }
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _loadSeasons() async {
    try {
      final seasons = await widget.client.fetchSeasons(widget.itemId);
      if (!mounted) return;
      setState(() {
        _seasons = seasons;
        _selectedSeasonId = seasons.isNotEmpty ? seasons.first.id : null;
      });
      await _loadEpisodes();
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _episodesError = e);
    }
  }

  Future<void> _loadEpisodes() async {
    final seasonId = _selectedSeasonId;
    if (seasonId == null) return;
    setState(() {
      _episodesLoading = true;
      _episodesError = null;
    });
    try {
      final episodes =
          await widget.client.fetchEpisodes(widget.itemId, seasonId: seasonId);
      if (!mounted) return;
      setState(() {
        _episodes = episodes;
        _episodesLoading = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _episodesError = e;
        _episodesLoading = false;
      });
    }
  }

  /// 播放后返回刷新：进度 / 已看角标以服务器为准。
  Future<void> _play(ServerMediaItem item, {bool fromStart = false}) async {
    AppHaptics.selectionClick();
    await openMediaServerPlayer(
      context,
      client: widget.client,
      item: item,
      fromStart: fromStart,
    );
    if (_isSeries) {
      await _loadEpisodes();
    }
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(_detail?.name ?? l10n.mediaServerSettings)),
      body: _buildBody(context, l10n),
    );
  }

  Widget _buildBody(BuildContext context, AppLocalizations l10n) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppTokens.spaceLg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                l10n.mediaServerLoadFailed('$_error'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: AppTokens.spaceMd),
              OutlinedButton(
                onPressed: _reload,
                child: Text(l10n.mediaServerRetry),
              ),
            ],
          ),
        ),
      );
    }
    final detail = _detail;
    if (detail == null) return const SizedBox.shrink();
    return ListView(
      padding: const EdgeInsets.all(AppTokens.spaceMd),
      children: <Widget>[
        _header(context, detail),
        if (detail.type != 'Series') ..._movieActions(context, detail, l10n),
        if (detail.overview != null && detail.overview!.isNotEmpty) ...<Widget>[
          const SizedBox(height: AppTokens.spaceMd),
          Text(
            detail.overview!,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  height: 1.5,
                ),
          ),
        ],
        if (_isSeries) ..._seriesSection(context, l10n),
      ],
    );
  }

  Widget _header(BuildContext context, ServerMediaItem detail) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final runtime = detail.runTimeTicks;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        ClipRRect(
          borderRadius: BorderRadius.circular(AppTokens.radiusMd),
          child: SizedBox(
            width: 110,
            height: 165,
            child: MediaServerPoster(
              url: widget.client.imageUrl(detail.id, maxWidth: 400),
              headers: widget.client.authHeaders(),
            ),
          ),
        ),
        const SizedBox(width: AppTokens.spaceMd),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                detail.name,
                style: textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: AppTokens.spaceXs),
              Wrap(
                spacing: AppTokens.spaceSm,
                runSpacing: AppTokens.spaceXs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  if (detail.productionYear != null)
                    Text(
                      '${detail.productionYear}',
                      style: textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  if (detail.type == 'Series')
                    Text(
                      l10n.mediaServerTypeSeries,
                      style: textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    )
                  else if (runtime != null && runtime > 0)
                    Text(
                      _formatRuntime(runtime),
                      style: textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 电影：播放按钮组（有续播位置时二选一）。
  List<Widget> _movieActions(
    BuildContext context,
    ServerMediaItem detail,
    AppLocalizations l10n,
  ) {
    final hasPosition = (detail.userData?.playbackPositionTicks ?? 0) > 0;
    return <Widget>[
      const SizedBox(height: AppTokens.spaceLg),
      FilledButton.icon(
        onPressed: () => _play(detail),
        icon: const Icon(Icons.play_arrow_rounded),
        label: Text(hasPosition
            ? l10n.mediaServerResumePlay
            : l10n.mediaServerPlay),
      ),
      if (hasPosition) ...<Widget>[
        const SizedBox(height: AppTokens.spaceSm),
        OutlinedButton.icon(
          onPressed: () => _play(detail, fromStart: true),
          icon: const Icon(Icons.replay_rounded),
          label: Text(l10n.mediaServerPlayFromStart),
        ),
      ],
    ];
  }

  /// 剧集：季切换 + 集列表。
  List<Widget> _seriesSection(BuildContext context, AppLocalizations l10n) {
    final seasons = _seasons;
    if (seasons == null) {
      return const <Widget>[
        Padding(
          padding: EdgeInsets.all(AppTokens.spaceLg),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    return <Widget>[
      const SizedBox(height: AppTokens.spaceLg),
      if (seasons.length > 1)
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: <Widget>[
              for (final s in seasons)
                Padding(
                  padding: const EdgeInsets.only(right: AppTokens.spaceSm),
                  child: ChoiceChip(
                    label: Text(s.name),
                    selected: s.id == _selectedSeasonId,
                    onSelected: (_) {
                      AppHaptics.selectionClick();
                      setState(() => _selectedSeasonId = s.id);
                      _loadEpisodes();
                    },
                  ),
                ),
            ],
          ),
        ),
      if (_episodesLoading)
        const Padding(
          padding: EdgeInsets.all(AppTokens.spaceLg),
          child: Center(child: CircularProgressIndicator()),
        )
      else if (_episodesError != null)
        Text(
          l10n.mediaServerLoadFailed('$_episodesError'),
          style: Theme.of(context).textTheme.bodySmall,
        )
      else
        for (final ep in _episodes ?? const <ServerMediaItem>[])
          _EpisodeCard(
            client: widget.client,
            episode: ep,
            onTap: () => _play(ep),
          ),
    ];
  }

  /// 100ns ticks → 「x 小时 y 分 / y 分钟」。
  String _formatRuntime(int ticks) {
    final l10n = AppLocalizations.of(context);
    final totalMinutes = ticks ~/ 10000 ~/ 1000 ~/ 60;
    if (totalMinutes >= 60) {
      return l10n.mediaServerRuntimeHoursMinutes(
        '${totalMinutes ~/ 60}',
        '${totalMinutes % 60}',
      );
    }
    return l10n.mediaServerRuntimeMinutes('$totalMinutes');
  }
}

/// 集卡片：缩略图 / 时长 / 已看角标 / 未看完进度条 / PGS 标注。
class _EpisodeCard extends StatelessWidget {
  final MediaServerClientBase client;
  final ServerMediaItem episode;
  final VoidCallback onTap;

  const _EpisodeCard({
    required this.client,
    required this.episode,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final userData = episode.userData;
    final played = userData?.played ?? false;
    final ticks = userData?.playbackPositionTicks ?? 0;
    final runtime = episode.runTimeTicks ?? 0;
    final progress =
        (runtime > 0 && ticks > 0 && !played) ? (ticks / runtime).clamp(0.0, 1.0) : null;

    return Card(
      margin: const EdgeInsets.only(bottom: AppTokens.spaceSm),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppTokens.spaceSm),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Stack(
                children: <Widget>[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(AppTokens.radiusSm),
                    child: SizedBox(
                      width: 110,
                      height: 62,
                      child: MediaServerPoster(
                        url: client.imageUrl(episode.id, maxWidth: 300),
                        headers: client.authHeaders(),
                      ),
                    ),
                  ),
                  if (played)
                    Positioned(
                      top: 4,
                      right: 4,
                      child: CircleAvatar(
                        radius: 10,
                        backgroundColor: scheme.primary,
                        child: Icon(
                          Icons.check_rounded,
                          size: 14,
                          color: scheme.onPrimary,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: AppTokens.spaceSm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      (episode.parentIndexNumber != null &&
                              episode.indexNumber != null)
                          ? '${episode.parentIndexNumber}'
                              'x${episode.indexNumber.toString().padLeft(2, '0')}'
                              ' ${episode.name}'
                          : episode.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodyMedium,
                    ),
                    const SizedBox(height: AppTokens.spaceXs),
                    if (runtime > 0)
                      Text(
                        l10n.mediaServerRuntimeMinutes(
                          '${runtime ~/ 10000 ~/ 1000 ~/ 60}',
                        ),
                        style: textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    if (progress != null) ...<Widget>[
                      const SizedBox(height: AppTokens.spaceXs),
                      LinearProgressIndicator(
                        value: progress,
                        minHeight: 3,
                      ),
                    ],
                    if (episode.hasGraphicSubtitle) ...<Widget>[
                      const SizedBox(height: AppTokens.spaceXs),
                      Row(
                        children: <Widget>[
                          Icon(
                            Icons.subtitles_off_rounded,
                            size: 14,
                            color: scheme.error,
                          ),
                          const SizedBox(width: AppTokens.spaceXs),
                          Expanded(
                            child: Text(
                              l10n.mediaServerPgsSubtitleWarn,
                              style: textTheme.labelSmall
                                  ?.copyWith(color: scheme.error),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 媒体服务器播放：会话上报（Start / Progress / Stopped 三段式 + 已看标记）、
/// 播放列表控制器（集内切换 / 自动连播）与「协商 → 打开播放页」开场函数。
///
/// 位置一律以毫秒传入，内部换算 ticks（× 10000，两家 API 的 100ns 单位）。
/// 上报失败静默忽略：网络抖动不应打断本地播放，服务器进度以下一次心跳为准。
library;

import 'package:flutter/material.dart';

import '../../../core/models/episode.dart';
import '../../../core/navigation/app_page_route.dart';
import '../../../generated/app_localizations.dart';
import '../../../features/player/presentation/video_player_screen.dart';
import 'media_server_client.dart';
import 'media_server_models.dart';
import 'media_server_settings.dart';

/// 「已看」自动标记阈值（服务器端同样按 0.9 判定，双保险）。
const double kMediaServerWatchedRatio = 0.9;

/// 单集播放的上报会话（每次切集新建）。
///
/// 生命周期：open 成功后 [start] → 播放中 [reportProgress]（约 10s 周期，
/// 暂停 / seek 后由播放页立即补报）→ 退出 / 播完 / 切走 [stop]
/// （≥90% 自动标记已看）。
class MediaServerPlaybackSession {
  MediaServerPlaybackSession({
    required this.client,
    required this.itemId,
    required this.playSessionId,
    this.initialPositionTicks = 0,
    this.runTimeTicks,
    this.playMethod = MediaServerPlayMethod.directPlay,
  });

  final MediaServerClientBase client;
  final String itemId;
  final String playSessionId;

  /// 服务器记录的续播位置（Resume 行 / 详情页带入），0 = 从头播。
  final int initialPositionTicks;
  final int? runTimeTicks;

  /// 本次协商的播放方式（上报 PlayMethod；转码时退出需清会话）。
  final MediaServerPlayMethod playMethod;

  bool _started = false;
  bool _markedPlayed = false;

  int get initialPositionMs => initialPositionTicks ~/ 10000;

  /// 开始上报。
  Future<void> start({required int positionMs}) async {
    if (_started) return;
    _started = true;
    try {
      await client.reportPlayingStart(
        itemId: itemId,
        playSessionId: playSessionId,
        positionTicks: positionMs * 10000,
        playMethod: playMethod.reportName,
      );
    } on Object {
      // 上报失败不打断播放。
    }
  }

  /// 进度心跳 / 暂停与 seek 补报。
  Future<void> reportProgress({
    required int positionMs,
    required bool paused,
  }) async {
    try {
      await client.reportPlayingProgress(
        itemId: itemId,
        playSessionId: playSessionId,
        positionTicks: positionMs * 10000,
        isPaused: paused,
      );
    } on Object {
      // 上报失败不打断播放。
    }
  }

  /// 停止上报 + 已看判定（[completed] = 播完事件，直接标记）。
  /// 转码会话额外调 DELETE /Videos/ActiveEncodings 清理服务器转码进程。
  Future<void> stop({required int positionMs, bool completed = false}) async {
    try {
      await client.reportPlayingStopped(
        itemId: itemId,
        playSessionId: playSessionId,
        positionTicks: positionMs * 10000,
      );
    } on Object {
      // 上报失败不打断退出。
    }
    if (playMethod == MediaServerPlayMethod.transcode) {
      try {
        await client.stopActiveEncodings(playSessionId);
      } on Object {
        // 清理失败不影响退出（服务器有会话超时兜底）。
      }
    }
    await _maybeMarkPlayed(positionMs, completed);
  }

  /// ≥90%（或播完）→ 标记已看（每会话至多一次）。
  Future<void> _maybeMarkPlayed(int positionMs, bool completed) async {
    if (_markedPlayed) return;
    final runtime = runTimeTicks;
    if (!completed) {
      if (runtime == null || runtime <= 0) return;
      if (positionMs * 10000 / runtime < kMediaServerWatchedRatio) return;
    }
    _markedPlayed = true;
    try {
      await client.markPlayed(itemId);
    } on Object {
      // 上报失败不打断退出。
    }
  }
}

/// 媒体服务器播放列表控制器：一次播放持有整季（或单集）列表，
/// 供播放器内上下集切换 / 选集面板 / 自动连播按需协商新集直连地址。
class MediaServerPlayback {
  MediaServerPlayback({
    required this.client,
    required this.episodes,
    required this.initialIndex,
    this.initialInfo,
    this.fromStart = false,
  }) : currentIndex = initialIndex;

  final MediaServerClientBase client;

  /// 播放列表（整季剧集或单集电影）。
  final List<ServerMediaItem> episodes;
  final int initialIndex;

  /// true = 用户选择「从头播放」，忽略首集的服务器续播位置。
  final bool fromStart;

  /// 已为 [initialIndex] 协商好的直连信息（开场函数解析后带入，省一次请求）。
  PlaybackInfoResult? initialInfo;

  int currentIndex = 0;

  int get length => episodes.length;

  ServerMediaItem get current =>
      episodes[currentIndex.clamp(0, episodes.length - 1)];

  /// 切到 [index] 并协商该集播放地址（带当前码率档位；协商失败原样上抛，
  /// 由播放器回滚）。[audioStreamIndex] 供转码流切换音轨重新协商。
  Future<PlaybackInfoResult> resolveAt(
    int index, {
    int? audioStreamIndex,
  }) async {
    currentIndex = index.clamp(0, episodes.length - 1);
    return client.createPlaybackInfo(
      current.id,
      maxStreamingBitrate: MediaServerPlaybackSettings.instance.tier.maxBitrate,
      audioStreamIndex: audioStreamIndex,
    );
  }

  /// 由当前列表构造播放器通用的 Episode 列表（url 占位：媒体服务器切集
  /// 走专用分支按需协商，不读该字段）。
  List<Episode> toPlayerEpisodes() => <Episode>[
        for (final e in episodes)
          Episode(
            id: e.id,
            title: (e.parentIndexNumber != null && e.indexNumber != null)
                ? '${e.parentIndexNumber}'
                    'x${e.indexNumber.toString().padLeft(2, '0')} ${e.name}'
                : e.name,
            url: '',
            number: e.indexNumber,
          ),
      ];
}

/// 打开媒体服务器播放页：组装播放列表 → PlaybackInfo 协商 → 播放器
/// （directUrl 模式）。
///
/// - 详情页已加载整季时直接复用（[playlist]）；集条目未带列表时拉取该季
///   一次（仅集；电影单集自成一列）；
/// - 协商期间显示「正在连接服务器…」（慢速服务器可能数秒）；
/// - 需转码时 SnackBar 明确提示并返回（不静默黑屏）。
/// 返回播放页已退出（供详情页刷新已看角标与进度）。
Future<void> openMediaServerPlayer(
  BuildContext context, {
  required MediaServerClientBase client,
  required ServerMediaItem item,
  List<ServerMediaItem>? playlist,
  bool fromStart = false,
}) async {
  final l10n = AppLocalizations.of(context);

  // 组装播放列表（尽量少请求：详情页传入则零请求）。
  var list = playlist ?? const <ServerMediaItem>[];
  final seriesId = item.seriesId;
  if (list.isEmpty && item.type == 'Episode' && seriesId != null) {
    try {
      list = await client.fetchEpisodes(seriesId, seasonId: item.seasonId);
    } on Object {
      list = const <ServerMediaItem>[];
    }
    if (!list.any((e) => e.id == item.id)) list = <ServerMediaItem>[item];
  }
  if (list.isEmpty) list = <ServerMediaItem>[item];

  final resolvedIndex =
      list.indexWhere((e) => e.id == item.id).clamp(0, list.length - 1);
  final settings = MediaServerPlaybackSettings.instance;
  await settings.load();
  final playback = MediaServerPlayback(
    client: client,
    episodes: list,
    initialIndex: resolvedIndex,
    fromStart: fromStart,
  );

  // 协商播放地址（按码率档位；慢速服务器可能数秒：显示连接中遮罩）。
  if (!context.mounted) return;
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      content: Row(
        children: <Widget>[
          const CircularProgressIndicator(),
          const SizedBox(width: 20),
          Expanded(child: Text(l10n.mediaServerConnecting)),
        ],
      ),
    ),
  );
  final PlaybackInfoResult info;
  try {
    info = await client.createPlaybackInfo(
      list[resolvedIndex].id,
      maxStreamingBitrate: settings.tier.maxBitrate,
    );
  } on Object catch (e) {
    if (context.mounted) Navigator.of(context).pop();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.mediaServerOperationFailed('$e'))),
    );
    return;
  }
  if (context.mounted) Navigator.of(context).pop();
  if (!context.mounted) return;
  if (info.playUrl.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.mediaServerTranscodeRequired)),
    );
    return;
  }
  if (info.requiresTranscode &&
      settings.tier == MediaServerBitrateTier.original) {
    // 原画 = 强制直连：不支持直连的格式直接报错（不打开流，无转码会话）。
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.mediaServerOriginalNeedsDirect)),
    );
    return;
  }
  playback.initialInfo = info;
  if (info.requiresTranscode) {
    // 转码降级提示（不打断播放）。
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.mediaServerTranscodingNotice)),
    );
  }

  final target = list[resolvedIndex];
  final title = (target.seriesName != null && target.seriesName!.isNotEmpty)
      ? '${target.seriesName} ${target.name}'
      : target.name;
  await Navigator.of(context).push(
    AppPageRoute<void>(
      builder: (_) => VideoPlayerScreen(
        title: title,
        episode: Episode(id: target.id, title: target.name, url: info.playUrl),
        episodes: playback.toPlayerEpisodes(),
        initialEpisodeIndex: resolvedIndex,
        sourceId: 'media-server',
        itemId: target.id,
        directUrl: info.playUrl,
        directHeaders: info.headers,
        restoreProgress: true,
        mediaServerPlayback: playback,
      ),
    ),
  );
}

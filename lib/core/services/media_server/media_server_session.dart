/// 媒体服务器播放会话：Start / Progress（周期）/ Stopped 三段式上报 + 已看标记，
/// 以及「协商 → 打开播放页」的开场函数。
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

/// 「已看」自动标记阈值（服务器端同样按 0.9 判定，双保险）。
const double kMediaServerWatchedRatio = 0.9;

/// 一次媒体服务器播放的上报会话（每次播放新建）。
///
/// 生命周期：播放页 open 成功后 [start] → 播放中 [reportProgress]（约 10s 周期，
/// 暂停 / seek 后由播放页立即补报）→ 退出 / 播完 [stop]（≥90% 自动标记已看）。
class MediaServerPlaybackSession {
  MediaServerPlaybackSession({
    required this.client,
    required this.itemId,
    required this.playSessionId,
    this.initialPositionTicks = 0,
    this.runTimeTicks,
  });

  final MediaServerClientBase client;
  final String itemId;
  final String playSessionId;

  /// 服务器记录的续播位置（Resume 行 / 详情页带入），0 = 从头播。
  final int initialPositionTicks;
  final int? runTimeTicks;

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

/// 打开媒体服务器播放页：PlaybackInfo 协商 → 直连 URL → 播放器（directUrl 模式）。
///
/// 需转码时 SnackBar 明确提示并返回（不静默黑屏）；协商失败同样提示。
/// 返回播放页已退出（供详情页刷新已看角标与进度）。
Future<void> openMediaServerPlayer(
  BuildContext context, {
  required MediaServerClientBase client,
  required ServerMediaItem item,
  bool fromStart = false,
}) async {
  final l10n = AppLocalizations.of(context);
  final PlaybackInfoResult info;
  try {
    info = await client.createPlaybackInfo(item.id);
  } on Object catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.mediaServerOperationFailed('$e'))),
    );
    return;
  }
  if (!context.mounted) return;
  if (info.requiresTranscode || info.playUrl.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.mediaServerTranscodeRequired)),
    );
    return;
  }
  final title = (item.seriesName != null && item.seriesName!.isNotEmpty)
      ? '${item.seriesName} ${item.name}'
      : item.name;
  await Navigator.of(context).push(
    AppPageRoute<void>(
      builder: (_) => VideoPlayerScreen(
        title: title,
        episode: Episode(id: item.id, title: item.name, url: info.playUrl),
        sourceId: 'media-server',
        itemId: item.id,
        directUrl: info.playUrl,
        directHeaders: info.headers,
        restoreProgress: true,
        mediaServerSession: MediaServerPlaybackSession(
          client: client,
          itemId: item.id,
          playSessionId: info.playSessionId,
          initialPositionTicks:
              fromStart ? 0 : (item.userData?.playbackPositionTicks ?? 0),
          runTimeTicks: info.runTimeTicks ?? item.runTimeTicks,
        ),
      ),
    ),
  );
}

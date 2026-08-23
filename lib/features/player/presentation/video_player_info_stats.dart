part of 'video_player_screen.dart';

extension _VideoInfoStats on _VideoPlayerScreenState {
  /// #4 A4-#4: 显示媒体信息（标题/源/剧集/当前 URL/播放进度）。
  void _showMediaInfo(AppLocalizations l10n) {
    final url = _playUrl ?? widget.episode.url;
    final pos = _position.inSeconds;
    final dur = _duration.inSeconds;
    final posStr =
        '${pos ~/ 60}:${(pos % 60).toString().padLeft(2, '0')}';
    final durStr =
        '${dur ~/ 60}:${(dur % 60).toString().padLeft(2, '0')}';
    // F-16：面板打开期间持有控制栏，禁止自动隐藏。
    _acquirePanelHold();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext ctx) {
        final mq = MediaQuery.of(ctx);
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: mq.size.height * 0.85),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AppTokens.spaceMd),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(l10n.mediaInfo,
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: AppTokens.spaceSm),
                  Text('${l10n.browseLocalFileTypeVideo}: ${widget.title}'),
                  Text(_episodeTitle),
                  if (_isDirectMode)
                    Text('${l10n.localFileLabel}: ${widget.directUrl ?? widget.localUri}')
                  else
                    Text('${l10n.videoSourceLine}: ${widget.sourceId}'),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Text('URL: '),
                      Expanded(child: Text(url, softWrap: true)),
                      IconButton(
                        icon: const Icon(Icons.copy, size: 18),
                        tooltip: l10n.snifferCopy,
                        onPressed: () =>
                            unawaited(Clipboard.setData(ClipboardData(text: url))),
                      ),
                    ],
                  ),
                  Text('${l10n.novelHfProgressPercent}: $posStr / $durStr'),
                  const SizedBox(height: AppTokens.spaceMd),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: Text(l10n.close),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    )
        // F-16：面板关闭后释放控制栏租约。
        .whenComplete(_releasePanelHold);
  }

  /// 播放统计面板：读 mpv 只读属性展示实际软/硬解状态、编码、分辨率、
  /// 掉帧与码率，1s 定时刷新。软/硬解状态醒目标注，用于诊断
  /// 「hwdec=auto 实际落在哪条解码路径」与花屏问题排查。

  /// 播放统计面板：读 mpv 只读属性展示实际软/硬解状态、编码、分辨率、
  /// 掉帧与码率，1s 定时刷新。软/硬解状态醒目标注，用于诊断
  /// 「hwdec=auto 实际落在哪条解码路径」与花屏问题排查。
  void _showPlaybackStats(AppLocalizations l10n) {
    Timer? refreshTimer;
    // F-16：面板打开期间持有控制栏，禁止自动隐藏。
    _acquirePanelHold();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext ctx) => SafeArea(
        child: ConstrainedBox(
          constraints:
              BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppTokens.spaceMd),
            child: StatefulBuilder(
              builder: (BuildContext sbCtx, StateSetter setSheetState) {
                // 首次 build 时启动 1s 周期刷新；面板关闭后由 whenComplete 取消。
                refreshTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
                  if (sbCtx.mounted) setSheetState(() {});
                });
                return FutureBuilder<PlayerStats>(
                  future: _controller.queryStats(),
                  builder: (BuildContext _, AsyncSnapshot<PlayerStats> snap) {
                    final PlayerStats? stats = snap.data;
                    final theme = Theme.of(ctx);
                    Widget body;
                    if (stats == null || stats.isEmpty) {
                      body = Padding(
                        padding: const EdgeInsets.symmetric(
                            vertical: AppTokens.spaceMd),
                        child: Text(l10n.playerStatsUnavailable),
                      );
                    } else {
                      final bool isHw = stats.isHardwareDecoding;
                      // 解码状态醒目标注：硬解绿 / 软解橙，附带 hwdec-current 原值。
                      final String decodeText = isHw
                          ? '${l10n.playerStatsHardware} (${stats.hwdecCurrent})'
                          : l10n.playerStatsSoftware;
                      final ColorScheme scheme = Theme.of(ctx).colorScheme;
                      final Color decodeColor = isHw
                          ? AppStatusColors.ok(scheme)
                          : AppStatusColors.warn(scheme);
                      String orDash(String? v) =>
                          (v == null || v.isEmpty) ? '—' : v;
                      final String resolution =
                          (stats.width != null && stats.height != null)
                              ? '${stats.width}×${stats.height}'
                              : '—';
                      final String drops =
                          '${stats.frameDropCount ?? 0} / ${stats.decoderFrameDropCount ?? 0}';
                      final String bitrate = stats.videoBitrate == null
                          ? '—'
                          : '${(stats.videoBitrate! / 1000000).toStringAsFixed(2)} Mbps';
                      final String buffering = stats.cacheBufferingState == null
                          ? '—'
                          : '${stats.cacheBufferingState}%';
                      body = Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          _statsRow(
                            l10n.playerStatsDecoder,
                            decodeText,
                            valueStyle: theme.textTheme.bodyMedium?.copyWith(
                              color: decodeColor,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          _statsRow(l10n.playerStatsVideoCodec,
                              orDash(stats.videoCodec)),
                          _statsRow(l10n.playerStatsPixelFormat,
                              orDash(stats.videoFormat)),
                          _statsRow(l10n.playerStatsResolution, resolution),
                          _statsRow(l10n.playerStatsDroppedFrames, drops),
                          _statsRow(l10n.playerStatsBitrate, bitrate),
                          _statsRow(l10n.playerStatsBuffering, buffering),
                        ],
                      );
                    }
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(l10n.playerStats,
                            style: theme.textTheme.titleMedium),
                        const SizedBox(height: AppTokens.spaceSm),
                        body,
                        const SizedBox(height: AppTokens.spaceMd),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: Text(l10n.close),
                          ),
                        ),
                      ],
                    );
                  },
                );
              },
            ),
          ),
        ),
      ),
    ).whenComplete(() {
      refreshTimer?.cancel();
      // F-16：面板关闭后释放控制栏租约。
      _releasePanelHold();
    });
  }

  /// 播放统计面板的单行「标签: 值」。标签列上限 140（窄屏自动让位，值换行）。

  /// 播放统计面板的单行「标签: 值」。标签列上限 140（窄屏自动让位，值换行）。
  Widget _statsRow(String label, String value, {TextStyle? valueStyle}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppTokens.spaceXxs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 140),
            child: Text(label),
          ),
          const SizedBox(width: AppTokens.spaceSm),
          Expanded(child: Text(value, style: valueStyle, softWrap: true)),
        ],
      ),
    );
  }

  /// #4 A4-#4: 使用外部播放器打开当前 URL。
}

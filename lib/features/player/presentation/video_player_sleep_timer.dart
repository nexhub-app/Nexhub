part of 'video_player_screen.dart';

extension _VideoSleepTimer on _VideoPlayerScreenState {
  void _showSleepTimerPicker(AppLocalizations l10n) {
    // 面板打开期间持有控制栏，禁止自动隐藏。
    _acquirePanelHold();
    showModalBottomSheet<void>(
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
              leading: const Icon(Icons.timer_off),
              title: Text(l10n.playerTimerOff),
              onTap: () {
                Navigator.pop(ctx);
                _sleepTimer?.cancel();
                _sleepTimer = null;
                // 关闭定时同时清按集计数。
                _sleepEpisodesRemaining = 0;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(l10n.playerTimerCanceled)),
                );
              },
            ),
            for (final m in <int>[15, 30, 45, 60, 90])
              ListTile(
                leading: const Icon(Icons.timer),
                title: Text(l10n.playerTimerMinutes(m)),
                onTap: () {
                  Navigator.pop(ctx);
                  _setSleepTimer(m, l10n);
                },
              ),
            // 睡眠定时「按集数」模式（与按分钟互斥，跨集保留）。
            for (final n in <int>[1, 2, 3])
              ListTile(
                leading: const Icon(Icons.video_library),
                title: Text(l10n.playerTimerEpisodes(n)),
                onTap: () {
                  Navigator.pop(ctx);
                  _setSleepEpisodes(n, l10n);
                },
              ),
            ListTile(
              leading: const Icon(Icons.edit),
              title: Text(l10n.playerTimerCustom),
              onTap: () {
                Navigator.pop(ctx);
                _showCustomSleepTimerDialog(l10n);
              },
            ),
            const SizedBox(height: AppTokens.spaceSm),
          ],
        ),
      ),
    ),
  ),
)
      // 面板关闭后释放控制栏租约。
      .whenComplete(_releasePanelHold);
  }

  void _setSleepTimer(int minutes, AppLocalizations l10n) {
    // 按分钟模式与按集数模式互斥。
    _sleepEpisodesRemaining = 0;
    _sleepTimer?.cancel();
    _sleepTimer = Timer(Duration(minutes: minutes), () {
      _controller.pause();
      // 同步 UI 状态：_isPlaying 依赖 playing 流同步可能延迟，
      // 若流事件晚到，暂停后 UI 仍显示播放态。Timer 回调内直接置位
      // _isPlaying=false 并让控制层常显，保证「定时到点暂停」立即可见。
      _uiHideTimer?.cancel();
      if (mounted) {
        setState(() {
          _isPlaying = false;
          _uiVisible = true;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.playerTimerFired)),
        );
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.playerTimerMinutes(minutes))),
    );
  }

  /// 睡眠定时「再播 N 集后暂停」模式。
  ///
  /// 与按分钟模式互斥（取消分钟 Timer）；计数跨集保留（已保证切集不取消
  /// 定时器），由 [_onCompleted] 播完一集递减，归零时暂停并提示。

  /// 睡眠定时「再播 N 集后暂停」模式。
  ///
  /// 与按分钟模式互斥（取消分钟 Timer）；计数跨集保留（已保证切集不取消
  /// 定时器），由 [_onCompleted] 播完一集递减，归零时暂停并提示。
  void _setSleepEpisodes(int count, AppLocalizations l10n) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepEpisodesRemaining = count;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.playerTimerEpisodes(count))),
    );
  }

  void _showCustomSleepTimerDialog(AppLocalizations l10n) {
    final TextEditingController controller = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AppAlertDialog(
        title: Text(l10n.playerTimer),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(hintText: l10n.playerTimerCustom),
          autofocus: true,
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () {
              final m = int.tryParse(controller.text.trim());
              if (m != null && m > 0) {
                Navigator.pop(ctx);
                _setSleepTimer(m, l10n);
              }
            },
            child: Text(l10n.ok),
          ),
        ],
      ),
    );
  }

  void _share(AppLocalizations l10n) {
    final text = '$_episodeTitle\n${_playUrl ?? widget.episode.url}';
    Share.share(text);
  }

  /// #4 A4-#4: 显示媒体信息（标题/源/剧集/当前 URL/播放进度）。
}

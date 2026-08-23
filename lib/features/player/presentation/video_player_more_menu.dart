part of 'video_player_screen.dart';

extension _VideoMoreMenu on _VideoPlayerScreenState {
  void _showMoreMenu(AppLocalizations l10n) {
    // F-16：菜单打开期间持有控制栏，禁止自动隐藏；关闭后释放。
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
                _menuHeader(l10n),
            // 自动连播（本地 / 直链模式无下一集，隐藏）
            if (!_isDirectMode)
              ListTile(
                leading: Icon(
                  _controller.autoPlayNext
                      ? Icons.play_circle
                      : Icons.play_circle_outline,
                ),
                title: Text(l10n.playerAutoPlayNext),
                trailing: Switch(
                  value: _controller.autoPlayNext,
                  onChanged: (v) {
                    setState(() {
                      _controller.autoPlayNext = v;
                      _playerSettings =
                          _playerSettings.copyWith(autoPlayNext: v);
                    });
                    unawaited(_saveEpisodeSetting('autoPlayNext', v));
                    Navigator.pop(ctx);
                  },
                  activeColor: Theme.of(ctx).colorScheme.primary,
                ),
              ),
            // 功能5：长按手势设置（开关 + 自定义倍速值）
            ListTile(
              leading: Icon(_playerSettings.longPressSpeedUp
                  ? Icons.fast_forward
                  : Icons.fast_forward_outlined),
              title: Text(l10n.playerLongPressSpeedUp),
              trailing: Switch(
                value: _playerSettings.longPressSpeedUp,
                onChanged: (v) {
                  setState(() {
                    _playerSettings =
                        _playerSettings.copyWith(longPressSpeedUp: v);
                  });
                  unawaited(_saveEpisodeSetting('longPressSpeedUp', v));
                  Navigator.pop(ctx);
                },
                activeColor: Theme.of(ctx).colorScheme.primary,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.speed),
              title: Text(l10n.playerLongPressSpeed),
              subtitle: Text('${_playerSettings.longPressSpeed}x'),
              enabled: _playerSettings.longPressSpeedUp,
              onTap: () {
                Navigator.pop(ctx);
                unawaited(_pickLongPressSpeed(context));
              },
            ),
            // 画中画（从顶栏移入更多菜单）
            ListTile(
              leading: const Icon(Icons.picture_in_picture),
              title: Text(l10n.playerPip),
              onTap: () {
                Navigator.pop(ctx);
                _togglePip(l10n);
              },
            ),
            ListTile(
              leading: const Icon(Icons.memory),
              title: Text(l10n.playerDecodeMode),
              trailing: DropdownButton<String>(
                value: _controller.currentHwdec,
                // 收起时只显短名，避免 hw+ 的提示后缀撑爆 trailing 宽度。
                selectedItemBuilder: (BuildContext _) => <Widget>[
                  Text(l10n.playerDecodeAuto),
                  Text(l10n.playerDecodeSw),
                  Text(l10n.playerDecodeHw),
                  Text(l10n.playerDecodeHwPlus),
                ],
                items: <DropdownMenuItem<String>>[
                  DropdownMenuItem<String>(
                      value: 'auto', child: Text(l10n.playerDecodeAuto)),
                  DropdownMenuItem<String>(
                      value: 'sw', child: Text(l10n.playerDecodeSw)),
                  DropdownMenuItem<String>(
                      value: 'hw', child: Text(l10n.playerDecodeHw)),
                  // hw+（auto-copy）绕开硬解直通纹理路径，是花屏设备的首选。
                  DropdownMenuItem<String>(
                      value: 'hw+',
                      child: Text(
                          '${l10n.playerDecodeHwPlus} · ${l10n.playerDecodeHwPlusHint}')),
                ],
                onChanged: (String? v) {
                  Navigator.pop(ctx);
                  // 与自动降级一致：设完 hwdec 后必须 re-open，否则对已在播的
                  // 解码器不生效（用户切“软解”看不到任何变化）。
                  if (v == null) return;
                  unawaited(_applyHwdecAndReopen(v));
                  _playerSettings = _playerSettings.copyWith(
                    decodeMode: DecodeMode.values.firstWhere(
                      (e) => e.name == v || (e.name == 'hwPlus' && v == 'hw+'),
                      orElse: () => DecodeMode.auto,
                    ),
                  );
                  unawaited(_saveEpisodeSetting(
                    'decodeMode',
                    _playerSettings.decodeMode.name,
                  ));
                },
              ),
            ),
            ListTile(
              leading: const Icon(Icons.graphic_eq),
              title: Text(l10n.playerAudioChannel),
              trailing: DropdownButton<String>(
                value: _controller.currentAudioChannel,
                items: <DropdownMenuItem<String>>[
                  DropdownMenuItem<String>(
                      value: 'auto', child: Text(l10n.playerDecodeAuto)),
                  DropdownMenuItem<String>(
                      value: 'auto-safe', child: Text(l10n.playerAudioAutoProtect)),
                  DropdownMenuItem<String>(
                      value: 'stereo', child: Text(l10n.playerAudioStereo)),
                  DropdownMenuItem<String>(
                      value: 'mono', child: Text(l10n.playerAudioMono)),
                  DropdownMenuItem<String>(
                      value: 'reverse-stereo', child: Text(l10n.playerAudioReverseStereo)),
                ],
                onChanged: (String? v) {
                  Navigator.pop(ctx);
                  if (v == null) return;
                  unawaited(_controller.setAudioChannel(v));
                  _playerSettings = _playerSettings.copyWith(
                    audioChannel: AudioChannel.values.firstWhere(
                      (e) => e.name == v,
                      orElse: () => AudioChannel.auto,
                    ),
                  );
                  unawaited(_saveEpisodeSetting(
                    'audioChannel',
                    _playerSettings.audioChannel.name,
                  ));
                },
              ),
            ),
            ListTile(
              leading: const Icon(Icons.bedtime),
              title: Text(l10n.playerTimer),
              onTap: () {
                Navigator.pop(ctx);
                _showSleepTimerPicker(l10n);
              },
            ),
            // #4 A4-#4: 媒体信息
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text(l10n.mediaInfo),
              onTap: () {
                Navigator.pop(ctx);
                _showMediaInfo(l10n);
              },
            ),
            // 播放统计（实际软/硬解状态、编码、掉帧等，1s 刷新）
            ListTile(
              leading: const Icon(Icons.query_stats),
              title: Text(l10n.playerStats),
              onTap: () {
                Navigator.pop(ctx);
                _showPlaybackStats(l10n);
              },
            ),
            // #4 A4-#4: 外部播放
            ListTile(
              leading: const Icon(Icons.open_in_new),
              title: Text(l10n.playExternal),
              onTap: () {
                Navigator.pop(ctx);
                _playInExternal(l10n);
              },
            ),
            // #4 A4-#4: 分享（复用 _share）
            ListTile(
              leading: const Icon(Icons.share_outlined),
              title: Text(l10n.share),
              onTap: () {
                Navigator.pop(ctx);
                _share(l10n);
              },
            ),
            // 截图保存路径设置
            ListTile(
              leading: const Icon(Icons.folder_open),
              title: Text(l10n.screenshotPathSetting),
              subtitle: _customScreenshotDir != null
                  ? Text(_customScreenshotDir!,
                      maxLines: 1, overflow: TextOverflow.ellipsis)
                  : Text(l10n.screenshotPathDefault),
              onTap: () {
                Navigator.pop(ctx);
                _pickScreenshotDirectory(l10n);
              },
            ),
            // 跳过片头/片尾设置（F-3）
            ListTile(
              leading: const Icon(Icons.skip_next),
              title: Text(l10n.playerSkipOpEd),
              subtitle: (_skipOpEndSec != null || _skipEdStartSec != null)
                  ? Text(
                      '${_fmtMmSs(_skipOpEndSec)} / ${_fmtMmSs(_skipEdStartSec)}'
                      '${_skipAuto ? ' · ${l10n.playerSkipAuto}' : ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    )
                  : null,
              onTap: () {
                Navigator.pop(ctx);
                unawaited(_showSkipSettings());
              },
            ),
            // 重置该视频的单独设置（恢复跟随全局默认）
            ListTile(
              leading: const Icon(Icons.settings_backup_restore),
              title: Text(l10n.playerResetEpisodeSettings),
              onTap: () {
                Navigator.pop(ctx);
                unawaited(_resetEpisodeSettings());
              },
            ),
            // ── F-4 播放队列（跨作品）──
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.playlist_add),
              title: Text(l10n.playerAddToQueue),
              onTap: () {
                Navigator.pop(ctx);
                unawaited(_addCurrentToQueue());
              },
            ),
            ListTile(
              leading: const Icon(Icons.playlist_play),
              title: Text(l10n.playerPlayNext),
              onTap: () {
                Navigator.pop(ctx);
                unawaited(_playCurrentNext());
              },
            ),
            ListTile(
              leading: const Icon(Icons.queue_music),
              title: Text(l10n.playerQueue),
              onTap: () {
                Navigator.pop(ctx);
                unawaited(_showQueueSheet(l10n));
              },
            ),
            const SizedBox(height: AppTokens.spaceSm),
          ],
        ),
      ),
    ),
  ),
)
      // F-16：菜单关闭后释放控制栏租约，重启自动隐藏倒计时。
      .whenComplete(_releasePanelHold);
  }

  Widget _menuHeader(AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTokens.spaceLg,
        AppTokens.spaceMd,
        AppTokens.spaceSm,
        AppTokens.spaceSm,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              l10n.playerPlayInfo,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          // 投屏入口（打开设备选择面板）。
          IconButton(
            icon: Icon(Icons.cast,
                color: _isCasting
                    ? Theme.of(context).colorScheme.primary
                    : null),
            tooltip: l10n.cast,
            onPressed: () {
              Navigator.pop(context);
              _showCastSheet(l10n);
            },
          ),
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }
}

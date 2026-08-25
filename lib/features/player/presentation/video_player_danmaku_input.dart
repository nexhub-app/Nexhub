part of 'video_player_screen.dart';

extension _VideoDanmakuInput on _VideoPlayerScreenState {
  /// 显示弹幕输入框（支持选择弹幕颜色与样式）。
  /// 横屏：底部弹层（项 4a）；竖屏：可滚动对话框，避免小屏显示不全。
  void _showDanmakuInput() {
    final l10n = AppLocalizations.of(context);
    final controller = TextEditingController();
    Color selectedColor = Colors.white;
    cd.DanmakuItemType selectedType = cd.DanmakuItemType.scroll;
    final bool landscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    // 内容区（输入框 + 样式 + 颜色），横竖屏共用，由 setSt 驱动重建。
    Widget buildContent(
      BuildContext ctx,
      void Function(VoidCallback) setSt,
    ) {
      final theme = Theme.of(ctx);
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              hintText: l10n.danmakuSendHint ?? '输入弹幕内容',
              border: const OutlineInputBorder(),
            ),
            maxLength: 50,
          ),
          const SizedBox(height: AppTokens.spaceMd),
          Text(l10n.danmakuStyle, style: theme.textTheme.bodyMedium),
          const SizedBox(height: AppTokens.spaceSm),
          Wrap(
            spacing: AppTokens.spaceSm,
            children: <Widget>[
              for (final (type, label) in <(cd.DanmakuItemType, String)>[
                (cd.DanmakuItemType.scroll, l10n.danmakuStyleScroll),
                (cd.DanmakuItemType.top, l10n.danmakuStyleTop),
                (cd.DanmakuItemType.bottom, l10n.danmakuStyleBottom),
              ])
                ChoiceChip(
                  label: Text(label),
                  selected: selectedType == type,
                  onSelected: (_) => setSt(() => selectedType = type),
                ),
            ],
          ),
          const SizedBox(height: AppTokens.spaceMd),
          Text(l10n.presetColor, style: theme.textTheme.bodyMedium),
          const SizedBox(height: AppTokens.spaceSm),
          Wrap(
            spacing: AppTokens.spaceSm,
            runSpacing: AppTokens.spaceSm,
            children: <Widget>[
              for (final color in _danmakuPresetColors)
                GestureDetector(
                  onTap: () => setSt(() => selectedColor = color),
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selectedColor == color
                            ? theme.colorScheme.primary
                            : Colors.black38,
                        width: selectedColor == color ? 3 : 1,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      );
    }

    // 发送逻辑（横竖屏共用）。
    //
    // F-18：本地即时显示保持不变；关闭输入框后后台尝试经弹弹play API 上传
    // （需登录态），校验时长 / 集数匹配，结果以 SnackBar 提示。
    void send(BuildContext ctx) {
      final text = controller.text.trim();
      if (text.isEmpty) return;
      final time = _position +
          Duration(
              milliseconds: (_danmakuSettings.timeOffset * 1000).round());
      final item = DanmakuItem(
        text: text,
        time: time,
        color: selectedColor,
        type: selectedType,
        selfSend: true,
      );
      _danmakuKey.currentState?.addSingle(item);
      Navigator.pop(ctx);
      unawaited(_uploadDanmaku(text, time, selectedColor, selectedType));
    }

    if (landscape) {
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
                builder: (BuildContext ctx, void Function(VoidCallback) setSt) =>
                    Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    buildContent(ctx, setSt),
                    const SizedBox(height: AppTokens.spaceMd),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: <Widget>[
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: Text(l10n.cancel),
                        ),
                        TextButton(
                          onPressed: () => send(ctx),
                          child: Text(l10n.ok),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    } else {
      showDialog<void>(
        context: context,
        builder: (BuildContext ctx) => StatefulBuilder(
          builder: (BuildContext ctx, void Function(VoidCallback) setSt) =>
              AppAlertDialog(
            title: Text(l10n.danmakuSend ?? '发送弹幕'),
            content: SingleChildScrollView(child: buildContent(ctx, setSt)),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(l10n.cancel),
              ),
              TextButton(
                onPressed: () => send(ctx),
                child: Text(l10n.ok),
              ),
            ],
          ),
        ),
      );
    }
  }

  /// F-18：上传弹幕到弹弹play（本地显示后后台执行）。
  ///
  /// - 集数校验：解析不到 dandanplay episodeId（源为 bilibili / 自定义 URL /
  ///   匹配失败）时不上传，提示仅本地显示；
  /// - 时长校验：发送位置超出视频时长时不上传；
  /// - 登录态：未登录先弹就地登录框；凭据未配置 / 账号密码错误 / 上传失败
  ///   均以 SnackBar 提示。
  Future<void> _uploadDanmaku(
    String text,
    Duration time,
    Color color,
    cd.DanmakuItemType type,
  ) async {
    if (_disposed || !mounted) return;
    final l10n = AppLocalizations.of(context);
    // 集数校验：无 episodeId 无法定位弹幕库。
    final ep = widget.episodes?[_episodeIndex] ?? widget.episode;
    int? episodeId;
    try {
      episodeId = await _resolveDandanId(ep);
    } on Object {
      episodeId = null;
    }
    if (episodeId == null) {
      _safeSnackBar(l10n.danmakuSendNoEpisode);
      return;
    }
    // 时长校验：发送位置超出视频时长（timeOffset 拉偏导致）不上传。
    if (_duration > Duration.zero && time >= _duration) {
      _safeSnackBar(l10n.danmakuSendTimeInvalid);
      return;
    }
    // 登录态：未登录就地登录，取消则放弃上传（本地已显示）。
    await DandanplayAuth.instance.init();
    if (!DandanplayAuth.instance.isLoggedIn) {
      final ok = await _showDandanplayLoginDialog();
      if (!ok || _disposed || !mounted) return;
    }
    try {
      final service = DandanplayService(configStore: DanmakuConfigStore());
      await service.sendComment(
        episodeId: '$episodeId',
        time: time.inMilliseconds / 1000.0,
        mode: switch (type) {
          cd.DanmakuItemType.scroll => 1,
          cd.DanmakuItemType.bottom => 4,
          cd.DanmakuItemType.top => 5,
          _ => 1,
        },
        color: color.toARGB32() & 0xFFFFFF,
        comment: text,
        bearerToken: DandanplayAuth.instance.token ?? '',
      );
      if (_disposed || !mounted) return;
      _safeSnackBar(l10n.danmakuUploadSuccess);
    } on Object catch (e) {
      AppLog.instance.e('[F-18] 弹幕上传失败：$e');
      if (_disposed || !mounted) return;
      _safeSnackBar(l10n.danmakuUploadFailed(e.toString()));
    }
  }

  /// F-18：弹弹play 就地登录对话框。返回 true 表示登录成功。
  Future<bool> _showDandanplayLoginDialog() async {
    final l10n = AppLocalizations.of(context);
    final userCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    var busy = false;
    String? error;

    Future<void> submit(BuildContext ctx, void Function(VoidCallback) setSt) async {
      final userName = userCtrl.text.trim();
      final password = passCtrl.text;
      if (userName.isEmpty || password.isEmpty) {
        setSt(() => error = l10n.danmakuLoginEmptyFields);
        return;
      }
      setSt(() {
        busy = true;
        error = null;
      });
      try {
        await DandanplayAuth.instance.login(userName, password);
        if (!mounted) return;
        Navigator.pop(ctx, true);
        _safeSnackBar(l10n.loginSuccess);
      } on Object catch (e) {
        AppLog.instance.e('[F-18] 弹弹play 登录失败：$e');
        setSt(() {
          busy = false;
          error = e.toString();
        });
      }
    }

    try {
      final result = await showDialog<bool>(
        context: context,
        builder: (BuildContext ctx) => StatefulBuilder(
          builder: (BuildContext ctx, void Function(VoidCallback) setSt) =>
              AppAlertDialog(
            title: Text(l10n.danmakuLoginTitle),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(l10n.danmakuLoginRequiredHint),
                const SizedBox(height: AppTokens.spaceMd),
                TextField(
                  controller: userCtrl,
                  autofocus: true,
                  enabled: !busy,
                  decoration:
                      InputDecoration(labelText: l10n.danmakuUsername),
                ),
                const SizedBox(height: AppTokens.spaceSm),
                TextField(
                  controller: passCtrl,
                  obscureText: true,
                  enabled: !busy,
                  decoration:
                      InputDecoration(labelText: l10n.danmakuPassword),
                  onSubmitted: (_) {
                    if (!busy) submit(ctx, setSt);
                  },
                ),
                if (error != null) ...<Widget>[
                  const SizedBox(height: AppTokens.spaceSm),
                  Text(
                    error!,
                    style: TextStyle(
                        color: Theme.of(ctx).colorScheme.error, fontSize: 12),
                  ),
                ],
              ],
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(l10n.cancel),
              ),
              TextButton(
                onPressed: busy ? null : () => submit(ctx, setSt),
                child: Text(l10n.danmakuLoginAction),
              ),
            ],
          ),
        ),
      );
      return result ?? false;
    } finally {
      userCtrl.dispose();
      passCtrl.dispose();
    }
  }
}

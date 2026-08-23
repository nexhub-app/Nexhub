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
    void send(BuildContext ctx) {
      final text = controller.text.trim();
      if (text.isNotEmpty) {
        final item = DanmakuItem(
          text: text,
          time: _position +
              Duration(milliseconds: (_danmakuSettings.timeOffset * 1000).round()),
          color: selectedColor,
          type: selectedType,
          selfSend: true,
        );
        _danmakuKey.currentState?.addSingle(item);
      }
      Navigator.pop(ctx);
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
}

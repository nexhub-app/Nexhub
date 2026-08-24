part of 'video_player_screen.dart';

extension _VideoScreenshot on _VideoPlayerScreenState {
  /// 抽出 [_takeScreenshot] 的核心实现，供边缘常驻按钮与「更多」菜单共用。
  ///
  /// 使用 media_kit 的 [Player.screenshot] 截取当前帧，
  /// 保存为 PNG 到截图目录（默认 Documents/screenshots 或用户自定义）。
  Future<void> _captureAndSaveScreenshot(AppLocalizations l10n) async {
    try {
      final Uint8List? bytes = await _controller.player.screenshot();
      if (bytes == null || bytes.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.screenshotFailed)),
          );
        }
        return;
      }
      Directory baseDir;
      if (_customScreenshotDir != null && _customScreenshotDir!.isNotEmpty) {
        baseDir = Directory(_customScreenshotDir!);
        if (!await baseDir.exists()) {
          await baseDir.create(recursive: true);
        }
      } else {
        final docDir = await getApplicationDocumentsDirectory();
        baseDir = Directory(p.join(docDir.path, 'screenshots'));
        if (!await baseDir.exists()) {
          await baseDir.create(recursive: true);
        }
      }
      final String fileName =
          'nexhub_${DateTime.now().millisecondsSinceEpoch}.png';
      final File file = File(p.join(baseDir.path, fileName));
      await file.writeAsBytes(bytes);
      if (mounted) {
        // X-3：截图保存后提供「收藏到图库」快捷入口（统一图片收藏图库）。
        final String path = file.path;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.screenshotSaved),
            action: SnackBarAction(
              label: l10n.imageFavoriteAdd,
              onPressed: () => unawaited(_favoriteScreenshot(path, l10n)),
            ),
          ),
        );
      }
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${l10n.screenshotFailed}: $e')),
        );
      }
    }
  }

  /// X-3：把刚保存的截图收藏进统一图片图库（来源 = 播放器）。
  Future<void> _favoriteScreenshot(String path, AppLocalizations l10n) async {
    final String label = _episodeTitle.isEmpty
        ? widget.title
        : '${widget.title} · $_episodeTitle';
    final bool added = await ImageFavoriteManager().toggleByUrl(
      source: ImageFavoriteSource.player,
      workId: widget.itemId,
      workTitle: widget.title,
      label: label,
      imageUrl: path,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          added ? l10n.imageFavoriteAdded : l10n.imageFavoriteRemoved,
        ),
      ),
    );
  }

  /// 选择自定义截图保存目录。
  Future<void> _pickScreenshotDirectory(AppLocalizations l10n) async {
    try {
      final String? selected = await FilePicker.platform.getDirectoryPath(
        dialogTitle: l10n.playerScreenshot,
      );
      if (selected == null || selected.isEmpty) return;
      setState(() => _customScreenshotDir = selected);
      // 持久化到 SharedPreferences
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('screenshot_custom_dir', selected);
      } on Object {
        // 写入失败不影响功能
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(selected)),
        );
      }
    } on Object {
      // 用户取消或平台不支持，静默忽略
    }
  }
}

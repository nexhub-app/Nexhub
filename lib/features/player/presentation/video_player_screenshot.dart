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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.screenshotSaved)),
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

  /// 选择自定义截图保存目录。

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

  /// 刷新收藏状态（P9.1.7 §16.1 顶栏收藏按钮）。
}

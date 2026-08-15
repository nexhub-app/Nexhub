import 'package:media_kit/media_kit.dart';

import 'video_player_backend.dart';

/// 基于 media_kit / mpv 的视频播放后端实现。
///
/// 通过 [NativePlayer.setProperty] 调整 mpv 属性，提供硬件解码、音频通道
/// 与画面比例的运行时切换能力。持有底层 [Player] 实例供控制器与 UI 使用。
class MediaKitBackend extends VideoPlayerBackend {
  MediaKitBackend(this._player) {
    _applyDefaultProperties();
  }

  final Player _player;

  String _currentHwdec = 'auto';
  String _currentAudioChannel = 'auto';
  String _currentAspectRatio = 'default';

  /// 暴露底层 [Player] 实例供 [PlayerController] / Video 控件使用。
  Player get player => _player;

  /// 将应用层解码模式映射为 mpv `hwdec` 属性值。
  static String _hwdecToMpv(String mode) {
    switch (mode) {
      case 'auto':
        return 'auto';
      case 'sw':
        return 'no';
      case 'hw':
        return 'auto-safe';
      case 'hw+':
        return 'auto-copy';
      default:
        return 'auto';
    }
  }

  /// 将应用层画面比例映射为 mpv `video-aspect-override` 值。
  /// 返回 null 表示需要额外依赖 `keepaspect` 控制（fill 模式）。
  static double? _aspectToValue(String ratio) {
    switch (ratio) {
      case '4:3':
        return 4.0 / 3.0;
      case '16:9':
        return 16.0 / 9.0;
      case 'fill':
        return null;
      default:
        return -1; // default：使用视频原始比例
    }
  }

  /// 设置 mpv 属性，若后端不支持则静默忽略。
  ///
  /// media_kit 在原生平台通过 [NativePlayer.setProperty] 暴露 mpv 属性；
  /// Web 平台无此能力，try/catch 保证不会中断播放流程。
  Future<void> _setProperty(String name, String value) async {
    try {
      final platform = _player.platform;
      if (platform is NativePlayer) {
        await platform.setProperty(name, value);
      }
    } catch (_) {
      // 当前平台不支持 mpv 属性设置（如 Web）或属性名无效，忽略。
    }
  }

  /// 初始化默认 mpv 属性，优化网络流播放体验。
  Future<void> _applyDefaultProperties() async {
    await _setProperty('cache-secs', '120');
    await _setProperty('demuxer-readahead-secs', '120');
    await _setProperty('network-timeout', '60');
    await _setProperty('force-seekable', 'yes');
    // 注：mpv / FFmpeg lavf 的网络自动重连选项（reconnect 等）本可在此追加以减少
    // 应用层重连，但 `stream-lavf-o` 须用逗号分隔且不同源兼容性不一，易在 open() 阶段
    // 引发解码失败（黑屏）。应用层重连已改为同一实例 re-open 自愈，故此处不启用，
    // 待后续单独验证后再按需加入。
  }

  @override
  Future<void> setHwdec(String mode) async {
    _currentHwdec = mode;
    await _setProperty('hwdec', _hwdecToMpv(mode));
  }

  /// 读取 mpv 只读属性（如 `hwdec-current` / `video-codec`）。
  ///
  /// 平台不支持（如 Web）、属性不存在或尚无值时返回 null。
  @override
  Future<String?> getProperty(String name) async {
    try {
      final platform = _player.platform;
      if (platform is NativePlayer) {
        final value = await platform.getProperty(name);
        return value.isEmpty ? null : value;
      }
    } catch (_) {
      // 当前平台不支持 mpv 属性查询或属性名无效，忽略。
    }
    return null;
  }

  @override
  Future<void> setAudioChannel(String channel) async {
    _currentAudioChannel = channel;
    await _setProperty('audio-channels', channel);
  }

  @override
  Future<void> setAspectRatio(String ratio) async {
    _currentAspectRatio = ratio;
    final value = _aspectToValue(ratio);
    if (value == null) {
      // fill：禁用保持比例，拉伸填满画面。
      await _setProperty('keepaspect', 'no');
      await _setProperty('video-aspect-override', '-1');
    } else {
      await _setProperty('keepaspect', 'yes');
      await _setProperty('video-aspect-override', value.toString());
    }
  }

  @override
  String get currentHwdec => _currentHwdec;

  @override
  String get currentAudioChannel => _currentAudioChannel;

  @override
  String get currentAspectRatio => _currentAspectRatio;
}

import 'package:media_kit/media_kit.dart';

import 'player_capability.dart';
import 'video_player_backend.dart';

/// 基于 media_kit / mpv 的视频播放后端实现。
///
/// 通过 [NativePlayer.setProperty] 调整 mpv 属性，提供硬件解码、音频通道
/// 与画面比例的运行时切换能力。持有底层 [Player] 实例供控制器与 UI 使用。
class MediaKitBackend extends VideoPlayerBackend {
  MediaKitBackend(this._player) {
    // F-31：能力集合反映真实运行时——mpv 属性系能力仅在原生平台可用，
    // Web（WebPlayer）与异常构造下返回空集，菜单按能力自动隐藏 mpv 专属项。
    _native = _player.platform is NativePlayer;
    _applyDefaultProperties();
  }

  static const Set<PlayerCapability> _nativeCapabilities =
      <PlayerCapability>{
    PlayerCapability.hwdec,
    PlayerCapability.audioChannel,
    PlayerCapability.aspectRatio,
    PlayerCapability.propertyQuery,
    PlayerCapability.subtitle,
    PlayerCapability.danmaku,
    PlayerCapability.upscaleShader,
  };

  @override
  Set<PlayerCapability> get capabilities =>
      _native ? _nativeCapabilities : const <PlayerCapability>{};

  final Player _player;

  /// 底层是否为 NativePlayer（mpv）；false 表示 Web 等无属性能力的平台。
  bool _native = false;

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
    // F-29：标准档 demuxer 前向缓存预算（mpv 默认仅 128MiB，加大后长视频
    // 拖动更顺滑）；移动网络 / 低内存时经 [setDemuxerCacheBudget] 降到
    // 低内存档，避免后台 demux 缓存挤占前台内存。
    await _setProperty('demuxer-max-bytes', '1500MiB');
    await _setProperty('demuxer-max-back-bytes', '750MiB');
    // 注：mpv / FFmpeg lavf 的网络自动重连选项（reconnect 等）本可在此追加以减少
    // 应用层重连，但 `stream-lavf-o` 须用逗号分隔且不同源兼容性不一，易在 open() 阶段
    // 引发解码失败（黑屏）。应用层重连已改为同一实例 re-open 自愈，故此处不启用，
    // 待后续单独验证后再按需加入。
  }

  /// F-29：设置 demuxer 前向 / 后向缓存预算（字节）。
  ///
  /// 移动网络或低内存设备降级调用（如 2MiB / 1MiB），非原生平台静默忽略。
  Future<void> setDemuxerCacheBudget(int maxBytes, int maxBackBytes) async {
    await _setProperty('demuxer-max-bytes', '$maxBytes');
    await _setProperty('demuxer-max-back-bytes', '$maxBackBytes');
  }

  /// F-29：open 前按地址准备 demuxer 格式。
  ///
  /// HLS（.m3u8）强制 `demuxer-lavf-format=hls`，跳过 FFmpeg 内容探测——
  /// 部分 CMS 媒体服务器的 m3u8 首段被误探为 mpegts 导致时长缺失 / 黑屏；
  /// 非 HLS 地址复位为自动探测，避免普通 mp4 被错误按 hls 解析。
  Future<void> prepareDemuxerForUrl(String url) async {
    final isHls = url.toLowerCase().contains('.m3u8');
    await _setProperty('demuxer-lavf-format', isHls ? 'hls' : '');
  }

  @override
  Future<void> setHwdec(String mode) async {
    _currentHwdec = mode;
    await _setProperty('hwdec', _hwdecToMpv(mode));
  }

  /// 设置 GLSL 用户 shader 列表（F-7 超分辨率）。
  ///
  /// mpv 运行时替换 `glsl-shaders`，渲染管线下一帧重建，无需 re-open；
  /// 空字符串清空。平台不支持（如 Web）由 [_setProperty] 静默忽略。
  @override
  Future<void> setUpscaleShaders(String shaders) async {
    await _setProperty('glsl-shaders', shaders);
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

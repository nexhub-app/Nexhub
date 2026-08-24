/// 播放器后端能力枚举（F-2）。
///
/// 定义 [VideoPlayerBackend] 可能支持的能力项目，调用方可通过
/// `backend.capabilities.contains(PlayerCapability.hwdec)` 探测。
enum PlayerCapability {
  /// 硬件解码模式切换（auto/sw/hw/hw+）。
  hwdec,

  /// 音频通道切换（auto/stereo/mono）。
  audioChannel,

  /// 画面比例切换（default/4:3/16:9/fill）。
  aspectRatio,

  /// 后端只读属性查询（hwdec-current、video-codec 等）。
  propertyQuery,

  /// 字幕样式设置（字号、颜色、位置等）。
  subtitle,

  /// 弹幕功能（仅 media_kit 后端通过画布层实现）。
  danmaku,

  /// GLSL 用户 shader 注入（mpv `glsl-shaders`，F-7 超分辨率）。
  upscaleShader,
}
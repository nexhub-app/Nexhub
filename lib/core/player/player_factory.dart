import 'package:media_kit/media_kit.dart';

import 'media_kit_backend.dart';
import 'no_op_player_backend.dart';
import 'video_player_backend.dart';

/// 播放器后端工厂。
///
/// 按平台/可用依赖选择 [VideoPlayerBackend] 实现：
/// - 桌面/移动端：默认 [MediaKitBackend]（media_kit / mpv）；
/// - Web 或其他无原生播放环境：返回 [NoOpPlayerBackend]（降级）。
///
/// 调用方通过 `backend.capabilities` 探测实际能力，而非依赖后端类型
/// 判断，保持与具体实现解耦。
class PlayerFactory {
  PlayerFactory._();

  /// 创建播放后端实例。
  ///
  /// [player] 可选外部传入的 [Player] 实例（如测试用 mock），
  /// 为 null 时由工厂内部创建。
  static VideoPlayerBackend createBackend({Player? player}) {
    // 当前仅 media_kit 后端；后续可在此按平台/编译标记切换：
    // - Web 平台：WebMediaKitBackend 或 NoOpPlayerBackend
    // - 纯音频：just_audio 后端
    // - 无 media_kit：NoOpPlayerBackend
    try {
      return MediaKitBackend(player ?? Player());
    } on Object {
      // 初始化失败时安全降级（如 Web 平台无原生支持）。
      return NoOpPlayerBackend();
    }
  }
}
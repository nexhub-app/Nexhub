import 'player_capability.dart';
import 'video_player_backend.dart';

/// 无操作播放后端（F-2 NoOp 降级）。
///
/// 所有方法返回空值或抛出 [UnsupportedError]，[capabilities] 返回空集。
/// 用于平台无可用播放内核时的降级占位，避免调用方 null 检查。
class NoOpPlayerBackend extends VideoPlayerBackend {
  @override
  Set<PlayerCapability> get capabilities => const <PlayerCapability>{};

  @override
  String get currentHwdec => '';

  @override
  String get currentAudioChannel => '';

  @override
  String get currentAspectRatio => '';
}
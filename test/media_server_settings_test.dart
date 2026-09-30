/// 媒体服务器播放设置单测（A2 码率档位持久化）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/comic/models/reader_preferences.dart';
import 'package:nexhub/core/services/media_server/media_server_settings.dart';

void main() {
  test('档位持久化往返', () async {
    final backend = InMemoryBackend();
    final settings = MediaServerPlaybackSettings(backend: backend);
    await settings.load();
    expect(settings.tier, MediaServerBitrateTier.auto);

    await settings.setTier(MediaServerBitrateTier.m8);
    expect(settings.tier, MediaServerBitrateTier.m8);

    // 新实例（模拟重启）恢复已存档位。
    final settings2 = MediaServerPlaybackSettings(backend: backend);
    await settings2.load();
    expect(settings2.tier, MediaServerBitrateTier.m8);
  });

  test('档位码率取值语义', () {
    // 原画 = 极大值强制直连；自动 = 高值交服务器决策。
    expect(
      MediaServerBitrateTier.original.maxBitrate,
      greaterThan(MediaServerBitrateTier.auto.maxBitrate),
    );
    expect(MediaServerBitrateTier.m4.maxBitrate, 4000000);
  });

  test('损坏数据回落自动档', () async {
    final backend = InMemoryBackend();
    await backend.set('media_server_playback_settings_v1', '{broken');
    final settings = MediaServerPlaybackSettings(backend: backend);
    await settings.load();
    expect(settings.tier, MediaServerBitrateTier.auto);
  });
}

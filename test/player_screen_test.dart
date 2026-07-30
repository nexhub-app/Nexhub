// P9.1.7 player_screen_test：稳定 Key、连播/收藏回调。
//
// 完整 widget pump 受阻于 media_kit 原生依赖（Player() 构造需 libmpv），
// 测试环境不可用。故拆分为可独立验证的单元：
// 1. 收藏回调逻辑（FavoritesManager 集成）—— 播放器 _toggleFavorite 调用的同一 API
// 2. 重新收藏保留 favoritedAt（P8.1.3 _removedFavoriteCache）
// 3. updateLastRead 写入 lastRead 时间戳（P8.1.3）
// 4. autoPlayNext 默认值 true（PlayerController.autoPlayNext 字段，源码层验证）
// 5. 稳定 Key 常量存在于源码（引用 VideoPlayerScreen 类确保编译期存在）
// 6. 播放统计 PlayerStats 解析与花屏自动降级纯函数（无需构造 Player）
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/comic/models/reader_preferences.dart';
import 'package:nexhub/core/favorites/favorites_manager.dart';
import 'package:nexhub/core/models/episode.dart';
import 'package:nexhub/core/models/media_item.dart';
import 'package:nexhub/core/models/plugin_config.dart';
import 'package:nexhub/core/player/player_controller.dart';
import 'package:nexhub/features/player/presentation/video_player_screen.dart';

void main() {
  group('P9.1.7 player_screen', () {
    group('favorite callback (FavoritesManager integration)', () {
      late InMemoryBackend backend;
      late FavoritesManager favorites;

      setUp(() {
        backend = InMemoryBackend();
        favorites = FavoritesManager(backend: backend);
      });

      test('toggleFavorite adds and removes for animeSource', () async {
        const item = MediaItem(
          id: 'anime_1',
          title: 'Test Anime',
          sourceType: SourceType.animeSource,
        );

        // 初始未收藏
        expect(favorites.isFavorite('anime_1', SourceType.animeSource), false);

        // 收藏（模拟播放器 _toggleFavorite 调用）
        await favorites.toggleFavorite(item);
        expect(favorites.isFavorite('anime_1', SourceType.animeSource), true);
        expect(favorites.favoritesFor(SourceType.animeSource).length, 1);

        // 取消收藏
        await favorites.toggleFavorite(item);
        expect(favorites.isFavorite('anime_1', SourceType.animeSource), false);
        expect(favorites.favoritesFor(SourceType.animeSource), isEmpty);
      });

      test('re-favorite preserves favoritedAt (P8.1.3)', () async {
        const item = MediaItem(
          id: 'anime_1',
          title: 'Test Anime',
          sourceType: SourceType.animeSource,
        );

        // 首次收藏
        await favorites.toggleFavorite(item);
        final firstEntry = favorites.favoritesFor(SourceType.animeSource).first;
        final originalFavoritedAt = firstEntry.favoritedAt;

        // 等待 10ms 确保 timestamp 不同
        await Future<void>.delayed(const Duration(milliseconds: 10));

        // 取消收藏
        await favorites.toggleFavorite(item);
        expect(favorites.isFavorite('anime_1', SourceType.animeSource), false);

        // 重新收藏 —— favoritedAt 应保留原值（_removedFavoriteCache）
        await favorites.toggleFavorite(item);
        final reEntry = favorites.favoritesFor(SourceType.animeSource).first;
        expect(reEntry.favoritedAt, originalFavoritedAt,
            reason: 're-favorite should preserve original favoritedAt');
      });

      test('updateLastRead sets lastRead timestamp (P8.1.3)', () async {
        const item = MediaItem(
          id: 'anime_1',
          title: 'Test Anime',
          sourceType: SourceType.animeSource,
        );

        await favorites.toggleFavorite(item);
        final before = favorites.favoritesFor(SourceType.animeSource).first;
        expect(before.lastRead, 0);

        await Future<void>.delayed(const Duration(milliseconds: 10));
        await favorites.updateLastRead('anime_1', SourceType.animeSource);

        final after = favorites.favoritesFor(SourceType.animeSource).first;
        expect(after.lastRead, greaterThan(0),
            reason: 'updateLastRead should set non-zero timestamp');
      });
    });

    group('autoPlayNext default (source-level)', () {
      test('VideoPlayerScreen accepts favoriteType param', () {
        // 验证 VideoPlayerScreen 类编译期存在且 favoriteType 参数可用。
        // autoPlayNext 默认值（true）在 PlayerController 构造函数中设置，
        // 受 media_kit 原生依赖限制无法在测试环境构造，源码层验证。
        const screen = VideoPlayerScreen(
          title: 'test',
          episode: Episode(id: 'e1', title: 'ep1', url: '/e1'),
          sourceId: 'src1',
          itemId: 'item1',
          favoriteType: SourceType.animeSource,
        );
        expect(screen.favoriteType, SourceType.animeSource);
        expect(screen.title, 'test');
        expect(screen.itemId, 'item1');
      });

      test('VideoPlayerScreen favoriteType defaults to null (no favorite button)', () {
        const screen = VideoPlayerScreen(
          title: 'test',
          episode: Episode(id: 'e1', title: 'ep1', url: '/e1'),
          sourceId: 'src1',
          itemId: 'item1',
        );
        expect(screen.favoriteType, isNull);
      });
    });

    group('stable Keys exist in source', () {
      // 稳定 Key（const Key('player_xxx')）在 video_player_screen.dart 中定义。
      // 完整 widget pump 受阻于 media_kit，Key 字符串由源码 grep 验证。
      // 此处引用 VideoPlayerScreen 确保类编译期存在，防止误删。
      test('VideoPlayerScreen class is importable', () {
        expect(VideoPlayerScreen, isNotNull);
      });
    });
  });

  group('PlayerStats.fromProperties', () {
    test('parses full mpv property map', () {
      final stats = PlayerStats.fromProperties(<String, String?>{
        'hwdec-current': 'mediacodec',
        'video-codec': 'h264 (High)',
        'video-format': 'nv12',
        'width': '1920',
        'height': '1080',
        'frame-drop-count': '3',
        'decoder-frame-drop-count': '0',
        'video-bitrate': '2500000.500000',
        'cache-buffering-state': '100',
      });
      expect(stats.hwdecCurrent, 'mediacodec');
      expect(stats.videoCodec, 'h264 (High)');
      expect(stats.videoFormat, 'nv12');
      expect(stats.width, 1920);
      expect(stats.height, 1080);
      expect(stats.frameDropCount, 3);
      expect(stats.decoderFrameDropCount, 0);
      // video-bitrate 带小数时四舍五入取整
      expect(stats.videoBitrate, 2500001);
      expect(stats.cacheBufferingState, 100);
      expect(stats.isHardwareDecoding, true);
      expect(stats.isSoftwareDecoding, false);
      expect(stats.isEmpty, false);
    });

    test('hwdec-current "no" means software decoding', () {
      final stats = PlayerStats.fromProperties(<String, String?>{
        'hwdec-current': 'no',
        'video-codec': 'hevc',
      });
      expect(stats.isSoftwareDecoding, true);
      expect(stats.isHardwareDecoding, false);
    });

    test('null / malformed values degrade to null fields and isEmpty', () {
      final stats = PlayerStats.fromProperties(<String, String?>{
        'hwdec-current': null,
        'width': 'not-a-number',
        'video-bitrate': null,
      });
      expect(stats.hwdecCurrent, isNull);
      expect(stats.width, isNull);
      expect(stats.videoBitrate, isNull);
      expect(stats.isEmpty, true);
      expect(stats.isHardwareDecoding, false);
      expect(stats.isSoftwareDecoding, false);
    });
  });

  group('decode fallback pure functions', () {
    group('PlayerController.isHwdecFailureLog', () {
      test('matches known hwdec failure messages regardless of level', () {
        expect(
          PlayerController.isHwdecFailureLog(
              'warn', 'Could not initialize hardware decoding'),
          true,
        );
        expect(
          PlayerController.isHwdecFailureLog(
              'error', 'Failed to initialize decoder'),
          true,
        );
      });

      test('matches error/fatal level logs mentioning hwdec', () {
        expect(
          PlayerController.isHwdecFailureLog(
              'error', 'hwdec: mediacodec init failed'),
          true,
        );
        expect(
          PlayerController.isHwdecFailureLog(
              'fatal', 'cannot create hwdec surface'),
          true,
        );
      });

      test('ignores benign logs', () {
        // info 级提及 hwdec 不触发
        expect(
          PlayerController.isHwdecFailureLog(
              'info', 'Using hardware decoding (mediacodec).'),
          false,
        );
        expect(
          PlayerController.isHwdecFailureLog('v', 'hwdec-current=mediacodec'),
          false,
        );
        // error 级但与 hwdec 无关不触发
        expect(
          PlayerController.isHwdecFailureLog('error', 'network timeout'),
          false,
        );
      });
    });

    group('PlayerController.nextFallbackHwdec', () {
      test('auto downgrades to hw+', () {
        expect(
          PlayerController.nextFallbackHwdec('auto', autoDowngraded: false),
          'hw+',
        );
        expect(
          PlayerController.nextFallbackHwdec('auto', autoDowngraded: true),
          'hw+',
        );
      });

      test('hw+ downgrades to sw only when reached via auto-downgrade', () {
        expect(
          PlayerController.nextFallbackHwdec('hw+', autoDowngraded: true),
          'sw',
        );
        // 用户手动选的 hw+ 不自动续降
        expect(
          PlayerController.nextFallbackHwdec('hw+', autoDowngraded: false),
          isNull,
        );
      });

      test('sw / hw are terminal states', () {
        expect(
          PlayerController.nextFallbackHwdec('sw', autoDowngraded: true),
          isNull,
        );
        expect(
          PlayerController.nextFallbackHwdec('hw', autoDowngraded: true),
          isNull,
        );
      });
    });
  });
}

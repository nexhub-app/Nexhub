/// D4 清理联动单测：removeContentIdPrefix（watched / position / history）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:nexhub/core/comic/models/reader_preferences.dart';
import 'package:nexhub/core/history/history_manager.dart';
import 'package:nexhub/core/history/media_playback_position_manager.dart';
import 'package:nexhub/core/history/media_watched_manager.dart';
import 'package:nexhub/core/models/plugin_config.dart' show SourceType;

void main() {
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('ms_cleanup_');
    try {
      Hive.init(tempDir.path);
    } catch (_) {}
  });

  tearDownAll(() async {
    await Hive.deleteFromDisk();
  });

  test('MediaWatchedManager.removeContentIdPrefix', () async {
    final box = await Hive.openBox('media_watched');
    final mgr = MediaWatchedManager(box: box);
    await mgr.init();
    await mgr.markWatched('ms:s1:work1', 0);
    await mgr.markWatched('ms:s1:work2', 3);
    await mgr.markWatched('ms:s2:work3', 1);
    await mgr.removeContentIdPrefix('ms:s1:');
    expect(mgr.watchedList('ms:s1:work1'), isEmpty);
    expect(mgr.watchedList('ms:s1:work2'), isEmpty);
    expect(mgr.watchedList('ms:s2:work3'), <int>[1]);
    expect(box.get('ms:s1:work1'), isNull);
    expect(box.get('ms:s2:work3'), isNotNull);
  });

  test('MediaPlaybackPositionManager.removeContentIdPrefix', () async {
    final box = await Hive.openBox('media_playback_position');
    final mgr = MediaPlaybackPositionManager(box: box);
    await mgr.init();
    await mgr.savePosition('ms:s1:work1', 0, 1000);
    await mgr.savePosition('ms:s1:work1', 1, 2000);
    await mgr.savePosition('ms:s2:work3', 0, 3000);
    await mgr.removeContentIdPrefix('ms:s1:');
    expect(mgr.getPosition('ms:s1:work1', 0), 0);
    expect(mgr.getPosition('ms:s1:work1', 1), 0);
    expect(mgr.getPosition('ms:s2:work3', 0), 3000);
    expect(mgr.getLastEpisode('ms:s1:work1'), -1);
    expect(mgr.getLastEpisode('ms:s2:work3'), 0);
  });

  test('HistoryManager addEntryRaw / removeByContentIdPrefix', () async {
    final backend = InMemoryBackend();
    final mgr = HistoryManager(backend: backend);
    await mgr.init();
    await mgr.addEntryRaw(
      const HistoryEntry(
        id: 'ms:s1:work1',
        title: 'Server Work',
        sourceType: SourceType.animeSource,
        detailUrl: 'ms:s1:work1',
        viewedAt: 1,
        kind: 'mediaServer',
      ),
    );
    await mgr.addEntryRaw(
      const HistoryEntry(
        id: 'local-1',
        title: 'Local Work',
        sourceType: SourceType.animeSource,
        viewedAt: 2,
      ),
    );
    // kind 往返：fromJson 恢复 mediaServer 标记。
    final serverEntry = mgr.historyFor(SourceType.animeSource).firstWhere(
          (e) => e.id == 'ms:s1:work1',
        );
    expect(serverEntry.kind, 'mediaServer');
    expect(serverEntry.detailUrl, 'ms:s1:work1');

    await mgr.removeByContentIdPrefix('ms:s1:');
    final ids = mgr
        .historyFor(SourceType.animeSource)
        .map((e) => e.id)
        .toList();
    expect(ids, <String>['local-1']);
  });
}

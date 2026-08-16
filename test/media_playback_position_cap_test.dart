/// 播放位置记录按作品限 50 条（F-9）自测：MRU 裁剪最旧记录、
/// 重复保存去重、清除内容后可重新累计。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:nexhub/core/history/media_playback_position_manager.dart';

void main() {
  late Box<dynamic> box;

  setUpAll(() async {
    Hive.init(Directory.systemTemp.createTempSync('pos_cap_').path);
    box = await Hive.openBox<dynamic>('pos_cap_test');
  });

  tearDown(() async {
    await box.clear();
  });

  test('超过 50 条时裁剪最旧，保留最近保存的 50 条', () async {
    final mgr = MediaPlaybackPositionManager(box: box);
    for (var i = 0; i < 60; i++) {
      await mgr.savePosition('anime1', i, i * 1000);
    }
    // 前 10 集（最旧）被裁剪
    expect(mgr.getPosition('anime1', 0), 0);
    expect(mgr.getPosition('anime1', 9), 0);
    expect(mgr.getPosition('anime1', 10), 10 * 1000);
    expect(mgr.getPosition('anime1', 59), 59 * 1000);
    // Hive 侧同步删除
    expect(box.containsKey('pos:anime1:0'), isFalse);
    expect(box.containsKey('pos:anime1:59'), isTrue);
    // last_ep 不受裁剪影响
    expect(mgr.getLastEpisode('anime1'), 59);
  });

  test('回看旧集会刷新其新鲜度，不会被裁剪', () async {
    final mgr = MediaPlaybackPositionManager(box: box);
    for (var i = 0; i < 50; i++) {
      await mgr.savePosition('anime2', i, i * 1000);
    }
    // 回看第 0 集（最新鲜），再保存第 50 集 → 被裁的是第 1 集而非第 0 集。
    await mgr.savePosition('anime2', 0, 123);
    await mgr.savePosition('anime2', 50, 50 * 1000);
    expect(mgr.getPosition('anime2', 0), 123);
    expect(mgr.getPosition('anime2', 1), 0);
    expect(mgr.getPosition('anime2', 50), 50 * 1000);
  });

  test('clearContent 后重新保存正常累计', () async {
    final mgr = MediaPlaybackPositionManager(box: box);
    for (var i = 0; i < 55; i++) {
      await mgr.savePosition('anime3', i, 1000);
    }
    await mgr.clearContent('anime3');
    expect(mgr.getPosition('anime3', 30), 0);
    expect(mgr.getLastEpisode('anime3'), -1);
    await mgr.savePosition('anime3', 3, 777);
    expect(mgr.getPosition('anime3', 3), 777);
  });

  test('不同作品的记录互不影响', () async {
    final mgr = MediaPlaybackPositionManager(box: box);
    for (var i = 0; i < 60; i++) {
      await mgr.savePosition('animeA', i, 1);
    }
    await mgr.savePosition('animeB', 0, 9);
    expect(mgr.getPosition('animeB', 0), 9);
    expect(mgr.getPosition('animeA', 59), 1);
  });
}

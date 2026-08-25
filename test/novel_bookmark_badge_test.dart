/// 书签角标自定义图自测（I7）：iconPath 序列化、copyWithIcon、setBadge 更新。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:nexhub/features/novel/presentation/novel_bookmark_manager.dart';

void main() {
  setUpAll(() async {
    Hive.init(Directory.systemTemp
        .createTempSync('novel_bookmark_badge_test')
        .path);
  });

  tearDownAll(() async {
    await Hive.deleteFromDisk();
  });

  test('copyWithIcon 设置与清除 iconPath，原对象不变', () {
    final bm = NovelBookmark(
      novelId: 'n1',
      chapterIndex: 3,
      chapterId: 'c3',
      chapterTitle: '第三章',
      page: 2,
      createdAt: 42,
    );
    expect(bm.iconPath, isNull);

    final withIcon = bm.copyWithIcon('/tmp/badge.png');
    expect(withIcon.iconPath, '/tmp/badge.png');
    expect(bm.iconPath, isNull);
    expect(withIcon.key, bm.key);

    // JSON 往返
    final restored =
        NovelBookmark.fromJson(withIcon.toJson());
    expect(restored.iconPath, '/tmp/badge.png');

    // 清除后不再序列化该键
    final cleared = withIcon.copyWithIcon(null);
    expect(cleared.iconPath, isNull);
    expect(cleared.toJson().containsKey('iconPath'), isFalse);
  });

  test('setBadge 持久化更新角标图路径', () async {
    final box = await Hive.openBox(NovelBookmarkManager.boxName);
    await box.clear();
    final mgr = NovelBookmarkManager(box: box);
    final bm = await mgr.add(NovelBookmark(
      novelId: 'n2',
      chapterIndex: 0,
      chapterId: 'c0',
      chapterTitle: '第一章',
      page: 0,
      createdAt: 100,
    ));

    await mgr.setBadge(bm.key, '/docs/novel_badges/1.jpg');
    final listed = await mgr.listFor('n2');
    expect(listed.single.iconPath, '/docs/novel_badges/1.jpg');

    await mgr.setBadge(bm.key, null);
    final after = await mgr.listFor('n2');
    expect(after.single.iconPath, isNull);

    // 不存在的 key 静默忽略
    await mgr.setBadge('missing::0::0', '/x.png');
    expect(await mgr.listFor('n2').then((l) => l.single.iconPath), isNull);
  });
}

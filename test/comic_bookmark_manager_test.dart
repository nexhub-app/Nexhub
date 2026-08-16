import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:nexhub/core/comic/comic_bookmark_manager.dart';

void main() {
  late Directory dir;
  late Box<dynamic> box;
  late ComicBookmarkManager manager;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('comic_bookmark_test');
    try {
      Hive.init(dir.path);
    } on Object {
      // Hive.init 二次调用可能抛错或静默，包一层避免影响。
    }
    box = await Hive.openBox<dynamic>('comic_bookmarks_test');
    manager = ComicBookmarkManager(box: box);
  });

  tearDown(() async {
    await box.deleteFromDisk();
    await dir.delete(recursive: true);
  });

  test('添加 / 列出 / 判断书签（REQ-C1）', () async {
    final bm = ComicBookmark(
      comicId: 'c1',
      chapterIndex: 3,
      chapterId: 'ch3',
      chapterTitle: '第3话',
      createdAt: 1000,
    );
    await manager.add(bm);
    final list = await manager.listFor('c1');
    expect(list.length, 1);
    expect(list.first.chapterTitle, '第3话');
    expect(await manager.hasBookmark('c1', 3), true);
    expect(await manager.hasBookmark('c1', 4), false);
    expect(await manager.listFor('other'), isEmpty);
  });

  test('按章节删除与 toggle（REQ-C1）', () async {
    expect(await manager.toggleChapter('c1', 2,
        chapterId: 'ch2', chapterTitle: '第2话'), true);
    expect(await manager.hasBookmark('c1', 2), true);
    // 再次 toggle 取消书签
    expect(await manager.toggleChapter('c1', 2,
        chapterId: 'ch2', chapterTitle: '第2话'), false);
    expect(await manager.hasBookmark('c1', 2), false);
    expect(await manager.listFor('c1'), isEmpty);
  });

  test('removeForChapter 只删指定章节', () async {
    await manager.add(ComicBookmark(
        comicId: 'c1',
        chapterIndex: 1,
        chapterId: 'ch1',
        chapterTitle: '第1话',
        createdAt: 1));
    await manager.add(ComicBookmark(
        comicId: 'c1',
        chapterIndex: 2,
        chapterId: 'ch2',
        chapterTitle: '第2话',
        createdAt: 2));
    await manager.removeForChapter('c1', 1);
    expect(await manager.hasBookmark('c1', 1), false);
    expect(await manager.hasBookmark('c1', 2), true);
  });

  test('书签按创建时间倒序', () async {
    await manager.add(ComicBookmark(
        comicId: 'c1',
        chapterIndex: 1,
        chapterId: 'ch1',
        chapterTitle: 'old',
        createdAt: 1));
    await manager.add(ComicBookmark(
        comicId: 'c1',
        chapterIndex: 2,
        chapterId: 'ch2',
        chapterTitle: 'new',
        createdAt: 2));
    final list = await manager.listFor('c1');
    expect(list.first.chapterIndex, 2);
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:nexhub/core/comic/image_favorite_manager.dart';

void main() {
  late Directory dir;
  late Box<dynamic> box;
  late ImageFavoriteManager manager;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('image_favorite_test');
    try {
      Hive.init(dir.path);
    } on Object {
      // Hive.init 二次调用可能抛错或静默，包一层避免影响。
    }
    box = await Hive.openBox<dynamic>('image_favorites_test');
    manager = ImageFavoriteManager(box: box);
  });

  tearDown(() async {
    await box.deleteFromDisk();
    await dir.delete(recursive: true);
  });

  test('添加 / 列出 / 判断收藏（REQ-C2）', () async {
    final fav = ImageFavorite(
      comicId: 'c1',
      chapterIndex: 2,
      chapterTitle: '第2话',
      pageIndex: 5,
      imageUrl: 'https://example.com/2/5.jpg',
      createdAt: 1000,
    );
    await manager.add(fav);
    final list = await manager.list();
    expect(list.length, 1);
    expect(list.first.pageIndex, 5);
    expect(await manager.isFavorite('c1', 2, 5), true);
    expect(await manager.isFavorite('c1', 2, 6), false);
    expect(await manager.isFavoriteByUrl('https://example.com/2/5.jpg'), true);
    expect(await manager.isFavoriteByUrl('https://example.com/other.jpg'), false);
  });

  test('toggle 添加与取消（REQ-C2）', () async {
    expect(
      await manager.toggle(
        comicId: 'c1',
        chapterIndex: 1,
        chapterTitle: '第1话',
        pageIndex: 3,
        imageUrl: 'u1',
      ),
      true,
    );
    expect(await manager.isFavorite('c1', 1, 3), true);
    expect(
      await manager.toggle(
        comicId: 'c1',
        chapterIndex: 1,
        chapterTitle: '第1话',
        pageIndex: 3,
        imageUrl: 'u1',
      ),
      false,
    );
    expect(await manager.isFavorite('c1', 1, 3), false);
    expect(await manager.list(), isEmpty);
  });

  test('同一作品同一章同一页只保留一份（复合 key 覆盖）', () async {
    // 先收藏一页。
    await manager.toggle(
        comicId: 'c1',
        chapterIndex: 0,
        chapterTitle: 't',
        pageIndex: 1,
        imageUrl: 'a');
    // 用同一复合 key 再收藏（同位置）：应覆盖而非新增。
    await manager.add(ImageFavorite(
      comicId: 'c1',
      chapterIndex: 0,
      chapterTitle: 't',
      pageIndex: 1,
      imageUrl: 'b',
      createdAt: 2,
    ));
    final list = await manager.list();
    expect(list.length, 1);
    expect(list.first.imageUrl, 'b');
    // 两次 toggle = 添加 + 删除 → 空。
    await manager.toggle(
        comicId: 'c1',
        chapterIndex: 0,
        chapterTitle: 't',
        pageIndex: 1,
        imageUrl: 'b');
    expect(await manager.list(), isEmpty);
  });

  test('列表按创建时间倒序（图库最新在前）', () async {
    // 用显式 createdAt 避免 toggle 内部 DateTime.now() 同毫秒碰撞导致排序不稳。
    await manager.add(ImageFavorite(
        comicId: 'c1',
        chapterIndex: 1,
        chapterTitle: 'old',
        pageIndex: 1,
        imageUrl: 'old.jpg',
        createdAt: 1));
    await manager.add(ImageFavorite(
        comicId: 'c1',
        chapterIndex: 2,
        chapterTitle: 'new',
        pageIndex: 1,
        imageUrl: 'new.jpg',
        createdAt: 2));
    final list = await manager.list();
    expect(list.first.chapterIndex, 2);
    expect(list.last.chapterIndex, 1);
  });

  test('remove 删除单条', () async {
    final fav = ImageFavorite(
      comicId: 'c1',
      chapterIndex: 0,
      chapterTitle: 't',
      pageIndex: 0,
      imageUrl: 'x',
      createdAt: 1,
    );
    await manager.add(fav);
    await manager.remove(fav.key);
    expect(await manager.list(), isEmpty);
  });
}

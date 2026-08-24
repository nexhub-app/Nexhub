import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/comic/models/reader_preferences.dart';
import 'package:nexhub/core/models/plugin_config.dart';
import 'package:nexhub/core/reader/reading_queue_store.dart';

void main() {
  group('ReadingQueueStore（X-2 待读队列）', () {
    late InMemoryBackend backend;
    late ReadingQueueStore store;

    setUp(() {
      backend = InMemoryBackend();
      store = ReadingQueueStore(backend: backend);
    });

    QueuedReading work({
      String id = 'novel-1',
      SourceType type = SourceType.novelSource,
      String title = '作品一',
    }) =>
        QueuedReading(
          sourceType: type,
          sourceId: 'src-1',
          itemId: id,
          title: title,
          coverUrl: 'https://cover/${id}.jpg',
          detailUrl: 'https://detail/${id}',
          initialChapterIndex: 3,
          updatedAt: 1234567890,
        );

    test('初始队列为空', () async {
      expect(await store.getQueue(), isEmpty);
      expect(await store.getCurrent(), isNull);
    });

    test('add 追加队尾且同 itemId 去重', () async {
      await store.add(work());
      await store.add(work());
      final q = await store.getQueue();
      expect(q.length, 1);
      expect(q.first.title, '作品一');
      expect(q.first.sourceType, SourceType.novelSource);
    });

    test('insertNext 插入队首并去重', () async {
      await store.add(work(id: 'a', title: 'A'));
      await store.add(work(id: 'b', title: 'B'));
      await store.insertNext(work(id: 'b', title: 'B'));
      final q = await store.getQueue();
      expect(q.map((e) => e.itemId).toList(), ['b', 'a']);
    });

    test('removeAt / removeByItemId 移除', () async {
      await store.add(work(id: 'a'));
      await store.add(work(id: 'b'));
      await store.removeAt(0);
      expect((await store.getQueue()).single.itemId, 'b');
      await store.removeByItemId('b');
      expect(await store.getQueue(), isEmpty);
    });

    test('take 移出并返回该条', () async {
      await store.add(work(id: 'a'));
      final taken = await store.take(0);
      expect(taken?.itemId, 'a');
      expect(await store.getQueue(), isEmpty);
    });

    test('setCurrent / getCurrent 往返', () async {
      expect(await store.getCurrent(), isNull);
      await store.setCurrent(work(id: 'x'));
      final cur = await store.getCurrent();
      expect(cur?.itemId, 'x');
      expect(cur?.initialChapterIndex, 3);
      await store.setCurrent(null);
      expect(await store.getCurrent(), isNull);
    });

    test('clear 清空队列', () async {
      await store.add(work(id: 'a'));
      await store.add(work(id: 'b'));
      await store.clear();
      expect(await store.getQueue(), isEmpty);
    });

    test('漫画条目：mangaSource 类型序列化往返', () async {
      await store.add(work(id: 'c1', type: SourceType.mangaSource, title: '漫画一'));
      final q = await store.getQueue();
      expect(q.single.sourceType, SourceType.mangaSource);
    });
  });
}
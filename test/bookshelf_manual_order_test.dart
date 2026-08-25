/// 书架手动排序存储测试（M2 手动排序）。
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/comic/models/reader_preferences.dart'
    show InMemoryBackend;
import 'package:nexhub/core/models/bookshelf_manual_order.dart';
import 'package:nexhub/core/models/plugin_config.dart' show SourceType;

void main() {
  group('BookshelfManualOrderStore', () {
    test('applyOrder 写入 0..n-1 索引', () async {
      final store =
          BookshelfManualOrderStore(backend: InMemoryBackend());
      await store.applyOrder(SourceType.novelSource, <String>['a', 'b', 'c']);
      expect(store.indexFor(SourceType.novelSource, 'a'), 0);
      expect(store.indexFor(SourceType.novelSource, 'b'), 1);
      expect(store.indexFor(SourceType.novelSource, 'c'), 2);
    });

    test('未排序条目返回 null', () {
      final store = BookshelfManualOrderStore(backend: InMemoryBackend());
      expect(store.indexFor(SourceType.novelSource, 'z'), isNull);
    });

    test('跨模块索引互相隔离', () async {
      final store = BookshelfManualOrderStore(backend: InMemoryBackend());
      await store.applyOrder(SourceType.novelSource, <String>['a', 'b']);
      await store.applyOrder(SourceType.mangaSource, <String>['x', 'y']);
      expect(store.indexFor(SourceType.novelSource, 'a'), 0);
      expect(store.indexFor(SourceType.mangaSource, 'x'), 0);
      // 另一模块的条目不在本模块索引中
      expect(store.indexFor(SourceType.novelSource, 'x'), isNull);
    });

    test('持久化可经新实例 reload 还原', () async {
      final backend = InMemoryBackend();
      final s1 = BookshelfManualOrderStore(backend: backend);
      await s1.applyOrder(SourceType.animeSource, <String>['p', 'q']);
      final s2 = BookshelfManualOrderStore(backend: backend);
      await s2.load();
      expect(s2.indexFor(SourceType.animeSource, 'p'), 0);
      expect(s2.indexFor(SourceType.animeSource, 'q'), 1);
    });

    test('remove 清除单条索引', () async {
      final store = BookshelfManualOrderStore(backend: InMemoryBackend());
      await store.applyOrder(SourceType.novelSource, <String>['a', 'b']);
      await store.remove(SourceType.novelSource, 'a');
      expect(store.indexFor(SourceType.novelSource, 'a'), isNull);
      expect(store.indexFor(SourceType.novelSource, 'b'), 1);
    });
  });
}

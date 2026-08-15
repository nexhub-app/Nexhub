import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/models/episode.dart';
import 'package:nexhub/core/novel/novel_toc_cache.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tempDir;
  late NovelTocCache cache;

  const sourceId = 'novel_biquge';
  // novelId 为完整 URL（超长 + 含非法文件名字符）→ 验证哈希文件名可落盘。
  const novelId = 'https://m.biqubu3.com/book_18093/?from=history&page=1';

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('novel_toc_cache_test');
    cache = NovelTocCache(baseDirOverride: tempDir);
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } on Object {
      // Windows 下偶发文件句柄未释放，忽略清理失败。
    }
  });

  List<Episode> chapters(int count, {String prefix = '第'}) => <Episode>[
        for (var i = 1; i <= count; i++)
          Episode(
            id: 'ch$i',
            title: '$prefix$i章',
            url: 'https://m.biqubu3.com/book_18093/$i.html',
          ),
      ];

  test('write then read round-trips id/title/url', () async {
    final input = chapters(3);
    await cache.write(sourceId, novelId, input);

    final result = await cache.read(sourceId, novelId);
    expect(result, isNotNull);
    expect(result!.length, 3);
    for (var i = 0; i < 3; i++) {
      expect(result[i].id, input[i].id);
      expect(result[i].title, input[i].title);
      expect(result[i].url, input[i].url);
    }
  });

  test('read returns null when no cache exists', () async {
    expect(await cache.read(sourceId, 'https://other.example/none'), isNull);
  });

  test('corrupted JSON returns null silently', () async {
    await cache.write(sourceId, novelId, chapters(2));
    // 定位缓存目录下唯一的文件并写入损坏内容。
    final dir = Directory(p.join(tempDir.path, 'novel_toc_cache'));
    final files = dir.listSync().whereType<File>().toList();
    expect(files, hasLength(1));
    await files.single.writeAsString('{not valid json');

    expect(await cache.read(sourceId, novelId), isNull);
  });

  test('write overwrites previous cache', () async {
    await cache.write(sourceId, novelId, chapters(2));
    await cache.write(sourceId, novelId, chapters(5, prefix: '新第'));

    final result = await cache.read(sourceId, novelId);
    expect(result, isNotNull);
    expect(result!.length, 5);
    expect(result.first.title, '新第1章');
  });

  test('empty chapter list is not written (keeps existing cache)', () async {
    await cache.write(sourceId, novelId, chapters(2));
    await cache.write(sourceId, novelId, const <Episode>[]);

    final result = await cache.read(sourceId, novelId);
    expect(result, isNotNull);
    expect(result!.length, 2);
  });

  test('different sourceId/novelId map to independent cache entries', () async {
    await cache.write(sourceId, novelId, chapters(1));
    await cache.write('other_source', novelId, chapters(4));

    expect((await cache.read(sourceId, novelId))!.length, 1);
    expect((await cache.read('other_source', novelId))!.length, 4);
  });
}

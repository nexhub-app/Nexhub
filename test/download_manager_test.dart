import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/comic/models/reader_preferences.dart';
import 'package:nexhub/core/download/download_file_system.dart';
import 'package:nexhub/core/download/download_format_preferences.dart';
import 'package:nexhub/core/download/download_manager.dart';
import 'package:nexhub/core/download/download_storage.dart';
import 'package:nexhub/core/download/download_task.dart';
import 'package:nexhub/core/models/plugin_config.dart';
import 'package:nexhub/core/models/episode.dart';
import 'package:nexhub/core/models/media_item.dart';
import 'package:nexhub/core/local/saf_bridge.dart' show safBaseName;
import 'package:nexhub/core/resolver/resolver_registry.dart';
import 'package:nexhub/core/scraper/media_api_service.dart';
import 'package:nexhub/core/services/source_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('DownloadTask', () {
    test('JSON round-trip preserves all fields', () {
      const task = DownloadTask(
        id: 'test_001',
        title: 'Test Comic',
        sourceType: SourceType.mangaSource,
        sourceId: 'src1',
        contentId: 'comic123',
        format: DownloadFormat.cbz,
        coverUrl: 'https://example.com/cover.jpg',
        chapterTitles: <String>['Ch1', 'Ch2'],
        totalChapters: 10,
        downloadedChapters: 5,
        status: DownloadStatus.downloading,
        createdAt: 1700000000000,
      );

      final json = task.toJsonString();
      final restored = DownloadTask.fromJsonString(json);

      expect(restored.id, task.id);
      expect(restored.title, task.title);
      expect(restored.sourceType, task.sourceType);
      expect(restored.contentId, task.contentId);
      expect(restored.format, task.format);
      expect(restored.totalChapters, task.totalChapters);
      expect(restored.downloadedChapters, task.downloadedChapters);
      expect(restored.status, task.status);
      expect(restored.chapterTitles, task.chapterTitles);
    });

    test('progress calculates correctly', () {
      const task = DownloadTask(
        id: 't',
        title: 'T',
        sourceType: SourceType.novelSource,
        contentId: 'c',
        format: DownloadFormat.epub,
        totalChapters: 4,
        downloadedChapters: 3,
        createdAt: 0,
      );
      expect(task.progress, 0.75);
    });

    test('isActive and isCompleted flags', () {
      const base = DownloadTask(
        id: 't', title: 'T', sourceType: SourceType.mangaSource,
        contentId: 'c', format: DownloadFormat.cbz, createdAt: 0,
      );

      expect(base.copyWith(status: DownloadStatus.pending).isActive, true);
      expect(base.copyWith(status: DownloadStatus.downloading).isActive, true);
      expect(base.copyWith(status: DownloadStatus.paused).isActive, true);
      expect(base.copyWith(status: DownloadStatus.completed).isActive, false);
      expect(base.copyWith(status: DownloadStatus.completed).isCompleted, true);
      expect(base.copyWith(status: DownloadStatus.failed).isActive, false);
      expect(base.copyWith(status: DownloadStatus.cancelled).isActive, false);
    });
  });

  group('DownloadFormatPreferences', () {
    test('defaults are cbz and epub', () {
      const prefs = DownloadFormatPreferences.defaults();
      expect(prefs.comicFormat, DownloadFormat.cbz);
      expect(prefs.novelFormat, DownloadFormat.epub);
    });

    test('JSON round-trip', () {
      const prefs = DownloadFormatPreferences(
        comicFormat: DownloadFormat.folder,
        novelFormat: DownloadFormat.txt,
      );
      final json = prefs.toJsonString();
      final restored = DownloadFormatPreferences.fromJsonString(json);
      expect(restored.comicFormat, DownloadFormat.folder);
      expect(restored.novelFormat, DownloadFormat.txt);
      expect(restored, prefs);
    });
  });

  group('DownloadStorage', () {
    late InMemoryBackend backend;
    late DownloadStorage storage;

    setUp(() {
      backend = InMemoryBackend();
      storage = DownloadStorage(backend: backend);
    });

    test('loadAll returns empty when no data', () async {
      final tasks = await storage.loadAll();
      expect(tasks, isEmpty);
    });

    test('saveAll and loadAll round-trip', () async {
      final tasks = <DownloadTask>[
        const DownloadTask(
          id: 't1', title: 'Task 1',
          sourceType: SourceType.mangaSource,
          contentId: 'c1', format: DownloadFormat.cbz,
          totalChapters: 5, downloadedChapters: 5,
          status: DownloadStatus.completed,
          createdAt: 1700000000000,
          localPath: '/tmp/t1.cbz',
        ),
        const DownloadTask(
          id: 't2', title: 'Task 2',
          sourceType: SourceType.novelSource,
          contentId: 'c2', format: DownloadFormat.epub,
          totalChapters: 3, downloadedChapters: 1,
          status: DownloadStatus.downloading,
          createdAt: 1700000000001,
        ),
      ];

      await storage.saveAll(tasks);
      final loaded = await storage.loadAll();
      expect(loaded.length, 2);
      expect(loaded[0].id, 't1');
      expect(loaded[0].status, DownloadStatus.completed);
      expect(loaded[1].id, 't2');
      expect(loaded[1].status, DownloadStatus.downloading);
    });

    test('clear empties storage', () async {
      await storage.saveAll(<DownloadTask>[
        const DownloadTask(
          id: 't', title: 'T',
          sourceType: SourceType.mangaSource,
          contentId: 'c', format: DownloadFormat.cbz,
          createdAt: 0,
        ),
      ]);
      await storage.clear();
      final loaded = await storage.loadAll();
      expect(loaded, isEmpty);
    });
  });

  group('DownloadManager clear-records rules', () {
    late InMemoryFileSystem fs;
    late InMemoryBackend backend;
    late DownloadStorage storage;
    late DownloadManager manager;

    setUp(() async {
      fs = InMemoryFileSystem();
      backend = InMemoryBackend();
      storage = DownloadStorage(backend: backend);
      manager = DownloadManager(
        storage: storage,
        fs: fs,
        service: MediaApiService(ResolverRegistry.instance),
        sourceRepo: SourceRepository(<PluginConfig>[]),
      );
      await manager.init();
    });

    test('clearAll(false) keeps completed tasks, removes active only',
        () async {
      // Simulate a completed download: write meta.json + product file
      final task = DownloadTask(
        id: 'orphan_1',
        title: 'Orphaned Comic',
        sourceType: SourceType.mangaSource,
        contentId: 'comic_orphan',
        format: DownloadFormat.cbz,
        totalChapters: 5,
        downloadedChapters: 5,
        status: DownloadStatus.completed,
        createdAt: 1700000000000,
        completedAt: 1700000001000,
        localPath: '${fs.basePath}/orphan_1.cbz',
      );

      // Simulate an in-progress download
      final active = DownloadTask(
        id: 'active_1',
        title: 'Active Novel',
        sourceType: SourceType.novelSource,
        contentId: 'novel_active',
        format: DownloadFormat.epub,
        totalChapters: 10,
        downloadedChapters: 3,
        status: DownloadStatus.downloading,
        createdAt: 1700000000000,
        localPath: '${fs.basePath}/active_1.epub',
      );

      // Write product file and meta.json
      await fs.writeBytes(
        task.localPath!,
        Uint8List.fromList([0x50, 0x4B, 0x03, 0x04]),
      );
      await fs.writeString(
        fs.join(fs.basePath, '${task.id}.meta.json'),
        task.toJsonString(),
      );

      // Add to manager's task list, then clearAll(false)
      await storage.saveAll(<DownloadTask>[task, active]);
      await manager.init();
      expect(manager.completedTasks.length, 1);
      expect(manager.activeTasks.length, 1);

      // Clear all records (keep files)
      await manager.clearAll(deleteFiles: false);

      // All records cleared; completed tasks are rebuilt from disk meta.json
      // for the downloaded-content page, active tasks are fully removed.
      expect(manager.completedTasks.length, 1);
      expect(manager.completedTasks.first.id, 'orphan_1');
      expect(manager.activeTasks, isEmpty);
      // 下载列表页应过滤 completed：列表查询排除已完成记录。
      final listTasks = manager.tasks
          .where((t) => !t.archived && !t.isCompleted)
          .toList();
      expect(listTasks, isEmpty);
    });

    test('clearAll(true) deletes files and does not recover', () async {
      final task = DownloadTask(
        id: 'del_1',
        title: 'To Delete',
        sourceType: SourceType.novelSource,
        contentId: 'novel_del',
        format: DownloadFormat.epub,
        totalChapters: 3,
        downloadedChapters: 3,
        status: DownloadStatus.completed,
        createdAt: 1700000000000,
        completedAt: 1700000001000,
        localPath: '${fs.basePath}/del_1.epub',
      );

      await fs.writeBytes(
        task.localPath!,
        Uint8List.fromList([0x50, 0x4B, 0x03, 0x04]),
      );
      await fs.writeString(
        fs.join(fs.basePath, '${task.id}.meta.json'),
        task.toJsonString(),
      );

      await storage.saveAll(<DownloadTask>[task]);
      await manager.init();
      expect(manager.completedTasks.length, 1);

      // Clear all records + delete files
      await manager.clearAll(deleteFiles: true);

      // Both pages should be empty
      expect(manager.completedTasks, isEmpty);
      expect(manager.activeTasks, isEmpty);

      // Files should be deleted
      expect(await fs.exists(task.localPath!), false);
      expect(
        await fs.exists(fs.join(fs.basePath, '${task.id}.meta.json')),
        false,
      );
    });

    test('isItemDownloaded checks completed tasks', () async {
      final task = DownloadTask(
        id: 'check_1',
        title: 'Downloaded',
        sourceType: SourceType.mangaSource,
        contentId: 'content_123',
        format: DownloadFormat.cbz,
        totalChapters: 2,
        downloadedChapters: 2,
        status: DownloadStatus.completed,
        createdAt: 0,
        localPath: '${fs.basePath}/check_1.cbz',
      );

      await fs.writeBytes(task.localPath!, Uint8List(4));
      await fs.writeString(
        fs.join(fs.basePath, '${task.id}.meta.json'),
        task.toJsonString(),
      );
      await storage.saveAll(<DownloadTask>[task]);
      await manager.init();

      expect(manager.isItemDownloaded('content_123'), true);
      expect(manager.isItemDownloaded('not_downloaded'), false);
    });

    test('activeTasks filters out completed', () async {
      const active = DownloadTask(
        id: 'a1',
        title: 'Active',
        sourceType: SourceType.mangaSource,
        contentId: 'c_a',
        format: DownloadFormat.cbz,
        totalChapters: 5,
        downloadedChapters: 2,
        status: DownloadStatus.downloading,
        createdAt: 0,
      );
      final completed = DownloadTask(
        id: 'c1',
        title: 'Completed',
        sourceType: SourceType.mangaSource,
        contentId: 'c_c',
        format: DownloadFormat.cbz,
        totalChapters: 5,
        downloadedChapters: 5,
        status: DownloadStatus.completed,
        createdAt: 0,
        localPath: '${fs.basePath}/c1.cbz',
      );

      await fs.writeBytes(completed.localPath!, Uint8List(4));
      await fs.writeString(
        fs.join(fs.basePath, '${completed.id}.meta.json'),
        completed.toJsonString(),
      );
      await storage.saveAll(<DownloadTask>[active, completed]);
      await manager.init();

      expect(manager.activeTasks.length, 1);
      expect(manager.activeTasks.first.id, 'a1');
      expect(manager.completedTasks.length, 1);
      expect(manager.completedTasks.first.id, 'c1');
    });

    test('cancel with deleteFiles=false keeps meta.json', () async {
      const task = DownloadTask(
        id: 'cancel_1',
        title: 'Cancel Me',
        sourceType: SourceType.mangaSource,
        contentId: 'cancel_content',
        format: DownloadFormat.cbz,
        totalChapters: 3,
        downloadedChapters: 1,
        status: DownloadStatus.downloading,
        createdAt: 0,
      );

      await fs.writeString(
        fs.join(fs.basePath, '${task.id}.meta.json'),
        task.toJsonString(),
      );
      await storage.saveAll(<DownloadTask>[task]);
      await manager.init();

      await manager.cancel('cancel_1', deleteFiles: false);

      // meta.json should still exist
      expect(
        await fs.exists(fs.join(fs.basePath, '${task.id}.meta.json')),
        true,
      );
    });

    test('cancel with deleteFiles=true removes meta.json and files', () async {
      final task = DownloadTask(
        id: 'cancel_del',
        title: 'Cancel Delete',
        sourceType: SourceType.mangaSource,
        contentId: 'cancel_del_content',
        format: DownloadFormat.cbz,
        totalChapters: 3,
        downloadedChapters: 3,
        status: DownloadStatus.completed,
        createdAt: 0,
        localPath: '${fs.basePath}/cancel_del.cbz',
      );

      await fs.writeBytes(task.localPath!, Uint8List(4));
      await fs.writeString(
        fs.join(fs.basePath, '${task.id}.meta.json'),
        task.toJsonString(),
      );
      await storage.saveAll(<DownloadTask>[task]);
      await manager.init();

      await manager.cancel('cancel_del', deleteFiles: true);

      expect(await fs.exists(task.localPath!), false);
      expect(
        await fs.exists(fs.join(fs.basePath, '${task.id}.meta.json')),
        false,
      );
    });
  });

  group('DownloadManager merge-by-content (no duplicate downloads)', () {
    late InMemoryFileSystem fs;
    late InMemoryBackend backend;
    late DownloadStorage storage;
    late DownloadManager manager;

    setUp(() async {
      fs = InMemoryFileSystem();
      backend = InMemoryBackend();
      storage = DownloadStorage(backend: backend);
      manager = DownloadManager(
        storage: storage,
        fs: fs,
        service: MediaApiService(ResolverRegistry.instance),
        sourceRepo: SourceRepository(<PluginConfig>[]),
      );
      await manager.init();
    });

    DownloadTask _makeTask({
      required String id,
      required String contentId,
      required String sourceId,
      required String title,
      required int createdAt,
      List<String> chapters = const <String>['Ch1', 'Ch2'],
      String? coverKey,
    }) =>
        DownloadTask(
          id: id,
          title: title,
          sourceType: SourceType.mangaSource,
          sourceId: sourceId,
          contentId: contentId,
          format: DownloadFormat.cbz,
          coverUrl: 'https://example.com/$id.jpg',
          chapterTitles: chapters,
          totalChapters: chapters.length,
          downloadedChapters: chapters.length,
          status: DownloadStatus.completed,
          createdAt: createdAt,
          completedAt: createdAt + 1000,
          localPath: '${fs.basePath}/$id.cbz',
          coverKey: coverKey,
        );

    test('groupKeyFor distinguishes different sources vs same content', () {
      final a = _makeTask(
        id: 'a',
        contentId: 'comic1',
        sourceId: 'srcA',
        title: 'A',
        createdAt: 1,
      );
      final b = _makeTask(
        id: 'b',
        contentId: 'comic1',
        sourceId: 'srcB',
        title: 'B',
        createdAt: 1,
      );
      expect(DownloadManager.groupKeyFor(a),
          isNot(DownloadManager.groupKeyFor(b)));
    });

    test('groupedDownloaded merges same-content batches into one card', () {
      manager.injectTask(_makeTask(
        id: 't1',
        contentId: 'comic1',
        sourceId: 'src1',
        title: 'Comic One',
        createdAt: 100,
        chapters: const <String>['Ch1', 'Ch2'],
      ));
      manager.injectTask(_makeTask(
        id: 't2',
        contentId: 'comic1',
        sourceId: 'src1',
        title: 'Comic One',
        createdAt: 200,
        chapters: const <String>['Ch3', 'Ch4', 'Ch5'],
      ));
      manager.injectTask(_makeTask(
        id: 't3',
        contentId: 'comic2',
        sourceId: 'src1',
        title: 'Comic Two',
        createdAt: 150,
        chapters: const <String>['Ch1'],
      ));

      final groups = manager.groupedDownloaded();
      // 两部作品各一张卡片：comic1（含 2 批次）与 comic2（1 批次）。
      expect(groups.length, 2);

      final merged = groups.firstWhere((g) => g.contentId == 'comic1');
      expect(merged.batches.length, 2);
      // 总章节 = 2 + 3 = 5；章节标题并集 = 5（无重复）。
      expect(merged.totalChapters, 5);
      expect(merged.chapterTitles.length, 5);
      // 标题取最新批次（createdAt 较大者）。
      expect(merged.title, 'Comic One');
    });

    test('tasksForContent returns only the matching content batches', () {
      manager.injectTask(_makeTask(
        id: 't1',
        contentId: 'comic1',
        sourceId: 'src1',
        title: 'A',
        createdAt: 100,
      ));
      manager.injectTask(_makeTask(
        id: 't2',
        contentId: 'comic2',
        sourceId: 'src1',
        title: 'B',
        createdAt: 200,
      ));

      final batches =
          manager.tasksForContent('comic1', 'src1', includeArchived: false);
      expect(batches.length, 1);
      expect(batches.first.id, 't1');
    });

    test('cancelContent removes all batches of a content at once', () async {
      manager.injectTask(_makeTask(
        id: 't1',
        contentId: 'comic1',
        sourceId: 'src1',
        title: 'A',
        createdAt: 100,
      ));
      manager.injectTask(_makeTask(
        id: 't2',
        contentId: 'comic1',
        sourceId: 'src1',
        title: 'A',
        createdAt: 200,
      ));

      await manager.cancelContent('comic1', deleteFiles: false);
      expect(
        manager.groupedDownloaded().any((g) => g.contentId == 'comic1'),
        false,
      );
    });

    test('coverKey JSON round-trip preserves the merge key', () {
      final task = _makeTask(
        id: 't1',
        contentId: 'comic1',
        sourceId: 'src1',
        title: 'A',
        createdAt: 1,
        coverKey: 'src1|comic1',
      );
      final restored = DownloadTask.fromJsonString(task.toJsonString());
      expect(restored.coverKey, 'src1|comic1');
    });
  });

  group('DownloadTask chapterFilePaths (per-work folder layout)', () {
    test('chapterFilePaths round-trips through JSON', () {
      const task = DownloadTask(
        id: 't',
        title: 'T',
        sourceType: SourceType.mangaSource,
        contentId: 'c',
        format: DownloadFormat.cbz,
        createdAt: 0,
        localPath: '/work/t',
        chapterFilePaths: <String>['/work/t/0001.cbz', '/work/t/0002.cbz'],
      );
      final restored = DownloadTask.fromJsonString(task.toJsonString());
      expect(restored.chapterFilePaths, task.chapterFilePaths);
    });

    test('missing chapterFilePaths parses to null (backward compatible)',
        () {
      final legacyJson = <String, dynamic>{
        'id': 't',
        'title': 'T',
        'sourceType': 'mangaSource',
        'contentId': 'c',
        'format': 'cbz',
        'createdAt': 0,
        'localPath': '/work/t',
      };
      final restored = DownloadTask.fromJson(legacyJson);
      expect(restored.chapterFilePaths, isNull);
    });

    test('copyWith updates chapterFilePaths and localPath', () {
      const base = DownloadTask(
        id: 't',
        title: 'T',
        sourceType: SourceType.mangaSource,
        contentId: 'c',
        format: DownloadFormat.cbz,
        createdAt: 0,
      );
      final updated = base.copyWith(
        localPath: '/work/t',
        chapterFilePaths: <String>['/work/t/0001.cbz'],
      );
      expect(updated.localPath, '/work/t');
      expect(updated.chapterFilePaths, <String>['/work/t/0001.cbz']);
      // base 不被修改（不可变）。
      expect(base.localPath, isNull);
      expect(base.chapterFilePaths, isNull);
    });
  });

  group('DownloadManager work-dir recovery derivation', () {
    late InMemoryFileSystem fs;
    late InMemoryBackend backend;
    late DownloadManager manager;

    setUp(() async {
      fs = InMemoryFileSystem();
      backend = InMemoryBackend();
      final storage = DownloadStorage(backend: backend);
      manager = DownloadManager(
        storage: storage,
        fs: fs,
        service: MediaApiService(ResolverRegistry.instance),
        sourceRepo: SourceRepository(<PluginConfig>[]),
      );
      await manager.init();
    });

    /// 写一个每话一 cbz 的"作品目录"产物（新布局），用旧 meta.json（无 chapterFilePaths）
    /// 验证 [recoverOrphanedDownloads] 能从 localPath 推导出逐话路径。
    ///
    /// 注意：只落盘 meta.json + 产物，**不**写入 storage，使其走孤立恢复分支
    /// （storage 正常加载不会推导，仅恢复分支会推导）。
    test('recover derives chapterFilePaths for per-chapter cbz work dir',
        () async {
      final workDir = '${fs.basePath}/src1_comic1';
      final task = DownloadTask(
        id: 'rec_1',
        title: 'Recovered Comic',
        sourceType: SourceType.mangaSource,
        sourceId: 'src1',
        contentId: 'comic1',
        format: DownloadFormat.cbz,
        totalChapters: 2,
        downloadedChapters: 2,
        status: DownloadStatus.completed,
        createdAt: 1700000000000,
        localPath: workDir,
      );

      // 写作品目录 + 两话 cbz（旧 meta 无 chapterFilePaths）。
      await fs.createDir(workDir);
      await fs.writeBytes(
        fs.join(workDir, '0001.cbz'),
        Uint8List.fromList([0x50, 0x4B, 0x03, 0x04]),
      );
      await fs.writeBytes(
        fs.join(workDir, '0002.cbz'),
        Uint8List.fromList([0x50, 0x4B, 0x03, 0x04]),
      );
      await fs.writeString(
        fs.join(fs.basePath, '${task.id}.meta.json'),
        task.toJsonString(),
      );

      // 仅落盘，不入 storage → init() 走孤儿恢复，从 localPath 推导逐话路径。
      await manager.init();

      final recovered = manager.completedTasks
          .where((t) => t.id == 'rec_1')
          .firstOrNull;
      expect(recovered, isNotNull);
      // 推导出的逐话路径：两话 cbz。
      final chapterFiles = recovered!.chapterFilePaths;
      expect(chapterFiles, isNotNull);
      expect(chapterFiles!.length, 2);
      expect(chapterFiles.every((p) => p.endsWith('.cbz')), true);
    });
  });

  group('safBaseName with Chinese path segments', () {
    test('Chinese segment does not throw Illegal percent encoding', () {
      // 中文段直接调 Uri.decodeComponent 会抛 "Illegal percent encoding in URI"
      // （下载后打开小说/漫画报错的根源）；safBaseName 必须安全返回。
      expect(safBaseName('content://tree/document/小说/诡秘之主.epub'),
          '诡秘之主.epub');
      expect(safBaseName('D:/Downloads/小说/诡秘之主/诡秘之主.epub'),
          '诡秘之主.epub');
    });

    test('percent-encoded segment is decoded', () {
      // `primary%3Afoo%2Fbar.txt` 解码为 `primary:foo/bar.txt`，按 :/ 拆后取末段。
      expect(safBaseName('content://tree/document/primary%3Afoo%2Fbar.txt'),
          'bar.txt');
    });

    test('bare percent in segment falls back to raw (no throw)', () {
      expect(safBaseName('content://tree/document/100%好评.epub'),
          '100%好评.epub');
    });
  });

  group('DownloadManager per-work folder naming (type/title)', () {
    late InMemoryFileSystem fs;
    late InMemoryBackend backend;
    late DownloadManager manager;

    setUp(() async {
      fs = InMemoryFileSystem();
      backend = InMemoryBackend();
      final storage = DownloadStorage(backend: backend);
      manager = DownloadManager(
        storage: storage,
        fs: fs,
        service: MediaApiService(ResolverRegistry.instance),
        sourceRepo: SourceRepository(<PluginConfig>[]),
      );
      await manager.init();
    });

    test('addTask localPath uses 类型/作品名 layout', () async {
      const item = MediaItem(
        id: 'content_abc',
        title: '我的漫画作品',
        sourceId: 'goda',
        sourceType: SourceType.mangaSource,
      );
      final chapters = <Episode>[
        const Episode(id: 'c1', title: '第1话', url: 'u1'),
        const Episode(id: 'c2', title: '第2话', url: 'u2'),
      ];
      final task = await manager.addTask(item: item, chapters: chapters);
      expect(task, isNotNull);
      // 目录层级：<根>/漫画/我的漫画作品（类型中文 + 作品名）。
      expect(task.localPath, contains('漫画'));
      expect(task.localPath, contains('我的漫画作品'));
      // 同作品再下一批 → 仍落到同一 localPath（Mihon 风格：每部作品一个目录）。
      final second = await manager.addTask(item: item, chapters: <Episode>[
        const Episode(id: 'c3', title: '第3话', url: 'u3'),
      ]);
      expect(second.localPath, task.localPath);
    });

    test('addTask title with illegal chars is sanitized for folder name',
        () async {
      const item = MediaItem(
        id: 'content_x',
        title: '作品: 第一季/番外',
        sourceId: 'src',
        sourceType: SourceType.novelSource,
      );
      final chapters = <Episode>[
        const Episode(id: 'c1', title: 'Ch1', url: 'u1'),
      ];
      final task = await manager.addTask(item: item, chapters: chapters);
      expect(task, isNotNull);
      // 小说 → 类型目录"小说"；标题中的 : 与 / 被清洗，作品名段不含路径分隔符。
      expect(task.localPath, contains('小说'));
      final String workName = task.localPath!.split('/').last;
      expect(workName.contains('/'), false);
      // 清洗后不含原始非法字符 : 与 /。
      expect(workName.contains(':'), false);
      expect(workName.contains('/'), false);
    });
  });
}

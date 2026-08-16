import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:nexhub/core/comic/models/reader_preferences.dart';
import 'package:nexhub/core/download/download_file_system.dart';
import 'package:nexhub/core/download/download_manager.dart';
import 'package:nexhub/core/download/download_storage.dart';
import 'package:nexhub/core/download/download_task.dart';
import 'package:nexhub/core/favorites/favorites_manager.dart';
import 'package:nexhub/core/models/episode.dart';
import 'package:nexhub/core/models/media_item.dart';
import 'package:nexhub/core/models/plugin_config.dart';
import 'package:nexhub/core/resolver/resolver_registry.dart';
import 'package:nexhub/core/scraper/media_api_service.dart';
import 'package:nexhub/core/services/source_repository.dart';
import 'package:nexhub/features/manga/presentation/comic_reader_screen.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Bug5 / Bug2 自动行为测试：
/// - 自动下载：进度越过 25% 后防抖触发 [_maybeAutoDownload]，使用最新页码；
/// - 自动翻页：间隔配置即时生效（定时器按新间隔重建）；
/// - 自动滚动：分块累积不抛错。
class _FakeMediaApiService extends MediaApiService {
  _FakeMediaApiService() : super(ResolverRegistry.instance);

  @override
  Future<List<String>> fetchImages(
    PluginConfig source, {
    required String comicId,
    required String chapterId,
    String? renderedHtml,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return <String>[
      for (var i = 0; i < 10; i++) 'https://example.com/p$i.png',
    ];
  }
}

class _RecordingDownloadManager extends DownloadManager {
  _RecordingDownloadManager()
      : super(
          storage: DownloadStorage(backend: InMemoryBackend()),
          fs: InMemoryFileSystem(),
          service: MediaApiService(ResolverRegistry.instance),
          sourceRepo: SourceRepository(<PluginConfig>[]),
        );

  final List<({MediaItem item, List<int>? indices})> added = <
      ({MediaItem item, List<int>? indices})>[];

  @override
  Future<DownloadTask> addTask({
    required MediaItem item,
    required List<Episode> chapters,
    List<int>? chapterIndices,
  }) async {
    added.add((item: item, indices: chapterIndices));
    return DownloadTask(
      id: 't-${added.length}',
      title: item.title,
      sourceType: SourceType.mangaSource,
      contentId: item.id,
      format: DownloadFormat.cbz,
      totalChapters: chapterIndices?.length ?? chapters.length,
      downloadedChapters: 0,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
  }
}

class _StaticDownloadManager extends DownloadManager {
  _StaticDownloadManager()
      : super(
          storage: DownloadStorage(backend: InMemoryBackend()),
          fs: InMemoryFileSystem(),
          service: MediaApiService(ResolverRegistry.instance),
          sourceRepo: SourceRepository(<PluginConfig>[]),
        );

  @override
  List<DownloadTask> get tasks => _tasks;

  final List<DownloadTask> _tasks = <DownloadTask>[];
}

Widget _wrapReader({
  required SourceRepository repo,
  required MediaApiService service,
  required FavoritesManager favorites,
  DownloadManager? downloadManager,
  List<Episode> chapters = const <Episode>[
    Episode(id: 'c1', title: '第1话', url: '/c1'),
    Episode(id: 'c2', title: '第2话', url: '/c2'),
    Episode(id: 'c3', title: '第3话', url: '/c3'),
  ],
}) {
  return Provider<MediaApiService>.value(
    value: service,
    child: ChangeNotifierProvider<SourceRepository>.value(
      value: repo,
      child: ChangeNotifierProvider<FavoritesManager>.value(
        value: favorites,
        child: ChangeNotifierProvider<DownloadManager>.value(
          value: downloadManager ?? _StaticDownloadManager(),
          child: MaterialApp(
            locale: const Locale('zh'),
            supportedLocales: const <Locale>[Locale('zh'), Locale('en')],
            localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: ComicReaderScreen(
              comicId: 'm1',
              title: '测试漫画',
              sourceId: 'src1',
              chapters: chapters,
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  setUp(() async {
    final Directory dir =
        await Directory.systemTemp.createTemp('comic_auto_hive');
    try {
      Hive.init(dir.path);
    } on Object {
      // Hive.init 二次调用可能抛错或静默，包一层避免影响。
    }
  });

  PluginConfig source() => PluginConfig.fromJson(<String, dynamic>{
        'id': 'src1', 'name': 'S', 'type': 'mangaSource', 'responseType': 'json',
        'site': {'domain': 'https://example.com', 'baseUrl': 'https://example.com'},
        'parser': {'type': 'builtin'},
        'routes': {'images': '/images?cid={cid}'},
        'selectors': {'images': '\$.images'},
      });

  /// 提取进度条页码文本：右竖进度条显示纯数字，底横进度条显示 "第 X / Y 页"。
  String pageIndicatorText(WidgetTester tester) {
    // 优先匹配底横进度条格式 "第 X / Y 页"
    final Iterable<Text> texts =
        tester.widgetList<Text>(find.byType(Text)).where((t) {
      final String d = t.data ?? '';
      return RegExp(r'第\s+\d+\s*/\s*\d+\s*页').hasMatch(d.trim());
    });
    if (texts.isNotEmpty) return texts.first.data!.trim();
    // 回退到右竖进度条纯数字
    final Iterable<Text> digits =
        tester.widgetList<Text>(find.byType(Text)).where((t) {
      final String d = t.data ?? '';
      return RegExp(r'^\d+$').hasMatch(d.trim()) && int.parse(d.trim()) > 0;
    });
    return digits.isNotEmpty ? digits.first.data!.trim() : '';
  }

  testWidgets('Bug5: 进度越过 25% 后触发自动下载且用最新页码', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'reader_prefs_m1': jsonPrefs({
        'readingMode': 'singleLTR',
        'autoDownloadChapters': true,
      }),
      // 进度恢复到第 3 页（10 页的 30% > 25%）：恢复后 _loadChapter 直接保存该页，
      // 若使用旧页码（恢复期过渡页 0）则 (0+1)/10=10% < 25% 永不触发。
      'comic_progress_m1':
          '{"chapterId":"c1","currentPage":3,"chapterIndex":0,"totalChapters":3}',
    });
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;

    final service = _FakeMediaApiService();
    final repo = SourceRepository(<PluginConfig>[source()]);
    final favorites = FavoritesManager();
    await favorites.init();
    final dm = _RecordingDownloadManager();

    await tester.pumpWidget(_wrapReader(
        repo: repo, service: service, favorites: favorites, downloadManager: dm));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 50));

    expect(dm.added, hasLength(1)); // 恢复页 3（30%）即触发。
    expect(dm.added.single.indices, isNotNull);
    expect(dm.added.single.indices, isNotEmpty);
    expect(dm.added.single.indices!.first, 1); // 后续章节从 index 1 起。
  });

  testWidgets('Bug5: 自动翻页越过 25% 后防抖触发自动下载且用最新页码',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'reader_prefs_m1': jsonPrefs({
        'readingMode': 'singleLTR',
        'autoDownloadChapters': true,
        'autoPageTurningInterval': 1,
        'doubleTapZoom': false,
      }),
      // 进度恢复到第 2 页（20% < 25%），不会自动触发下载。
      'comic_progress_m1':
          '{"chapterId":"c1","currentPage":1,"chapterIndex":0,"totalChapters":3}',
    });
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;

    final service = _FakeMediaApiService();
    final repo = SourceRepository(<PluginConfig>[source()]);
    final favorites = FavoritesManager();
    await favorites.init();
    final dm = _RecordingDownloadManager();

    await tester.pumpWidget(_wrapReader(
        repo: repo, service: service, favorites: favorites, downloadManager: dm));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 50));

    // 第 2 页（20% < 25%），尚未触发。
    expect(dm.added, isEmpty);

    // 自动翻页每 1s 一页（逐帧推进让翻页动画完成）；进度越过 25% 后，翻页暂停
    // 产生的 1s 防抖到期即触发自动下载（用最新页码判定）。
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 120));
    }
    expect(dm.added, hasLength(1));
    expect(dm.added.single.indices, isNotNull);
    expect(dm.added.single.indices!.first, 1); // 后续章节从 index 1 起。
  });

  testWidgets('Bug5: 已完成的下载批次不阻塞新的自动下载', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'reader_prefs_m1': jsonPrefs({
        'readingMode': 'singleLTR',
        'autoDownloadChapters': true,
      }),
      'comic_progress_m1':
          '{"chapterId":"c1","currentPage":3,"chapterIndex":0,"totalChapters":3}',
    });
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;

    final service = _FakeMediaApiService();
    final repo = SourceRepository(<PluginConfig>[source()]);
    final favorites = FavoritesManager();
    await favorites.init();
    final dm = _RecordingDownloadManager();
    // 预置一条已完成批次：isActive=false，不应阻塞后续自动下载。
    dm.injectTask(const DownloadTask(
      id: 'done',
      title: '测试漫画',
      sourceType: SourceType.mangaSource,
      contentId: 'm1',
      format: DownloadFormat.cbz,
      totalChapters: 2,
      downloadedChapters: 2,
      status: DownloadStatus.completed,
      createdAt: 1,
      completedAt: 2,
    ));

    await tester.pumpWidget(_wrapReader(
        repo: repo, service: service, favorites: favorites, downloadManager: dm));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 1200));

    expect(dm.added, hasLength(1)); // 已完成批次不阻塞，正常触发。
  });

  testWidgets('Bug5: 活跃下载批次仍会阻塞（避免重复入队）', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'reader_prefs_m1': jsonPrefs({
        'readingMode': 'singleLTR',
        'autoDownloadChapters': true,
      }),
      'comic_progress_m1':
          '{"chapterId":"c1","currentPage":3,"chapterIndex":0,"totalChapters":3}',
    });
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;

    final service = _FakeMediaApiService();
    final repo = SourceRepository(<PluginConfig>[source()]);
    final favorites = FavoritesManager();
    await favorites.init();
    final dm = _RecordingDownloadManager();
    dm.injectTask(const DownloadTask(
      id: 'active',
      title: '测试漫画',
      sourceType: SourceType.mangaSource,
      contentId: 'm1',
      format: DownloadFormat.cbz,
      totalChapters: 2,
      downloadedChapters: 1,
      status: DownloadStatus.downloading,
      createdAt: 1,
    ));

    await tester.pumpWidget(_wrapReader(
        repo: repo, service: service, favorites: favorites, downloadManager: dm));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 1200));

    expect(dm.added, isEmpty); // 活跃批次存在时跳过，避免重复入队。
  });

  testWidgets('Bug2: 自动翻页按间隔翻页，间隔变化后定时器以新间隔重建',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'reader_prefs_m1': jsonPrefs({
        'readingMode': 'singleLTR',
        'autoPageTurningInterval': 1,
        'showPageNumber': true,
        'progressBarOnRight': false,
      }),
    });
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;

    final service = _FakeMediaApiService();
    final repo = SourceRepository(<PluginConfig>[source()]);
    final favorites = FavoritesManager();
    await favorites.init();

    await tester.pumpWidget(_wrapReader(
        repo: repo, service: service, favorites: favorites));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 50));

    // 显示控制栏（进度条）。
    await tester.tapAt(const Offset(400, 600));
    await tester.pump(const Duration(milliseconds: 100));

    // 初始第 1 页。
    expect(pageIndicatorText(tester), contains('第 1'));

    // 1s 间隔翻页：第 1 次翻页后到第 2 页。
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 300));
    expect(pageIndicatorText(tester), contains('第 2'));
  });

  testWidgets('Bug2: 自动滚动分块累积不抛错', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'reader_prefs_m1': jsonPrefs({
        'readingMode': 'webtoon',
        'autoScroll': true,
        'readerScrollSpeed': 1.0,
      }),
    });
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;

    final service = _FakeMediaApiService();
    final repo = SourceRepository(<PluginConfig>[source()]);
    final favorites = FavoritesManager();
    await favorites.init();

    await tester.pumpWidget(_wrapReader(
        repo: repo, service: service, favorites: favorites));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 50));

    // 1s 内不应抛错：自动滚动 Ticker 启动后 _onAutoScrollTick 会累积像素，
    // 分块窗口 120ms 后调用 animateScroll（测试环境可能无 ScrollablePositionedList
    // 视图，animateScroll 会 catchError 静默忽略）。
    await tester.pump(const Duration(seconds: 2));
    // 没有崩溃即通过。
    expect(find.byType(MangaPageImage), findsAtLeastNWidgets(0));
  });
}

/// 便捷构造 reader_prefs JSON。
String jsonPrefs(Map<String, Object?> map) {
  final buf = StringBuffer('{');
  var first = true;
  map.forEach((k, v) {
    if (!first) buf.write(',');
    first = false;
    buf
      ..write('"')
      ..write(k)
      ..write('":');
    if (v is bool) {
      buf.write(v ? 'true' : 'false');
    } else if (v is int || v is double) {
      buf.write(v);
    } else {
      buf
        ..write('"')
        ..write(v)
        ..write('"');
    }
  });
  buf.write('}');
  return buf.toString();
}
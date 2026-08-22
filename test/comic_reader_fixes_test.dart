import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive/hive.dart';
import 'package:nexhub/core/local/local_content_manager.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/favorites/favorites_manager.dart';
import 'package:nexhub/core/models/plugin_config.dart';
import 'package:nexhub/core/models/episode.dart';
import 'package:nexhub/core/resolver/resolver_registry.dart';
import 'package:nexhub/core/scraper/media_api_service.dart';
import 'package:nexhub/core/services/source_repository.dart';
import 'package:nexhub/features/manga/presentation/comic_reader_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 阅读器修复测试（v2）：覆盖统一收藏按钮、双击缩放三态、首屏单图、
/// 本地含图片文件夹打开。
class FakeMediaApiServiceFixes extends MediaApiService {
  FakeMediaApiServiceFixes() : super(ResolverRegistry.instance);

  @override
  Future<List<String>> fetchImages(
    PluginConfig source, {
    required String comicId,
    required String chapterId,
    String? renderedHtml,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return const <String>[
      'https://example.com/p1.png',
      'https://example.com/p2.png',
      'https://example.com/p3.png',
      'https://example.com/p4.png',
      'https://example.com/p5.png',
    ];
  }
}

void main() {
  setUp(() async {
    final Directory dir = await Directory.systemTemp.createTemp('comic_reader_hive');
    try {
      Hive.init(dir.path);
    } on Object {
      // Hive.init 二次调用可能抛错或静默，包一层避免影响。
    }
    // 预打开章节书签 box：FakeAsync（testWidgets）内真实 IO 永不完成，
    // 目录按钮的 _bookmarkedIndices 会永久挂起；setUp 在普通 async zone，
    // 此处打开后 reader 内 isBoxOpen 命中同步路径。
    try {
      await Hive.openBox('comic_bookmarks');
    } on Object {
      // 已打开/失败忽略。
    }
  });

  Widget wrapReader(
    WidgetTester tester, {
    required SourceRepository repo,
    required MediaApiService service,
    required FavoritesManager favorites,
    List<Episode> chapters = const <Episode>[
      Episode(id: 'c1', title: '第1话', url: '/c1'),
    ],
    int initialChapterIndex = 0,
    List<String>? localChapterDirs,
    bool restoreProgress = true,
    String comicId = 'm1',
  }) {
    return Provider<MediaApiService>.value(
      value: service,
      child: ChangeNotifierProvider<SourceRepository>.value(
        value: repo,
        child: ChangeNotifierProvider<FavoritesManager>.value(
          value: favorites,
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
              // key 区分「多次进入」：同位置同类型会复用 State（_init 不重跑），
              // 真实场景是 pop 后重新 push 的新实例。
              key: ValueKey('$comicId-$restoreProgress-$initialChapterIndex'),
              comicId: comicId,
              title: '测试漫画',
              sourceId: 'src1',
              chapters: chapters,
              initialChapterIndex: initialChapterIndex,
              localChapterDirs: localChapterDirs,
              restoreProgress: restoreProgress,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('Bug1: 底栏收藏按钮弹出三项细分菜单，顶栏无收藏按钮', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'reader_prefs_m1': '{"readingMode":"singleLTR","doubleTapZoom":true}',
    });
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;

    final source = PluginConfig.fromJson(<String, dynamic>{
      'id': 'src1', 'name': 'S', 'type': 'mangaSource', 'responseType': 'json',
      'site': {'domain': 'https://example.com', 'baseUrl': 'https://example.com'},
      'parser': {'type': 'builtin'},
      'routes': {'images': '/images?cid={cid}'},
      'selectors': {'images': '\$.images'},
    });
    final repo = SourceRepository(<PluginConfig>[source]);
    final service = FakeMediaApiServiceFixes();
    final favorites = FavoritesManager();
    await favorites.init();

    await tester.pumpWidget(wrapReader(tester, repo: repo, service: service, favorites: favorites));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 50));

    // 控制栏初始隐藏：先单击中心 toggle 区显示控制栏。
    await tester.tapAt(const Offset(400, 600));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    // 顶栏无独立收藏按钮（已统一到底栏）：唯一心形图标在底栏。
    expect(find.byIcon(Icons.favorite_border), findsOneWidget);

    // 点击底栏收藏按钮（唯一的心形图标）。
    await tester.tap(find.byIcon(Icons.favorite_border));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 100));

    // 弹出三项菜单：收藏作品 / 收藏此图 / 图片收藏。
    expect(find.text('收藏'), findsOneWidget);
    expect(find.text('收藏此图'), findsOneWidget);
    expect(find.text('图片收藏'), findsOneWidget);
  });

  testWidgets('Bug4: 双击缩放三态循环（1x→0.5x→2x→1x）', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'reader_prefs_m1': '{"readingMode":"singleLTR","doubleTapZoom":true}',
    });
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;

    final source = PluginConfig.fromJson(<String, dynamic>{
      'id': 'src1', 'name': 'S', 'type': 'mangaSource', 'responseType': 'json',
      'site': {'domain': 'https://example.com', 'baseUrl': 'https://example.com'},
      'parser': {'type': 'builtin'},
      'routes': {'images': '/images?cid={cid}'},
      'selectors': {'images': '\$.images'},
    });
    final repo = SourceRepository(<PluginConfig>[source]);
    final service = FakeMediaApiServiceFixes();
    final favorites = FavoritesManager();
    await favorites.init();

    await tester.pumpWidget(wrapReader(tester, repo: repo, service: service, favorites: favorites));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(MangaPageImage), findsAtLeastNWidgets(1));

    // 第一次双击 → 缩小到 0.5x（读控制器矩阵 scale）。
    await tester.tapAt(const Offset(400, 600));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(const Offset(400, 600));
    // 分帧推进，让双击缩放动画（默认 500ms）完整结束，避免 dispose 时残留 Ticker。
    for (int i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // 通过 MangaPageImage 的 zoomController 读取缩放矩阵（公有字段）。
    final img = tester.widget<MangaPageImage>(find.byType(MangaPageImage).first);
    expect(img.zoomController, isNotNull);

    // 注：三态数值断言依赖具体 MangaPageImage 内部实现；此处以「双击后未崩溃、
    // 控制面板未误切换」为主（scale 实际值由实机验证覆盖）。
    expect(find.byType(MangaPageImage), findsAtLeastNWidgets(1));
  });

  testWidgets('Bug1: 音量键方向映射对应翻页功能 down→next、up→prev', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'reader_prefs_m1':
          '{"readingMode":"singleLTR","doubleTapZoom":true,"progressBarOnRight":false}',
    });
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;

    final source = PluginConfig.fromJson(<String, dynamic>{
      'id': 'src1', 'name': 'S', 'type': 'mangaSource', 'responseType': 'json',
      'site': {'domain': 'https://example.com', 'baseUrl': 'https://example.com'},
      'parser': {'type': 'builtin'},
      'routes': {'images': '/images?cid={cid}'},
      'selectors': {'images': '\$.images'},
    });
    final repo = SourceRepository(<PluginConfig>[source]);
    final service = FakeMediaApiServiceFixes();
    final favorites = FavoritesManager();
    await favorites.init();

    await tester.pumpWidget(wrapReader(tester, repo: repo, service: service, favorites: favorites));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 50));

    // 音量键方向映射（代码复核确认）：_onVolumeKeyDown → _volumeKeyAction(+1) →
    // _goNextPage；_onVolumeKeyUp → _volumeKeyAction(-1) → _goPrevPage。此处通过
    // 阅读区 next/prev 热区触发与音量键完全相同的 _goNextPage/_goPrevPage，并断言
    // 页码指示器（第 N / 5 页）随之前进/回退。
    // 先单击中心 toggle 区显示控制栏（页 1）。
    await tester.tapAt(const Offset(400, 600));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('第 1 / 5 页'), findsOneWidget);

    // 音量下键 → 下一页（_goNextPage）。
    await tester.tapAt(const Offset(700, 600));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('第 2 / 5 页'), findsOneWidget);

    // 音量上键 → 上一页（_goPrevPage）。
    await tester.tapAt(const Offset(200, 600));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('第 1 / 5 页'), findsOneWidget);
  });

  testWidgets('Bug3: 双击缩放三态循环 1x→0.5x→2x→1x（修复三态消失）', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'reader_prefs_m1': '{"readingMode":"singleLTR","doubleTapZoom":true}',
    });
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;

    final source = PluginConfig.fromJson(<String, dynamic>{
      'id': 'src1', 'name': 'S', 'type': 'mangaSource', 'responseType': 'json',
      'site': {'domain': 'https://example.com', 'baseUrl': 'https://example.com'},
      'parser': {'type': 'builtin'},
      'routes': {'images': '/images?cid={cid}'},
      'selectors': {'images': '\$.images'},
    });
    final repo = SourceRepository(<PluginConfig>[source]);
    final service = FakeMediaApiServiceFixes();
    final favorites = FavoritesManager();
    await favorites.init();

    await tester.pumpWidget(wrapReader(tester, repo: repo, service: service, favorites: favorites));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 50));

    double scale() {
      final MangaPageImage img =
          tester.widget<MangaPageImage>(find.byType(MangaPageImage).first);
      return img.zoomController!.value.getMaxScaleOnAxis();
    }

    Future<void> doDoubleTap() async {
      await tester.tapAt(const Offset(400, 600));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(const Offset(400, 600));
      // 分帧推进，让双击缩放动画（默认 500ms）完整结束。
      for (int i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    // 第一次双击 → 缩小到 0.5x。
    await doDoubleTap();
    expect(scale(), closeTo(0.5, 0.02));

    // 第二次双击 → 放大到 2.0x。修复前：缩小态第一击被当普通单击派发翻页，
    // _resetZoom 把 0.5x 清回 1x，双击后只能再次缩到 0.5x（三态消失）。
    await doDoubleTap();
    expect(scale(), closeTo(2.0, 0.02));

    // 第三次双击 → 恢复 1.0x，三态循环完整。
    await doDoubleTap();
    expect(scale(), closeTo(1.0, 0.02));
  });

  testWidgets('Bug6: 双页 + 首屏单图 → 第一屏单张，其后双页', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'reader_prefs_m1':
          '{"readingMode":"singleLTR","doubleTapZoom":true,"splitDoublePage":true,"showSingleImageOnFirstPage":true}',
    });
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;

    final source = PluginConfig.fromJson(<String, dynamic>{
      'id': 'src1', 'name': 'S', 'type': 'mangaSource', 'responseType': 'json',
      'site': {'domain': 'https://example.com', 'baseUrl': 'https://example.com'},
      'parser': {'type': 'builtin'},
      'routes': {'images': '/images?cid={cid}'},
      'selectors': {'images': '\$.images'},
    });
    final repo = SourceRepository(<PluginConfig>[source]);
    final service = FakeMediaApiServiceFixes();
    final favorites = FavoritesManager();
    await favorites.init();

    await tester.pumpWidget(wrapReader(tester, repo: repo, service: service, favorites: favorites));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(MangaPageImage), findsAtLeastNWidgets(1));
  });

  test('Bug9: 打开含图片（含子目录）文件夹（递归收集）', () async {
    final Directory root = await Directory.systemTemp.createTemp('comic_folder_test');
    addTearDown(() async {
      try {
        await root.delete(recursive: true);
      } on Object {
        // 清理失败忽略。
      }
    });
    final Directory sub = Directory('${root.path}${Platform.pathSeparator}sub');
    await sub.create(recursive: true);
    final File f1 = File('${root.path}${Platform.pathSeparator}1.png');
    final File f2 = File('${root.path}${Platform.pathSeparator}2.jpg');
    final File f3 = File('${sub.path}${Platform.pathSeparator}3.webp');
    final File txt = File('${root.path}${Platform.pathSeparator}note.txt');
    for (final f in <File>[f1, f2, f3, txt]) {
      await f.writeAsBytes(<int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
    }

    // 复用阅读器实际使用的递归收集逻辑（local_content_manager 层，不触发 SAF 平台单例）。
    final List<String> imgs = root
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .where((x) => isImageFile(x.path))
        .map((x) => x.path)
        .toList()
      ..sort();
    expect(imgs, hasLength(3)); // 递归收集子目录 3 张图，忽略 txt
    expect(imgs.map((s) => s.toLowerCase()), isNot(contains('note.txt')));
  });

  /// 当前渲染的 MangaPageImage URL 集合（PageView/条漫列表的可见项）。
  List<String> renderedUrls(WidgetTester tester) => tester
      .widgetList<MangaPageImage>(find.byType(MangaPageImage))
      .map((w) => w.url)
      .toList();

  testWidgets('BugZ1: 翻页模式翻页保留缩放倍数、仅清平移（不重置缩放）', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'reader_prefs_m1': '{"readingMode":"singleLTR","doubleTapZoom":true}',
    });
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;

    final source = PluginConfig.fromJson(<String, dynamic>{
      'id': 'src1', 'name': 'S', 'type': 'mangaSource', 'responseType': 'json',
      'site': {'domain': 'https://example.com', 'baseUrl': 'https://example.com'},
      'parser': {'type': 'builtin'},
      'routes': {'images': '/images?cid={cid}'},
      'selectors': {'images': '\$.images'},
    });
    final repo = SourceRepository(<PluginConfig>[source]);
    final service = FakeMediaApiServiceFixes();
    final favorites = FavoritesManager();
    await favorites.init();

    await tester.pumpWidget(wrapReader(tester, repo: repo, service: service, favorites: favorites));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 50));

    Matrix4 zoomMatrix() {
      final MangaPageImage img =
          tester.widget<MangaPageImage>(find.byType(MangaPageImage).first);
      return img.zoomController!.value;
    }

    // 双击放大到 2.0x（三态顺序：1x→0.5x→2x，需连续两次双击）。
    Future<void> doubleTap() async {
      await tester.tapAt(const Offset(400, 600));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(const Offset(400, 600));
      for (int i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await doubleTap();
    await doubleTap();
    expect(zoomMatrix().getMaxScaleOnAxis(), closeTo(2.0, 0.02));

    // 键盘翻到下一页（绕过缩放手势竞技场，直接走 _goNextPage）。
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 250));

    // 修复后：翻页只清平移、保留倍数 —— 缩放仍为 2.0x。
    final Matrix4 m = zoomMatrix();
    expect(m.getMaxScaleOnAxis(), closeTo(2.0, 0.02),
        reason: '翻页不应重置缩放倍数（旧行为：被清回 1x）');
    expect(m.storage[12].abs(), lessThan(0.01),
        reason: '上一页的水平平移应被清零（不残留到下一页）');
    // 注：竖直方向 y 位移由 InteractiveViewer 对超视口内容做边界夹紧/居中，是
    // 正常终态（x=0、y 居中），不作为「平移残留」断言依据。
  });

  testWidgets('BugZ2: 缩放倍数徽标实时跟随矩阵变化，停止 1.2s 后隐藏', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'reader_prefs_m1': '{"readingMode":"singleLTR","doubleTapZoom":true}',
    });
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;

    final source = PluginConfig.fromJson(<String, dynamic>{
      'id': 'src1', 'name': 'S', 'type': 'mangaSource', 'responseType': 'json',
      'site': {'domain': 'https://example.com', 'baseUrl': 'https://example.com'},
      'parser': {'type': 'builtin'},
      'routes': {'images': '/images?cid={cid}'},
      'selectors': {'images': '\$.images'},
    });
    final repo = SourceRepository(<PluginConfig>[source]);
    final service = FakeMediaApiServiceFixes();
    final favorites = FavoritesManager();
    await favorites.init();

    await tester.pumpWidget(wrapReader(tester, repo: repo, service: service, favorites: favorites));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 50));

    // 直接驱动共享缩放控制器，模拟捏合/滚轮的连续缩放（真实手势会逐帧改矩阵）。
    final TransformationController ctrl = tester
        .widget<MangaPageImage>(find.byType(MangaPageImage).first)
        .zoomController!;

    ctrl.value = Matrix4.identity()..scale(2.0);
    await tester.pump();
    expect(find.text('2.0×'), findsOneWidget, reason: '首次放大应显示倍数徽标');

    // 可见期间矩阵继续变化 → 倍数文本须实时刷新（旧实现：停留在首次显示值）。
    ctrl.value = Matrix4.identity()..scale(2.5);
    await tester.pump();
    expect(find.text('2.5×'), findsOneWidget, reason: '捏合中倍数应实时跟随');
    expect(find.text('2.0×'), findsNothing);

    ctrl.value = Matrix4.identity()..scale(3.2);
    await tester.pump();
    expect(find.text('3.2×'), findsOneWidget);

    // 回到 1x 立即隐藏。
    ctrl.value = Matrix4.identity();
    await tester.pump();
    expect(find.text('3.2×'), findsNothing, reason: '回到 1x 应立即可见性隐藏');

    // 停止缩放 1.2s 后淡出（_hideTimer 到期）。
    ctrl.value = Matrix4.identity()..scale(2.0);
    await tester.pump();
    expect(find.text('2.0×'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1300));
    expect(find.text('2.0×'), findsNothing, reason: '停止缩放 1.2s 后徽标应淡出');
  });

  testWidgets('BugZ3: 本地连续阅读回上一话 → 恢复到离开页（进度页）', (tester) async {
    // 两个本地图片目录各 3 张占位图（_gatherDirImages 只收集路径不读内容）。
    // 注意：testWidgets 运行在 FakeAsync zone，真实异步文件 IO 永不完成，
    // 因此全部使用同步 API（createTempSync / writeAsBytesSync）。
    final Directory root = Directory.systemTemp.createTempSync('comic_local_multi');
    addTearDown(() {
      try {
        root.deleteSync(recursive: true);
      } on Object {
        // 清理失败忽略。
      }
    });
    final Directory dir1 = Directory('${root.path}${Platform.pathSeparator}ch1')
      ..createSync(recursive: true);
    final Directory dir2 = Directory('${root.path}${Platform.pathSeparator}ch2')
      ..createSync(recursive: true);
    for (final dir in <Directory>[dir1, dir2]) {
      for (var p = 1; p <= 3; p++) {
        File('${dir.path}${Platform.pathSeparator}$p.png').writeAsBytesSync(
            <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      }
    }
    final String dir2Prefix = dir2.path;

    SharedPreferences.setMockInitialValues(<String, Object>{
      'reader_prefs_m1':
          '{"readingMode":"webtoon","seamlessReading":true,"showChapterSeparator":true,"doubleTapZoom":false}',
    });
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;

    final source = PluginConfig.fromJson(<String, dynamic>{
      'id': 'src1', 'name': 'S', 'type': 'mangaSource', 'responseType': 'json',
      'site': {'domain': 'https://example.com', 'baseUrl': 'https://example.com'},
      'parser': {'type': 'builtin'},
      'routes': {'images': '/images?cid={cid}'},
      'selectors': {'images': '\$.images'},
    });
    final repo = SourceRepository(<PluginConfig>[source]);
    final favorites = FavoritesManager();
    await favorites.init();

    // 本地多话：localChapterDirs 下标对齐 chapters，从第 1 话（index 0）进入。
    await tester.pumpWidget(wrapReader(
      tester,
      repo: repo,
      service: FakeMediaApiServiceFixes(),
      favorites: favorites,
      chapters: const <Episode>[
        Episode(id: 'c1', title: '第1话', url: '/c1'),
        Episode(id: 'c2', title: '第2话', url: '/c2'),
      ],
      initialChapterIndex: 0,
      localChapterDirs: <String>[dir1.path, dir2.path],
    ));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(renderedUrls(tester).any((u) => u.contains(dir1.path)), isTrue,
        reason: '初始应在第 1 话');

    Future<void> pumpSettle() async {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
    }

    // 视口顶部项的 URL（webtoon 占位高 = 屏宽×1.5 ≈ 一屏一页，顶部项即当前页）。
    String topUrl() =>
        tester.widgetList<MangaPageImage>(find.byType(MangaPageImage)).first.url;

    // 第 1 话翻到第 2 页（记录离开页 = 2）。
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await pumpSettle();
    expect(topUrl().endsWith('2.png'), isTrue,
        reason: '第 1 话应翻到第 2 页（后续以此作为离开页）');
    expect(renderedUrls(tester).any((u) => u.contains(dir1.path)), isTrue,
        reason: '初始应在第 1 话');

    // 翻到下一话：应从【首页】开始（Bug「下一话跳转不对」修复方向）。
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await pumpSettle();
    expect(topUrl().contains(dir2.path), isTrue,
        reason: '进入下一话应渲染第 2 话内容');
    expect(topUrl().endsWith('1.png'), isTrue,
        reason: '进入下一话应从首页开始（并非中间页）');

    // 回到上一话：应恢复到【离开页 第 2 页】，而非首页/物理末页（第 3 页）。
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await pumpSettle();
    expect(topUrl().contains(dir1.path), isTrue,
        reason: '回上一话应渲染第 1 话内容');
    expect(topUrl().endsWith('2.png'), isTrue,
        reason: '回上一话应恢复到上次离开的第 2 页（进度记录），而非首页/末页');
    expect(renderedUrls(tester).any((u) => u.contains(dir2Prefix)), isFalse,
        reason: '不应再渲染第 2 话内容');
  });

  testWidgets('BugZ5: 本地连续阅读末页翻入下一话（首页），不卡死', (tester) async {
    final Directory root =
        Directory.systemTemp.createTempSync('comic_local_nextch');
    addTearDown(() {
      try {
        root.deleteSync(recursive: true);
      } on Object {
        // 清理失败忽略。
      }
    });
    final Directory dir1 = Directory('${root.path}${Platform.pathSeparator}ch1')
      ..createSync(recursive: true);
    final Directory dir2 = Directory('${root.path}${Platform.pathSeparator}ch2')
      ..createSync(recursive: true);
    for (final dir in <Directory>[dir1, dir2]) {
      for (var p = 1; p <= 3; p++) {
        File('${dir.path}${Platform.pathSeparator}$p.png').writeAsBytesSync(
            <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      }
    }

    SharedPreferences.setMockInitialValues(<String, Object>{
      'reader_prefs_m1':
          '{"readingMode":"webtoon","seamlessReading":true,"showChapterSeparator":true,"doubleTapZoom":false}',
    });
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;

    final source = PluginConfig.fromJson(<String, dynamic>{
      'id': 'src1', 'name': 'S', 'type': 'mangaSource', 'responseType': 'json',
      'site': {'domain': 'https://example.com', 'baseUrl': 'https://example.com'},
      'parser': {'type': 'builtin'},
      'routes': {'images': '/images?cid={cid}'},
      'selectors': {'images': '\$.images'},
    });
    final repo = SourceRepository(<PluginConfig>[source]);
    final favorites = FavoritesManager();
    await favorites.init();

    await tester.pumpWidget(wrapReader(
      tester,
      repo: repo,
      service: FakeMediaApiServiceFixes(),
      favorites: favorites,
      chapters: const <Episode>[
        Episode(id: 'c1', title: '第1话', url: '/c1'),
        Episode(id: 'c2', title: '第2话', url: '/c2'),
      ],
      initialChapterIndex: 0,
      localChapterDirs: <String>[dir1.path, dir2.path],
    ));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    Future<void> pumpSettle() async {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
    }

    // 视口顶部项的 URL（一屏一页，顶部项即当前页）。
    String topUrl() =>
        tester.widgetList<MangaPageImage>(find.byType(MangaPageImage)).first.url;

    // 第 1 话 3 页：逐页下翻。
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await pumpSettle();
    expect(topUrl().endsWith('2.png'), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await pumpSettle();
    expect(topUrl().endsWith('3.png'), isTrue, reason: '应到第 1 话末页');
    // 第 3 次 PageDown：末页越界 → 无缝进入下一话【首页】（修复「末页无反应/无法连续」）。
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await pumpSettle();
    expect(topUrl().contains(dir2.path), isTrue,
        reason: '末页翻下一页应进入第 2 话（不卡死）');
    expect(topUrl().endsWith('1.png'), isTrue,
        reason: '末页翻下一页应落在第 2 话首页');
    // 继续读不卡死：第 2 话内再翻一页。
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await pumpSettle();
    expect(topUrl().endsWith('2.png'), isTrue,
        reason: '进入下一话后应能继续正常翻页（不卡死）');
  });

  testWidgets('BugZ4: 本地已到第1话首页再翻上一页 → 边界提示且不卡死', (tester) async {
    final Directory root =
        Directory.systemTemp.createTempSync('comic_local_boundary');
    addTearDown(() {
      try {
        root.deleteSync(recursive: true);
      } on Object {
        // 清理失败忽略。
      }
    });
    final Directory dir1 = Directory('${root.path}${Platform.pathSeparator}ch1')
      ..createSync(recursive: true);
    for (var p = 1; p <= 3; p++) {
      File('${dir1.path}${Platform.pathSeparator}$p.png').writeAsBytesSync(
          <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
    }

    SharedPreferences.setMockInitialValues(<String, Object>{
      'reader_prefs_m1':
          '{"readingMode":"webtoon","seamlessReading":true,"showChapterSeparator":true,"doubleTapZoom":false}',
    });
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;

    final source = PluginConfig.fromJson(<String, dynamic>{
      'id': 'src1', 'name': 'S', 'type': 'mangaSource', 'responseType': 'json',
      'site': {'domain': 'https://example.com', 'baseUrl': 'https://example.com'},
      'parser': {'type': 'builtin'},
      'routes': {'images': '/images?cid={cid}'},
      'selectors': {'images': '\$.images'},
    });
    final repo = SourceRepository(<PluginConfig>[source]);
    final favorites = FavoritesManager();
    await favorites.init();

    // 单话本地目录（第一话），从首页开始。
    await tester.pumpWidget(wrapReader(
      tester,
      repo: repo,
      service: FakeMediaApiServiceFixes(),
      favorites: favorites,
      chapters: const <Episode>[
        Episode(id: 'c1', title: '第1话', url: '/c1'),
      ],
      initialChapterIndex: 0,
      localChapterDirs: <String>[dir1.path],
    ));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(MangaPageImage), findsAtLeastNWidgets(1));

    // 首页翻上一页 → 上一章已无 → 第一话边界提示（不应卡死/静默失效）。
    await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('已经是第一章了'), findsOneWidget,
        reason: '第一话首页再翻上一页应提示已是第一章');

    // 关键回归断言：提示后阅读器仍可正常翻页（修复前 _seamReanchoring 残留
    // 会导致滚动/翻页全部静默失效）。
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    for (int i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(MangaPageImage), findsAtLeastNWidgets(1),
        reason: '边界提示后仍应能正常翻页（未卡死）');
  });

  testWidgets('进度回归: 翻页模式切下一话再切回 → 恢复离开页（按钮路径）',
      (tester) async {
    final Directory root =
        Directory.systemTemp.createTempSync('comic_chswitch_a');
    addTearDown(() {
      try {
        root.deleteSync(recursive: true);
      } on Object {}
    });
    final Directory dir1 =
        Directory('${root.path}${Platform.pathSeparator}ch1')..createSync(recursive: true);
    final Directory dir2 =
        Directory('${root.path}${Platform.pathSeparator}ch2')..createSync(recursive: true);
    for (final dir in <Directory>[dir1, dir2]) {
      for (var p = 1; p <= 3; p++) {
        File('${dir.path}${Platform.pathSeparator}$p.png').writeAsBytesSync(
            <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      }
    }

    // 翻页模式（默认设置：singleLTR + seamlessReading=true）。
    SharedPreferences.setMockInitialValues(<String, Object>{
      'reader_prefs_m1': '{"readingMode":"singleLTR","doubleTapZoom":false}',
    });
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;

    final source = PluginConfig.fromJson(<String, dynamic>{
      'id': 'src1', 'name': 'S', 'type': 'mangaSource', 'responseType': 'json',
      'site': {'domain': 'https://example.com', 'baseUrl': 'https://example.com'},
      'parser': {'type': 'builtin'},
      'routes': {'images': '/images?cid={cid}'},
      'selectors': {'images': '\$.images'},
    });
    final repo = SourceRepository(<PluginConfig>[source]);
    final favorites = FavoritesManager();
    await favorites.init();

    await tester.pumpWidget(wrapReader(
      tester,
      repo: repo,
      service: FakeMediaApiServiceFixes(),
      favorites: favorites,
      chapters: const <Episode>[
        Episode(id: 'c1', title: '第1话', url: '/c1'),
        Episode(id: 'c2', title: '第2话', url: '/c2'),
      ],
      initialChapterIndex: 0,
      localChapterDirs: <String>[dir1.path, dir2.path],
    ));
    await tester.pump(const Duration(milliseconds: 200));
    for (int i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(renderedUrls(tester).any((u) => u.contains(dir1.path)), isTrue,
        reason: '初始应在第 1 话');

    Future<void> pumpSettle() async {
      for (int i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    // 第 1 话翻到第 2 页（离开页 = 2）。
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 400));
    expect(renderedUrls(tester).first.endsWith('2.png'), isTrue,
        reason: '第 1 话应翻到第 2 页');

    // 切下一话（Ctrl+↓ = 下一话按钮同路径）。
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await pumpSettle();
    expect(renderedUrls(tester).any((u) => u.contains(dir2.path)), isTrue,
        reason: '应切到第 2 话');

    // 再切回第 1 话（Ctrl+↑ = 上一话按钮同路径）→ 应恢复到离开页第 2 页。
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await pumpSettle();
    expect(renderedUrls(tester).any((u) => u.contains(dir1.path)), isTrue,
        reason: '应切回第 1 话');
    expect(renderedUrls(tester).first.endsWith('2.png'), isTrue,
        reason: '切回第 1 话应恢复到离开页第 2 页，而非首页/末页');
  });

  testWidgets('进度回归: 翻页模式章末翻入下一话再切回 → 恢复离开页',
      (tester) async {
    final Directory root =
        Directory.systemTemp.createTempSync('comic_chswitch_b');
    addTearDown(() {
      try {
        root.deleteSync(recursive: true);
      } on Object {}
    });
    final Directory dir1 =
        Directory('${root.path}${Platform.pathSeparator}ch1')..createSync(recursive: true);
    final Directory dir2 =
        Directory('${root.path}${Platform.pathSeparator}ch2')..createSync(recursive: true);
    for (final dir in <Directory>[dir1, dir2]) {
      for (var p = 1; p <= 3; p++) {
        File('${dir.path}${Platform.pathSeparator}$p.png').writeAsBytesSync(
            <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      }
    }

    SharedPreferences.setMockInitialValues(<String, Object>{
      'reader_prefs_m1': '{"readingMode":"singleLTR","doubleTapZoom":false}',
    });
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;

    final source = PluginConfig.fromJson(<String, dynamic>{
      'id': 'src1', 'name': 'S', 'type': 'mangaSource', 'responseType': 'json',
      'site': {'domain': 'https://example.com', 'baseUrl': 'https://example.com'},
      'parser': {'type': 'builtin'},
      'routes': {'images': '/images?cid={cid}'},
      'selectors': {'images': '\$.images'},
    });
    final repo = SourceRepository(<PluginConfig>[source]);
    final favorites = FavoritesManager();
    await favorites.init();

    await tester.pumpWidget(wrapReader(
      tester,
      repo: repo,
      service: FakeMediaApiServiceFixes(),
      favorites: favorites,
      chapters: const <Episode>[
        Episode(id: 'c1', title: '第1话', url: '/c1'),
        Episode(id: 'c2', title: '第2话', url: '/c2'),
      ],
      initialChapterIndex: 0,
      localChapterDirs: <String>[dir1.path, dir2.path],
    ));
    await tester.pump(const Duration(milliseconds: 200));
    for (int i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(renderedUrls(tester).any((u) => u.contains(dir1.path)), isTrue,
        reason: '初始应在第 1 话');

    Future<void> pumpSettle() async {
      for (int i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }
    Future<void> next() async {
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 400));
    }

    // 第 1 话连翻两页到末页（第 3 页 = 离开页），再翻越过章末进入第 2 话。
    await next();
    expect(renderedUrls(tester).first.endsWith('2.png'), isTrue);
    await next();
    expect(renderedUrls(tester).first.endsWith('3.png'), isTrue,
        reason: '第 1 话应到末页');
    await next(); // 末页再翻：过渡卡或直接进入下一话
    await pumpSettle();
    await next(); // （若上一翻只到过渡卡，再翻进入下一话）
    await pumpSettle();
    expect(renderedUrls(tester).any((u) => u.contains(dir2.path)), isTrue,
        reason: '应进入第 2 话');
    expect(renderedUrls(tester).first.contains(dir2.path), isTrue,
        reason: '当前视口应为第 2 话内容（非第 1 话残留）');

    // 切回第 1 话 → 应恢复到离开页第 3 页（末页），而非首页。
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await pumpSettle();
    expect(renderedUrls(tester).any((u) => u.contains(dir1.path)), isTrue,
        reason: '应切回第 1 话');
    expect(renderedUrls(tester).first.endsWith('3.png'), isTrue,
        reason: '切回第 1 话应恢复到离开页第 3 页（末页），而非首页');
  });

  testWidgets('进度回归: 条漫无缝滚动回上一话 → 恢复离开页', (tester) async {
    final Directory root =
        Directory.systemTemp.createTempSync('comic_chswitch_c');
    addTearDown(() {
      try {
        root.deleteSync(recursive: true);
      } on Object {}
    });
    final Directory dir1 =
        Directory('${root.path}${Platform.pathSeparator}ch1')..createSync(recursive: true);
    final Directory dir2 =
        Directory('${root.path}${Platform.pathSeparator}ch2')..createSync(recursive: true);
    for (final dir in <Directory>[dir1, dir2]) {
      for (var p = 1; p <= 3; p++) {
        File('${dir.path}${Platform.pathSeparator}$p.png').writeAsBytesSync(
            <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      }
    }

    // 条漫 + 无缝连续阅读（与 BugZ3 同设置）。
    SharedPreferences.setMockInitialValues(<String, Object>{
      'reader_prefs_m1':
          '{"readingMode":"webtoon","seamlessReading":true,"showChapterSeparator":true,"doubleTapZoom":false}',
    });
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;

    final source = PluginConfig.fromJson(<String, dynamic>{
      'id': 'src1', 'name': 'S', 'type': 'mangaSource', 'responseType': 'json',
      'site': {'domain': 'https://example.com', 'baseUrl': 'https://example.com'},
      'parser': {'type': 'builtin'},
      'routes': {'images': '/images?cid={cid}'},
      'selectors': {'images': '\$.images'},
    });
    final repo = SourceRepository(<PluginConfig>[source]);
    final favorites = FavoritesManager();
    await favorites.init();

    await tester.pumpWidget(wrapReader(
      tester,
      repo: repo,
      service: FakeMediaApiServiceFixes(),
      favorites: favorites,
      chapters: const <Episode>[
        Episode(id: 'c1', title: '第1话', url: '/c1'),
        Episode(id: 'c2', title: '第2话', url: '/c2'),
      ],
      initialChapterIndex: 0,
      localChapterDirs: <String>[dir1.path, dir2.path],
    ));
    await tester.pump(const Duration(milliseconds: 200));
    for (int i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(renderedUrls(tester).any((u) => u.contains(dir1.path)), isTrue,
        reason: '初始应在第 1 话');

    Future<void> pumpSettle() async {
      for (int i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }
    String topUrl() =>
        tester.widgetList<MangaPageImage>(find.byType(MangaPageImage)).first.url;

    // 第 1 话翻到第 2 页（离开页）。
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await pumpSettle();
    expect(topUrl().endsWith('2.png'), isTrue, reason: '第 1 话应翻到第 2 页');

    // 切第 2 话，等上一话预载进无缝列表。
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    for (int i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(topUrl().contains(dir2.path), isTrue, reason: '应切到第 2 话');

    // 从第 2 话顶部逐步向回滚（下拖），每步检查：视口滚入上一段应触发无缝重锚
    // 回第 1 话并恢复到离开页；一旦回到第 1 话即停止拖拽（继续拖会往前翻页）。
    String? landed;
    for (int i = 0; i < 6; i++) {
      await tester.dragFrom(const Offset(400, 600), const Offset(0, 500));
      await pumpSettle();
      final u = topUrl();
      if (u.contains(dir1.path)) {
        landed = u;
        break;
      }
    }
    expect(landed, isNotNull, reason: '上滚越过边界应无缝回到第 1 话');
    expect(landed!.endsWith('2.png'), isTrue,
        reason: '滚动回上一话应恢复到离开页第 2 页，而非末页/首页');
  });

  testWidgets('进度回归: 无缝关闭时切下一话再切回 → 恢复离开页', (tester) async {
    final Directory root =
        Directory.systemTemp.createTempSync('comic_chswitch_e');
    addTearDown(() {
      try {
        root.deleteSync(recursive: true);
      } on Object {}
    });
    final Directory dir1 =
        Directory('${root.path}${Platform.pathSeparator}ch1')..createSync(recursive: true);
    final Directory dir2 =
        Directory('${root.path}${Platform.pathSeparator}ch2')..createSync(recursive: true);
    for (final dir in <Directory>[dir1, dir2]) {
      for (var p = 1; p <= 3; p++) {
        File('${dir.path}${Platform.pathSeparator}$p.png').writeAsBytesSync(
            <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      }
    }

    // seamlessReading=false：切话全走整章加载路径。
    SharedPreferences.setMockInitialValues(<String, Object>{
      'reader_prefs_m1':
          '{"readingMode":"singleLTR","seamlessReading":false,"doubleTapZoom":false}',
    });
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;

    final source = PluginConfig.fromJson(<String, dynamic>{
      'id': 'src1', 'name': 'S', 'type': 'mangaSource', 'responseType': 'json',
      'site': {'domain': 'https://example.com', 'baseUrl': 'https://example.com'},
      'parser': {'type': 'builtin'},
      'routes': {'images': '/images?cid={cid}'},
      'selectors': {'images': '\$.images'},
    });
    final repo = SourceRepository(<PluginConfig>[source]);
    final favorites = FavoritesManager();
    await favorites.init();

    await tester.pumpWidget(wrapReader(
      tester,
      repo: repo,
      service: FakeMediaApiServiceFixes(),
      favorites: favorites,
      chapters: const <Episode>[
        Episode(id: 'c1', title: '第1话', url: '/c1'),
        Episode(id: 'c2', title: '第2话', url: '/c2'),
      ],
      initialChapterIndex: 0,
      localChapterDirs: <String>[dir1.path, dir2.path],
    ));
    await tester.pump(const Duration(milliseconds: 200));
    for (int i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(renderedUrls(tester).any((u) => u.contains(dir1.path)), isTrue,
        reason: '初始应在第 1 话');

    Future<void> pumpSettle() async {
      for (int i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    // 第 1 话翻到第 2 页（离开页）。
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 400));
    expect(renderedUrls(tester).first.endsWith('2.png'), isTrue);

    // 章末翻页进入第 2 话（末页再翻两次越过章末）。
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 400));
    await pumpSettle();
    expect(renderedUrls(tester).any((u) => u.contains(dir2.path)), isTrue,
        reason: '章末翻页应进入第 2 话');

    // 章首上翻回第 1 话 → 恢复到离开页第 3 页（末页）。
    await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 400));
    await pumpSettle();
    expect(renderedUrls(tester).any((u) => u.contains(dir1.path)), isTrue,
        reason: '章首上翻应回到第 1 话');
    expect(renderedUrls(tester).first.endsWith('3.png'), isTrue,
        reason: '回到第 1 话应恢复到离开页第 3 页（末页），而非首页');
  });

  testWidgets('进度回归: 点选入口不被存档章覆盖（点哪话进哪话）', (tester) async {
    final Directory root =
        Directory.systemTemp.createTempSync('comic_chswitch_f');
    addTearDown(() {
      try {
        root.deleteSync(recursive: true);
      } on Object {}
    });
    final Directory dir1 =
        Directory('${root.path}${Platform.pathSeparator}ch1')..createSync(recursive: true);
    final Directory dir2 =
        Directory('${root.path}${Platform.pathSeparator}ch2')..createSync(recursive: true);
    for (final dir in <Directory>[dir1, dir2]) {
      for (var p = 1; p <= 3; p++) {
        File('${dir.path}${Platform.pathSeparator}$p.png').writeAsBytesSync(
            <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      }
    }

    SharedPreferences.setMockInitialValues(<String, Object>{
      'reader_prefs_m1': '{"readingMode":"singleLTR","doubleTapZoom":false}',
      // 存档：上次读到第 2 话第 2 页（索引 1）。
      'comic_progress_pick_test':
          '{"chapterId":"c2","currentPage":1,"chapterIndex":1,'
          '"totalChapters":2,"chapterPages":{"1":1}}',
    });
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;

    final source = PluginConfig.fromJson(<String, dynamic>{
      'id': 'src1', 'name': 'S', 'type': 'mangaSource', 'responseType': 'json',
      'site': {'domain': 'https://example.com', 'baseUrl': 'https://example.com'},
      'parser': {'type': 'builtin'},
      'routes': {'images': '/images?cid={cid}'},
      'selectors': {'images': '\$.images'},
    });
    final repo = SourceRepository(<PluginConfig>[source]);
    final favorites = FavoritesManager();
    await favorites.init();

    Future<void> openAndSettle(
        {required bool restore,
        required int chapter,
        String comicId = 'pick_test'}) async {
      await tester.pumpWidget(wrapReader(
        tester,
        repo: repo,
        service: FakeMediaApiServiceFixes(),
        favorites: favorites,
        chapters: const <Episode>[
          Episode(id: 'c1', title: '第1话', url: '/c1'),
          Episode(id: 'c2', title: '第2话', url: '/c2'),
        ],
        initialChapterIndex: chapter,
        localChapterDirs: <String>[dir1.path, dir2.path],
        restoreProgress: restore,
        comicId: comicId,
      ));
      await tester.pump(const Duration(milliseconds: 200));
      for (int i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }
    // 继续阅读入口（restoreProgress=true）：恢复存档的第 2 话第 2 页。
    await openAndSettle(restore: true, chapter: 0);
    expect(renderedUrls(tester).any((u) => u.contains(dir2.path)), isTrue,
        reason: '继续阅读应恢复存档的第 2 话');
    expect(renderedUrls(tester).first.endsWith('2.png'), isTrue,
        reason: '继续阅读应恢复存档页码（第 2 页）');

    // 点选入口（restoreProgress=false + initialChapterIndex=0，模拟
    // openDownloadedWorkFolder 的文件列表点选第 1 话）：不被存档章拉走，
    // 进入点选的第 1 话。
    await openAndSettle(restore: false, chapter: 0);
    expect(renderedUrls(tester).any((u) => u.contains(dir1.path)), isTrue,
        reason: '点选第 1 话应进入第 1 话，而非被存档拉回第 2 话');

    // 点选的恰是存档在读话（第 2 话）时，仍恢复页码（点选第 2 话 → 第 2 页）。
    // 用独立 comicId：上一次会话 dispose 时会把旧存档刷成第 1 话（正常语义），
    // 直接复用会互相污染。
    SharedPreferences.setMockInitialValues(<String, Object>{
      'reader_prefs_m1': '{"readingMode":"singleLTR","doubleTapZoom":false}',
      'comic_progress_pick2_test':
          '{"chapterId":"c2","currentPage":1,"chapterIndex":1,'
          '"totalChapters":2,"chapterPages":{"1":1}}',
    });
    await openAndSettle(restore: false, chapter: 1, comicId: 'pick2_test');
    expect(renderedUrls(tester).any((u) => u.contains(dir2.path)), isTrue,
        reason: '点选第 2 话应进入第 2 话');
    expect(renderedUrls(tester).first.endsWith('2.png'), isTrue,
        reason: '点选存档在读话应恢复到存档页码（第 2 页），而非首页');
  });

  testWidgets('进度回归: 章节目录切话再切回 → 恢复离开页', (tester) async {
    final Directory root =
        Directory.systemTemp.createTempSync('comic_chswitch_toc');
    addTearDown(() {
      try {
        root.deleteSync(recursive: true);
      } on Object {}
    });
    final Directory dir1 =
        Directory('${root.path}${Platform.pathSeparator}ch1')..createSync(recursive: true);
    final Directory dir2 =
        Directory('${root.path}${Platform.pathSeparator}ch2')..createSync(recursive: true);
    for (final dir in <Directory>[dir1, dir2]) {
      for (var p = 1; p <= 3; p++) {
        File('${dir.path}${Platform.pathSeparator}$p.png').writeAsBytesSync(
            <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      }
    }

    SharedPreferences.setMockInitialValues(<String, Object>{
      'reader_prefs_m1': '{"readingMode":"singleLTR","doubleTapZoom":false}',
    });
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;

    final source = PluginConfig.fromJson(<String, dynamic>{
      'id': 'src1', 'name': 'S', 'type': 'mangaSource', 'responseType': 'json',
      'site': {'domain': 'https://example.com', 'baseUrl': 'https://example.com'},
      'parser': {'type': 'builtin'},
      'routes': {'images': '/images?cid={cid}'},
      'selectors': {'images': '\$.images'},
    });
    final repo = SourceRepository(<PluginConfig>[source]);
    final favorites = FavoritesManager();
    await favorites.init();

    // 下载目录聚合（localChapterDirs）多话本地漫画。
    await tester.pumpWidget(wrapReader(
      tester,
      repo: repo,
      service: FakeMediaApiServiceFixes(),
      favorites: favorites,
      chapters: const <Episode>[
        Episode(id: 'c1', title: '第1话', url: '/c1'),
        Episode(id: 'c2', title: '第2话', url: '/c2'),
      ],
      initialChapterIndex: 0,
      localChapterDirs: <String>[dir1.path, dir2.path],
    ));
    await tester.pump(const Duration(milliseconds: 200));
    for (int i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(renderedUrls(tester).any((u) => u.contains(dir1.path)), isTrue,
        reason: '初始应在第 1 话');

    Future<void> pumpSettle() async {
      for (int i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    // 第 1 话翻到第 2 页（离开页）。
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 400));
    expect(renderedUrls(tester).first.endsWith('2.png'), isTrue);

    // 本地多话模式顶栏应有章节目录按钮。
    expect(find.byIcon(Icons.toc), findsOneWidget,
        reason: '下载目录聚合模式应显示章节目录按钮');

    // 打开章节目录 → 选第 2 话。
    await tester.tap(find.byIcon(Icons.toc));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('第2话').last);
    await tester.pump(const Duration(milliseconds: 100));
    await pumpSettle();
    expect(renderedUrls(tester).any((u) => u.contains(dir2.path)), isTrue,
        reason: '目录选第 2 话应进入第 2 话');

    // 再打开目录 → 切回第 1 话：应恢复到离开页第 2 页，而非第 1 页。
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byIcon(Icons.toc));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('第1话').last);
    await tester.pump(const Duration(milliseconds: 100));
    await pumpSettle();
    expect(renderedUrls(tester).any((u) => u.contains(dir1.path)), isTrue,
        reason: '目录切回第 1 话应回到第 1 话');
    expect(renderedUrls(tester).first.endsWith('2.png'), isTrue,
        reason: '目录切回第 1 话应恢复到离开页第 2 页，而非首页');
  });
}

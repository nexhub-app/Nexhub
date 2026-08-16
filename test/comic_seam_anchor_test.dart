import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:nexhub/core/favorites/favorites_manager.dart';
import 'package:nexhub/core/models/episode.dart';
import 'package:nexhub/core/models/plugin_config.dart';
import 'package:nexhub/core/resolver/resolver_registry.dart';
import 'package:nexhub/core/scraper/media_api_service.dart';
import 'package:nexhub/core/services/source_repository.dart';
import 'package:nexhub/features/manga/presentation/comic_reader_screen.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Bug 6 锚点重放测试：条漫（webtoon）seam 无缝连续模式下，上一章预载完成触发
/// seam 重建（前插上一段、当前章扁平索引整体后移）时，视口应锚回当前章原内容，
/// 不应误触发 [_seamAdvance(-1, last)] 把用户从本章首页拉回上一话末页。
class _FakeApiServiceSeam extends MediaApiService {
  _FakeApiServiceSeam() : super(ResolverRegistry.instance);

  @override
  Future<List<String>> fetchImages(
    PluginConfig source, {
    required String comicId,
    required String chapterId,
    String? renderedHtml,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    // 章节相关 URL，便于断言视口内容属于哪一章（c1/c2/c3 前缀）。
    return <String>[
      for (var p = 0; p < 5; p++)
        'https://example.com/$chapterId/p$p.png',
    ];
  }
}

Widget _wrapReader({
  required SourceRepository repo,
  required MediaApiService service,
  required FavoritesManager favorites,
  int initialChapterIndex = 1,
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
            initialChapterIndex: initialChapterIndex,
          ),
        ),
      ),
    ),
  );
}

/// 当前渲染的 MangaPageImage 是否包含 [chapterPrefix]（如 '/c1/'）的 URL。
bool _rendersChapter(WidgetTester tester, String chapterPrefix) {
  final Iterable<MangaPageImage> imgs =
      tester.widgetList<MangaPageImage>(find.byType(MangaPageImage));
  return imgs.any((w) => w.url.contains(chapterPrefix));
}

void main() {
  setUp(() async {
    final Directory dir =
        await Directory.systemTemp.createTemp('comic_seam_anchor_hive');
    try {
      Hive.init(dir.path);
    } on Object {
      // Hive.init 二次调用可能抛错或静默。
    }
  });

  PluginConfig makeSource() => PluginConfig.fromJson(<String, dynamic>{
        'id': 'src1', 'name': 'S', 'type': 'mangaSource', 'responseType': 'json',
        'site': {'domain': 'https://example.com', 'baseUrl': 'https://example.com'},
        'parser': {'type': 'builtin'},
        'routes': {'images': '/images?cid={cid}'},
        'selectors': {'images': '\$.images'},
      });

  testWidgets('Bug6: 上一章预载完成触发 seam 重建后视口仍锚在当前章（不跳回上一话末页）',
      (tester) async {
    // 3 章；从中章（c2，index 1）首页开始读，webtoon + seamless。
    // 章内 5 页、占位高度 = 屏宽×1.5 = 1200px = 视口高，逐条可定位。
    SharedPreferences.setMockInitialValues(<String, Object>{
      'reader_prefs_m1':
          '{"readingMode":"webtoon","seamlessReading":true,"showChapterSeparator":true,"doubleTapZoom":false}',
    });
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;

    final service = _FakeApiServiceSeam();
    final repo = SourceRepository(<PluginConfig>[makeSource()]);
    final favorites = FavoritesManager();
    await favorites.init();

    await tester.pumpWidget(_wrapReader(
      repo: repo,
      service: service,
      favorites: favorites,
      chapters: const <Episode>[
        Episode(id: 'c1', title: '第1话', url: '/c1'),
        Episode(id: 'c2', title: '第2话', url: '/c2'),
        Episode(id: 'c3', title: '第3话', url: '/c3'),
      ],
    ));
    // 等待 _loadChapter 完成（20ms 延迟 + 图片加载 + 布局）。
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    // 确认 MangaPageImage 已渲染。
    expect(find.byType(MangaPageImage), findsAtLeastNWidgets(1),
        reason: '应有至少一张漫画页渲染');

    // 初始在当前章 c2（index 1），未预载上一章前不渲染 c1 内容。
    expect(_rendersChapter(tester, '/c2/'), isTrue,
        reason: '当前应渲染 c2（第2话）的内容');
    expect(_rendersChapter(tester, '/c1/'), isFalse,
        reason: '未预载前不应渲染 c1 内容');

    // 轻微向下滚动 → 触发 _onWebtoonScroll → _maybePreload(0)
    // → 预载上一章 c1。预载完成会 _rebuildSeamKeepViewport：前插 c1 段并锚点重放。
    await tester.drag(find.byType(ScrollablePositionedList), const Offset(0, -300));
    await tester.pump(const Duration(milliseconds: 100));
    // 等 c1 预载完成 + seam 重建 + jumpTo 重放落定。
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));

    // 核心不变式：未被 _seamAdvance(-1, last) 拉回上一话末页——
    // 仍停留在 c2（当前章），不显示 c3 的内容（c3 是往后跳，不是往前跳）。
    expect(_rendersChapter(tester, '/c2/'), isTrue,
        reason: '上一章预载完成触发 seam 重建后视口应仍锚在当前章 c2');
    expect(_rendersChapter(tester, '/c3/'), isFalse,
        reason: '不应被拉回或跳到 c3');

    // 证明前插确实发生：向上滚入上一段即可看到 c1 内容（c1 已拼在 c2 之前）。
    await tester.drag(find.byType(ScrollablePositionedList), const Offset(0, 800));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(_rendersChapter(tester, '/c1/'), isTrue,
        reason: '上一章预载完成前插后，向上滚应能看到 c1 内容');
  });
}
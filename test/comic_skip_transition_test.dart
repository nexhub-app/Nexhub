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

/// Bug 7 连续阅读测试（2026-08-20 重写）：条漫跳过被筛选/已读章时，滚到章末
/// 【直接自动连读】到过滤后的目标章——不再显示「下一章：{标题}」过渡横幅、
/// 无需点击/延时确认（横幅机制已由「直接自动连读」取代）。
///
/// 覆盖：
/// - l10n 键值（en/zh 跳章过渡提示文本，键保留兼容）
/// - 滚到章末直接加载目标章（不显示横幅、不整章跳跃等待）
class _FakeApiServiceSkip extends MediaApiService {
  _FakeApiServiceSkip() : super(ResolverRegistry.instance);

  @override
  Future<List<String>> fetchImages(
    PluginConfig source, {
    required String comicId,
    required String chapterId,
    String? renderedHtml,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    // 章节相关 URL，便于断言视口内容属于哪一章。
    return <String>[
      for (var p = 0; p < 3; p++)
        'https://example.com/$chapterId/p$p.png',
    ];
  }
}

Widget _wrapReader({
  required SourceRepository repo,
  required MediaApiService service,
  required FavoritesManager favorites,
  List<Episode> chapters = const <Episode>[
    Episode(id: 'c1', title: '第1话', url: '/c1'),
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
          ),
        ),
      ),
    ),
  );
}

/// 断言当前渲染的 MangaPageImage 是否包含 [chapterPrefix]（如 '/c3/'）的 URL。
bool _rendersChapter(WidgetTester tester, String chapterPrefix) {
  final Iterable<MangaPageImage> imgs =
      tester.widgetList<MangaPageImage>(find.byType(MangaPageImage));
  return imgs.any((w) => w.url.contains(chapterPrefix));
}

/// 逐步向下滚动条漫列表（每次 150px），直到 [until] 返回 true 或超过 [maxSteps]。
Future<void> _scrollUntil(
  WidgetTester tester,
  bool Function() until, {
  int maxSteps = 40,
}) async {
  final Finder list = find.byType(ScrollablePositionedList);
  for (int i = 0; i < maxSteps; i++) {
    if (until()) return;
    await tester.drag(list, const Offset(0, -150));
    await tester.pump(const Duration(milliseconds: 30));
  }
}

void main() {
  setUp(() async {
    final Directory dir =
        await Directory.systemTemp.createTemp('comic_skip_hive');
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

  List<Episode> chapters() => const <Episode>[
        Episode(id: 'c1', title: '第1话', url: '/c1'),
        // c2 标题为空 → 被筛选（skipFilteredChapters 时跳过），下一目标章为 c3。
        Episode(id: 'c2', title: '', url: '/c2'),
        Episode(id: 'c3', title: '第3话', url: '/c3'),
      ];

  test('Bug7: 跳章过渡提示 l10n 键值正确（zh/en）', () {
    final AppLocalizations zh = lookupAppLocalizations(const Locale('zh'));
    final AppLocalizations en = lookupAppLocalizations(const Locale('en'));
    expect(zh.readerNextChapterSkipped('第3话'), '下一章：第3话');
    expect(zh.readerNextChapterSkippedHint, '点击立即跳转');
    expect(en.readerNextChapterSkipped('Ch. 3'), 'Next chapter: Ch. 3');
    expect(en.readerNextChapterSkippedHint, 'Tap to jump now');
  });

  testWidgets('Bug7: 条漫滚到章末直接自动连读目标章（无横幅、无需点击）',
      (tester) async {
    // 条漫 + seamless + 跳过被筛选章（c2 空标题被跳过，目标章 c3）。
    SharedPreferences.setMockInitialValues(<String, Object>{
      'reader_prefs_m1':
          '{"readingMode":"webtoon","seamlessReading":true,"showChapterSeparator":true,"skipFilteredChapters":true,"doubleTapZoom":false}',
    });
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;

    final service = _FakeApiServiceSkip();
    final repo = SourceRepository(<PluginConfig>[makeSource()]);
    final favorites = FavoritesManager();
    await favorites.init();

    await tester.pumpWidget(_wrapReader(
      repo: repo,
      service: service,
      favorites: favorites,
      chapters: chapters(),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(MangaPageImage), findsAtLeastNWidgets(1));
    expect(_rendersChapter(tester, '/c1/'), isTrue,
        reason: '初始应渲染当前章 c1');

    // 初始无横幅、无 c3 内容。
    expect(find.text('下一章：第3话'), findsNothing);

    // 滚到章末：逐步滚动直到目标章 c3 被渲染（自动连读，无需点击/等待横幅）。
    await _scrollUntil(
      tester,
      () => _rendersChapter(tester, '/c3/'),
    );

    expect(_rendersChapter(tester, '/c3/'), isTrue,
        reason: '滚到章末后应直接自动连读到过滤后的目标章 c3');
    // 不再出现「下一章」横幅（直接自动连读，无过渡确认）。
    expect(find.text('下一章：第3话'), findsNothing);
  });

  testWidgets('Bug7: 无跳章过滤时滚到章末直接无缝进入下一章（c2）', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'reader_prefs_m1':
          '{"readingMode":"webtoon","seamlessReading":true,"showChapterSeparator":true,"doubleTapZoom":false}',
    });
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;

    final service = _FakeApiServiceSkip();
    final repo = SourceRepository(<PluginConfig>[makeSource()]);
    final favorites = FavoritesManager();
    await favorites.init();

    await tester.pumpWidget(_wrapReader(
      repo: repo,
      service: service,
      favorites: favorites,
      chapters: chapters(),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 50));

    // 滚到章末：逐步滚动直到下一章 c2 被渲染。
    await _scrollUntil(
      tester,
      () => _rendersChapter(tester, '/c2/'),
    );

    expect(_rendersChapter(tester, '/c2/'), isTrue,
        reason: '无过滤时滚到章末应直接连读到相邻下一章 c2');
    expect(find.text('下一章：第2话'), findsNothing);
  });
}
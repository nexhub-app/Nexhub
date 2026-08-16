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

/// Bug 7 跳章过渡提示测试：条漫跳过被筛选/已读章时，滚到章末显示「下一章：{标题}」
/// 过渡横幅（短暂停留或点击后跳转），不再直接整章跳跃，改善连续性感知。
///
/// 覆盖：
/// - l10n 键值（en/zh 跳章过渡提示文本）
/// - 滚到章末显示横幅（不直接整章跳转）
/// - 点击横幅立即跳转到过滤后的目标章
/// - 延时到期自动跳转到过滤后的目标章
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

  testWidgets('Bug7: 滚到章末显示跳章过渡横幅，点击立即跳转到目标章',
      (tester) async {
    // 条漫 + seamless + 跳过被筛选章（c2 空标题被跳过）。
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

    // 初始无横幅。
    expect(find.text('下一章：第3话'), findsNothing);

    // 滚到章末（逐步滚动，避免 overscroll 触发整章跳转）。
    await _scrollUntil(
      tester,
      () => find.text('下一章：第3话').evaluate().isNotEmpty,
    );

    // 横幅出现：不再直接整章跳跃，仍停留在当前章 c1。
    expect(find.text('下一章：第3话'), findsOneWidget);
    expect(find.text('点击立即跳转'), findsOneWidget);
    expect(_rendersChapter(tester, '/c1/'), isTrue,
        reason: '跳章过渡期间应停留在当前章内容，不直接整章跳跃');

    // 点击横幅 → 立即跳转到过滤后的目标章 c3。
    await tester.tap(find.text('下一章：第3话'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 100));

    expect(_rendersChapter(tester, '/c3/'), isTrue,
        reason: '点击横幅后应跳到过滤后的目标章 c3');
    // 横幅已收起。
    expect(find.text('下一章：第3话'), findsNothing);
  });

  testWidgets('Bug7: 跳章过渡横幅延时到期自动跳转到目标章', (tester) async {
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

    // 滚到章末显示横幅。
    await _scrollUntil(
      tester,
      () => find.text('下一章：第3话').evaluate().isNotEmpty,
    );
    expect(find.text('下一章：第3话'), findsOneWidget);

    // 延时到期（约 1.8s）自动跳转到目标章 c3。
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 100));

    expect(_rendersChapter(tester, '/c3/'), isTrue,
        reason: '延时到期后应自动跳到过滤后的目标章 c3');
    expect(find.text('下一章：第3话'), findsNothing);
  });
}
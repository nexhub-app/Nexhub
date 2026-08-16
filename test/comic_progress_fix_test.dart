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
import 'package:shared_preferences/shared_preferences.dart';

/// Task 4 双页 + 首屏单图进度条显示测试：
/// 双页 + 首屏单图下 spread 0/1/2 → 1 / 2-3 / 4-5；非首屏单图保持 1-2 / 3-4。
class _FakeService extends MediaApiService {
  _FakeService() : super(ResolverRegistry.instance);

  @override
  Future<List<String>> fetchImages(
    PluginConfig source, {
    required String comicId,
    required String chapterId,
    String? renderedHtml,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    // 5 张图（末跨页单张）。
    return <String>[
      'https://example.com/p0.png',
      'https://example.com/p1.png',
      'https://example.com/p2.png',
      'https://example.com/p3.png',
      'https://example.com/p4.png',
    ];
  }
}

PluginConfig _src() => PluginConfig.fromJson(<String, dynamic>{
  'id': 'src1', 'name': 'S', 'type': 'mangaSource', 'responseType': 'json',
  'site': {'domain': 'https://example.com', 'baseUrl': 'https://example.com'},
  'parser': {'type': 'builtin'},
  'routes': {'images': '/images?cid={cid}'},
  'selectors': {'images': '\$.images'},
});

Widget _wrapReader({
  required SourceRepository repo,
  required MediaApiService service,
  required FavoritesManager favorites,
}) {
  return Provider<MediaApiService>.value(
    value: service,
    child: ChangeNotifierProvider<SourceRepository>.value(
      value: repo,
      child: ChangeNotifierProvider<FavoritesManager>.value(
        value: favorites,
        child: const MaterialApp(
          locale: Locale('zh'),
          supportedLocales: <Locale>[Locale('zh'), Locale('en')],
          localizationsDelegates: <LocalizationsDelegate<dynamic>>[
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: ComicReaderScreen(
            comicId: 'm1',
            title: '测试漫画',
            sourceId: 'src1',
            chapters: <Episode>[
              Episode(id: 'c1', title: '第1话', url: '/c1'),
            ],
          ),
        ),
      ),
    ),
  );
}

void main() {
  setUp(() async {
    final Directory dir =
        await Directory.systemTemp.createTemp('comic_progress_fix');
    try {
      Hive.init(dir.path);
    } on Object {
      // 静默忽略。
    }
  });

  /// 提取底部进度条的跨页范围文本（双页格式 "X-Y / 总数" 或单页 "第 X / Y 页"）。
  String progressText(WidgetTester tester) {
    final Iterable<Text> texts =
        tester.widgetList<Text>(find.byType(Text)).where((t) {
      final String d = t.data ?? '';
      return RegExp(r'^\d+-\d+\s*/\s*\d+$').hasMatch(d.trim()) ||
          RegExp(r'^第\s+\d+\s*/\s*\d+\s*页$').hasMatch(d.trim());
    });
    return texts.isEmpty ? '' : texts.first.data!.trim();
  }

  Future<void> pumpReader(
    WidgetTester tester, {
    required int restorePage,
    required bool firstSingle,
  }) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'reader_prefs_m1': jsonPrefs({
        'readingMode': 'singleLTR',
        'splitDoublePage': true,
        'showSingleImageOnFirstPage': firstSingle,
        'showPageNumber': true,
        'progressBarOnRight': false,
      }),
      'comic_progress_m1': jsonPrefs({
        'chapterId': 'c1',
        'currentPage': restorePage,
        'chapterIndex': 0,
        'totalChapters': 1,
      }),
    });
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;

    final service = _FakeService();
    final repo = SourceRepository(<PluginConfig>[_src()]);
    final favorites = FavoritesManager();
    await favorites.init();

    await tester.pumpWidget(
        _wrapReader(repo: repo, service: service, favorites: favorites));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 50));
    // 显示控制栏。
    await tester.tapAt(const Offset(400, 600));
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('双页 + 首屏单图：spread0/1/2 → 1-1 / 2-3 / 4-5（含总数）',
      (tester) async {
    await pumpReader(tester, restorePage: 0, firstSingle: true);
    // spread0 → 左页 0 +1 = 第 1 页（首屏单图仅一页）。
    expect(progressText(tester), contains('1-1 / 5'));
  });

  testWidgets('双页 + 首屏单图：恢复第 2 页 → spread1 → 2-3', (tester) async {
    await pumpReader(tester, restorePage: 2, firstSingle: true);
    expect(progressText(tester), contains('2-3 / 5'));
  });

  testWidgets('双页 + 首屏单图：恢复第 4 页 → spread2 → 4-5（夹紧到 5）',
      (tester) async {
    await pumpReader(tester, restorePage: 4, firstSingle: true);
    expect(progressText(tester), contains('4-5 / 5'));
  });

  testWidgets('双页（无首屏单图）：spread 映射保持 1-2 / 3-4 语义', (tester) async {
    await pumpReader(tester, restorePage: 2, firstSingle: false);
    // 常规双页：第 2 页(0-indexed) → spread1 → 第 3-4 页。
    expect(progressText(tester), contains('3-4 / 5'));
  });
}

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
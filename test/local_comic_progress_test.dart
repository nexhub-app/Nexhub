import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive/hive.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/favorites/favorites_manager.dart';
import 'package:nexhub/core/models/episode.dart';
import 'package:nexhub/core/models/plugin_config.dart';
import 'package:nexhub/core/resolver/resolver_registry.dart';
import 'package:nexhub/core/scraper/media_api_service.dart';
import 'package:nexhub/core/services/source_repository.dart';
import 'package:nexhub/features/manga/presentation/comic_reader_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 本地（单文件/散图）漫画进度恢复：保存侧主记录 + 重进恢复。
class _NoopApi extends MediaApiService {
  _NoopApi() : super(ResolverRegistry.instance);
}

void main() {
  setUp(() async {
    final Directory dir =
        await Directory.systemTemp.createTemp('local_comic_hive');
    try {
      Hive.init(dir.path);
    } on Object {
      // Hive.init 二次调用可能抛错或静默，包一层避免影响。
    }
  });

  Widget wrap(Widget child) {
    final source = PluginConfig.fromJson(<String, dynamic>{
      'id': 'src1', 'name': 'S', 'type': 'mangaSource', 'responseType': 'json',
      'site': {'domain': 'https://example.com', 'baseUrl': 'https://example.com'},
      'parser': {'type': 'builtin'},
      'routes': <String, dynamic>{},
      'selectors': <String, dynamic>{},
    });
    return Provider<MediaApiService>.value(
      value: _NoopApi(),
      child: ChangeNotifierProvider<SourceRepository>.value(
        value: SourceRepository(<PluginConfig>[source]),
        child: ChangeNotifierProvider<FavoritesManager>.value(
          value: FavoritesManager(),
          child: MaterialApp(
            locale: const Locale('zh'),
            supportedLocales: const <Locale>[Locale('zh'), Locale('en')],
            localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: child,
          ),
        ),
      ),
    );
  }

  testWidgets('单文件本地漫画：翻页后进度落盘，重进恢复到已读页', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;

    const List<String> images = <String>[
      '/tmp/nx/p1.png', '/tmp/nx/p2.png', '/tmp/nx/p3.png',
      '/tmp/nx/p4.png', '/tmp/nx/p5.png',
    ];

    // 第一次进入：本地散图模式（chapters 为空）。
    await tester.pumpWidget(wrap(const ComicReaderScreen(
      comicId: 'local_single_test',
      title: '本地单卷',
      sourceId: '',
      chapters: <Episode>[],
      localImages: images,
      restoreProgress: true,
    )));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(PageView), findsOneWidget);

    // PageDown 翻两页（键盘路径直连 _goNextPage，绕开 tap 双击/热区判定）。
    // 翻页为动画：每次按键后分两段 pump（事件派发 + 动画完成）。
    for (var i = 0; i < 2; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 400));
    }
    // 防抖 1s 到期 → _saveProgress 落盘。
    await tester.pump(const Duration(milliseconds: 1200));

    // 保存侧：主进度记录（chapterIndex + currentPage）必须真实写入页码。
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('comic_progress_local_single_test');
    expect(raw, isNotNull, reason: '单文件本地漫画的进度主记录未落盘');
    final Map<String, dynamic> saved =
        jsonDecode(raw!) as Map<String, dynamic>;
    expect(saved['currentPage'], 2,
        reason: '翻到第 3 页后主记录 currentPage 应为 2（索引）');

    // 第二次进入（同 comicId）：应恢复到第 3 页（索引 2），而非第 1 页。
    // _init 的多个 await（偏好/进度读取）跨事件循环轮次，分帧 pump 推进。
    await tester.pumpWidget(wrap(const ComicReaderScreen(
      comicId: 'local_single_test',
      title: '本地单卷',
      sourceId: '',
      chapters: <Episode>[],
      localImages: images,
      restoreProgress: true,
    )));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final pv = tester.widget<PageView>(find.byType(PageView));
    // 断言真实显示页（controller 可能经偏好回调重建后纠偏跳转，initialPage 不可靠）。
    expect(pv.controller?.page?.round(), 2,
        reason: '重进本地漫画应恢复到上次读到的页');
  });
}

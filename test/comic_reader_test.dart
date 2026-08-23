import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/favorites/favorites_manager.dart';
import 'package:nexhub/core/comic/models/reader_preferences.dart';
import 'package:nexhub/core/models/plugin_config.dart';
import 'package:nexhub/core/models/episode.dart';
import 'package:nexhub/core/resolver/resolver_registry.dart';
import 'package:nexhub/core/scraper/media_api_service.dart';
import 'package:nexhub/core/services/source_repository.dart';
import 'package:nexhub/features/manga/presentation/comic_reader_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 阅读器界面测试：widget 测试环境下 HttpClient 被桩为返回 400，
/// 无法走真实网络。此处注入 [FakeMediaApiService] 提供固定的图片列表，
/// 真实 fetchImages 路径由 media_api_service_images_test 的 loopback 测试覆盖。
class FakeMediaApiService extends MediaApiService {
  FakeMediaApiService() : super(ResolverRegistry.instance);

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
  });

  testWidgets('reader renders pages and toggles UI', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      // 默认开启双击缩放（InteractiveViewer 参与手势竞技场），
      // 用于验证「单击导航不被缩放手势吞掉」的修复。
      'reader_prefs_m1':
          '{"readingMode":"singleLTR","doubleTapZoom":true,"tapZoneLayout":"lShape"}',
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
    final service = FakeMediaApiService();
    final favorites = FavoritesManager();
    await favorites.init();
    const chapters = <Episode>[Episode(id: 'c1', title: '第1话', url: '/c1')];

    await tester.pumpWidget(
      Provider<MediaApiService>.value(
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
                chapters: chapters,
              ),
            ),
          ),
        ),
      ),
    );

    // 等待异步加载完成（FakeMediaApiService.fetchImages 延迟 20ms）。
    // 不用 pumpAndSettle：SourceImage 的 CachedNetworkImage 在测试环境
    // 发起网络请求返回 400，placeholder 的 CircularProgressIndicator
    // 无限动画会导致 pumpAndSettle 超时。pump 推进足够时间让 fetchImages
    // 完成并触发 setState 重建即可，断言不依赖图片真正解码。
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 50));

    // 至少一页漫画已渲染（MangaPageImage 在加载/解码中即存在；
    // 分页模式下 PageView 仅实例化可见页，故用 atLeast）。
    expect(find.byType(MangaPageImage), findsAtLeastNWidgets(1));

    // 点击中心（默认布局中部 1/3 为切换控件）切换阅读器控件显隐。
    await tester.tapAt(const Offset(400, 600));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);

    // 再次点击（中心另一位置，避开双击缩放：双击间距需 <300ms 且距离 <36px，
    // 因此换一个仍在中心 toggle 区的点，确保这是一次独立的单击而非双击缩放）。
    await tester.tapAt(const Offset(300, 600));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byIcon(Icons.arrow_back), findsNothing);
  });

  test('设备层草稿提交到 store 持久化', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final store = ReaderPreferencesStore();
    final draft = const ReaderPreferences().copyWith(autoPageTurningInterval: 10);
    // 模拟 _commitDeviceOverride 路径：设备层草稿写入作品层持久化。
    await store.save('m2', draft);
    final loaded = await store.get('m2');
    expect(loaded.autoPageTurningInterval, 10);
  });

  test('关闭自动翻页不清零间隔，重新开启恢复原间隔', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final store = ReaderPreferencesStore();
    // 开启并设间隔 12s → 仅关开关（UI 新路径：只切 enabled）。
    final draft = const ReaderPreferences()
        .copyWith(autoPageTurningEnabled: true, autoPageTurningInterval: 12)
        .copyWith(autoPageTurningEnabled: false);
    expect(draft.autoPageTurningInterval, 12);
    await store.save('m2', draft);
    var loaded = await store.get('m2');
    expect(loaded.autoPageTurningEnabled, isFalse);
    expect(loaded.autoPageTurningInterval, 12);
    // 重新开启：间隔保持上次值而非重置为 5。
    loaded = loaded.copyWith(autoPageTurningEnabled: true);
    expect(loaded.autoPageTurningInterval, 12);
  });

  test('旧数据迁移：无 autoPageTurningEnabled 键时按 interval>0 推导开关', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'reader_prefs_m3': '{"autoPageTurningInterval":7}',
      'reader_prefs_m4': '{"autoPageTurningInterval":0}',
    });
    final store = ReaderPreferencesStore();
    final on = await store.get('m3');
    expect(on.autoPageTurningEnabled, isTrue);
    expect(on.autoPageTurningInterval, 7);
    final off = await store.get('m4');
    expect(off.autoPageTurningEnabled, isFalse);
  });
}

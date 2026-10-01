/// 设置入口可见性回归测试。
///
/// 背景：功能代码写好了但入口被折叠/放错页，用户会认为「功能没做」——这是本次
/// 真实出现过的缺陷。本测试锁死三件事：
/// 1. 漫画设置页「画面与滤镜」卡片里存在超分开关（开关 + 两档选项，非独立分组）；
/// 2. 阅读器内联面板可搜索到「超分」关键词；
/// 3. 隐私与安全页不再有旧的「清除缓存」内联项（缓存清理已统一到缓存管理页）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nexhub/core/comic/manga_upscale.dart';
import 'package:nexhub/core/comic/models/reader_preferences.dart';
import 'package:nexhub/core/settings/reader_default_settings.dart';
import 'package:nexhub/core/widgets/app_animations.dart';
import 'package:nexhub/features/manga/presentation/reader_settings_sheet.dart';
import 'package:nexhub/features/settings/presentation/settings_advanced_screen.dart';
import 'package:nexhub/features/settings/presentation/settings_cache_manager_screen.dart';
import 'package:nexhub/features/settings/presentation/settings_comic_reader_screen.dart';
import 'package:nexhub/features/settings/presentation/settings_privacy_security_screen.dart';
import 'package:nexhub/features/settings/presentation/widgets/settings_widgets.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _host(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        AppLocalizations.delegate,
        ...GlobalMaterialLocalizations.delegates,
      ],
      supportedLocales: const <Locale>[Locale('zh'), Locale('en')],
      home: child,
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('漫画设置页 · 图片超分入口', () {
    testWidgets('画面与滤镜卡片内存在超分开关（不是独立二级分类）',
        (WidgetTester tester) async {
      await tester.pumpWidget(_host(const SettingsComicReaderScreen()));
      await tester.pumpAndSettle();

      // 「画面与滤镜」卡片默认折叠：展开它才能看到内部开关。
      final Finder card = find.text('画面与滤镜');
      expect(card, findsWidgets);
      await tester.tap(card.first);
      await tester.pumpAndSettle();

      // 超分开关必须以开关形式呈现（用户要求：直接开关，不单独做二级分类）。
      expect(find.text('图片超分'), findsWidgets,
          reason: '漫画设置页必须能看到「图片超分」入口');
      expect(find.byKey(const ValueKey<String>('comic.upscaleToggle')),
          findsOneWidget);
      expect(find.byKey(const ValueKey<String>('comic.upscaleMode')),
          findsNothing, reason: '关闭状态下不显示档位选项');
    });

    testWidgets('打开开关后显示两个档位选项', (WidgetTester tester) async {
      await tester.pumpWidget(_host(const SettingsComicReaderScreen()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('画面与滤镜').first);
      await tester.pumpAndSettle();

      // 滚动到超分开关并打开。
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey<String>('comic.upscaleToggle')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('comic.upscaleToggle')));
      await tester.pumpAndSettle();

      // 开启后出现档位选择，且只列生效档（不含「关闭」）。
      expect(find.text('高清重采样'), findsOneWidget);
      expect(find.text('超分（锐化）'), findsOneWidget);
      expect(find.text('关闭'), findsNothing, reason: 'off 由开关表达，不重复列出');

      // 设置已持久化。
      final ReaderDefaultSettings saved =
          await ReaderDefaultSettingsStore().load();
      expect(saved.comicUpscaleMode.enabled, isTrue);
    });
  });

  group('MangaUpscaleMode 契约', () {
    test('开关语义：enabled 恰好区分 off 与生效档', () {
      expect(MangaUpscaleMode.off.enabled, isFalse);
      expect(MangaUpscaleMode.resample.enabled, isTrue);
      expect(MangaUpscaleMode.sharpen.enabled, isTrue);
    });
  });

  group('缓存入口收敛', () {
    testWidgets('隐私与安全页不再有旧的「清除缓存」内联项',
        (WidgetTester tester) async {
      await tester.pumpWidget(_host(const SettingsPrivacySecurityScreen()));
      await tester.pumpAndSettle();

      // 旧内联项（只清 Cookie + 内存图片缓存）已删除：缓存清理统一到缓存管理页，
      // 避免两个入口能力不一致。此处不应再出现「清除缓存」快捷项。
      expect(find.text('清除缓存'), findsNothing,
          reason: '隐私页不应再保留能力更弱的旧清理入口');
      // 高级设置入口仍在（缓存管理的唯一路径经由此处）。
      expect(find.text('高级设置'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('高级设置「数据清理」只保留 Cookie + 缓存管理（WebView 已并入分类）',
        (WidgetTester tester) async {
      await tester.pumpWidget(_host(const SettingsAdvancedScreen()));
      await tester.pumpAndSettle();

      expect(find.text('清除 Cookie'), findsOneWidget);
      // WebView 数据成为缓存管理页的一个类别，高级页不再有重复入口。
      expect(find.text('清除 WebView 数据'), findsNothing,
          reason: 'WebView 清理应只保留一处（缓存管理页的类别行）');
      expect(find.byKey(const ValueKey<String>('advanced.imageCache')),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('缓存管理页是缓存清理的唯一入口且六类齐全',
        (WidgetTester tester) async {
      await tester.pumpWidget(_host(const SettingsCacheManagerScreen()));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();

      for (final String label in <String>[
        '图片缓存',
        '弹幕缓存',
        '翻译缓存',
        'WebView 数据',
        '临时文件',
        '更新包残留',
      ]) {
        expect(find.text(label), findsOneWidget, reason: '缺少类别：$label');
      }
      expect(tester.takeException(), isNull);
    });
  });

  group('漫画阅读器内联面板 · 图片超分入口', () {
    testWidgets('面板里能搜到「超分」并看到开关', (WidgetTester tester) async {
      await tester.pumpWidget(_host(Scaffold(
        body: buildComicSettingsSheet(
          initial: const ReaderPreferences(),
          onClose: () {},
        ),
      )));
      await tester.pumpAndSettle();

      // 用搜索直达：搜索词命中后该分组保持展开，条目可见。
      final Finder searchField = find.byType(TextField).first;
      await tester.enterText(searchField, '超分');
      await tester.pumpAndSettle();

      expect(find.text('图片超分'), findsWidgets,
          reason: '内联面板必须能通过搜索找到「图片超分」');
      expect(tester.takeException(), isNull);
    });

    testWidgets('面板开关可切换并回调生效档位', (WidgetTester tester) async {
      ReaderPreferences? latest;
      await tester.pumpWidget(_host(Scaffold(
        body: buildComicSettingsSheet(
          initial: const ReaderPreferences(),
          onChanged: (ReaderPreferences p) => latest = p,
          onClose: () {},
        ),
      )));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '超分');
      await tester.pumpAndSettle();

      // 面板是滚动容器：先滚到可见，否则 tap 落在视口外会被丢弃。
      final Finder sw = find.descendant(
        of: find.ancestor(
          of: find.text('图片超分'),
          matching: find.byType(SettingsSwitchTile),
        ),
        matching: find.byType(Switch),
      );
      expect(sw, findsOneWidget, reason: '超分开关必须存在且唯一');
      await tester.ensureVisible(sw);
      await tester.pumpAndSettle();
      await tester.tap(sw);
      await tester.pumpAndSettle();

      expect(latest?.upscaleMode.enabled, isTrue,
          reason: '打开开关后回调应带出生效档位');
      // 开启后档位选项出现（不含「关闭」）。
      expect(find.text('高清重采样'), findsOneWidget);
      expect(find.text('超分（锐化）'), findsOneWidget);
      expect(find.text('关闭'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('搜索命中项必须自动展开（否则「搜到了但看不见」）',
        (WidgetTester tester) async {
      await tester.pumpWidget(_host(Scaffold(
        body: buildComicSettingsSheet(
          initial: const ReaderPreferences(),
          onClose: () {},
        ),
      )));
      await tester.pumpAndSettle();

      // 「画面与滤镜」默认折叠：不搜索时其内部条目不可见。
      expect(find.text('图片超分'), findsNothing);

      // 搜索命中后必须自动展开，条目立即可见（这是曾经踩过的坑：
      // 分组只过滤不展开，用户搜到了关键词却看不到内容）。
      await tester.enterText(find.byType(TextField).first, '超分');
      await tester.pumpAndSettle();
      expect(find.text('图片超分'), findsWidgets,
          reason: '搜索命中后分组必须自动展开');

      // 清空搜索回到折叠态。
      await tester.enterText(find.byType(TextField).first, '');
      await tester.pumpAndSettle();
      expect(find.text('图片超分'), findsNothing,
          reason: '清空搜索后应回到默认折叠态');
      expect(tester.takeException(), isNull);
    });
  });
}

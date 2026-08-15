/// 收藏分组栏 Widget 测试（计划 §测试 7）。
///
/// - chip 渲染：[全部] [未分组] [分组…] [管理]。
/// - 多选回调：点击分组 chip 回传新的完整集合（并集语义）。
/// - 管理入口：点击「管理分组」打开管理面板。
library;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/favorites/favorites_manager.dart';
import 'package:nexhub/core/models/plugin_config.dart';
import 'package:nexhub/core/widgets/favorite_group_bar.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const SourceType anime = SourceType.animeSource;
const SourceType manga = SourceType.mangaSource;

Widget wrap({required FavoritesManager manager, required Widget child}) =>
    ChangeNotifierProvider<FavoritesManager>.value(
      value: manager,
      child: MaterialApp(
        locale: const Locale('zh'),
        supportedLocales: const <Locale>[Locale('zh'), Locale('en')],
        localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Scaffold(body: child),
      ),
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('分组栏渲染全部/未分组/分组/管理 chip', (WidgetTester tester) async {
    final manager = FavoritesManager();
    await manager.init();
    await manager.createGroup('追番', type: anime);
    await manager.createGroup('补番', type: anime);

    await tester.pumpWidget(
      wrap(
        manager: manager,
        child: FavoriteGroupBar(
          sourceType: anime,
          selectedGroupIds: const <String>{},
          onChanged: (_) {},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('全部'), findsOneWidget);
    expect(find.text('未分组'), findsOneWidget);
    expect(find.text('追番'), findsOneWidget);
    expect(find.text('补番'), findsOneWidget);
    expect(find.text('管理分组'), findsOneWidget);
  });

  testWidgets('点击分组 chip 回传多选集合', (WidgetTester tester) async {
    final manager = FavoritesManager();
    await manager.init();
    final group = (await manager.createGroup('追番', type: anime))!;

    Set<String>? changed;
    await tester.pumpWidget(
      wrap(
        manager: manager,
        child: FavoriteGroupBar(
          sourceType: anime,
          selectedGroupIds: const <String>{},
          onChanged: (Set<String> ids) => changed = ids,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    // 点击分组 chip → 回传含该 id 的集合。
    await tester.tap(find.text('追番'));
    expect(changed, <String>{group.id});

    // 已选中该分组时再点击 → 回传移除后的集合（toggle 语义）。
    changed = null;
    await tester.pumpWidget(
      wrap(
        manager: manager,
        child: FavoriteGroupBar(
          sourceType: anime,
          selectedGroupIds: <String>{group.id},
          onChanged: (Set<String> ids) => changed = ids,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    // 选中态触发 AppValuePulse 缩放动画，派生坐标可能偏移，仅验证回调。
    await tester.tap(find.text('追番'), warnIfMissed: false);
    expect(changed, isEmpty);

    // 点击「全部」→ 清空集合。
    changed = null;
    await tester.tap(find.text('全部'));
    expect(changed, isEmpty);
  });

  testWidgets('点击管理入口打开分组管理面板', (WidgetTester tester) async {
    final manager = FavoritesManager();
    await manager.init();
    await manager.createGroup('追番', type: anime);

    await tester.pumpWidget(
      wrap(
        manager: manager,
        child: FavoriteGroupBar(
          sourceType: anime,
          selectedGroupIds: const <String>{},
          onChanged: (_) {},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.text('管理分组'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    // 管理面板标题 + 新建按钮出现。
    expect(find.text('新建分组'), findsOneWidget);
    // 面板列表内渲染既有分组（分组栏 chip + 面板 ListTile 各一处）。
    expect(find.text('追番'), findsNWidgets(2));
  });

  testWidgets('分组栏只展示本模块的分类夹', (WidgetTester tester) async {
    final manager = FavoritesManager();
    await manager.init();
    await manager.createGroup('追番', type: anime);
    await manager.createGroup('在看漫画', type: manga);

    await tester.pumpWidget(
      wrap(
        manager: manager,
        child: FavoriteGroupBar(
          sourceType: anime,
          selectedGroupIds: const <String>{},
          onChanged: (_) {},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('追番'), findsOneWidget);
    expect(find.text('在看漫画'), findsNothing);
  });

  testWidgets('隐藏的分类不在分组栏显示', (WidgetTester tester) async {
    final manager = FavoritesManager();
    await manager.init();
    final hiddenGroup = (await manager.createGroup('已隐藏夹', type: anime))!;
    await manager.createGroup('可见夹', type: anime);
    await manager.setGroupHidden(hiddenGroup.id, true);

    await tester.pumpWidget(
      wrap(
        manager: manager,
        child: FavoriteGroupBar(
          sourceType: anime,
          selectedGroupIds: const <String>{},
          onChanged: (_) {},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('可见夹'), findsOneWidget);
    expect(find.text('已隐藏夹'), findsNothing);

    // 管理面板中仍可见（用于恢复显示）。
    await tester.tap(find.text('管理分组'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.textContaining('已隐藏夹'), findsOneWidget);
  });
}

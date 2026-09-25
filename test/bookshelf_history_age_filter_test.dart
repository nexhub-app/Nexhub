/// 书架历史 Tab 年龄限制过滤测试。
///
/// 开启年龄限制时，R18（mature）源的历史条目自动从历史列表隐藏；
/// 关闭后自动恢复（过滤仅在展示层，不动持久化数据）。
/// sourceId 为空 / 源已卸载（无法判定）的条目不受影响。
library;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/history/history_manager.dart';
import 'package:nexhub/core/models/bookshelf_filter.dart';
import 'package:nexhub/core/models/media_item.dart';
import 'package:nexhub/core/models/plugin_config.dart';
import 'package:nexhub/core/services/source_repository.dart';
import 'package:nexhub/core/widgets/bookshelf_content.dart';
import 'package:nexhub/core/widgets/library_shell.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const SourceType manga = SourceType.mangaSource;

SourceRepository _repo() => SourceRepository.fromJsonList(<Map<String, dynamic>>[
      {
        'id': 'manga_normal',
        'name': 'Normal Manga',
        'type': 'mangaSource',
        'site': {
          'domain': 'https://a.example.com',
          'baseUrl': 'https://a.example.com',
        },
        'parser': {'type': 'builtin'},
        'routes': {},
        'enabled': true,
      },
      {
        'id': 'manga_r18',
        'name': 'R18 Manga',
        'type': 'mangaSource',
        'ageRating': 'mature',
        'site': {
          'domain': 'https://b.example.com',
          'baseUrl': 'https://b.example.com',
        },
        'parser': {'type': 'builtin'},
        'routes': {},
        'enabled': true,
      },
    ]);

Widget _wrap(SourceRepository repo, HistoryManager history) =>
    MultiProvider(
      providers: [
        ChangeNotifierProvider<SourceRepository>.value(value: repo),
        ChangeNotifierProvider<HistoryManager>.value(value: history),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        supportedLocales: const <Locale>[Locale('zh'), Locale('en')],
        localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: const Scaffold(
          body: BookshelfContent(
            sourceType: manga,
            subTab: LibrarySubTab.history,
            emptyIcon: Icons.history,
            emptyMessage: 'empty',
            filter: BookshelfFilter(),
          ),
        ),
      ),
    );

Future<void> _seedHistory(HistoryManager history) async {
  await history.addHistory(
    const MediaItem(id: 'item_normal', title: '普通漫画A', sourceId: 'manga_normal'),
    sourceType: manga,
  );
  await history.addHistory(
    const MediaItem(id: 'item_r18', title: 'R18漫画B', sourceId: 'manga_r18'),
    sourceType: manga,
  );
  // sourceId 为空（本地/导入内容）：不受年龄限制过滤影响。
  await history.addHistory(
    const MediaItem(id: 'item_local', title: '本地漫画C'),
    sourceType: manga,
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('开启年龄限制：R18 源历史隐藏，普通与无源条目可见',
      (WidgetTester tester) async {
    final repo = _repo();
    final history = HistoryManager();
    await history.init();
    await _seedHistory(history);

    await tester.pumpWidget(_wrap(repo, history));
    await tester.pumpAndSettle();

    expect(find.text('普通漫画A'), findsOneWidget);
    expect(find.text('本地漫画C'), findsOneWidget);
    expect(find.text('R18漫画B'), findsNothing);
  });

  testWidgets('切换开关即时隐藏/恢复（展示层过滤，不改持久化数据）',
      (WidgetTester tester) async {
    final repo = _repo();
    final history = HistoryManager();
    await history.init();
    await _seedHistory(history);

    await tester.pumpWidget(_wrap(repo, history));
    await tester.pumpAndSettle();
    expect(find.text('R18漫画B'), findsNothing);

    // 关闭年龄限制 → 自动恢复显示。
    repo.setAgeRestrictionEnabled(false);
    await tester.pumpAndSettle();
    expect(find.text('R18漫画B'), findsOneWidget);

    // 重新开启 → 再次隐藏。
    repo.setAgeRestrictionEnabled(true);
    await tester.pumpAndSettle();
    expect(find.text('R18漫画B'), findsNothing);

    // 持久化数据未被动过：条目仍在 manager 缓存中。
    expect(history.findById('item_r18', sourceType: manga), isNotNull);
  });

  testWidgets('源已卸载（无法判定分级）的条目保持可见',
      (WidgetTester tester) async {
    final repo = _repo();
    final history = HistoryManager();
    await history.init();
    await history.addHistory(
      const MediaItem(id: 'item_orphan', title: '孤儿漫画D',
          sourceId: 'manga_uninstalled'),
      sourceType: manga,
    );

    await tester.pumpWidget(_wrap(repo, history));
    await tester.pumpAndSettle();

    expect(find.text('孤儿漫画D'), findsOneWidget);
  });
}

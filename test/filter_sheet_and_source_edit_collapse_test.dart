// 筛选面板分组折叠懒加载 + 源编辑页模块化折叠 的行为测试。
//
// 覆盖：
// 1. 动态筛选 Sheet：大配置默认折叠（懒加载，折叠分组不构建选项 chips）、
//    小配置默认全展开（保留旧版一次看全的体验）、有选中值的分组自动展开、
//    展开→选值→应用 回调透传。
// 2. 源编辑页：默认全部折叠、展开才出现编辑框（懒加载）、折叠再展开
//    编辑内容不丢、保存合并各模块并整体替换源。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nexhub/core/models/plugin_config.dart';
import 'package:nexhub/core/services/source_repository.dart';
import 'package:nexhub/core/theme/app_theme.dart';
import 'package:nexhub/core/widgets/online_filter_sheet.dart';
import 'package:nexhub/features/sources/presentation/source_edit_screen.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget appHost({required WidgetBuilder home, SourceRepository? repo}) {
  final child = MaterialApp(
    theme: AppTheme.light(),
    locale: const Locale('zh'),
    supportedLocales: const <Locale>[Locale('zh'), Locale('en')],
    localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
      AppLocalizations.delegate,
      ...GlobalMaterialLocalizations.delegates,
    ],
    home: Scaffold(body: Builder(builder: home)),
  );
  // 源编辑页保存路径会 context.read<SourceRepository>()，须挂在 MaterialApp 之上。
  if (repo == null) return child;
  return ChangeNotifierProvider<SourceRepository>.value(value: repo, child: child);
}

FilterGroupConfig group(
  String id,
  String title,
  int optionCount, {
  bool multiSelect = true,
  String labelPrefix = '选项',
}) =>
    FilterGroupConfig(
      id: id,
      title: title,
      param: 'keyword',
      multiSelect: multiSelect,
      options: List<FilterOptionConfig>.generate(
        optionCount,
        (i) => FilterOptionConfig(value: 'v$i', label: '$labelPrefix$i'),
      ),
    );

Future<void> openSheet(
  WidgetTester tester, {
  required List<FilterGroupConfig> groups,
  DynamicOnlineFilter? initial,
  required ValueChanged<DynamicOnlineFilter> onApply,
}) async {
  await tester.pumpWidget(appHost(
    home: (ctx) => Center(
      child: TextButton(
        onPressed: () => showDynamicFilterSheet(
          ctx,
          groups: groups,
          initial: initial ?? const DynamicOnlineFilter(),
          onApply: onApply,
        ),
        child: const Text('OPEN_SHEET'),
      ),
    ),
  ));
  await tester.tap(find.text('OPEN_SHEET'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('动态筛选：大配置默认折叠，选项懒加载（展开才构建 chips）',
      (WidgetTester tester) async {
    // 总选项数 140 > 60 阈值 → 全部折叠。
    await openSheet(
      tester,
      groups: <FilterGroupConfig>[
        group('category', '分类', 20),
        group('tag', '标签', 120),
      ],
      onApply: (_) {},
    );

    // 分组标题可见，但折叠分组的选项 chips 完全未构建。
    expect(find.text('标签'), findsOneWidget);
    expect(find.text('分类'), findsOneWidget);
    expect(find.text('选项0'), findsNothing);

    // 展开标签分组后选项才构建。
    await tester.tap(find.text('标签'));
    await tester.pumpAndSettle();
    expect(find.text('选项0'), findsOneWidget);
  });

  testWidgets('动态筛选：小配置默认全展开（保留旧版体验）',
      (WidgetTester tester) async {
    await openSheet(
      tester,
      groups: <FilterGroupConfig>[group('category', '分类', 10)],
      onApply: (_) {},
    );

    expect(find.text('选项0'), findsOneWidget);
  });

  testWidgets('动态筛选：已有选中值的分组自动展开，其余折叠',
      (WidgetTester tester) async {
    await openSheet(
      tester,
      groups: <FilterGroupConfig>[
        group('category', '分类', 20, labelPrefix: '分类项'),
        group('tag', '标签', 120, labelPrefix: '标签项'),
      ],
      initial: const DynamicOnlineFilter(selections: <DynamicFilterSelection>[
        DynamicFilterSelection(groupId: 'tag', param: 'keyword', value: 'v1'),
      ]),
      onApply: (_) {},
    );

    // tag 有选中 → 自动展开；category 无选中 → 折叠。
    expect(find.text('标签项1'), findsOneWidget);
    expect(find.text('分类项0'), findsNothing);

    // 折叠箭头必须贴行右缘（摘要出现时不得把箭头顶离右缘）。
    final headerRow =
        find.ancestor(of: find.text('标签'), matching: find.byType(Row)).first;
    final rowRect = tester.getRect(headerRow);
    final iconRect = tester.getRect(find.descendant(
      of: headerRow,
      matching: find.byIcon(Icons.expand_more_rounded),
    ));
    expect(rowRect.right - iconRect.right, closeTo(0, 1.0));
  });

  testWidgets('动态筛选：展开→选值→应用，回调透传选中值',
      (WidgetTester tester) async {
    DynamicOnlineFilter? applied;
    await openSheet(
      tester,
      groups: <FilterGroupConfig>[group('tag', '标签', 120)],
      onApply: (f) => applied = f,
    );

    await tester.tap(find.text('标签'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('选项3'));
    await tester.pumpAndSettle();
    // 120 个 chip 展开后「应用」按钮在可视区下方，先滚动到可见再点。
    await tester.ensureVisible(find.text('应用'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();

    expect(applied, isNotNull);
    expect(applied!.selections.length, 1);
    expect(applied!.selections.first.groupId, 'tag');
    expect(applied!.selections.first.value, 'v3');
  });

  testWidgets('源编辑页：默认全折叠，展开才出现编辑框，折叠再展开编辑不丢',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final source = PluginConfig.fromJson(<String, dynamic>{
      'id': 'test_src',
      'name': '测试源',
      'type': 'mangaSource',
      'site': <String, dynamic>{'baseUrl': 'https://example.com'},
    });
    final repo = SourceRepository(<PluginConfig>[]);
    await tester.pumpWidget(appHost(
      repo: repo,
      home: (ctx) => Center(
        child: TextButton(
          onPressed: () => Navigator.of(ctx).push(MaterialPageRoute<void>(
            builder: (_) => SourceEditScreen(source: source),
          )),
          child: const Text('OPEN_EDIT'),
        ),
      ),
    ));
    await tester.tap(find.text('OPEN_EDIT'));
    await tester.pumpAndSettle();

    // 默认全部折叠：基础字段页签无编辑框；site 在「站点解析」页签。
    expect(find.byType(TextField), findsNothing);
    expect(find.text('基础字段'), findsOneWidget);
    expect(find.text('站点解析'), findsOneWidget);
    await tester.tap(find.text('站点解析'));
    await tester.pumpAndSettle();
    expect(find.text('site'), findsOneWidget);

    // 折叠箭头必须贴卡片右缘（留出卡片内边距）。
    final cardRect = tester.getRect(
      find.byKey(const ValueKey<String>('section-card-site')),
    );
    final iconRect = tester.getRect(find.descendant(
      of: find.byKey(const ValueKey<String>('section-card-site')),
      matching: find.byIcon(Icons.expand_more_rounded),
    ));
    expect(cardRect.right - iconRect.right, closeTo(12.0, 1.0));

    // 展开才构建编辑框（懒加载），内容为该模块美化 JSON。
    await tester.tap(find.text('site'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(find.textContaining('"baseUrl"'), findsOneWidget);

    // 编辑 → 折叠 → 再展开：编辑内容保留（控制器不销毁）。
    await tester.enterText(
      find.byType(TextField),
      '{"baseUrl": "https://edited.com"}',
    );
    await tester.pump();
    await tester.tap(find.text('site'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.text('site'));
    await tester.pumpAndSettle();
    expect(find.textContaining('edited.com'), findsOneWidget);

    // 保存：合并模块 JSON 整体替换源，保存后返回上一页。
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('OPEN_EDIT'), findsOneWidget);
    expect(repo.importedSources.single.site.baseUrl, 'https://edited.com');
  });

  testWidgets('源编辑页：模块 JSON 非法时保存被拦截并定位到出错模块',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final source = PluginConfig.fromJson(<String, dynamic>{
      'id': 'test_src',
      'name': '测试源',
      'type': 'mangaSource',
      'site': <String, dynamic>{'baseUrl': 'https://example.com'},
    });
    await tester.pumpWidget(appHost(
      repo: SourceRepository(<PluginConfig>[]),
      home: (ctx) => Center(
        child: TextButton(
          onPressed: () => Navigator.of(ctx).push(MaterialPageRoute<void>(
            builder: (_) => SourceEditScreen(source: source),
          )),
          child: const Text('OPEN_EDIT'),
        ),
      ),
    ));
    await tester.tap(find.text('OPEN_EDIT'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('站点解析'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('site'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'not-json');
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    // 保存被拦截：仍在编辑页，出错模块自动展开并带 errorText。
    expect(find.text('OPEN_EDIT'), findsNothing);
    expect(find.textContaining('not-json'), findsOneWidget);
  });
}

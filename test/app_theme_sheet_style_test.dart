// 全局列表弹窗样式基线：底部弹层与浮层菜单去阴影 + 圆角。
// 需求：「所有的列表弹窗都要删去阴影，增加圆角」——在主题层统一兜底，
// 各 showModalBottomSheet / PopupMenuButton 调用点未显式传样式时自动继承。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/theme/app_theme.dart';
import 'package:nexhub/core/theme/app_tokens.dart';

void main() {
  final ThemeData Function() factories = AppTheme.light;
  final List<ThemeData Function()> all = <ThemeData Function()>[
    AppTheme.light,
    AppTheme.dark,
  ];

  test('AppTheme 亮/暗主题的 bottomSheetTheme 去阴影+圆角+裁剪', () {
    for (final ThemeData theme in all.map((f) => f())) {
      final BottomSheetThemeData sheet = theme.bottomSheetTheme;
      expect(sheet.elevation, 0, reason: '弹层阴影必须为 0（含 modal）');
      expect(sheet.modalElevation, 0, reason: 'modal 弹层阴影必须为 0');
      expect(sheet.clipBehavior, Clip.antiAlias, reason: '贴边内容须裁进圆角');
      final RoundedRectangleBorder? shape =
          sheet.shape as RoundedRectangleBorder?;
      expect(shape, isNotNull);
      expect(
        shape!.borderRadius,
        BorderRadius.vertical(top: Radius.circular(AppTokens.radiusLg)),
      );
    }
  });

  test('AppTheme 亮/暗主题的 popupMenuTheme 去阴影+圆角', () {
    for (final ThemeData theme in all.map((f) => f())) {
      final PopupMenuThemeData menu = theme.popupMenuTheme;
      expect(menu.elevation, 0, reason: '三点菜单阴影必须为 0');
      final RoundedRectangleBorder? shape =
          menu.shape as RoundedRectangleBorder?;
      expect(shape, isNotNull);
      expect(
        shape!.borderRadius,
        BorderRadius.all(Radius.circular(AppTokens.radiusMd)),
      );
    }
  });

  // 覆盖 factories 引用避免未使用告警（light/dark 已在上方列表覆盖）。
  test('AppTheme.light 可直接构造', () {
    expect(factories(), isA<ThemeData>());
  });

  testWidgets('showModalBottomSheet 默认继承主题：无阴影+圆角+裁剪', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext ctx) => Center(
              child: TextButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: ctx,
                  builder: (_) => const SizedBox(
                    height: 120,
                    child: Center(child: Text('sheet-content')),
                  ),
                ),
                child: const Text('open-sheet'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open-sheet'));
    await tester.pumpAndSettle();

    final Material material = tester.widget<Material>(
      find
          .descendant(of: find.byType(BottomSheet), matching: find.byType(Material))
          .first,
    );
    expect(material.elevation, 0, reason: '弹层 Material 阴影必须为 0');
    expect(material.clipBehavior, Clip.antiAlias);
    final RoundedRectangleBorder? shape =
        material.shape as RoundedRectangleBorder?;
    expect(shape, isNotNull);
    expect(
      shape!.borderRadius,
      BorderRadius.vertical(top: Radius.circular(AppTokens.radiusLg)),
    );
  });

  testWidgets('未显式传样式的 PopupMenuButton 继承主题：无阴影', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Center(
            child: PopupMenuButton<String>(
              onSelected: (_) {},
              itemBuilder: (BuildContext ctx) => const <PopupMenuEntry<String>>[
                PopupMenuItem<String>(value: 'a', child: Text('item-a')),
                PopupMenuItem<String>(value: 'b', child: Text('item-b')),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();

    // 菜单 Material 是页面上唯一带 shape 的（AppBar/Scaffold 均无 shape）。
    final Material material = tester.widgetList<Material>(
      find.byWidgetPredicate((Widget w) => w is Material && w.shape != null),
    ).first;
    expect(material.elevation, 0, reason: '浮层菜单阴影必须为 0');
  });
}

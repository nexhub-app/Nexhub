/// 缓存管理页冒烟测试：验证新设置页能构建、六类缓存行齐全、滑块/开关可交互，
/// 且清理动作不会抛异常（IO 全部 best-effort）。
///
/// 这是防止「页面一打开就崩 / 分类漏项」的回归网。
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nexhub/core/settings/advanced_settings.dart';
import 'package:nexhub/core/storage/cache_inventory.dart';
import 'package:nexhub/features/settings/presentation/settings_cache_manager_screen.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory tmp;

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('nexhub_cache_ui_test_');
  });

  tearDownAll(() async {
    try {
      await tmp.delete(recursive: true);
    } on Object {
      // 忽略。
    }
  });

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // path_provider 无原生实现：注入临时目录，让缓存统计/清理走真实文件系统
    // （否则 getTemporaryDirectory 抛 MissingPluginException，页面统计全程失败）。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => tmp.path,
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        // 与应用一致：AppLocalizations.delegate + material_ui 的
        // GlobalMaterialLocalizations（MaterialApp 的 AppBar 需要它，
        // 否则 debugCheckHasMaterialLocalizations 断言失败）。
        localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
          AppLocalizations.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ],
        supportedLocales: const <Locale>[Locale('zh'), Locale('en')],
        home: const SettingsCacheManagerScreen(),
      ),
    );
    // 占用统计是异步 IO：给真实事件循环让出时间，再泵一帧。
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    });
    await tester.pumpAndSettle();
  }

  testWidgets('缓存管理页可构建且六类缓存入口齐全', (WidgetTester tester) async {
    await pumpScreen(tester);

    expect(find.text('缓存管理'), findsWidgets);
    // 六个类别行必须都在（缺一类 = 分类需求未达成）。
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

  testWidgets('自动清理开关与两个阈值可交互', (WidgetTester tester) async {
    await pumpScreen(tester);

    // 「缓存自动清理」卡片在列表下方：ListView 懒构建，必须先滚到可见。
    await tester.scrollUntilVisible(
      find.text('自动清理缓存'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    // 默认开启：应显示年龄与容量两个滑块。
    expect(find.text('缓存保留时长'), findsOneWidget);
    expect(find.text('缓存总容量上限'), findsOneWidget);

    // 关闭开关 → 阈值滑块收起（关闭后阈值不参与清理，UI 同步隐藏）。
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect(find.text('缓存保留时长'), findsNothing);
    expect(find.text('缓存总容量上限'), findsNothing);

    // 设置已持久化。
    final AdvancedSettings saved = await AdvancedSettingsStore.instance.load();
    expect(saved.autoCacheCleanEnabled, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('清理图片缓存不抛异常（best-effort IO）', (WidgetTester tester) async {
    await pumpScreen(tester);

    // 直接调用底层清理（跳过确认弹窗，弹窗本身在其它用例覆盖）。
    int freed = -1;
    await tester.runAsync(() async {
      freed = await CacheInventory.clear(CacheCategory.images);
    });
    expect(freed, greaterThanOrEqualTo(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('占用统计对任何类别都不抛异常', (WidgetTester tester) async {
    CacheUsageSnapshot? snap;
    await tester.runAsync(() async {
      snap = await CacheInventory.snapshot();
    });
    expect(snap, isNotNull);
    expect(snap!.usages.length, CacheCategory.values.length);
    // WebView 是唯一标记「无法统计」的类别。
    expect(snap!.usageOf(CacheCategory.webview).unknown, isTrue);
    expect(snap!.usageOf(CacheCategory.images).unknown, isFalse);
  });
}

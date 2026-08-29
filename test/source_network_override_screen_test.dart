/// 源级网络覆盖页 Widget 测试（导入沿用源 network 块）。
///
/// - 源 JSON 自带 `network` 块（代理 manual + hosts）：打开覆盖页直接沿用
///   源自带配置（开关开启、字段回填、显示「已自动沿用」提示），无需重新配置。
/// - 源无 `network` 块：各字段为空、显示「继承全局」，不显示沿用提示。
/// - 保存：沿用值固化为用户覆盖（写入 [SourceNetworkOverrideStore]）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/models/plugin_config.dart';
import 'package:nexhub/core/network/network_config_service.dart';
import 'package:nexhub/core/network/source_network_override_store.dart';
import 'package:nexhub/features/sources/presentation/source_network_override_screen.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

PluginConfig _sourceWithNetwork(Map<String, dynamic> network) =>
    PluginConfig.fromJson(<String, dynamic>{
      'id': 'net_seed_test',
      'name': '自带网络配置源',
      'type': 'mangaSource',
      'site': <String, dynamic>{
        'domain': 'example.com',
        'baseUrl': 'https://example.com',
      },
      if (network.isNotEmpty) 'network': network,
    });

Widget _wrap(PluginConfig source) => MaterialApp(
      locale: const Locale('zh'),
      supportedLocales: const <Locale>[Locale('zh'), Locale('en')],
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: SourceNetworkOverrideScreen(source: source),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // onSourceOverrideChanged 会重建 HttpFetcher（读取高级设置）。
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() async {
    // 清理单例缓存，避免用例间串扰。
    await SourceNetworkOverrideStore.instance.remove('net_seed_test');
    NetworkConfigService.instance.onSourceOverrideChanged();
  });

  testWidgets('源自带 network 块：覆盖页直接沿用，无需重新配置',
      (WidgetTester tester) async {
    final source = _sourceWithNetwork(<String, dynamic>{
      'proxy': <String, dynamic>{
        'mode': 'manual',
        'protocol': 'http',
        'host': '127.0.0.1',
        'port': 7890,
        'username': '',
      },
      'hosts': <Map<String, dynamic>>[
        <String, dynamic>{'ip': '1.2.3.4', 'host': 'cdn.example.com'},
      ],
    });

    await tester.pumpWidget(_wrap(source));
    await tester.pumpAndSettle();

    // 沿用提示可见。
    expect(find.textContaining('已自动沿用'), findsOneWidget);
    // 代理方面随源配置开启，字段回填源值。
    expect(find.text('127.0.0.1'), findsOneWidget);
    expect(find.text('7890'), findsOneWidget);
    // Hosts 方面同样开启并展示源自带条目（需滚动到视口内）。
    await tester.scrollUntilVisible(
      find.textContaining('1.2.3.4'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('1.2.3.4'), findsOneWidget);
  });

  testWidgets('源无 network 块：字段为空并继承全局', (WidgetTester tester) async {
    await tester.pumpWidget(_wrap(_sourceWithNetwork(const <String, dynamic>{})));
    await tester.pumpAndSettle();

    expect(find.textContaining('已自动沿用'), findsNothing);
    expect(find.text('继承全局'), findsWidgets);
    expect(find.text('127.0.0.1'), findsNothing);
  });

  testWidgets('保存把沿用值固化为用户覆盖', (WidgetTester tester) async {
    final source = _sourceWithNetwork(<String, dynamic>{
      'proxy': <String, dynamic>{
        'mode': 'manual',
        'protocol': 'http',
        'host': '127.0.0.1',
        'port': 7890,
        'username': '',
      },
    });
    expect(SourceNetworkOverrideStore.instance.get('net_seed_test'), isNull);

    await tester.pumpWidget(_wrap(source));
    await tester.pumpAndSettle();
    // 保存按钮在长列表底部，先滚进视口再点击。
    await tester.scrollUntilVisible(
      find.text('保存'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final saved = SourceNetworkOverrideStore.instance.get('net_seed_test');
    expect(saved, isNotNull);
    expect(saved!.proxy?.host, '127.0.0.1');
    expect(saved.proxy?.port, 7890);
  });
}

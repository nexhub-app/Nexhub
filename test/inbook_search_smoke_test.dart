// 冒烟测试：渲染书内搜索底部抽屉，验证打开阶段（build）不抛异常。
// 用于在无 logcat 的情况下复现「小说阅读器点击搜索按钮就卡退」。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:nexhub/core/models/episode.dart';
import 'package:nexhub/core/scraper/media_api_service.dart';
import 'package:nexhub/core/resolver/resolver_registry.dart';
import 'package:nexhub/features/novel/presentation/novel_in_book_search_sheet.dart';
import 'package:nexhub/core/novel/novel_chinese_converter.dart';

void main() {
  testWidgets('in-book search sheet opens without throwing', (tester) async {
    final chapters = <Episode>[
      const Episode(id: 'c1', title: '第一章', url: 'https://example.com/1'),
      const Episode(id: 'c2', title: '第二章', url: 'https://example.com/2'),
    ];
    final service = MediaApiService(ResolverRegistry.instance);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                await showNovelInBookSearchSheet(
                  context: context,
                  chapters: chapters,
                  currentChapterIndex: 0,
                  service: service,
                  source: null,
                  novelId: 'test-novel',
                  convertMode: ChineseConvertMode.none,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 打开抽屉（走真实 showModalBottomSheet 路由 build 路径）
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 抽屉根 DraggableScrollableSheet 应存在，且能找到搜索输入框
    expect(find.byType(DraggableScrollableSheet), findsOneWidget);
    expect(find.byType(TextField), findsWidgets);
  });
}

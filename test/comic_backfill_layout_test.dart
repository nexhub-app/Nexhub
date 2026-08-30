/// F7（漫画排版回填）单元测试：CJK 断行 / 禁则 / 拉丁保词 / 自适应字号 /
/// 竖排启发式 / 偏好字段回环。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/ai/backfill_layout.dart';
import 'package:nexhub/core/comic/models/reader_preferences.dart';

void main() {
  group('F7 CJK 断行', () {
    test('全角宽度按字号估算，超宽换行', () {
      // 每字 10px，5 字宽 50。
      final lines = BackfillLayout.breakLine('一二三四五六七', 50, 10);
      expect(lines.first, '一二三四五');
      expect(lines, hasLength(2));
    });

    test('拉丁单词保持完整不拆分', () {
      final lines = BackfillLayout.breakLine('Hello World 今日', 90, 10);
      // World 不应被拆成 W/orld。
      expect(lines.join('|'), contains('World'));
      expect(lines.join('|').split('\n'), isNotEmpty);
      for (final line in lines) {
        expect(line.contains('W') && line.contains('orld') == false || line.contains('World'),
            isTrue,
            reason: 'World 不应被拆开: $lines');
      }
    });

    test('行首禁则：收尾标点不落行首', () {
      // 「一二三。」宽 40：三之后换行时句号不能落行首。
      final lines = BackfillLayout.breakLine('一二三四。', 40, 10);
      for (final line in lines) {
        expect(line.startsWith('。'), isFalse, reason: '行首禁则: $lines');
      }
    });

    test('行尾禁则：起始标点不落行尾', () {
      final lines = BackfillLayout.breakLine('一二「三四五', 40, 10);
      for (final line in lines) {
        expect(line.endsWith('「'), isFalse, reason: '行尾禁则: $lines');
      }
    });
  });

  group('F7 字号自适应', () {
    test('文本越长字号越小；短文本可到大字号', () {
      final big = BackfillLayout.layout(
          text: '你好', boxW: 200, boxH: 60, maxFont: 48);
      final small = BackfillLayout.layout(
          text: '这是一段非常长的漫画台词内容需要更多行才能放进气泡框里',
          boxW: 200,
          boxH: 60,
          maxFont: 48);
      expect(big.fontSize, greaterThan(small.fontSize));
      expect(small.fontSize, greaterThanOrEqualTo(8));
      expect(big.fontSize, lessThanOrEqualTo(48));
    });

    test('回填结果总高不超 bbox（估算口径）', () {
      final r = BackfillLayout.layout(
          text: '段落一很长需要换行段落二也很长同样需要换行处理',
          boxW: 120,
          boxH: 80);
      expect(r.lines.length * r.fontSize * 1.22, lessThanOrEqualTo(80.001));
    });

    test('空文本回落最小字号', () {
      final r = BackfillLayout.layout(text: '', boxW: 100, boxH: 50);
      expect(r.fontSize, 8);
    });
  });

  group('F7 竖排启发式', () {
    test('高窄框 + CJK 文本判为疑似竖排', () {
      expect(
        BackfillLayout.looksVertical(
            boxW: 100, boxH: 200, sourceText: 'これは縦書きです'),
        isTrue,
      );
      expect(
        BackfillLayout.looksVertical(
            boxW: 200, boxH: 100, sourceText: 'これは横書き'),
        isFalse,
      );
      expect(
        BackfillLayout.looksVertical(boxW: 100, boxH: 200, sourceText: 'Latin'),
        isFalse,
      );
    });
  });

  group('F7 阅读器偏好字段', () {
    test('translationBackfill JSON 回环（默认 false）', () {
      const prefs = ReaderPreferences();
      expect(prefs.translationBackfill, isFalse);
      final restored = ReaderPreferences.fromJson(
          jsonDecode(jsonEncode(prefs.toJson())) as Map<String, dynamic>);
      expect(restored.translationBackfill, isFalse);
      final enabled = prefs.copyWith(translationBackfill: true);
      final restored2 = ReaderPreferences.fromJson(
          jsonDecode(jsonEncode(enabled.toJson())) as Map<String, dynamic>);
      expect(restored2.translationBackfill, isTrue);
    });
  });
}

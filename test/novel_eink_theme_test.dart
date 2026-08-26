import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/novel/novel_reader_preferences.dart';
import 'package:nexhub/core/theme/reader_tokens.dart';

void main() {
  group('B3 墨水屏背景主题化', () {
    test('选中墨水屏预设（末位索引）时 isEInkBackground 为真', () {
      const prefs = NovelReaderPreferences(
        bgPresetIndex: ReaderTokens.eInkPresetIndex,
      );
      expect(prefs.isEInkBackground, isTrue);
    });

    test('其他预设 / 自定义背景不触发墨水屏主题', () {
      const plain = NovelReaderPreferences(bgPresetIndex: 2);
      expect(plain.isEInkBackground, isFalse);

      final custom = const NovelReaderPreferences(
        bgPresetIndex: ReaderTokens.eInkPresetIndex,
      ).copyWith(customBgColor: 0xFFF5F5F5);
      expect(custom.isEInkBackground, isFalse);
    });

    test('浅色背景下正文联动炭灰，强调色联动朱批暗红', () {
      const prefs = NovelReaderPreferences(
        bgPresetIndex: ReaderTokens.eInkPresetIndex,
      );
      final bg = prefs.resolveBackgroundColor(false);
      expect(bg.computeLuminance() > 0.5, isTrue);
      expect(prefs.resolveTextColor(bg), ReaderTokens.eInkTextColor);
      expect(prefs.resolveEmphasisColor(), ReaderTokens.eInkEmphasisColor);
    });

    test('夜间压暗背景后回退亮色文字（保持可读）', () {
      const prefs = NovelReaderPreferences(
        bgPresetIndex: ReaderTokens.eInkPresetIndex,
      );
      final nightBg = prefs.resolveBackgroundColor(true);
      expect(nightBg.computeLuminance() < 0.5, isTrue);
      expect(prefs.resolveTextColor(nightBg), const Color(0xFFE0E0E0));
    });

    test('显式自定义文字/强调色优先级高于主题联动', () {
      final prefs = const NovelReaderPreferences(
        bgPresetIndex: ReaderTokens.eInkPresetIndex,
      ).copyWith(customTextColor: 0xFF123456, emphasisColor: 0xFF654321);
      expect(
        prefs.resolveTextColor(const Color(0xFFFFFFFF)),
        const Color(0xFF123456),
      );
      expect(prefs.resolveEmphasisColor(), const Color(0xFF654321));
    });

    test('非墨水屏预设行为不变（回归）', () {
      const prefs = NovelReaderPreferences(bgPresetIndex: 2);
      final bg = prefs.resolveBackgroundColor(false);
      expect(prefs.resolveTextColor(bg), const Color(0xFF1A1A1A));
      expect(prefs.resolveEmphasisColor(), ReaderTokens.emphasisDefault);
    });
  });
}

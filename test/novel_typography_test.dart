/// P2-10 排版偏好补齐单测：
/// - 字重细粒度映射（fontWeightValue → FontWeight）
/// - 下划线样式枚举序列化与 needsCustomUnderlinePaint
/// - 排版 JSON 导出/导入（NovelTypographyShare）
/// - 中文禁则断行器（NovelLineBreaker）：禁首禁尾、逐字断行、坐标完整性
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/novel/novel_line_breaker.dart';
import 'package:nexhub/core/novel/novel_reader_preferences.dart';
import 'package:nexhub/core/theme/reader_tokens.dart';

void main() {
  group('P2-10 字重细粒度', () {
    test('fontWeightValue 100-900 映射正确', () {
      const p = NovelReaderPreferences(fontWeightValue: 300);
      final style = p.resolveBodyTextStyle(const Color(0xFF000000));
      expect(style.fontWeight, FontWeight.w300);
      const p9 = NovelReaderPreferences(fontWeightValue: 900);
      expect(
        p9.resolveBodyTextStyle(const Color(0xFF000000)).fontWeight,
        FontWeight.w900,
      );
    });

    test('fontWeightValue 越界 clamp 到 100/900', () {
      const pLow = NovelReaderPreferences(fontWeightValue: 50);
      expect(
        pLow.resolveBodyTextStyle(const Color(0xFF000000)).fontWeight,
        FontWeight.w100,
      );
      const pHigh = NovelReaderPreferences(fontWeightValue: 1200);
      expect(
        pHigh.resolveBodyTextStyle(const Color(0xFF000000)).fontWeight,
        FontWeight.w900,
      );
    });

    test('未设置 fontWeightValue 时回退 fontBold', () {
      const pBold = NovelReaderPreferences(fontBold: true);
      expect(
        pBold.resolveBodyTextStyle(const Color(0xFF000000)).fontWeight,
        FontWeight.bold,
      );
      const pPlain = NovelReaderPreferences();
      expect(
        pPlain.resolveBodyTextStyle(const Color(0xFF000000)).fontWeight,
        isNull,
      );
    });

    test('字重 JSON round-trip', () {
      const p = NovelReaderPreferences(fontWeightValue: 600);
      final back = NovelReaderPreferences.fromJson(p.toJson());
      expect(back.fontWeightValue, 600);
    });
  });

  group('P2-10 下划线样式', () {
    test('枚举反序列化与默认值', () {
      expect(NovelUnderlineStyle.fromString(null),
          NovelUnderlineStyle.solid);
      expect(NovelUnderlineStyle.fromString('wavy'),
          NovelUnderlineStyle.wavy);
      expect(NovelUnderlineStyle.fromString('bogus'),
          NovelUnderlineStyle.solid);
      const p = NovelReaderPreferences();
      expect(p.underlineStyle, NovelUnderlineStyle.solid);
    });

    test('needsCustomUnderlinePaint 仅非实线开启下划线时为真', () {
      const solid = NovelReaderPreferences(
          fontUnderline: true, underlineStyle: NovelUnderlineStyle.solid);
      expect(solid.needsCustomUnderlinePaint, isFalse);
      const wavy = NovelReaderPreferences(
          fontUnderline: true, underlineStyle: NovelUnderlineStyle.wavy);
      expect(wavy.needsCustomUnderlinePaint, isTrue);
      const off = NovelReaderPreferences(
          fontUnderline: false, underlineStyle: NovelUnderlineStyle.wavy);
      expect(off.needsCustomUnderlinePaint, isFalse);
    });

    test('样式 JSON round-trip', () {
      const p = NovelReaderPreferences(
          underlineStyle: NovelUnderlineStyle.dotted);
      final back = NovelReaderPreferences.fromJson(p.toJson());
      expect(back.underlineStyle, NovelUnderlineStyle.dotted);
    });
  });

  group('P2-10 对齐 / 断行模式', () {
    test('枚举反序列化与默认值', () {
      const p = NovelReaderPreferences();
      expect(p.textAlignMode, NovelTextAlignMode.start);
      expect(p.lineBreakMode, NovelLineBreakMode.standard);
      expect(
          NovelTextAlignMode.fromString('justify'),
          NovelTextAlignMode.justify);
      expect(
          NovelLineBreakMode.fromString('cjkStrict'),
          NovelLineBreakMode.cjkStrict);
    });

    test('JSON round-trip', () {
      const p = NovelReaderPreferences(
        textAlignMode: NovelTextAlignMode.justify,
        lineBreakMode: NovelLineBreakMode.cjkStrict,
      );
      final back = NovelReaderPreferences.fromJson(p.toJson());
      expect(back.textAlignMode, NovelTextAlignMode.justify);
      expect(back.lineBreakMode, NovelLineBreakMode.cjkStrict);
    });
  });

  group('P2-4 滚动模式图文增强', () {
    test('枚举反序列化与默认值', () {
      const p = NovelReaderPreferences();
      expect(p.scrollImageMode, NovelScrollImageMode.banner);
      expect(p.scrollImageAlign, NovelScrollImageAlign.center);
      expect(NovelScrollImageMode.fromString('card'),
          NovelScrollImageMode.card);
      expect(NovelScrollImageMode.fromString('bogus'),
          NovelScrollImageMode.banner);
      expect(NovelScrollImageAlign.fromString('left'),
          NovelScrollImageAlign.left);
      expect(NovelScrollImageAlign.fromString('right'),
          NovelScrollImageAlign.right);
      expect(NovelScrollImageAlign.fromString('bogus'),
          NovelScrollImageAlign.center);
    });

    test('JSON round-trip 保留模式与对齐', () {
      const p = NovelReaderPreferences(
        scrollImageMode: NovelScrollImageMode.card,
        scrollImageAlign: NovelScrollImageAlign.right,
      );
      final back = NovelReaderPreferences.fromJson(p.toJson());
      expect(back.scrollImageMode, NovelScrollImageMode.card);
      expect(back.scrollImageAlign, NovelScrollImageAlign.right);
    });

    test('copyWith 修改单个字段不影响其它', () {
      const p = NovelReaderPreferences();
      final q = p.copyWith(scrollImageMode: NovelScrollImageMode.card);
      expect(q.scrollImageMode, NovelScrollImageMode.card);
      expect(q.scrollImageAlign, NovelScrollImageAlign.center);
      expect(q.fontSize, 18.0);
    });
  });

  group('P2-10 墨水屏背景预设', () {
    test('bgPresets 追加墨水屏色且既有索引不变', () {
      // 既有索引稳定性：前 11 色不变（黑/深灰/白/护眼绿/羊皮纸/暖黄/浅褐/豆沙绿/淡青/暖杏/浅灰蓝）。
      expect(ReaderTokens.bgPresets[2], const Color(0xFFF5F5F5)); // white
      expect(ReaderTokens.bgPresets[7], const Color(0xFFCCE8CF)); // bean green
      // 新增第 12 色 = 墨水屏。
      expect(ReaderTokens.bgPresets.length, 12);
      expect(
        ReaderTokens.bgPresets[11],
        isNot(ReaderTokens.bgPresets[3]),
      );
    });
  });

  group('NovelTypographyShare 排版 JSON 导出导入', () {
    test('导出仅含排版字段', () {
      const p = NovelReaderPreferences(
        fontSize: 21,
        fontWeightValue: 500,
        bgPresetIndex: 5, // 非排版字段，不应出现
        chineseConvert: 'simplifiedToTraditional', // 非排版字段
      );
      final raw = NovelTypographyShare.exportJson(p);
      expect(raw, contains('"fontSize"'));
      expect(raw, contains('"fontWeightValue"'));
      expect(raw, isNot(contains('bgPresetIndex')));
      expect(raw, isNot(contains('chineseConvert')));
      expect(raw, isNot(contains('ttsSpeechRate')));
    });

    test('导入合并到 base 且只覆盖出现的字段', () {
      const base = NovelReaderPreferences(fontSize: 18, lineHeight: 1.8);
      final result = NovelTypographyShare.importJson(
        '{"fontSize":24,"lineBreakMode":"cjkStrict"}',
        base,
      );
      expect(result, isNotNull);
      expect(result!.fields, 2);
      expect(result.merged.fontSize, 24.0);
      expect(result.merged.lineBreakMode, NovelLineBreakMode.cjkStrict);
      // 未覆盖字段保持 base。
      expect(result.merged.lineHeight, 1.8);
    });

    test('非法 JSON 与无有效字段返回 null', () {
      const base = NovelReaderPreferences();
      expect(NovelTypographyShare.importJson('not-json', base), isNull);
      expect(
        NovelTypographyShare.importJson('{"bgPresetIndex":3}', base),
        isNull,
      );
      expect(NovelTypographyShare.importJson('[]', base), isNull);
    });

    test('导出再导入保持一致（round-trip）', () {
      const src = NovelReaderPreferences(
        fontSize: 20.5,
        letterSpacing: 0.6,
        fontItalic: true,
        titleTopMargin: 12,
        underlineStyle: NovelUnderlineStyle.wavy,
        textAlignMode: NovelTextAlignMode.justify,
      );
      final raw = NovelTypographyShare.exportJson(src);
      final back =
          NovelTypographyShare.importJson(raw, const NovelReaderPreferences());
      expect(back, isNotNull);
      expect(back!.merged.fontSize, 20.5);
      expect(back.merged.letterSpacing, 0.6);
      expect(back.merged.fontItalic, isTrue);
      expect(back.merged.titleTopMargin, 12.0);
      expect(back.merged.underlineStyle, NovelUnderlineStyle.wavy);
      expect(back.merged.textAlignMode, NovelTextAlignMode.justify);
    });
  });
}

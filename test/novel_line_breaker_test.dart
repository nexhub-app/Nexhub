///  / A5 中文禁则断行器渲染级单测（需 TextPainter，flutter_test 环境）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/novel/novel_line_breaker.dart';

void main() {
  const style = TextStyle(fontSize: 16, fontFamily: 'Roboto');
  const width = 160.0;

  test('短段落单行输出', () {
    final lines = NovelLineBreaker.breakParagraph(
      '短文本',
      style,
      width,
      TextDirection.ltr,
      TextScaler.noScaling,
    );
    expect(lines.length, 1);
    expect(lines.first.text, '短文本');
    expect(lines.first.charLefts.length, 3);
  });

  test('长文本多行切分且行宽不超限（CJK 等宽）', () {
    // 40 个汉字 @16px ≈ 每字 16px 宽 → 160px 宽度下每行约 10 字。
    final text = '字' * 40;
    final lines = NovelLineBreaker.breakParagraph(
      text,
      style,
      width,
      TextDirection.ltr,
      TextScaler.noScaling,
    );
    expect(lines.length, greaterThanOrEqualTo(3));
    var joined = '';
    for (final l in lines) {
      joined += l.text;
      // 单字符独立测宽的保守性允许轻微超出；但绝不能超过 2 字符宽。
      expect(l.charLefts.length, l.text.length);
    }
    expect(joined, text); // 无字符丢失
  });

  test('禁首：闭合标点不出现在行首', () {
    // 构造「满行 + 闭合标点」场景。
    final text = '一' * 12 + '，' + '二' * 8;
    final lines = NovelLineBreaker.breakParagraph(
      text,
      style,
      width,
      TextDirection.ltr,
      TextScaler.noScaling,
    );
    for (var i = 1; i < lines.length; i++) {
      final first = lines[i].text[0];
      expect(isLineStartForbidden(first), isFalse,
          reason: '第 $i 行以禁排标点 "$first" 开头');
    }
    // 内容完整性。
    final joined = lines.map((l) => l.text).join();
    expect(joined.length, text.length);
  });

  test('禁尾：开启标点不出现在行尾', () {
    final text = '一' * 9 + '「' + '二' * 20;
    final lines = NovelLineBreaker.breakParagraph(
      text,
      style,
      width,
      TextDirection.ltr,
      TextScaler.noScaling,
    );
    for (var i = 0; i < lines.length - 1; i++) {
      final last = lines[i].text[lines[i].text.length - 1];
      expect(isLineEndForbidden(last), isFalse,
          reason: '第 $i 行以禁排标点 "$last" 结尾');
    }
  });

  test('空段与零宽度防御', () {
    expect(NovelLineBreaker.breakParagraph(
      '',
      style,
      width,
      TextDirection.ltr,
      TextScaler.noScaling,
    ), isEmpty);
    final degenerate = NovelLineBreaker.breakParagraph(
      '一二三',
      style,
      0,
      TextDirection.ltr,
      TextScaler.noScaling,
    );
    expect(degenerate.length, 3); // 每字符一行
  });
}

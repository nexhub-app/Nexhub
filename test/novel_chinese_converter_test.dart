import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/novel/novel_chinese_converter.dart';

/// E2 — 小说繁简转换：短语级最长匹配 + 排除词表。
///
/// 验证逐字转换之外的两个能力：
/// - **歧义纠偏**：一对多/单向误转词组（乾/後/里/发 等）按正确义项转换。
/// - **排除词**：登记为「自身→自身」的词组整体不转换（品牌/俚语等）。
/// 同时确认短语命中不影响其余字符的逐字转换。
void main() {
  group('ChineseConvertMode enum', () {
    test('fromString parses modes', () {
      expect(
        ChineseConvertMode.fromString('traditionalToSimplified'),
        ChineseConvertMode.traditionalToSimplified,
      );
      expect(
        ChineseConvertMode.fromString('simplifiedToTraditional'),
        ChineseConvertMode.simplifiedToTraditional,
      );
      expect(ChineseConvertMode.fromString(null), ChineseConvertMode.none);
      expect(ChineseConvertMode.fromString('garbage'), ChineseConvertMode.none);
    });
  });

  group('traditionalToSimplified phrase corrections', () {
    const mode = ChineseConvertMode.traditionalToSimplified;

    test('皇后 stays 皇后 (not 皇後)', () {
      expect(convertChinese('皇后', mode), '皇后');
      expect(convertChinese('太后', mode), '太后');
    });

    test('乾隆/乾坤/乾陵 keep 乾', () {
      expect(convertChinese('乾隆', mode), '乾隆');
      expect(convertChinese('乾坤', mode), '乾坤');
      expect(convertChinese('乾陵', mode), '乾陵');
    });

    test('故里/邻里/乡里 keep 里', () {
      expect(convertChinese('故里', mode), '故里');
      expect(convertChinese('邻里', mode), '邻里');
      expect(convertChinese('乡里', mode), '乡里');
    });

    test('exclusion 雪梨/芝士/魔法門 unchanged', () {
      expect(convertChinese('雪梨', mode), '雪梨');
      expect(convertChinese('芝士', mode), '芝士');
      expect(convertChinese('魔法門', mode), '魔法門');
    });

    test('phrase hit leaves surrounding chars char-level converted', () {
      // 愛→爱 在「皇后」之外仍逐字转换
      expect(convertChinese('皇后愛', mode), '皇后爱');
      expect(convertChinese('古老的故里', mode), '古老的故里');
    });
  });

  group('simplifiedToTraditional phrase corrections', () {
    const mode = ChineseConvertMode.simplifiedToTraditional;

    test('干部/干活/干线/骨干 use 幹 not 乾', () {
      expect(convertChinese('干部', mode), '幹部');
      expect(convertChinese('干活', mode), '幹活');
      expect(convertChinese('干线', mode), '幹線');
      expect(convertChinese('骨干', mode), '骨幹');
    });

    test('头发/理发/发型 use 髮 not 發', () {
      expect(convertChinese('头发', mode), '頭髮');
      expect(convertChinese('理发', mode), '理髮');
      expect(convertChinese('发型', mode), '髮型');
      expect(convertChinese('毛发', mode), '毛髮');
    });

    test('皇后/太后/后羿 keep 后', () {
      expect(convertChinese('皇后', mode), '皇后');
      expect(convertChinese('太后', mode), '太后');
      expect(convertChinese('后羿', mode), '后羿');
    });

    test('公里/里程/故里/邻里/里弄/乡里 keep 里', () {
      expect(convertChinese('公里', mode), '公里');
      expect(convertChinese('里程', mode), '里程');
      expect(convertChinese('故里', mode), '故里');
      expect(convertChinese('邻里', mode), '鄰里');
      expect(convertChinese('里弄', mode), '里弄');
      expect(convertChinese('乡里', mode), '鄉里');
    });

    test('exclusion 雪梨/芝士 unchanged', () {
      expect(convertChinese('雪梨', mode), '雪梨');
      expect(convertChinese('芝士', mode), '芝士');
    });

    test('phrase hit leaves other chars char-level converted', () {
      // 龙→龍 在「干部」之外仍逐字转换
      expect(convertChinese('干部龙', mode), '幹部龍');
      // 国→國 在「头发」之外仍逐字转换
      expect(convertChinese('国头发', mode), '國頭髮');
    });
  });

  group('char-level fallback still works', () {
    test('T2S single char', () {
      expect(
        convertChinese('愛', ChineseConvertMode.traditionalToSimplified),
        '爱',
      );
    });

    test('S2T single char', () {
      expect(
        convertChinese('龙', ChineseConvertMode.simplifiedToTraditional),
        '龍',
      );
    });

    test('none returns input', () {
      expect(convertChinese('皇后愛', ChineseConvertMode.none), '皇后愛');
      expect(convertChinese('', ChineseConvertMode.none), '');
    });

    test('empty input returns empty', () {
      expect(
        convertChinese('', ChineseConvertMode.traditionalToSimplified),
        '',
      );
    });
  });

  group('convertChineseList', () {
    test('converts each paragraph, returns new list', () {
      final src = <String>['皇后', '干部龙'];
      final out = convertChineseList(
        src,
        ChineseConvertMode.simplifiedToTraditional,
      );
      expect(out, <String>['皇后', '幹部龍']);
      // 原列表不被修改
      expect(src, <String>['皇后', '干部龙']);
    });

    test('none returns copy of input', () {
      final src = <String>['a', 'b'];
      final out = convertChineseList(src, ChineseConvertMode.none);
      expect(out, <String>['a', 'b']);
      expect(identical(out, src), isFalse);
    });
  });
}

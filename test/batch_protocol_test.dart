/// 批量译文协议（B9 收敛后的单份实现）的编解码测试。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/ai/batch_protocol.dart';
import 'package:nexhub/features/novel/domain/novel_translation_service.dart';

void main() {
  group('BatchProtocol.encode', () {
    test('生成 1 起始编号分隔格式', () {
      final encoded = BatchProtocol.encode(<String>['甲', '乙']);
      expect(encoded, contains('<<<1>>>'));
      expect(encoded, contains('<<<2>>>'));
      expect(encoded, contains('乙'));
      expect(encoded.indexOf('<<<1>>>'), lessThan(encoded.indexOf('<<<2>>>')));
    });

    test('空列表输出空串', () {
      expect(BatchProtocol.encode(<String>[]), isEmpty);
    });
  });

  group('BatchProtocol.decode', () {
    test('顺序完整返回', () {
      final decoded = BatchProtocol.decode(
        '<<<1>>>\nA one\n<<<2>>>\nB two\n<<<3>>>\nC three\n',
        3,
      );
      expect(decoded, <String>['A one', 'B two', 'C three']);
    });

    test('序号乱序按标记对位', () {
      final decoded = BatchProtocol.decode('<<<2>>>第二\n<<<1>>>第一\n', 2);
      expect(decoded, <String>['第一', '第二']);
    });

    test('段数不足 → null（触发分块回退）', () {
      expect(BatchProtocol.decode('<<<1>>>x\n<<<2>>>y\n', 3), isNull);
    });

    test('存在空槽 → null', () {
      expect(BatchProtocol.decode('<<<1>>>x\n<<<2>>> \n', 2), isNull);
    });

    test('无标记 / 空输入 → null', () {
      expect(BatchProtocol.decode('没有标记的输出', 1), isNull);
      expect(BatchProtocol.decode('', 2), isNull);
      expect(BatchProtocol.decode('<<<1>>>x\n', 0), isNull);
    });

    test('序号越界时按出现顺序落入空槽兜底', () {
      // 期望 2 段，模型输出 <<<9>>> / <<<1>>>：9 越界 → 顺延占首个空槽，
      // 后续 <<<1>>> 冲突 → 顺延占下一空槽（按出现顺序填满）。
      final decoded = BatchProtocol.decode('<<<9>>>乙\n<<<1>>>甲\n', 2);
      expect(decoded, <String>['乙', '甲']);
    });
  });

  group('旧入口委托兼容（B9）', () {
    test('NovelTranslationService.parseBatched 与 BatchProtocol.decode 等价', () {
      const raw = '<<<1>>>A\n<<<2>>>B\n';
      expect(
        NovelTranslationService.parseBatched(raw, 2),
        BatchProtocol.decode(raw, 2),
      );
      expect(
        NovelTranslationService.encodeBatch(<String>['a', 'b']),
        BatchProtocol.encode(<String>['a', 'b']),
      );
    });
  });
}

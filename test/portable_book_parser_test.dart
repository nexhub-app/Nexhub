import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/local/portable_book_parser.dart';

Uint8List _u32(int v) => Uint8List.fromList([
      (v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF,
    ]);
Uint8List _u16(int v) => Uint8List.fromList([(v >> 8) & 0xFF, v & 0xFF]);

/// 构造最小 PalmDB + PalmDOC（无压缩）Mobi：记录 0 = 头，记录 1..N = 文本切片。
Uint8List _buildMobi(String text, {int compression = 1}) {
  final rawText = Uint8List.fromList(utf8.encode(text));
  const recordSize = 4096;
  final textRecords = (rawText.length / recordSize).ceil().clamp(1, 1 << 15);
  final rec0 = BytesBuilder();
  rec0.add(_u16(compression)); // compression
  rec0.add(_u16(0)); // unused
  rec0.add(_u32(rawText.length)); // textLength
  rec0.add(_u16(textRecords)); // recordCount
  rec0.add(_u16(recordSize)); // recordSize
  rec0.add(_u16(0)); // encryption
  rec0.add(_u16(0)); // unknown
  rec0.add(Uint8List.fromList(latin1.encode('BOOKMOBI')));
  final rec0Bytes = rec0.toBytes();

  final records = <Uint8List>[rec0Bytes];
  for (var i = 0; i < textRecords; i++) {
    final start = i * recordSize;
    final end = ((i + 1) * recordSize).clamp(0, rawText.length);
    records.add(Uint8List.sublistView(rawText, start, end));
  }

  // PalmDB 头：name[32] … numRecords@76，记录表自 78。
  final header = Uint8List(78);
  header.setRange(0, 4, latin1.encode('Test'));
  header[76] = records.length >> 8;
  header[77] = records.length & 0xFF;

  final body = BytesBuilder();
  var offset = header.length + records.length * 8 + 2; // +2 pad 到偶数
  body.add(header);
  for (final r in records) {
    body.add(_u32(offset));
    body.add(Uint8List.fromList([0, 0, 0, 0])); // attr + uniqueId
    offset += r.length;
  }
  body.add(Uint8List.fromList([0, 0])); // padding gap
  for (final r in records) {
    body.add(r);
  }
  return body.toBytes();
}

void main() {
  group('D7 便携文档解析', () {
    test('isPortableBookFile 扩展名识别', () {
      expect(isPortableBookFile('/a/书.mobi'), isTrue);
      expect(isPortableBookFile('/a/书.PRC'), isTrue);
      expect(isPortableBookFile('/a/书.pdf'), isTrue);
      expect(isPortableBookFile('/a/书.epub'), isFalse);
    });

    test('Mobi 无压缩文本解析并按章节切分', () async {
      final tmp = await Directory.systemTemp.createTemp('d7_mobi');
      addTearDown(() => tmp.delete(recursive: true).catchError((_) {}));
      final path =
          '${tmp.path}${Platform.pathSeparator}测试书.mobi';
      await File(path).writeAsBytes(_buildMobi(
        '第一章 开端\n\n夜色渐深。\n\n第二章 转折\n\n门外无人。',
        compression: 1,
      ));

      final book = await PortableBookParser.parse(path);
      expect(book.chapters, isNotEmpty);
      final all = book.chapters.map((c) => c.content.join()).join();
      expect(all, contains('夜色渐深'));
      expect(all, contains('转折'));
    });

    test('PalmDOC LZ77 回引解压正确', () async {
      // 手工构造压缩记录：'abc' 字面量 + 两字节回引 token(distance=3,len=3)
      // 解压应为 "abcabc"。经 compression=2 的 Mobi 公开入口验证。
      const dist = 3, len = 3;
      final value = (dist << 3) | (len - 3);
      final b1 = 0x80 | ((value >> 8) & 0x1F);
      final b2 = value & 0xFF;
      final rawText = Uint8List.fromList(
          latin1.encode('abc') + <int>[b1, b2]);

      const recordSize = 4096;
      final rec0 = BytesBuilder()
        ..add(_u16(2)) // compression = PalmDOC
        ..add(_u16(0))
        ..add(_u32(6)) // textLength
        ..add(_u16(1))
        ..add(_u16(recordSize))
        ..add(_u16(0))
        ..add(_u16(0))
        ..add(Uint8List.fromList(latin1.encode('BOOKMOBI')));
      final rec0Bytes = rec0.toBytes();
      final records = <Uint8List>[rec0Bytes, rawText];
      final header = Uint8List(78);
      header[76] = 0;
      header[77] = 2;
      final body = BytesBuilder();
      var offset = header.length + records.length * 8 + 2;
      body.add(header);
      for (final r in records) {
        body.add(_u32(offset));
        body.add(Uint8List.fromList(<int>[0, 0, 0, 0]));
        offset += r.length;
      }
      body.add(Uint8List.fromList(<int>[0, 0]));
      for (final r in records) {
        body.add(r);
      }

      final tmp = await Directory.systemTemp.createTemp('d7_lz');
      addTearDown(() => tmp.delete(recursive: true).catchError((_) {}));
      final path = '${tmp.path}${Platform.pathSeparator}lz.prc';
      await File(path).writeAsBytes(body.toBytes());

      final book = await PortableBookParser.parse(path);
      final all = book.chapters.map((c) => c.content.join()).join();
      expect(all, contains('abcabc'));
    });

    test('PDF 文本层提取 Tj/TJ', () async {
      final tmp = await Directory.systemTemp.createTemp('d7_pdf');
      addTearDown(() => tmp.delete(recursive: true).catchError((_) {}));
      // 构造含一个 Flate 内容流的极简 PDF。
      const contentStream = 'BT (Chapter One) Tj ET\nBT [(Hello)] TJ ET';
      final flate = ZLibCodec().encoder.convert(
        Uint8List.fromList(latin1.encode(contentStream)),
      );
      final head = '1 0 obj<</Filter/FlateDecode/Length ${flate.length}>>stream\n';
      const tail = '\nendstream\n%%EOF';
      final bytes = BytesBuilder()
        ..add(Uint8List.fromList(latin1.encode(head)))
        ..add(flate)
        ..add(Uint8List.fromList(latin1.encode(tail)));
      final path = '${tmp.path}${Platform.pathSeparator}t.pdf';
      await File(path).writeAsBytes(bytes.toBytes());

      final book = await PortableBookParser.parse(path);
      expect(book.chapters, hasLength(1));
      final all = book.chapters.first.content.join('\n');
      expect(all, contains('Chapter One'));
      expect(all, contains('Hello'));
    });

    test('UMD 明确报不支持', () async {
      final tmp = await Directory.systemTemp.createTemp('d7_umd');
      addTearDown(() => tmp.delete(recursive: true).catchError((_) {}));
      final path = '${tmp.path}${Platform.pathSeparator}书.umd';
      await File(path).writeAsBytes(Uint8List.fromList([1, 2, 3]));
      await expectLater(
        PortableBookParser.parse(path),
        throwsA(isA<UnsupportedError>()),
      );
    });
  });
}

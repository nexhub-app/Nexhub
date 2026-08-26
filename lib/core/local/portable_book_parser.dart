/// 便携文档小说解析（D7）：Mobi / PDF 文本层。
///
/// 纯 Dart、零新依赖，尽力而为的文本抽取：
/// - **Mobi (.mobi/.prc/.azw)**：PalmDB 记录表 + PalmDOC 头解包，
///   支持「无压缩(1)」与「PalmDOC LZ77(2)」两种文本压缩；HUFF/CDIC
///   （compression=17480）与加密记录抛出明确错误。正文按 TXT 规则切章。
/// - **PDF (.pdf)**：扫描 `stream…endstream` 数据块，`/FlateDecode` 的用
///   zlib 解压；从内容流提取 `Tj` / `TJ` 字面量字符串拼接为文本。
///   CID 字体 / 扫描图像型 PDF 无法还原文字 → 得到的文本可能残缺或为空，
///   为空时抛错由调用方提示。整本作为单章。
/// - **UMD**：二进制协议缺乏可离线验证的样例，暂不实现——识别扩展名后
///   抛 [UnsupportedError] 给出明确提示（避免猜测式解析静默产出乱码书）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'local_novel_parser.dart'
    show LocalNovelBook, LocalNovelChapter, LocalNovelParser;
import 'text_encoding.dart' show decodeTextBytes;

/// 支持的便携文档扩展名（小写含点）。
const List<String> kPortableBookExtensions = <String>[
  '.mobi',
  '.prc',
  '.azw',
  '.pdf',
];

/// 是否为便携文档路径（按扩展名，大小写不敏感）。
bool isPortableBookFile(String path) {
  final lower = path.toLowerCase();
  return kPortableBookExtensions.any(lower.endsWith);
}

bool isUmdBookFile(String path) => path.toLowerCase().endsWith('.umd');

/// 便携文档解析器。
class PortableBookParser {
  PortableBookParser._();

  /// 按扩展名分发解析；返回与 TXT/EPUB 同构的 [LocalNovelBook]。
  static Future<LocalNovelBook> parse(String filePath) async {
    final lower = filePath.toLowerCase();
    if (lower.endsWith('.mobi') || lower.endsWith('.prc') ||
        lower.endsWith('.azw')) {
      return parseMobi(filePath);
    }
    if (lower.endsWith('.pdf')) {
      return parsePdf(filePath);
    }
    if (lower.endsWith('.umd')) {
      throw UnsupportedError(
          'UMD 格式暂不支持：缺少可校验的格式样例，为避免产出乱码未实现解析');
    }
    throw UnsupportedError('不支持的便携文档格式: $filePath');
  }

  // ── Mobi / PalmDOC ───────────────────────────────────────────

  static int _u16(Uint8List b, int off) => (b[off] << 8) | b[off + 1];

  static int _u32(Uint8List b, int off) =>
      (b[off] << 24) | (b[off + 1] << 16) | (b[off + 2] << 8) | b[off + 3];

  /// 解析 Mobi（PalmDB + PalmDOC）。整本文本经 TXT 章节规则切分。
  static Future<LocalNovelBook> parseMobi(String filePath) async {
    final bytes = await File(filePath).readAsBytes();
    if (bytes.length < 80) {
      throw const FormatException('文件过小，不是有效的 Mobi');
    }
    final recordCount = _u16(bytes, 76);
    if (recordCount < 2) throw const FormatException('Mobi 记录表为空');
    // 记录表自 78 起，每条 8 字节：offset u32 + attr u8 + uniqueId 3B。
    final offsets = <int>[];
    for (var i = 0; i < recordCount && 78 + i * 8 + 4 <= bytes.length; i++) {
      offsets.add(_u32(bytes, 78 + i * 8));
    }

    final rec0 = bytes.sublist(
        offsets[0], offsets.length > 1 ? offsets[1] : bytes.length);
    if (rec0.length < 16) throw const FormatException('PalmDOC 头缺失');
    final compression = _u16(rec0, 0);
    final textLength = _u32(rec0, 4);
    final textRecords = _u16(rec0, 8);
    final encryption = _u16(rec0, 12);
    if (encryption != 0) {
      throw UnsupportedError('该 Mobi 已加密，无法解析');
    }
    if (compression == 17480) {
      throw UnsupportedError('HUFF/CDIC 压缩的 Mobi 暂不支持');
    }
    if (compression != 1 && compression != 2) {
      throw FormatException('未知文本压缩方式: $compression');
    }

    // MOBI 扩展头（可选）：编码 / 全名，用于标题与 UTF-8 判定。
    String title = p.basenameWithoutExtension(filePath);
    var utf8Encoding = false;
    if (rec0.length >= 24 &&
        rec0[16] == 0x4D && // 'M'
        rec0[17] == 0x4F &&
        rec0[18] == 0x42 &&
        rec0[19] == 0x49) {
      final encoding = rec0.length >= 32 ? _u32(rec0, 28) : 1252;
      utf8Encoding = encoding == 65001;
      if (rec0.length >= 92) {
        final nameOff = _u32(rec0, 84);
        final nameLen = _u32(rec0, 88);
        if (nameOff > 0 && nameLen > 0 && nameOff + nameLen <= rec0.length) {
          try {
            title = utf8Encoding
                ? utf8.decode(rec0.sublist(nameOff, nameOff + nameLen))
                : decodeTextBytes(rec0.sublist(nameOff, nameOff + nameLen));
          } on Object {
            // 标题解码失败回退文件名。
          }
        }
      }
    }

    // 文本记录 1..textRecords：逐条解压后拼接。
    final buf = BytesBuilder(copy: false);
    final end = (1 + textRecords).clamp(0, offsets.length);
    for (var i = 1; i < end; i++) {
      final start = offsets[i];
      final stop = i + 1 < offsets.length ? offsets[i + 1] : bytes.length;
      final chunk =
          compression == 1 ? bytes.sublist(start, stop) : _palmDocDecompress(
              Uint8List.sublistView(bytes, start, stop));
      buf.add(chunk);
    }
    var raw = buf.toBytes();
    if (textLength > 0 && textLength <= raw.length) {
      raw = Uint8List.sublistView(raw, 0, textLength); // 去除尾部多字节余量
    }
    final text = utf8Encoding
        ? utf8.decode(raw, allowMalformed: true)
        : decodeTextBytes(raw);

    final chapters =
        LocalNovelParser.splitTxtChapters(text, fallbackTitle: title);
    return LocalNovelBook(title: title, chapters: chapters);
  }

  /// PalmDOC LZ77 解压。
  ///
  /// 规则：0x00 → 后一字面量转义输出；0x01–0x08 → 其后 N 字节原样拷贝；
  /// 0x09–0x7F → 自身即字面量；0x80–0xBF → 两字节 LZ 回引（距离/长度）；
  /// 0xC0–0xFF → 输出空格 + 低 7 位字面量。
  static Uint8List _palmDocDecompress(Uint8List input) {
    final out = BytesBuilder(copy: false);
    final list = <int>[];
    var i = 0;
    while (i < input.length) {
      final b = input[i++];
      if (b == 0x00) {
        if (i < input.length) list.add(input[i++]);
      } else if (b <= 0x08) {
        for (var n = 0; n < b && i < input.length; n++) {
          list.add(input[i++]);
        }
      } else if (b <= 0x7F) {
        list.add(b);
      } else if (b <= 0xBF) {
        if (i >= input.length) break;
        final b2 = input[i++];
        final distance = ((((b << 8) | b2) >> 3) & 0x7FF);
        final length = (b2 & 0x07) + 3;
        if (distance == 0 || distance > list.length) break; // 非法回引截断
        for (var n = 0; n < length; n++) {
          list.add(list[list.length - distance]);
        }
      } else {
        list.add(0x20);
        list.add(b & 0x7F);
      }
    }
    out.add(list);
    return out.toBytes();
  }

  // ── PDF（文本层 best-effort）────────────────────────────────

  /// 解析 PDF：提取全部内容流的可见文本，整本作为单章。
  /// 无文本层（扫描件）/ 全部流解压失败时抛错。
  static Future<LocalNovelBook> parsePdf(String filePath) async {
    final bytes = await File(filePath).readAsBytes();
    final latin = latin1.decode(bytes, allowInvalid: true);
    final textBuf = StringBuffer();

    var cursor = 0;
    while (true) {
      final streamStart = latin.indexOf('stream', cursor);
      if (streamStart < 0) break;
      final dictHead = latin.substring(
          (streamStart - 600).clamp(0, latin.length), streamStart);
      final dataStart = latin.indexOf('\n', streamStart);
      if (dataStart < 0) break;
      final dataEnd = latin.indexOf('endstream', dataStart);
      if (dataEnd < 0) break;
      cursor = dataEnd + 9;

      Uint8List chunk = bytes.sublist(dataStart + 1, dataEnd);
      // 行尾若为 \r\n，去掉开头多余的 \r。
      if (chunk.isNotEmpty && chunk.first == 0x0D) {
        chunk = Uint8List.sublistView(chunk, 1);
      }
      final flate = RegExp(r'/FlateDecode').hasMatch(dictHead);
      if (!flate) continue; // 仅处理 Flate 流（原始文本流罕见且多为元数据）
      String content;
      try {
        final decoded = ZLibCodec().decoder.convert(chunk);
        content = latin1.decode(decoded, allowInvalid: true);
      } on Object {
        continue; // 单流损坏跳过
      }
      textBuf.write(_extractPdfText(content));
    }

    final text = textBuf.toString().trim();
    if (text.isEmpty) {
      throw UnsupportedError('未能从 PDF 提取到文本（扫描件或纯图 PDF 不受支持）');
    }
    final title = p.basenameWithoutExtension(filePath);
    final paragraphs = <String>[
      for (final line in text.split('\n'))
        if (line.trim().isNotEmpty) line.trim(),
    ];
    return LocalNovelBook(title: title, chapters: <LocalNovelChapter>[
      LocalNovelChapter(title: title, content: paragraphs),
    ]);
  }

  /// 从单个内容流提取 `(...) Tj` 与 `[...] TJ` 的字符串字面量。
  static String _extractPdfText(String content) {
    final buf = StringBuffer();
    final tokenRe = RegExp(r'\((?:\\.|[^()\\])*\)|TJ|Tj|\[|\]');
    final matches = tokenRe.allMatches(content).toList(growable: false);
    final stack = <StringBuffer>[];
    for (final m in matches) {
      final t = m.group(0)!;
      if (t == '[') {
        stack.add(StringBuffer());
      } else if (t == ']') {
        // 数组闭合本身不输出，等 TJ 指令统一冲刷。
      } else if (t.startsWith('(')) {
        final s = _unescapePdfString(t.substring(1, t.length - 1));
        if (stack.isNotEmpty) {
          stack.last.write(s);
        } else {
          buf.write(s);
        }
      } else if (t == 'Tj') {
        // 单串已直写缓冲。
      } else if (t == 'TJ') {
        if (stack.isNotEmpty) {
          buf.write(stack.removeLast().toString());
        }
        buf.write('\n');
      }
    }
    return buf.toString();
  }

  static String _unescapePdfString(String s) => s
      .replaceAll(r'\(', '(')
      .replaceAll(r'\)', ')')
      .replaceAll(r'\\', '\\')
      .replaceAll(r'\n', '\n')
      .replaceAll(r'\r', '')
      .replaceAll(r'\t', '\t');
}

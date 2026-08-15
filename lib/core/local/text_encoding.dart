/// 本地文本字节 → 字符串的编码嗅探工具。
///
/// 中文 txt / epub 常见 UTF-8、GBK（GB2312/GB18030）、UTF-16 三种编码。
/// 统一按字节内容嗅探解码，避免两类乱码：
/// - GBK 文件被按 UTF-8 读（严格模式抛错、宽松模式全变 U+FFFD）；
/// - 用 latin1 兜底解码（latin1 把 GBK 双字节序列逐个映射成 U+00xx 字符，
///   得到一堆可见但完全错位的乱码）。
library;

import 'dart:convert';

import 'package:fast_gbk/fast_gbk.dart';

/// 按字节内容嗅探并解码文本。
///
/// 顺序：
/// 1. UTF-8 BOM（EF BB BF）→ UTF-8，去掉 BOM；
/// 2. UTF-8 严格解码（allowMalformed: false）成功 → UTF-8
///    （纯 ASCII 也是合法 UTF-8，原样通过）；
/// 3. 其余 → GB18030（GBK/GB2312 的超集，中文不乱码）。
///
/// 绝不回退 latin1。GB18030 也失败时最后用宽松 UTF-8 兜底（保证任何输入
/// 都有输出、不崩溃）。
String decodeTextBytes(List<int> bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    return utf8.decode(bytes.sublist(3));
  }
  try {
    return utf8.decode(bytes, allowMalformed: false);
  } on FormatException {
    try {
      return gbk.decode(bytes);
    } on FormatException {
      return utf8.decode(bytes, allowMalformed: true);
    }
  }
}

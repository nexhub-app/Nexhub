/// 批量译文协议（`<<<N>>>` 编号分隔）的编码与宽容解析。
///
/// 小说段落翻译 / 视频字幕批量翻译共用同一份实现（原两处副本收敛于此，
/// 后续「未翻译检测」「全角/半角容错」等演进只改这一处）。
library;

/// 批量协议编解码器。
class BatchProtocol {
  BatchProtocol._();

  /// 批量分隔标记（行首独立出现；正文含该串的概率可忽略）。
  static const String marker = '<<<';

  /// 把段落列表编码为单次请求的用户消息。
  static String encode(List<String> items) {
    final buf = StringBuffer();
    for (var i = 0; i < items.length; i++) {
      buf.writeln('$marker${i + 1}>>>');
      buf.writeln(items[i]);
    }
    return buf.toString();
  }

  /// 解析模型返回的批量译文为逐段列表。
  ///
  /// 宽容策略：以 `<<<N>>>` 行切分；序号缺失/乱序时按出现顺序对位；
  /// 解析出的段数少于 [expected] 或有空槽时返回 null（调用方走分块回退）。
  static List<String>? decode(String raw, int expected) {
    if (raw.trim().isEmpty || expected <= 0) return null;
    final pattern = RegExp(r'<<<\s*(\d+)\s*>>>');
    final matches = pattern.allMatches(raw).toList();
    if (matches.isEmpty) return null;
    // 按标记切出各段译文。
    final parts = <String>[];
    for (var i = 0; i < matches.length; i++) {
      final start = matches[i].end;
      final end = i + 1 < matches.length ? matches[i + 1].start : raw.length;
      parts.add(raw.substring(start, end).trim());
    }
    if (parts.length < expected) return null;
    // 按标记序号对位；序号越界/重复时落入第一个空槽顺延兜底。
    final result = List<String>.filled(expected, '');
    for (var i = 0; i < matches.length; i++) {
      var idx = (int.tryParse(matches[i].group(1)!) ?? (i + 1)) - 1;
      if (idx < 0 || idx >= expected || result[idx].isNotEmpty) {
        idx = result.indexWhere((s) => s.isEmpty);
        if (idx < 0) break;
      }
      result[idx] = parts[i];
    }
    return result.any((s) => s.isEmpty) ? null : result;
  }

  /// 轻量逐行解析（F8）：不依赖 `<<<N>>>` 编号，靠换行顺序对位。
  ///
  /// 宽容策略：剥 markdown 围栏 → 按行切分 → 丢弃编号标记行与空行；
  /// 非空行数等于 [expected] 时按顺序返回，否则返回 null（调用方回退
  /// 编号协议或分块）。
  static List<String>? decodeLoose(String raw, int expected) {
    if (raw.trim().isEmpty || expected <= 0) return null;
    var s = raw.trim();
    // 剥 ```json ... ``` / ```text ... ``` 围栏。
    s = s.replaceFirst(RegExp(r'^```[a-zA-Z]*[ \t]?\n?'), '');
    s = s.replaceFirst(RegExp(r'\n?```\s*$'), '');
    final marker = RegExp(r'^<<<\s*\d+\s*>>>\s*$');
    final lines = <String>[];
    for (final line in s.split('\n')) {
      final t = line.trim().replaceAll(RegExp(r'^[-*•]\s+'), '');
      if (t.isEmpty || marker.hasMatch(t)) continue;
      lines.add(t);
    }
    if (lines.length != expected) return null;
    return lines;
  }
}

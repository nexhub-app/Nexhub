/// 字幕文件解析与双语字幕生成（F6 视频离线管线一期）。
///
/// 纯函数、零 IO：
/// - **解析**：SRT / WebVTT / ASS(SSA) Dialogue 三种常见格式 →
///   [SubtitleCue] 列表（按时间升序）；
/// - **生成**：把逐句译文与原 cue 时间轴对齐，产出双语 SRT / ASS 文本
///   （原时间轴不变；SRT 为「原文+译文」两行，ASS 为同 Events 双语行）。
library;

/// 单条字幕 cue。
class SubtitleCue {
  final Duration start;
  final Duration end;

  /// 原 cue 文本行（已剥离 ASS 内联标记与序号）。
  final List<String> lines;

  SubtitleCue({required this.start, required this.end, required this.lines});

  String get text => lines.join('\n').trim();

  /// 关联的译文（离线管线填充；null = 未译）。可变字段：
  /// 解析与生成解耦，译文由管线回填。
  String? translation;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'start': start.inMilliseconds,
        'end': end.inMilliseconds,
        'lines': lines,
        if (translation != null) 'translation': translation,
      };

  factory SubtitleCue.fromJson(Map<String, dynamic> json) => SubtitleCue(
        start: Duration(milliseconds: (json['start'] as num?)?.toInt() ?? 0),
        end: Duration(milliseconds: (json['end'] as num?)?.toInt() ?? 0),
        lines: <String>[
          for (final l in (json['lines'] as List<dynamic>? ?? const <dynamic>[]))
            l as String? ?? '',
        ],
      )..translation = json['translation'] as String?;
}

/// 字幕文件解析与双语生成。
abstract final class SubtitleFile {
  /// 解析字幕文本；格式按内容自动嗅探（SRT / VTT / ASS）。
  /// 无法识别时返回空列表。
  static List<SubtitleCue> parse(String raw) {
    if (raw.trim().isEmpty) return const <SubtitleCue>[];
    if (RegExp(r'^\s*WEBVTT', multiLine: true).hasMatch(raw) ||
        raw.contains('-->') && !raw.contains('Dialogue:')) {
      final srtLike = _parseSrtLike(raw, decimalSeparator: '.');
      if (srtLike.isNotEmpty) return srtLike;
    }
    if (raw.contains('[Events]') && raw.contains('Dialogue:')) {
      final ass = _parseAss(raw);
      if (ass.isNotEmpty) return ass;
    }
    return _parseSrtLike(raw, decimalSeparator: ',');
  }

  // ── SRT / VTT ──

  static final RegExp _timeArrow =
      RegExp(r'(\d{1,2}):(\d{2}):(\d{2})[,.](\d{1,3})\s*-->\s*(\d{1,2}):(\d{2}):(\d{2})[,.](\d{1,3})');

  static List<SubtitleCue> _parseSrtLike(
    String raw, {
    required String decimalSeparator,
  }) {
    final cues = <SubtitleCue>[];
    final lines = raw.split(RegExp(r'\r?\n'));
    var i = 0;
    while (i < lines.length) {
      final m = _timeArrow.firstMatch(lines[i]);
      if (m == null) {
        i++;
        continue;
      }
      final start = _partsToDuration(
          m.group(1)!, m.group(2)!, m.group(3)!, m.group(4)!);
      final end = _partsToDuration(
          m.group(5)!, m.group(6)!, m.group(7)!, m.group(8)!);
      i++;
      final body = <String>[];
      while (i < lines.length &&
          lines[i].trim().isNotEmpty &&
          _timeArrow.firstMatch(lines[i]) == null) {
        body.add(_stripTags(lines[i]));
        i++;
      }
      if (body.any((l) => l.trim().isNotEmpty)) {
        cues.add(SubtitleCue(start: start, end: end, lines: body));
      }
    }
    return cues;
  }

  static Duration _partsToDuration(
      String h, String m, String s, String ms) {
    final millis = int.tryParse(ms.padRight(3, '0')) ?? 0;
    return Duration(
      hours: int.tryParse(h) ?? 0,
      minutes: int.tryParse(m) ?? 0,
      seconds: int.tryParse(s) ?? 0,
      milliseconds: millis,
    );
  }

  // ── ASS / SSA ──

  static List<SubtitleCue> _parseAss(String raw) {
    final cues = <SubtitleCue>[];
    String timeFmt = 'h:mm:ss.cc';
    for (final line in raw.split(RegExp(r'\r?\n'))) {
      final l = line.trim();
      if (l.startsWith('Format:')) {
        if (l.toLowerCase().contains('layer') ||
            l.toLowerCase().contains('start')) {
          timeFmt = l;
        }
        continue;
      }
      if (!l.startsWith('Dialogue:')) continue;
      final body = l.substring('Dialogue:'.length).trim();
      // 按 Format 字段名切分；无 Format 行时按传统 10 字段布局解析。
      final fields = body.split(',');
      final startIdx = _assFieldIndex(timeFmt, 'Start');
      final endIdx = _assFieldIndex(timeFmt, 'End');
      final textIdx = _assFieldIndex(timeFmt, 'Text');
      if (startIdx < 0 ||
          endIdx < 0 ||
          textIdx < 0 ||
          fields.length <= textIdx) {
        continue;
      }
      final start = _assTime(fields[startIdx].trim());
      final end = _assTime(fields[endIdx].trim());
      final text = fields.sublist(textIdx).join(',');
      final textLines = _stripTags(text)
          .split(RegExp(r'\\[Nn]'))
          .where((s) => s.trim().isNotEmpty)
          .toList();
      if (start != null && end != null && textLines.isNotEmpty) {
        cues.add(SubtitleCue(
            start: start, end: end, lines: textLines));
      }
    }
    return cues;
  }

  /// ASS Dialogue 字段下标（按 Format 行的字段名；无 Format 行时用传统布局）。
  static int _assFieldIndex(String formatLine, String fieldName) {
    if (formatLine == 'h:mm:ss.cc') {
      return switch (fieldName) {
        'Start' => 1,
        'End' => 2,
        'Text' => 9,
        _ => -1,
      };
    }
    final names = formatLine
        .substring('Format:'.length)
        .split(',')
        .map((s) => s.trim().toLowerCase())
        .toList();
    return names.indexOf(fieldName.toLowerCase());
  }

  /// ASS 时间 `H:MM:SS.CC` → Duration（百分秒）。
  static Duration? _assTime(String s) {
    final m = RegExp(r'^(\d+):(\d{1,2}):(\d{1,2})\.(\d{1,2})$').firstMatch(s);
    if (m == null) return null;
    return Duration(
      hours: int.tryParse(m.group(1)!) ?? 0,
      minutes: int.tryParse(m.group(2)!) ?? 0,
      seconds: int.tryParse(m.group(3)!) ?? 0,
      milliseconds: (int.tryParse(m.group(4)!.padRight(2, '0')) ?? 0) * 10,
    );
  }

  /// 剥 ASS 内联标记（{\\...}）与 HTML 标签。
  static String _stripTags(String s) {
    var out = s.replaceAll(RegExp(r'\{\\[^}]*\}'), '');
    out = out.replaceAll(RegExp(r'<[^>]+>'), ' ');
    return out;
  }

  // ── 双语生成 ──

  static String _fmtSrt(Duration d) {
    String two(int v) => v.toString().padLeft(2, '0');
    String three(int v) => v.toString().padLeft(3, '0');
    final h = two(d.inHours);
    final m = two(d.inMinutes % 60);
    final s = two(d.inSeconds % 60);
    final ms = three(d.inMilliseconds % 1000);
    return '$h:$m:$s,$ms';
  }

  /// 生成双语 SRT：每条 cue 为「原文 + 译文」两行；未译条目仅原文。
  static String buildBilingualSrt(List<SubtitleCue> cues) {
    final buf = StringBuffer();
    var index = 0;
    for (final c in cues) {
      final text = c.text;
      if (text.isEmpty) continue;
      index++;
      buf.writeln(index);
      buf.writeln('${_fmtSrt(c.start)} --> ${_fmtSrt(c.end)}');
      buf.writeln(text);
      final t = (c.translation ?? '').trim();
      if (t.isNotEmpty) buf.writeln(t);
      buf.writeln();
    }
    return buf.toString();
  }

  /// 生成双语 ASS（v4+ 默认样式）：Dialogue 为「原文\N译文」。
  static String buildBilingualAss(List<SubtitleCue> cues, {String title = 'bilingual'}) {
    final buf = StringBuffer()
      ..writeln('[Script Info]')
      ..writeln('Title: $title')
      ..writeln('ScriptType: v4.00+')
      ..writeln('PlayResX: 384')
      ..writeln('PlayResY: 288')
      ..writeln('WrapStyle: 0')
      ..writeln()
      ..writeln('[V4+ Styles]')
      ..writeln(
          'Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding')
      ..writeln(
          'Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H64000000,0,0,0,0,100,100,0,0,1,2,1,2,10,10,10,1')
      ..writeln()
      ..writeln('[Events]')
      ..writeln('Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text');
    String assTime(Duration d) {
      String two(int v) => v.toString().padLeft(2, '0');
      final cs = ((d.inMilliseconds % 1000) ~/ 10).toString().padLeft(2, '0');
      return '${d.inHours}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}.$cs';
    }
    for (final c in cues) {
      final text = c.text;
      if (text.isEmpty) continue;
      final t = (c.translation ?? '').trim();
      final combined = t.isEmpty ? text : '$text\\N$t';
      buf.writeln('Dialogue: 0,${assTime(c.start)},${assTime(c.end)},'
          'Default,,0,0,0,,${combined.replaceAll('\n', '\\N')}');
    }
    return buf.toString();
  }
}

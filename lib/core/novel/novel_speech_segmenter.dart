/// 小说 TTS 分句器（P2-3 / C4，对标 RuleBasedSpeechSegmenter 语义）。
///
/// 纯函数：输入段落文本，输出带角色标注的句子段序列。
/// 规则：
/// - **引号配对**：成对引号（「」『』“”‘’）内的内容视为对话，归属角色；
/// - **cue 判定**：开口引号前 ≤24 字符窗口内匹配「说道/心想/问/答/喊/说/道」
///   等 cue（含冒号句式「XX说：」），提取说话人；无 cue 的引号归属「对话」；
/// - **旁白**：引号外的文本按标点（。！？；…）切成短句，role = 旁白；
/// - **不含引号的整段**：按标点分句，均视为旁白；
/// - 空段返回空列表。
///
/// 角色名解析（C5 简化）：cue 匹配到的说话人取「前缀最长匹配」候选；
/// 引擎层用配置的音色表（角色名 → voice id）映射音色，未配置角色回退默认音色。
library;

/// 单条 TTS 句段。
class SpeechSegment {
  /// 朗读文本（不含引号）。
  final String text;

  /// 角色标注：cue 解析出的说话人，或 [narratorRole]（旁白）/ [quoteRole]（对话）。
  final String role;

  final String sourceRole;

  const SpeechSegment({
    required this.text,
    required this.role,
    required this.sourceRole,
  });
}

/// 旁白角色名。
const String narratorRole = '旁白';

/// 无 cue 对话的默认角色名。
const String quoteRole = '对话';

/// cue 关键词（说话/心理活动动词短语），用于匹配开口引号前的说话人。
const List<String> kSpeechCueWords = <String>[
  '说道',
  '说',
  '问道',
  '问',
  '答道',
  '回答',
  '答',
  '心想',
  '想',
  '喊道',
  '喊',
  '叫道',
  '笑道',
  '笑道：',
  '喃喃道',
  '低声道',
  '大声道',
  '沉声道',
  '冷声道',
  '叹道',
  '忙道',
];

/// 对话引号对（开/闭）。
const List<(String, String)> kQuotePairs = <(String, String)>[
  ('“', '”'),
  ('‘', '’'),
  ('「', '」'),
  ('『', '』'),
  ('"', '"'),
  ('\'', '\''),
];

/// 段落结束标点（旁白切句）。
const List<String> kSentencePunctuation = <String>['。', '！', '？', '…', '；'];

/// 把一段文本切分为 TTS 句段。
///
/// [text] 为原始段落。实现：先按引号对切分「旁白区/对话区」，对话区
/// 用 cue 提取角色并整体作为一句；旁白区按结束标点切句（role=旁白）。
List<SpeechSegment> segmentSpeech(String text) {
  if (text.isEmpty) return const <SpeechSegment>[];
  final segments = <SpeechSegment>[];

  // 1) 按引号配对扫描一次，收集对话区间。
  final quotes = <({int start, int end, String content, int windowStart})>[];
  var i = 0;
  while (i < text.length) {
    for (final (open, close) in kQuotePairs) {
      if (i + open.length <= text.length && text.startsWith(open, i)) {
        final closeIdx = text.indexOf(close, i + open.length);
        if (closeIdx > i) {
          final quoteStart = i;
          final quoteEnd = closeIdx + close.length;
          quotes.add((
            start: quoteStart,
            end: quoteEnd,
            content: text.substring(i + open.length, closeIdx),
            windowStart: (quoteStart - 24).clamp(0, quoteStart),
          ));
          i = quoteEnd;
          break;
        }
      }
    }
    i++;
  }

  // 2) 合并旁白区与对话区。
  var cursor = 0;
  for (final q in quotes) {
    // 引号前的旁白（剥离段尾「说话人+冒号」引导语，如 `小红说道：`——
    // 引导语属引号句的 cue 上下文，不单独朗读）。
    if (q.start > cursor) {
      final lead = _stripSpeechLead(text.substring(cursor, q.start));
      _appendNarration(lead, segments);
    }
    // 引号内容：用 cue 判角色。
    final role = _detectRole(text, q.windowStart, q.start, q.content);
    segments.add(SpeechSegment(
      text: q.content,
      role: role,
      sourceRole: role,
    ));
    cursor = q.end;
  }
  if (cursor < text.length) {
    _appendNarration(text.substring(cursor), segments);
  }
  return segments;
}

/// 剥离旁白文本段尾的「说话人 + 冒号」发言引导语（如 `李四喊：`），
/// 仅当段尾命中 cue 词 + 冒号时剥掉；其余原样返回。
String _stripSpeechLead(String s) {
  final trimmed = s.trimRight();
  if (trimmed.isEmpty) return '';
  // 段尾匹配：[说话人 cue]+[：:]，说话人限 ≤12 字符。
  final match = RegExp(
          r'((?:[^。！？；：:]{0,12})(?:说道|说道|说|问道|问|答道|答|心想|想|喊道|喊|叫道|叫|笑道|道|忙道|低声|大声|沉声|冷声|叹道|喃喃道|低声道)[：:])\s*$')
      .firstMatch(trimmed);
  if (match == null) return trimmed;
  return trimmed.substring(0, match.start).trimRight();
}

/// 从开口引号前的窗口文本中匹配 cue，返回说话人角色名。
///
/// 匹配策略：窗口内找最后一个 cue 词，其前面（≤14 字符内）的连续非标点
/// 子串视为说话人；找不到 cue 返回 [quoteRole]。
String _detectRole(String full, int windowStart, int quoteStart, String content) {
  final window = full.substring(windowStart, quoteStart);
  // 找 cue 词在窗口中的最后出现（最靠近引号）。
  var bestCue = -1;
  var bestRoleCandidate = '';
  for (final cue in kSpeechCueWords) {
    final idx = window.lastIndexOf(cue);
    if (idx < 0) continue;
    // 说/问/想 等单字 cue 太宽泛：要求前面紧跟人名词或后跟冒号，
    // 否则跳过（避免把「不知道说什么」误判）。
    final before = window.substring(0, idx);
    // 提取说话人：cue 前最近的连续汉字/字母串。
    final candidate = _extractSpeaker(before);
    if (candidate.isEmpty) continue;
    if (idx > bestCue) {
      bestCue = idx;
      bestRoleCandidate = candidate;
    }
  }
  if (bestRoleCandidate.isNotEmpty) return bestRoleCandidate;
  // 冒号句式：`XX：` / `XX:` 直接前置人名。
  final colon = window.lastIndexOf('：');
  if (colon > 0) {
    final speaker = _extractSpeaker(window.substring(0, colon));
    if (speaker.isNotEmpty) return speaker;
  }
  return quoteRole;
}

/// 提取字符串末尾的连续说话人（汉字/字母/数字，长度 ≤ 12）。
String _extractSpeaker(String s) {
  var end = s.length;
  while (end > 0 && _isNameChar(s[end - 1])) {
    end--;
  }
  // 去掉紧邻的连接词（如「只见」「就听」）——简单起见保留最近 12 字符。
  final name = s.substring(end).trim();
  if (name.isEmpty || name.length > 12) {
    // 超长视为未命名词。
    if (name.length > 12) return '';
    return '';
  }
  return name;
}

bool _isNameChar(String c) {
  final code = c.codeUnitAt(0);
  // 中文字符范围（含扩展区常见字）+ ascii 字母数字。
  return (code >= 0x4E00 && code <= 0x9FFF) ||
      (code >= 0x3400 && code <= 0x4DBF) ||
      (c.codeUnits.length > 0 && RegExp(r'[A-Za-z0-9]').hasMatch(c)) ||
      (c == '·');
}

/// 旁白切句：按结束标点切短句。句首若命中「角色 + 冒号」句式
/// （如 `他说：xxx` / `小王心想：xxx`），以冒号前文本为角色、冒号后为
/// 内容切分（P2-3 无引号句式也支持角色判定）。
void _appendNarration(String text, List<SpeechSegment> out) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return;
  var start = 0;
  for (var i = 0; i < trimmed.length; i++) {
    if (kSentencePunctuation.contains(trimmed[i])) {
      _appendNarrationSentence(trimmed.substring(start, i + 1), out);
      start = i + 1;
    }
  }
  if (start < trimmed.length) {
    _appendNarrationSentence(trimmed.substring(start), out);
  }
}

/// 追加一条旁白句（或拆为角色+内容）。
void _appendNarrationSentence(String raw, List<SpeechSegment> out) {
  final s = raw.trim();
  if (s.isEmpty) return;
  // 冒号句式：[说话人][：:][内容]。说话人限 ≤12 字符、不含标点。
  final colon = s.indexOf(RegExp(r'[：:]'));
  if (colon > 0 && colon <= 12) {
    final maybeRole = s.substring(0, colon).trimRight();
    final content = s.substring(colon + 1).trim();
    if (maybeRole.isNotEmpty && content.isNotEmpty) {
      final role = _stripCueSuffix(maybeRole);
      if (role.isNotEmpty) {
        out.add(SpeechSegment(
          text: content,
          role: role,
          sourceRole: role,
        ));
        return;
      }
    }
  }
  out.add(SpeechSegment(
    text: s,
    role: narratorRole,
    sourceRole: narratorRole,
  ));
}

/// 去除说话人候选末尾的 cue 动词词尾（「说道/问/喊/心想」等），
/// 保留纯人名。按词长优先匹配（避免「说道」被「说」提前截断）。
String _stripCueSuffix(String candidate) {
  var name = candidate.trim();
  // 按长度降序尝试 cue 词尾。
  final cues = [...kSpeechCueWords]..sort((a, b) => b.length.compareTo(a.length));
  for (final cue in cues) {
    if (name.endsWith(cue)) {
      name = name.substring(0, name.length - cue.length).trim();
      break;
    }
  }
  return name;
}
import 'dart:math' as math;

import 'package:dio/dio.dart';

/// 阅读速览（原「阅读总结」）的总结方式。
enum NovelOverviewMode {
  /// 离线抽取式摘要：纯本地、无网络、无配置，秒出。
  local,

  /// 云端 AI 总结：调用 OpenAI 兼容的 /chat/completions 接口。
  api,
}

/// 云端总结所需的接口配置（base 地址 / 密钥 / 模型）。
/// 注意：API 密钥以明文存于 SharedPreferences（与现有弹幕凭据一致的已知弱项），
/// 仅在本机使用，不随书源/备份外发。
class NovelSummaryConfig {
  const NovelSummaryConfig({
    this.baseUrl = '',
    this.apiKey = '',
    this.model = '',
  });

  final String baseUrl;
  final String apiKey;
  final String model;

  NovelSummaryConfig copyWith({
    String? baseUrl,
    String? apiKey,
    String? model,
  }) =>
      NovelSummaryConfig(
        baseUrl: baseUrl ?? this.baseUrl,
        apiKey: apiKey ?? this.apiKey,
        model: model ?? this.model,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'model': model,
      };

  static NovelSummaryConfig fromJson(Map<String, dynamic>? json) {
    if (json == null) return const NovelSummaryConfig();
    return NovelSummaryConfig(
      baseUrl: json['baseUrl'] as String? ?? '',
      apiKey: json['apiKey'] as String? ?? '',
      model: json['model'] as String? ?? '',
    );
  }
}

/// 小说章节内容总结服务。
/// - [localSummary]：离线抽取式摘要（位置加权 + 字频），确定性、无需网络。
/// - [cloudSummary]：云端 AI 摘要（OpenAI 兼容接口），需配置。
class NovelSummaryService {
  NovelSummaryService({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  /// 离线抽取式摘要。
  /// 将正文切分为句子，按「位置靠前加权 + 高频字加权」打分，取前 [maxSentences]
  /// 句（按原文顺序拼接）。正文过短时直接返回全文。
  String localSummary(String text, {int maxSentences = 8}) {
    final sentences = _splitSentences(text);
    if (sentences.isEmpty) return '';
    if (sentences.length <= maxSentences) {
      return sentences.join('\n');
    }

    // 字频统计（仅计 CJK 字符，近似关键词权重）。
    final freq = <String, int>{};
    for (final s in sentences) {
      for (final rune in s.runes) {
        final ch = String.fromCharCode(rune);
        if (_isCJK(ch)) freq[ch] = (freq[ch] ?? 0) + 1;
      }
    }

    final scores = <double>[];
    for (int i = 0; i < sentences.length; i++) {
      // 位置加权：越靠前权重越高（1.0 → 接近 0）。
      double score = 1.0 - (i / sentences.length) * 0.8;
      for (final rune in sentences[i].runes) {
        final ch = String.fromCharCode(rune);
        if (_isCJK(ch)) score += (freq[ch] ?? 0) * 0.02;
      }
      scores.add(score);
    }

    final order = List<int>.generate(sentences.length, (i) => i)
      ..sort((a, b) => scores[b].compareTo(scores[a]));
    final picked = order.take(maxSentences).toList()..sort();
    return picked.map((i) => sentences[i]).join('\n');
  }

  /// 云端 AI 摘要（OpenAI 兼容的 /chat/completions）。
  /// [text] 为章节正文，[cfg] 为接口配置。返回模型生成的摘要文本。
  /// 失败时抛出 [DioException] / [Exception]，由调用方展示。
  Future<String> cloudSummary(String text, NovelSummaryConfig cfg) async {
    final trimmedBase = cfg.baseUrl.trim();
    if (trimmedBase.isEmpty) {
      throw Exception('baseUrl empty');
    }
    final base = trimmedBase.replaceAll(RegExp(r'/+$'), '');
    final url = '$base/chat/completions';

    final resp = await _dio.post<Map<String, dynamic>>(
      url,
      options: Options(
        headers: <String, dynamic>{
          'Content-Type': 'application/json',
          if (cfg.apiKey.trim().isNotEmpty)
            'Authorization': 'Bearer ${cfg.apiKey.trim()}',
        },
        sendTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 30),
      ),
      data: <String, dynamic>{
        'model': cfg.model.trim().isNotEmpty ? cfg.model.trim() : 'gpt-3.5-turbo',
        'messages': <Map<String, dynamic>>[
          <String, dynamic>{
            'role': 'system',
            'content':
                '你是一个小说阅读助手。请用简洁的中文总结用户提供的章节内容，'
                '突出情节进展与关键人物/事件，不要复述原文，控制在 200 字以内。',
          },
          <String, dynamic>{
            'role': 'user',
            'content': text,
          },
        ],
        'temperature': 0.3,
        'max_tokens': 400,
      },
    );

    final data = resp.data;
    final choices = data?['choices'] as List?;
    if (choices == null || choices.isEmpty) {
      throw Exception('empty choices');
    }
    final message = choices.first['message'] as Map?;
    final content = message?['content'] as String?;
    if (content == null || content.trim().isEmpty) {
      throw Exception('empty content');
    }
    return content.trim();
  }

  /// 按中英文及常见断句符切分句子。
  static List<String> _splitSentences(String text) {
    final out = <String>[];
    final buf = StringBuffer();
    const terminators = '。！？!?；;\n';
    for (final rune in text.runes) {
      final ch = String.fromCharCode(rune);
      buf.write(ch);
      if (terminators.contains(ch)) {
        final s = buf.toString().trim();
        if (s.isNotEmpty) out.add(s);
        buf.clear();
      }
    }
    final tail = buf.toString().trim();
    if (tail.isNotEmpty) out.add(tail);
    return out;
  }

  /// 判断是否为 CJK 统一表意文字（粗略覆盖常用汉字区）。
  static bool _isCJK(String ch) {
    if (ch.length != 1) return false;
    final r = ch.codeUnitAt(0);
    return (r >= 0x4E00 && r <= 0x9FFF) ||
        (r >= 0x3400 && r <= 0x4DBF) ||
        (r >= 0x20000 && r <= 0x2A6DF);
  }
}

/// 避免与 dart:math 冲突的占位（保留扩展点）。
const _kMaxSentencesDefault = 8;

/// 计算摘要句数上限（按正文字数自适应，最少 3 句、最多 12 句）。
int adaptiveMaxSentences(int charCount) {
  if (charCount <= 0) return _kMaxSentencesDefault;
  // 每约 400 字取一句，下限 3、上限 12。
  return math.min(12, math.max(3, (charCount / 400).ceil()));
}

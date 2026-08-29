/// AI 视觉识别 + 翻译统一客户端（漫画页翻译 / 视频画面 OCR 共用）。
///
/// 走 OpenAI 兼容 `chat/completions` 接口（与小说翻译同族协议）：
/// - **视觉请求**：图片以 `data:` base64 随消息发送，模型同时完成
///   文字识别（OCR）与翻译，返回带区域坐标的 JSON；
/// - **文本请求**：批量协议 `<<<N>>>` 序号分隔（对齐小说段落翻译），
///   一次请求翻译多条短句（视频字幕逐句场景）。
///
/// 接口配置（baseUrl/apiKey/model）由调用方传入（各功能读取自己的
/// 功能级配置并回落通用配置），本文件不依赖任何 feature 层代码。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// 一段识别并翻译后的文字区域（坐标为相对图片宽高的千分比 0–1000）。
class VisionTextSegment {
  /// 归一化千分比坐标（左上原点）：x1/y1/x2/y2；无坐标（纯文本 OCR）时为 null。
  final int? x1;
  final int? y1;
  final int? x2;
  final int? y2;

  /// 识别出的原文。
  final String text;

  /// 翻译后的文本。
  final String translation;

  const VisionTextSegment({
    this.x1,
    this.y1,
    this.x2,
    this.y2,
    required this.text,
    required this.translation,
  });

  bool get hasBbox =>
      x1 != null && y1 != null && x2 != null && y2 != null && x2! > x1! && y2! > y1!;

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (x1 != null) 'x1': x1,
        if (y1 != null) 'y1': y1,
        if (x2 != null) 'x2': x2,
        if (y2 != null) 'y2': y2,
        'text': text,
        'translation': translation,
      };

  factory VisionTextSegment.fromJson(Map<String, dynamic> json) =>
      VisionTextSegment(
        x1: (json['x1'] as num?)?.toInt(),
        y1: (json['y1'] as num?)?.toInt(),
        x2: (json['x2'] as num?)?.toInt(),
        y2: (json['y2'] as num?)?.toInt(),
        text: json['text'] as String? ?? '',
        translation: json['translation'] as String? ?? '',
      );
}

/// AI 接口三元组（与小说域 NovelSummaryConfig 同构，独立定义避免 core→feature 依赖）。
class AiEndpointConfig {
  final String baseUrl;
  final String apiKey;
  final String model;

  const AiEndpointConfig({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
  });

  bool get isConfigured => baseUrl.trim().isNotEmpty;
}

/// 视觉识别 + 翻译客户端。
class VisionTranslationClient {
  VisionTranslationClient({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  /// 漫画页 OCR+翻译提示词：识别气泡/拟声词并逐区域翻译，
  /// 坐标用千分比（0–1000）避免像素尺寸歧义。
  static String mangaSystemPrompt(String targetLang) =>
      '你是专业的漫画翻译引擎。用户会给出一张漫画页面图片。'
      '请识别图中所有带文字的区域（对话气泡、旁白框、拟声词、标注），'
      '把每个区域的文字翻译成$targetLang。'
      '只输出一个 JSON 数组，不要输出任何解释或 markdown 代码块围栏。'
      '数组每个元素格式：'
      '{"bbox":[x1,y1,x2,y2],"text":"原文","translation":"译文"}，'
      '其中坐标是该区域在图片宽高上的千分比位置（0-1000，左上角为原点，'
      'x 向右 y 向下），text 为识别的原文（保留日文/英文等原样），'
      'translation 为翻译结果。忽略图片签名/水印/页码等非正文文字。'
      '若图中没有需要翻译的文字，输出 []。';

  /// 视频帧 OCR+翻译提示词：识别画面中的字幕/台词文字并翻译，
  /// 不需要坐标，输出逐行原文+译文。
  static String videoOcrSystemPrompt(String targetLang) =>
      '你是专业的视频字幕识别引擎。用户会给出一个视频画面帧。'
      '请识别画面中的台词/字幕文字（忽略台标、水印、进度条、按钮等界面元素），'
      '把识别结果翻译成$targetLang。'
      '只输出一个 JSON 数组，不要输出任何解释或 markdown 代码块围栏。'
      '数组每个元素格式：{"text":"原文","translation":"译文"}，'
      '按阅读顺序排列。若画面中没有台词文字，输出 []。';

  /// 单次视觉请求：识别并翻译图片中的文字。
  ///
  /// [mimeType] 目前支持 image/jpeg / image/png。
  Future<List<VisionTextSegment>> recognizeImage({
    required AiEndpointConfig config,
    required Uint8List imageBytes,
    required String mimeType,
    required String systemPrompt,
    int maxSide = 1600,
  }) async {
    final base = config.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final resp = await _dio.post<Map<String, dynamic>>(
      '$base/chat/completions',
      options: Options(
        headers: <String, dynamic>{
          'Content-Type': 'application/json',
          if (config.apiKey.trim().isNotEmpty)
            'Authorization': 'Bearer ${config.apiKey.trim()}',
        },
        sendTimeout: const Duration(seconds: 60),
        receiveTimeout: const Duration(seconds: 180),
      ),
      data: <String, dynamic>{
        'model': config.model.trim().isNotEmpty
            ? config.model.trim()
            : 'gpt-4o-mini',
        'messages': <Map<String, dynamic>>[
          <String, dynamic>{'role': 'system', 'content': systemPrompt},
          <String, dynamic>{
            'role': 'user',
            'content': <Map<String, dynamic>>[
              <String, dynamic>{
                'type': 'image_url',
                'image_url': <String, dynamic>{
                  'url':
                      'data:$mimeType;base64,${base64Encode(imageBytes)}',
                },
              },
            ],
          },
        ],
        'temperature': 0.2,
      },
    );
    final content = _extractContent(resp.data);
    if (content == null || content.trim().isEmpty) {
      throw Exception('AI 返回内容为空');
    }
    return parseSegmentsJson(content);
  }

  /// 批量翻译短句（视频字幕场景）：一次请求翻译多条，返回与输入等长的译文。
  ///
  /// 复用小说翻译同款 `<<<N>>>` 批量协议；解析失败/条数不齐时抛异常，
  /// 由调用方决定回退策略（逐条重试等）。
  Future<List<String>> translateBatch({
    required AiEndpointConfig config,
    required String targetLang,
    required List<String> texts,
  }) async {
    if (texts.isEmpty) return const <String>[];
    final base = config.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final buf = StringBuffer();
    for (var i = 0; i < texts.length; i++) {
      buf.writeln('<<<${i + 1}>>>');
      buf.writeln(texts[i]);
    }
    final resp = await _dio.post<Map<String, dynamic>>(
      '$base/chat/completions',
      options: Options(
        headers: <String, dynamic>{
          'Content-Type': 'application/json',
          if (config.apiKey.trim().isNotEmpty)
            'Authorization': 'Bearer ${config.apiKey.trim()}',
        },
        sendTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 120),
      ),
      data: <String, dynamic>{
        'model': config.model.trim().isNotEmpty
            ? config.model.trim()
            : 'gpt-4o-mini',
        'messages': <Map<String, dynamic>>[
          <String, dynamic>{
            'role': 'system',
            'content': '你是专业的字幕译者。把用户给出的每个编号段落翻译成'
                '$targetLang，保持原文的语气与人名译名一致，译文口语化。'
                '输出必须严格保持编号格式：每段译文前单独一行 <<<序号>>>，'
                '不要添加任何解释或合并段落。',
          },
          <String, dynamic>{'role': 'user', 'content': buf.toString()},
        ],
        'temperature': 0.2,
      },
    );
    final content = _extractContent(resp.data);
    final parsed = _parseBatched(content ?? '', texts.length);
    if (parsed == null) throw Exception('翻译返回格式异常');
    return parsed;
  }

  static String? _extractContent(Map<String, dynamic>? data) {
    final choices = data?['choices'] as List?;
    if (choices == null || choices.isEmpty) return null;
    return (choices.first['message'] as Map?)?['content'] as String?;
  }

  /// 宽容解析模型返回的区域 JSON：剥掉 markdown 围栏 / 前后杂文，
  /// 截取首个 `[` 到末个 `]` 之间的内容。
  static List<VisionTextSegment> parseSegmentsJson(String raw) {
    var s = raw.trim();
    // 剥 ```json ... ``` 围栏。
    final fence = RegExp(r'^```[a-zA-Z]*\s*|\s*```$');
    s = s.replaceAll(fence, '').trim();
    final start = s.indexOf('[');
    final end = s.lastIndexOf(']');
    if (start < 0 || end <= start) return const <VisionTextSegment>[];
    s = s.substring(start, end + 1);
    try {
      final dynamic decoded = jsonDecode(s);
      if (decoded is! List) return const <VisionTextSegment>[];
      final result = <VisionTextSegment>[];
      for (final dynamic item in decoded) {
        if (item is! Map<String, dynamic>) continue;
        // bbox 数组形式。
        int? x1;
        int? y1;
        int? x2;
        int? y2;
        final bbox = item['bbox'];
        if (bbox is List && bbox.length >= 4) {
          x1 = (bbox[0] as num?)?.toInt();
          y1 = (bbox[1] as num?)?.toInt();
          x2 = (bbox[2] as num?)?.toInt();
          y2 = (bbox[3] as num?)?.toInt();
        } else {
          // 平铺字段形式（x1/y1/x2/y2）。
          x1 = (item['x1'] as num?)?.toInt();
          y1 = (item['y1'] as num?)?.toInt();
          x2 = (item['x2'] as num?)?.toInt();
          y2 = (item['y2'] as num?)?.toInt();
        }
        final text = (item['text'] ?? item['original'] ?? '') as String? ?? '';
        final translation =
            (item['translation'] ?? item['translated'] ?? text) as String? ?? '';
        if (text.trim().isEmpty && translation.trim().isEmpty) continue;
        result.add(VisionTextSegment(
          x1: x1,
          y1: y1,
          x2: x2,
          y2: y2,
          text: text.trim(),
          translation: translation.trim(),
        ));
      }
      return result;
    } on Object {
      return const <VisionTextSegment>[];
    }
  }

  /// 解析 `<<<N>>>` 批量译文为逐条列表；条数不齐返回 null。
  static List<String>? _parseBatched(String raw, int expected) {
    if (raw.trim().isEmpty || expected <= 0) return null;
    final pattern = RegExp(r'<<<\s*(\d+)\s*>>>');
    final matches = pattern.allMatches(raw).toList();
    if (matches.isEmpty) return null;
    final parts = <String>[];
    for (var i = 0; i < matches.length; i++) {
      final start = matches[i].end;
      final end =
          i + 1 < matches.length ? matches[i + 1].start : raw.length;
      parts.add(raw.substring(start, end).trim());
    }
    if (parts.length < expected) return null;
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
}

/// AI 章节配图服务（O4）。
///
/// 复用阅读速览的 OpenAI 兼容配置（[NovelSummarySettings]），调用
/// `/images/generations` 为当前章节生成一张插图，落盘到应用支持目录
/// `novel_illustrations/<hash>.png` 并返回本地路径；由阅读器把该路径以
/// [kNexhubImgMarker] 占位行追加进正文编辑记录（N7 内容编辑管线复用），
/// 重载章节即图文混排显示。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../../core/local/local_novel_parser.dart' show kNexhubImgMarker;
import 'novel_summary_service.dart' show NovelSummaryConfig;
import 'novel_summary_settings.dart';

/// AI 配图服务。
class NovelIllustrationService {
  NovelIllustrationService({Dio? dio, NovelSummarySettings? settings})
      : _dio = dio ?? Dio(),
        _settings = settings ?? NovelSummarySettings.instance;

  final Dio _dio;
  final NovelSummarySettings _settings;

  /// 构建生图提示词（纯函数，便于测试与后续调参）。
  static String buildPrompt(String chapterTitle, String excerpt) {
    final brief = excerpt.length > 500 ? excerpt.substring(0, 500) : excerpt;
    return '为小说章节「${chapterTitle.trim().isEmpty ? '未命名章节' : chapterTitle}」'
        '绘制一张插图。依据以下正文片段把握场景与氛围，'
        '单幅、无文字、构图完整：\n$brief';
  }

  /// 生成并保存插图，返回本地文件路径。失败抛异常由 UI 展示。
  Future<String> generateAndSave({
    required String novelId,
    required String chapterId,
    required String chapterTitle,
    required String excerpt,
    NovelSummaryConfig? config,
    String model = '',
    String size = '1024x1024',
  }) async {
    final cfg = config ?? await _settings.getConfig();
    final base = cfg.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (base.isEmpty) throw Exception('未配置云端 AI 接口');

    final resp = await _dio.post<Map<String, dynamic>>(
      '$base/images/generations',
      options: Options(
        headers: <String, dynamic>{
          'Content-Type': 'application/json',
          if (cfg.apiKey.trim().isNotEmpty)
            'Authorization': 'Bearer ${cfg.apiKey.trim()}',
        },
        sendTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 180),
      ),
      data: <String, dynamic>{
        if (model.trim().isNotEmpty) 'model': model.trim(),
        'prompt': buildPrompt(chapterTitle, excerpt),
        'n': 1,
        'size': size,
        'response_format': 'b64_json',
      },
    );
    final data = resp.data?['data'] as List?;
    if (data == null || data.isEmpty) throw Exception('生成结果为空');
    final first = data.first as Map?;
    final Uint8List bytes;
    final b64 = first?['b64_json'] as String?;
    if (b64 != null && b64.isNotEmpty) {
      bytes = base64Decode(b64);
    } else {
      // 兼容返回 url 的服务：下载图片字节。
      final url = first?['url'] as String?;
      if (url == null || url.isEmpty) throw Exception('生成结果缺少图像数据');
      final imgResp = await _dio.get<List<int>>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          receiveTimeout: const Duration(seconds: 120),
        ),
      );
      bytes = Uint8List.fromList(imgResp.data ?? <int>[]);
    }
    if (bytes.isEmpty) throw Exception('图像数据为空');

    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'novel_illustrations'));
    await dir.create(recursive: true);
    // 文件名按 书+章 hash 稳定命名：同章再次生成覆盖旧图（保留最新一张）。
    final name =
        '${(novelId + '|' + chapterId).hashCode.abs()}.png';
    final file = File(p.join(dir.path, name));
    await file.writeAsBytes(bytes);
    return file.path;
  }

  /// 把生成的本地插图路径编码为可编辑文本占位行（N7 编辑管线格式）。
  static String markerLineFor(String localPath) => '$kNexhubImgMarker$localPath';
}

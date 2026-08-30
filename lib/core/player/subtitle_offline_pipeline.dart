/// 视频离线整片翻译管线（F6 一期）。
///
/// 面向「已有外挂字幕文件（srt/vtt/ass）」的视频：解析全轨 cue →
/// 按 [BatchProtocol] 分块批量翻译（复用字幕逐句链路与提示词）→
/// 每块完成即落盘检查点 → 按原时间轴生成**双语 SRT/ASS** 导出，
/// 可上传 WebDAV。中途中断自动续跑（已完成句不重复计费）。
///
/// 内嵌字幕轨的整轨抽取依赖播放内核接口（media_kit 未暴露全轨
/// `sub-text`），一期不覆盖；详见 docs/features.md 限制说明。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../ai/glossary_manager.dart';
import '../ai/prompt_builder.dart';
import '../ai/translation_exception.dart';
import '../ai/translation_options_store.dart';
import '../ai/vision_translation_client.dart';
import '../services/novel_export_upload_service.dart';
import '../utils/app_log.dart';
import '../../features/novel/domain/novel_summary_settings.dart';
import 'subtitle_file.dart';

/// 离线任务状态。
enum SubtitleJobStatus { pending, running, done, failed }

/// 一条离线翻译任务。
class SubtitleOfflineJob {
  /// 任务 id：`md5(视频路径|字幕路径|语言)`。
  final String id;
  final String videoPath;
  final String videoTitle;
  final String subtitlePath;
  final String lang;
  final int cueCount;

  /// 与 cue 索引对齐的译文列表（空串 = 未译）。
  final List<String> translations;
  final SubtitleJobStatus status;
  final String? error;
  final int updatedAt;

  const SubtitleOfflineJob({
    required this.id,
    required this.videoPath,
    required this.videoTitle,
    required this.subtitlePath,
    required this.lang,
    required this.cueCount,
    required this.translations,
    required this.status,
    this.error,
    required this.updatedAt,
  });

  int get translatedCount =>
      translations.where((t) => t.trim().isNotEmpty).length;

  bool get isComplete => cueCount > 0 && translatedCount >= cueCount;

  SubtitleOfflineJob copyWith({
    List<String>? translations,
    SubtitleJobStatus? status,
    String? error,
    bool clearError = false,
    int? updatedAt,
  }) =>
      SubtitleOfflineJob(
        id: id,
        videoPath: videoPath,
        videoTitle: videoTitle,
        subtitlePath: subtitlePath,
        lang: lang,
        cueCount: cueCount,
        translations: translations ?? this.translations,
        status: status ?? this.status,
        error: clearError ? null : (error ?? this.error),
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'videoPath': videoPath,
        'videoTitle': videoTitle,
        'subtitlePath': subtitlePath,
        'lang': lang,
        'cueCount': cueCount,
        'translations': translations,
        'status': status.name,
        if (error != null) 'error': error,
        'updatedAt': updatedAt,
      };

  factory SubtitleOfflineJob.fromJson(Map<String, dynamic> json) =>
      SubtitleOfflineJob(
        id: json['id'] as String? ?? '',
        videoPath: json['videoPath'] as String? ?? '',
        videoTitle: json['videoTitle'] as String? ?? '',
        subtitlePath: json['subtitlePath'] as String? ?? '',
        lang: json['lang'] as String? ?? 'zh',
        cueCount: (json['cueCount'] as num?)?.toInt() ?? 0,
        translations: <String>[
          for (final t in (json['translations'] as List<dynamic>? ??
              const <dynamic>[]))
            t as String? ?? '',
        ],
        status: SubtitleJobStatus.values.firstWhere(
          (s) => s.name == json['status'],
          orElse: () => SubtitleJobStatus.failed,
        ),
        error: json['error'] as String?,
        updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
      );
}

/// 离线整片翻译管线（ChangeNotifier 暴露任务列表/进度）。
class SubtitleOfflinePipeline extends ChangeNotifier {
  SubtitleOfflinePipeline({
    Box<dynamic>? box,
    VisionTranslationClient? client,
    GlossaryManager? glossary,
    TranslationOptionsStore? options,
  })  : _box = box,
        _client = client ?? VisionTranslationClient(),
        _glossary = glossary ?? GlossaryManager(),
        _options = options ?? TranslationOptionsStore();

  static const String boxName = 'subtitle_offline_jobs';

  /// 分块大小（句/请求）：字幕句子短，默认 20 句。
  static const int kChunkSize = 20;

  final VisionTranslationClient _client;
  final GlossaryManager _glossary;
  final TranslationOptionsStore _options;
  Box<dynamic>? _box;

  /// 运行中的任务（id → 取消标记）。
  final Map<String, bool> _cancelled = <String, bool>{};

  Future<void> init() async {
    if (_box != null) return;
    if (Hive.isBoxOpen(boxName)) {
      _box = Hive.box(boxName);
      return;
    }
    _box = await Hive.openBox(boxName);
  }

  Future<Box<dynamic>> _ensureBox() async {
    if (_box != null) return _box!;
    await init();
    return _box!;
  }

  static String keyFor(String id) => id;

  static String jobIdFor({
    required String videoPath,
    required String subtitlePath,
    required String lang,
  }) =>
      md5.convert(utf8.encode('$videoPath|$subtitlePath|$lang')).toString();

  Future<List<SubtitleOfflineJob>> listJobs() async {
    final box = await _ensureBox();
    final jobs = <SubtitleOfflineJob>[];
    for (final raw in box.values) {
      if (raw is! String || raw.isEmpty) continue;
      try {
        jobs.add(SubtitleOfflineJob.fromJson(
            jsonDecode(raw) as Map<String, dynamic>));
      } on Object {
        // 损坏数据忽略。
      }
    }
    jobs.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return jobs;
  }

  Future<SubtitleOfflineJob?> getJob(String id) async {
    final box = await _ensureBox();
    final raw = box.get(keyFor(id));
    if (raw is! String || raw.isEmpty) return null;
    try {
      return SubtitleOfflineJob.fromJson(
          jsonDecode(raw) as Map<String, dynamic>);
    } on Object {
      return null;
    }
  }

  Future<void> _save(SubtitleOfflineJob job) async {
    final box = await _ensureBox();
    await box.put(keyFor(job.id), jsonEncode(job.toJson()));
    notifyListeners();
  }

  Future<void> removeJob(String id) async {
    final box = await _ensureBox();
    await box.delete(keyFor(id));
    _cancelled[id] = true;
    notifyListeners();
  }

  bool isRunning(String id) => _cancelled.containsKey(id) && !_cancelled[id]!;

  /// 启动（或续跑）一个离线翻译任务；同一任务重复调用会先续跑未完成部分。
  ///
  /// 返回任务 id。失败时任务状态置为 failed 且保留已完成句，可再次
  /// 调用 [start] 续跑。
  Future<String> start({
    required String videoPath,
    required String videoTitle,
    required String subtitlePath,
    required String lang,
    required AiEndpointConfig config,
    int? chunkSize,
  }) async {
    final id = jobIdFor(
        videoPath: videoPath, subtitlePath: subtitlePath, lang: lang);
    final cues = SubtitleFile.parse(await File(subtitlePath).readAsString());
    if (cues.isEmpty) {
      throw const TranslationException('字幕文件解析为空，请确认格式（SRT/VTT/ASS）');
    }
    final existing = await getJob(id);
    final translations = List<String>.generate(
      cues.length,
      (i) =>
          (existing != null && i < existing.translations.length)
              ? existing.translations[i]
              : '',
    );
    var job = SubtitleOfflineJob(
      id: id,
      videoPath: videoPath,
      videoTitle: videoTitle,
      subtitlePath: subtitlePath,
      lang: lang,
      cueCount: cues.length,
      translations: translations,
      status: SubtitleJobStatus.running,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _save(job);
    _cancelled[id] = false;
    // 异步执行：调用方（UI）拿 id 监听进度即可。
    unawaited(_run(job, cues, config, chunkSize ?? kChunkSize));
    return id;
  }

  Future<void> _run(
    SubtitleOfflineJob job,
    List<SubtitleCue> cues,
    AiEndpointConfig config,
    int chunkSize,
  ) async {
    final id = job.id;
    try {
      var translations = List<String>.of(job.translations);
      // F1/F8：全局术语表 + 风格（离线管线与实时字幕共用注入方式）。
      var glossary = const <GlossaryEntry>[];
      var style = TranslationStyle.standard;
      var lightweight = false;
      try {
        final master =
            await NovelSummarySettings.instance.getTranslationTargetLanguage();
        glossary = await _glossary.effectiveEntriesWithFallback(
            GlossaryManager.globalWorkId, job.lang, master);
        style = await _options.effectiveStyle(null);
        lightweight = await _options.getSubtitleLightweight();
      } on Object {
        // 选项读取失败按默认。
      }
      final system = PromptBuilder.subtitleSystemPrompt(
        lang: job.lang,
        glossary: glossary,
        style: style,
        lightweight: lightweight,
      );
      for (var start = 0; start < cues.length; start += chunkSize) {
        if (_cancelled[id] == true) return;
        final end = (start + chunkSize).clamp(0, cues.length);
        final already = <String>[
          for (var i = start; i < end; i++) translations[i],
        ];
        if (already.every((t) => t.trim().isNotEmpty)) continue;
        final texts = <String>[
          for (var i = start; i < end; i++) cues[i].text,
        ];
        final result = await _client.translateBatch(
          config: config,
          targetLang: job.lang,
          texts: texts,
          lightweight: lightweight,
          systemPrompt: system,
        );
        for (var i = 0; i < texts.length; i++) {
          translations[start + i] = result[i].trim();
        }
        // F6：逐块检查点（不重复计费）。
        await _save(job.copyWith(
          translations: List<String>.of(translations),
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ));
      }
      if (_cancelled[id] == true) return;
      await _save(job.copyWith(
        translations: translations,
        status: SubtitleJobStatus.done,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ));
    } on Object catch (e) {
      AppLog.instance.w('[字幕离线] 任务失败 id=$id: $e');
      if (_cancelled[id] == true) return;
      final current = await getJob(id);
      if (current != null) {
        await _save(current.copyWith(
          status: SubtitleJobStatus.failed,
          error: TranslationException.from(e).message,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ));
      }
    } finally {
      _cancelled.remove(id);
      notifyListeners();
    }
  }

  void cancel(String id) {
    _cancelled[id] = true;
    notifyListeners();
  }

  // ── 导出（双语 SRT / ASS）与 WebDAV 上传 ──

  /// 生成导出文件；返回本地路径（临时目录 `nexhub/subtitles/`）。
  Future<String> export({
    required SubtitleOfflineJob job,
    required bool ass,
  }) async {
    final cues = SubtitleFile.parse(await File(job.subtitlePath).readAsString());
    final translations = job.translations;
    for (var i = 0; i < cues.length && i < translations.length; i++) {
      cues[i].translation = translations[i];
    }
    final content = ass
        ? SubtitleFile.buildBilingualAss(cues, title: job.videoTitle)
        : SubtitleFile.buildBilingualSrt(cues);
    final dir = await getTemporaryDirectory();
    final out = Directory(p.join(dir.path, 'nexhub', 'subtitles'));
    if (!out.existsSync()) out.createSync(recursive: true);
    final base = p.basenameWithoutExtension(job.subtitlePath);
    final safe = base.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final file = File(p.join(
        out.path, '${safe}_双语.${ass ? 'ass' : 'srt'}'));
    await file.writeAsString(content);
    return file.path;
  }

  /// 上传导出文件到 WebDAV（best-effort；未配置时抛异常由 UI 提示）。
  Future<String> uploadToWebDav(String filePath) async {
    final result = await NovelExportUploadService().uploadFile(filePath);
    return result.remoteUrl;
  }
}

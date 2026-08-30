/// 翻译审查报告持久化（F5 多阶段质量：证据驱动审查）。
///
/// 每条结论附带「原文 / 译文 / 位置」证据；报告按 书 + 语言 存 Hive
/// box `novel_review_reports`，并落 JSON 文件（应用文档目录
/// `nexhub/reviews/`）供外部查看。默认仅保留摘要版（条数封顶防刷屏）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 审查发现类型。
class ReviewFindingType {
  static const String glossary = 'glossary';
  static const String missing = 'missing';
  static const String literal = 'literal';
  static const String unsupported = 'unsupported';
}

/// 单条审查发现（证据驱动：原文/译文/位置齐备）。
class TranslationReviewFinding {
  final String type;
  final String chapterId;
  final String chapterTitle;
  final int paragraphIndex;

  /// 证据原文（术语类可为空串）。
  final String source;
  final String translation;
  final String detail;

  const TranslationReviewFinding({
    required this.type,
    required this.chapterId,
    required this.chapterTitle,
    required this.paragraphIndex,
    required this.source,
    required this.translation,
    required this.detail,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'type': type,
        'chapterId': chapterId,
        'chapterTitle': chapterTitle,
        'paragraphIndex': paragraphIndex,
        'source': source,
        'translation': translation,
        'detail': detail,
      };

  factory TranslationReviewFinding.fromJson(Map<String, dynamic> json) =>
      TranslationReviewFinding(
        type: json['type'] as String? ?? '',
        chapterId: json['chapterId'] as String? ?? '',
        chapterTitle: json['chapterTitle'] as String? ?? '',
        paragraphIndex: (json['paragraphIndex'] as num?)?.toInt() ?? -1,
        source: json['source'] as String? ?? '',
        translation: json['translation'] as String? ?? '',
        detail: json['detail'] as String? ?? '',
      );
}

/// 一本书的审查报告。
class TranslationReviewReport {
  final String novelId;
  final String lang;
  final String novelTitle;
  final int createdAt;
  final int chaptersReviewed;
  final List<TranslationReviewFinding> findings;

  /// true = 超出摘要版上限被截断（完整版见落盘 JSON）。
  final bool truncated;

  const TranslationReviewReport({
    required this.novelId,
    required this.lang,
    required this.novelTitle,
    required this.createdAt,
    required this.chaptersReviewed,
    required this.findings,
    required this.truncated,
  });

  Map<String, int> get countsByType {
    final m = <String, int>{};
    for (final f in findings) {
      m[f.type] = (m[f.type] ?? 0) + 1;
    }
    return m;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'novelId': novelId,
        'lang': lang,
        'novelTitle': novelTitle,
        'createdAt': createdAt,
        'chaptersReviewed': chaptersReviewed,
        'truncated': truncated,
        'findings': <Map<String, dynamic>>[
          for (final f in findings) f.toJson(),
        ],
      };

  factory TranslationReviewReport.fromJson(Map<String, dynamic> json) =>
      TranslationReviewReport(
        novelId: json['novelId'] as String? ?? '',
        lang: json['lang'] as String? ?? 'zh',
        novelTitle: json['novelTitle'] as String? ?? '',
        createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
        chaptersReviewed: (json['chaptersReviewed'] as num?)?.toInt() ?? 0,
        findings: <TranslationReviewFinding>[
          for (final f in (json['findings'] as List<dynamic>? ??
              const <dynamic>[]))
            if (f is Map<String, dynamic>) TranslationReviewFinding.fromJson(f),
        ],
        truncated: json['truncated'] as bool? ?? false,
      );
}

/// 审查报告管理器——Hive box `novel_review_reports`，键 `novelId|lang`。
class NovelReviewManager {
  NovelReviewManager({Box<dynamic>? box}) : _box = box;

  static const String boxName = 'novel_review_reports';

  /// 摘要版条数上限（成本护栏：报告默认仅生成摘要版）。
  static const int summaryMaxFindings = 100;

  Box<dynamic>? _box;

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

  static String keyFor(String novelId, String lang) => '$novelId|$lang';

  Future<void> save(TranslationReviewReport report) async {
    final box = await _ensureBox();
    await box.put(keyFor(report.novelId, report.lang),
        jsonEncode(report.toJson()));
  }

  Future<TranslationReviewReport?> load(String novelId,
      {String lang = 'zh'}) async {
    final box = await _ensureBox();
    final raw = box.get(keyFor(novelId, lang));
    if (raw is! String || raw.isEmpty) return null;
    try {
      return TranslationReviewReport.fromJson(
          jsonDecode(raw) as Map<String, dynamic>);
    } on Object {
      return null;
    }
  }

  /// 已有报告的全部作品（审查入口列表标记用）。
  Future<Set<String>> listReviewedNovelIds() async {
    final box = await _ensureBox();
    final ids = <String>{};
    for (final key in box.keys) {
      if (key is! String) continue;
      final idx = key.lastIndexOf('|');
      if (idx > 0) ids.add(key.substring(0, idx));
    }
    return ids;
  }

  /// 报告落盘（应用文档目录 `nexhub/reviews/`）；失败静默（Hive 已有副本）。
  static Future<String?> writeReportFile(TranslationReviewReport report) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final out = Directory(p.join(dir.path, 'nexhub', 'reviews'));
      if (!out.existsSync()) out.createSync(recursive: true);
      final safeName = report.novelId.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final file = File(p.join(
          out.path, '${safeName}_${report.lang}_${report.createdAt}.json'));
      await file.writeAsString(
          const JsonEncoder.withIndent('  ').convert(report.toJson()));
      return file.path;
    } on Object {
      return null;
    }
  }
}

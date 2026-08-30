/// 翻译术语表管理器（F1：术语表与人名一致性）。
///
/// 按「作品|语言」维度把术语条目持久化到 Hive box `translation_glossaries`，
/// 作品维度为空串（`''`）表示**全局术语表**（视频字幕等无作品身份的模块使用）；
/// 生效条目 = 全局 + 当前作品（同术语时作品级覆盖全局）。
///
/// 提示词注入统一经 [PromptBuilder.glossarySection]（core/ai/prompt_builder.dart），
/// 响应侧冲突检测走 [detectConflicts]（结果仅入日志，修正通道后续迭代）。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

/// 单条术语。
class GlossaryEntry {
  final String id;

  /// 原文术语（日文/英文名词原样）。
  final String term;

  /// 统一译名（全书唯一）。
  final String preferred;

  /// 可接受的别名（冲突检测时不告警）。
  final List<String> aliases;

  /// 备注（音译理由 / 出场说明等，不注入提示词正文，仅编辑器展示）。
  final String note;

  const GlossaryEntry({
    required this.id,
    required this.term,
    required this.preferred,
    this.aliases = const <String>[],
    this.note = '',
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'term': term,
        'preferred': preferred,
        'aliases': aliases,
        if (note.isNotEmpty) 'note': note,
      };

  factory GlossaryEntry.fromJson(Map<String, dynamic> json) => GlossaryEntry(
        id: json['id'] as String? ?? '',
        term: json['term'] as String? ?? '',
        preferred: json['preferred'] as String? ?? '',
        aliases: <String>[
          for (final a in (json['aliases'] as List<dynamic>? ?? const <dynamic>[]))
            a as String? ?? '',
        ].where((a) => a.isNotEmpty).toList(),
        note: json['note'] as String? ?? '',
      );

  GlossaryEntry copyWith({
    String? id,
    String? term,
    String? preferred,
    List<String>? aliases,
    String? note,
  }) =>
      GlossaryEntry(
        id: id ?? this.id,
        term: term ?? this.term,
        preferred: preferred ?? this.preferred,
        aliases: aliases ?? this.aliases,
        note: note ?? this.note,
      );
}

/// 术语表管理器——Hive box `translation_glossaries`，键 `workId|lang`。
class GlossaryManager {
  GlossaryManager({Box<dynamic>? box}) : _box = box;

  static const String boxName = 'translation_glossaries';

  /// 全局术语表的 workId 占位（视频字幕等无作品身份的模块）。
  static const String globalWorkId = '';

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

  static String keyFor(String workId, String lang) => '$workId|$lang';

  Future<List<GlossaryEntry>> _readKey(String key) async {
    final box = await _ensureBox();
    final raw = box.get(key);
    if (raw is! String || raw.isEmpty) return const <GlossaryEntry>[];
    try {
      final dynamic decoded = jsonDecode(raw);
      if (decoded is! List) return const <GlossaryEntry>[];
      return <GlossaryEntry>[
        for (final dynamic item in decoded)
          if (item is Map<String, dynamic>) GlossaryEntry.fromJson(item),
      ];
    } on Object {
      return const <GlossaryEntry>[]; // 损坏数据按空表处理。
    }
  }

  Future<void> _writeKey(String key, List<GlossaryEntry> entries) async {
    final box = await _ensureBox();
    if (entries.isEmpty) {
      await box.delete(key);
      return;
    }
    await box.put(
      key,
      jsonEncode(<Map<String, dynamic>>[for (final e in entries) e.toJson()]),
    );
  }

  /// 某作品（或全局）某语言的全部术语。
  Future<List<GlossaryEntry>> entriesFor(String workId, String lang) =>
      _readKey(keyFor(workId, lang));

  /// 生效术语表：全局 + 作品级（同 term 时作品级覆盖全局，保序去重）。
  Future<List<GlossaryEntry>> effectiveEntries(String? workId, String lang) async {
    final global = await _readKey(keyFor(globalWorkId, lang));
    if (workId == null || workId.isEmpty || workId == globalWorkId) return global;
    final work = await _readKey(keyFor(workId, lang));
    if (work.isEmpty) return global;
    final merged = <GlossaryEntry>[...global];
    final seen = <String>{for (final e in global) e.term};
    for (final e in work) {
      if (seen.contains(e.term)) {
        final idx = merged.indexWhere((g) => g.term == e.term);
        if (idx >= 0) merged[idx] = e;
      } else {
        merged.add(e);
        seen.add(e.term);
      }
    }
    return merged;
  }

  /// 生效术语表（带语言回落）：优先 [lang]（各功能自己的目标语言），
  /// 该语言下完全无条目时回落 [fallbackLang]（小说翻译的主目标语言），
  /// 避免多模块语言不一致时术语表「失明」。
  Future<List<GlossaryEntry>> effectiveEntriesWithFallback(
    String? workId,
    String lang,
    String fallbackLang,
  ) async {
    final primary = await effectiveEntries(workId, lang);
    if (primary.isNotEmpty || lang == fallbackLang) return primary;
    return effectiveEntries(workId, fallbackLang);
  }

  /// 新增或更新（按 id 匹配；id 为空时生成）。返回保存后的完整列表。
  Future<List<GlossaryEntry>> saveEntry(
    String workId,
    String lang,
    GlossaryEntry entry,
  ) async {
    final list = <GlossaryEntry>[...await _readKey(keyFor(workId, lang))];
    final id = entry.id.isEmpty
        ? 'g${DateTime.now().microsecondsSinceEpoch}'
        : entry.id;
    final next = entry.id.isEmpty ? entry.copyWith(id: id) : entry;
    final idx = list.indexWhere((e) => e.id == id);
    if (idx >= 0) {
      list[idx] = next;
    } else {
      list.add(next);
    }
    await _writeKey(keyFor(workId, lang), list);
    return list;
  }

  /// 删除条目。返回删除后的完整列表。
  Future<List<GlossaryEntry>> removeEntry(
    String workId,
    String lang,
    String id,
  ) async {
    final list = <GlossaryEntry>[...await _readKey(keyFor(workId, lang))];
    list.removeWhere((e) => e.id == id);
    await _writeKey(keyFor(workId, lang), list);
    return list;
  }

  /// 用 [entries] 整体替换某作品（或全局）的术语表（导入用）。
  Future<void> replaceAll(
    String workId,
    String lang,
    List<GlossaryEntry> entries,
  ) async {
    await _writeKey(keyFor(workId, lang), entries);
  }

  /// 导出 JSON 字符串（术语数组，跨设备迁移用）。
  static String exportJson(List<GlossaryEntry> entries) => jsonEncode(
        <Map<String, dynamic>>[for (final e in entries) e.toJson()],
      );

  /// 解析导入的 JSON；格式非法时抛 [FormatException]。
  static List<GlossaryEntry> parseImportJson(String raw) {
    final dynamic decoded = jsonDecode(raw);
    if (decoded is! List) throw const FormatException('术语表格式应为数组');
    return <GlossaryEntry>[
      for (final dynamic item in decoded)
        if (item is Map) GlossaryEntry.fromJson(item.cast<String, dynamic>()),
    ];
  }

  /// 导入合并：同 term 覆盖、新 term 追加（写入 [workId] 表）。返回合并后列表。
  Future<List<GlossaryEntry>> importMerge(
    String workId,
    String lang,
    List<GlossaryEntry> incoming,
  ) async {
    final list = <GlossaryEntry>[...await _readKey(keyFor(workId, lang))];
    for (final e in incoming) {
      if (e.term.trim().isEmpty) continue;
      final idx = list.indexWhere((x) => x.term == e.term);
      if (idx >= 0) {
        list[idx] = e.copyWith(id: list[idx].id);
      } else {
        list.add(e.id.isEmpty
            ? e.copyWith(id: 'g${DateTime.now().microsecondsSinceEpoch}_${list.length}')
            : e);
      }
    }
    await _writeKey(keyFor(workId, lang), list);
    return list;
  }

  /// 术语冲突检测（F1，日志告警通道）：同一术语在原文出现，但译文既非
  /// 首选译名也非任何别名时返回告警描述。
  ///
  /// 纯函数、零副作用，供三个模块在解析译文后调用（当前仅写日志，
  /// 修正通道与 UI 呈现属后续迭代）。
  static List<String> detectConflicts(
    List<GlossaryEntry> entries,
    List<String> sources,
    List<String> translations,
  ) {
    if (entries.isEmpty || sources.length != translations.length) {
      return const <String>[];
    }
    final warnings = <String>[];
    for (final e in entries) {
      if (e.term.trim().isEmpty || e.preferred.trim().isEmpty) continue;
      final ok = <String>{e.preferred, ...e.aliases};
      var hit = false;
      var bad = <String>{};
      for (var i = 0; i < sources.length; i++) {
        if (!sources[i].contains(e.term)) continue;
        hit = true;
        if (!ok.any(translations[i].contains)) {
          bad.add(translations[i].isEmpty ? '（空译文）' : translations[i]);
        }
      }
      if (hit && bad.isNotEmpty) {
        warnings.add('术语「${e.term}」应译为「${e.preferred}」，'
            '实际出现：${bad.take(3).join(' / ')}');
      }
    }
    return warnings;
  }
}

/// 术语表变更通知（编辑器与设置页刷新用；轻量 ChangeNotifier）。
class GlossaryChangeNotifier extends ChangeNotifier {
  GlossaryChangeNotifier._();
  static final GlossaryChangeNotifier instance = GlossaryChangeNotifier._();

  void notifyChanged() => notifyListeners();
}

/// 小说正文内容编辑管理器（N7：读者直接改正文并持久化）。
///
/// 按 书 + 章 保存编辑后的完整正文块列表到 Hive box `novel_content_edits`。
/// 编辑以「整章覆盖」为语义：加载章节时若存在编辑记录，则以编辑块列表
/// 替换抓取结果（替换净化规则与繁简转换仍在其后照常应用，互不冲突）。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../models/novel_block.dart';
import '../../core/local/local_novel_parser.dart' show kNexhubImgMarker;

/// 标题行前缀标记：可编辑文本中以该前缀开头的行解析为标题块。
const String kNexhubHeadingMarker = '@@NEXHUB_TITLE@@';

/// 单条章节内容编辑记录。
class NovelContentEdit {
  final String novelId;
  final String chapterId;
  final int chapterIndex;
  final String chapterTitle;
  final List<NovelBlock> blocks;
  final int updatedAt;

  const NovelContentEdit({
    required this.novelId,
    required this.chapterId,
    required this.chapterIndex,
    required this.chapterTitle,
    required this.blocks,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'novelId': novelId,
        'chapterId': chapterId,
        'chapterIndex': chapterIndex,
        'chapterTitle': chapterTitle,
        'blocks': <Map<String, dynamic>>[
          for (final b in blocks)
            if (b is NovelTextBlock)
              <String, dynamic>{'t': 'x', 'h': b.isHeading, 'v': b.text}
            else if (b is NovelImageBlock)
              <String, dynamic>{'t': 'i', 'u': b.url, 's': b.style},
        ],
        'updatedAt': updatedAt,
      };

  factory NovelContentEdit.fromJson(Map<String, dynamic> json) {
    final rawBlocks = json['blocks'] as List<dynamic>? ?? const <dynamic>[];
    return NovelContentEdit(
      novelId: json['novelId'] as String? ?? '',
      chapterId: json['chapterId'] as String? ?? '',
      chapterIndex: (json['chapterIndex'] as num?)?.toInt() ?? 0,
      chapterTitle: json['chapterTitle'] as String? ?? '',
      blocks: <NovelBlock>[
        for (final raw in rawBlocks)
          if (raw is Map<String, dynamic>)
            if (raw['t'] == 'i')
              NovelImageBlock(
                raw['u'] as String? ?? '',
                style: raw['s'] as String?,
              )
            else
              NovelTextBlock(
                raw['v'] as String? ?? '',
                isHeading: raw['h'] as bool? ?? false,
              ),
      ],
      updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 正文内容编辑管理器——Hive box `novel_content_edits`，键 `novelId|chapterId`。
class NovelContentEditManager extends ChangeNotifier {
  NovelContentEditManager({Box<dynamic>? box}) : _box = box;

  /// Hive box 名。
  static const String boxName = 'novel_content_edits';

  Box<dynamic>? _box;

  /// 存储不可用降级标记（如测试环境未初始化 Hive 时 openBox 可能**永久挂起**
  /// 而非抛错——该管理器位于章节加载热路径，必须快速失败避免阅读器无限转圈）。
  bool _degraded = false;

  Future<void> init() async {
    if (_box != null) return;
    if (_degraded) throw StateError('novel_content_edits 存储不可用');
    if (Hive.isBoxOpen(boxName)) {
      _box = Hive.box(boxName);
      return;
    }
    try {
      _box = await Hive.openBox(boxName).timeout(
            const Duration(seconds: 2),
            onTimeout: () => throw StateError('openBox 超时'),
          );
    } on Object {
      _degraded = true;
      rethrow;
    }
  }

  Future<Box<dynamic>> _ensureBox() async {
    if (_box != null) return _box!;
    await init();
    return _box!;
  }

  static String keyFor(String novelId, String chapterId) =>
      '$novelId|$chapterId';

  /// 保存（覆盖）某章的编辑内容。
  Future<void> save(NovelContentEdit edit) async {
    final box = await _ensureBox();
    await box.put(
      keyFor(edit.novelId, edit.chapterId),
      jsonEncode(edit.toJson()),
    );
    notifyListeners();
  }

  /// 读取某章的编辑内容；无编辑返回 null。
  Future<NovelContentEdit?> load(String novelId, String chapterId) async {
    final box = await _ensureBox();
    final raw = box.get(keyFor(novelId, chapterId));
    if (raw is! String || raw.isEmpty) return null;
    try {
      return NovelContentEdit.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } on Object {
      // 损坏数据按无编辑处理。
      return null;
    }
  }

  /// 是否存在某章的编辑（同步快速判断需先 [load]，此方法供列表页等场景）。
  Future<bool> hasEdit(String novelId, String chapterId) async {
    final edit = await load(novelId, chapterId);
    return edit != null;
  }

  /// 移除某章的编辑（恢复原文）。
  Future<void> remove(String novelId, String chapterId) async {
    final box = await _ensureBox();
    await box.delete(keyFor(novelId, chapterId));
    notifyListeners();
  }

  /// 列出某本书全部被编辑过的章节（按更新时间倒序）。
  Future<List<NovelContentEdit>> listForNovel(String novelId) async {
    final box = await _ensureBox();
    final result = <NovelContentEdit>[];
    for (final key in box.keys) {
      final raw = box.get(key);
      if (raw is! String || raw.isEmpty) continue;
      try {
        final e = NovelContentEdit.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
        if (e.novelId == novelId) result.add(e);
      } on Object {
        // 损坏数据忽略。
      }
    }
    result.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return result;
  }

  // ── 可编辑文本序列化（编辑框 ↔ 块列表）──────────────────────────

  /// 把块列表序列化为编辑框文本：图片块独占一行 `@@NEXHUB_IMG@@url`，
  /// 标题块行首加 `@@NEXHUB_TITLE@@` 前缀；普通段落原样保留换行。
  static String encodeBlocksToEditableText(List<NovelBlock> blocks) =>
      blocks.map((NovelBlock b) {
        if (b is NovelImageBlock) return '$kNexhubImgMarker${b.url}';
        if (b is NovelTextBlock && b.isHeading) {
          return '$kNexhubHeadingMarker${b.text}';
        }
        return b is NovelTextBlock ? b.text : '';
      }).join('\n\n');

  /// 解析编辑框文本回块列表：空行分段；标记行转图片 / 标题块；
  /// 其余为普通文本段。段内保留用户输入的单换行（由阅读器排版层处理）。
  ///
  /// 边界清理刻意**不使用 [String.trim]**：trim 会把段首全角缩进（U+3000，
  /// 中文正文标准「　　」两格）一并剥掉，导致保存后全文顶格。此处只去
  /// 制表符 / 换行 / 半角空白，全角空格视为正文的一部分。
  static List<NovelBlock> parseEditableText(String text) {
    final paragraphs = text.split(RegExp(r'\n\s*\n'));
    final result = <NovelBlock>[];
    for (var p in paragraphs) {
      p = _stripEdges(p);
      if (p.isEmpty) continue;
      if (p.startsWith(kNexhubImgMarker)) {
        final url = p.substring(kNexhubImgMarker.length).trim();
        if (url.isNotEmpty) result.add(NovelImageBlock(url));
        continue;
      }
      if (p.startsWith(kNexhubHeadingMarker)) {
        final title = p.substring(kNexhubHeadingMarker.length).trim();
        if (title.isNotEmpty) {
          result.add(NovelTextBlock(title, isHeading: true));
        }
        continue;
      }
      result.add(NovelTextBlock(p));
    }
    return result;
  }

  /// 去除段落首尾的制表符 / 换行 / 半角空格（不含全角 U+3000）。
  static String _stripEdges(String s) => s
      .replaceAll(RegExp(r'^[\t\n\r\f\v ]+'), '')
      .replaceAll(RegExp(r'[\t\n\r\f\v ]+$'), '');
}

/// 规则编译缓存：排版期编译规则缓存 + 局部重排。
///
/// 按书籍存储预编译的替换/高亮规则。规则变更时只清空缓存并触发局部重排，
/// 不重拉全书正文，避免流量浪费。
library;

import 'dart:convert';
import '../comic/models/reader_preferences.dart';
import 'novel_replace_rule.dart';
import 'novel_highlight_rule.dart';

/// 单本书的规则缓存快照。
class _BookRuleCache {
  final String bookId;
  NovelReplaceRuleSet? replaceRules;
  NovelHighlightRuleSet? highlightRules;

  _BookRuleCache(this.bookId);
}

class NovelRuleCache {
  NovelRuleCache._();

  static final NovelRuleCache _instance = NovelRuleCache._();
  factory NovelRuleCache() => _instance;

  final Map<String, _BookRuleCache> _cache = {};

  static const String _replaceKey = 'novel_replace_rules_v1';
  static const String _highlightKey = 'novel_highlight_rules_v1';

  final PrefsBackend _backend = const SharedPrefsBackend();

  // ─── 替换规则 ───

  /// 获取某本书的替换规则。优先返回缓存，无则从持久化加载。
  Future<NovelReplaceRuleSet> getReplaceRules(String bookId) async {
    final entry = _cache.putIfAbsent(bookId, () => _BookRuleCache(bookId));
    if (entry.replaceRules != null) return entry.replaceRules!;
    entry.replaceRules = await _loadReplaceRules(bookId);
    return entry.replaceRules!;
  }

  /// 保存替换规则（持久化 + 更新缓存）。
  Future<void> saveReplaceRules(NovelReplaceRuleSet rules) async {
    final key = '$_replaceKey::${rules.bookId}';
    await _backend.set(key, jsonEncode(rules.toJson()));
    final entry = _cache.putIfAbsent(rules.bookId, () => _BookRuleCache(rules.bookId));
    entry.replaceRules = rules;
  }

  /// 标记替换规则缓存无效（触发局部重排）。
  void invalidateReplaceRules(String bookId) {
    _cache.remove(bookId);
  }

  // ─── 高亮规则 ───

  /// 获取某本书的高亮规则。
  Future<NovelHighlightRuleSet> getHighlightRules(String bookId) async {
    final entry = _cache.putIfAbsent(bookId, () => _BookRuleCache(bookId));
    if (entry.highlightRules != null) return entry.highlightRules!;
    entry.highlightRules = await _loadHighlightRules(bookId);
    return entry.highlightRules!;
  }

  /// 保存高亮规则（持久化 + 更新缓存）。
  Future<void> saveHighlightRules(NovelHighlightRuleSet rules) async {
    final key = '$_highlightKey::${rules.bookId}';
    await _backend.set(key, jsonEncode(rules.toJson()));
    final entry = _cache.putIfAbsent(rules.bookId, () => _BookRuleCache(rules.bookId));
    entry.highlightRules = rules;
  }

  /// 标记高亮规则缓存无效。
  void invalidateHighlightRules(String bookId) {
    _cache.remove(bookId);
  }

  /// 清空全部缓存（切换书籍/退出时调用）。
  void clear() => _cache.clear();

  // ─── 持久化 ───

  Future<NovelReplaceRuleSet> _loadReplaceRules(String bookId) async {
    final key = '$_replaceKey::$bookId';
    final raw = await _backend.get(key);
    if (raw == null || raw.isEmpty) return NovelReplaceRuleSet(bookId: bookId, enabled: false);
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return NovelReplaceRuleSet.fromJson(decoded);
      }
    } catch (_) {}
    return NovelReplaceRuleSet(bookId: bookId, enabled: false);
  }

  Future<NovelHighlightRuleSet> _loadHighlightRules(String bookId) async {
    final key = '$_highlightKey::$bookId';
    final raw = await _backend.get(key);
    if (raw == null || raw.isEmpty) return NovelHighlightRuleSet(bookId: bookId, enabled: false);
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return NovelHighlightRuleSet.fromJson(decoded);
      }
    } catch (_) {}
    return NovelHighlightRuleSet(bookId: bookId, enabled: false);
  }
}
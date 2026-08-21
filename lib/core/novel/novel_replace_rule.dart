/// 替换规则模型：正文净化规则（对标 legado ReplaceRule）。
///
/// 支持多条规则按 order 排序，scope 限定作用范围（标题/正文/全部），
/// isRegex 切换正则/纯文本替换，timeout 防死循环，书籍级开关。
library;

class NovelReplaceRule {
  final String id;
  String name;
  String group;
  String pattern;
  String replacement;
  String scope; // 'all' | 'title' | 'content'
  bool isEnabled;
  bool isRegex;
  int timeoutMilliseconds;
  int order;

  NovelReplaceRule({
    String? id,
    this.name = '',
    this.group = '',
    this.pattern = '',
    this.replacement = '',
    this.scope = 'content',
    this.isEnabled = true,
    this.isRegex = true,
    this.timeoutMilliseconds = 3000,
    this.order = 0,
  }) : id = id ?? _uuid();

  static String _uuid() => DateTime.now().microsecondsSinceEpoch.toRadixString(36);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'group': group,
        'pattern': pattern,
        'replacement': replacement,
        'scope': scope,
        'isEnabled': isEnabled,
        'isRegex': isRegex,
        'timeoutMilliseconds': timeoutMilliseconds,
        'order': order,
      };

  factory NovelReplaceRule.fromJson(Map<String, dynamic> json) => NovelReplaceRule(
        id: json['id'] as String?,
        name: json['name'] as String? ?? '',
        group: json['group'] as String? ?? '',
        pattern: json['pattern'] as String? ?? '',
        replacement: json['replacement'] as String? ?? '',
        scope: json['scope'] as String? ?? 'content',
        isEnabled: json['isEnabled'] as bool? ?? true,
        isRegex: json['isRegex'] as bool? ?? true,
        timeoutMilliseconds: json['timeoutMilliseconds'] as int? ?? 3000,
        order: json['order'] as int? ?? 0,
      );

  NovelReplaceRule copyWith({
    String? name,
    String? group,
    String? pattern,
    String? replacement,
    String? scope,
    bool? isEnabled,
    bool? isRegex,
    int? timeoutMilliseconds,
    int? order,
  }) =>
      NovelReplaceRule(
        id: id,
        name: name ?? this.name,
        group: group ?? this.group,
        pattern: pattern ?? this.pattern,
        replacement: replacement ?? this.replacement,
        scope: scope ?? this.scope,
        isEnabled: isEnabled ?? this.isEnabled,
        isRegex: isRegex ?? this.isRegex,
        timeoutMilliseconds: timeoutMilliseconds ?? this.timeoutMilliseconds,
        order: order ?? this.order,
      );

  /// 检查规则是否有效（pattern 非空）。
  bool isValid() => pattern.isNotEmpty;

  /// 编译后的正则（缓存，惰性）。
  RegExp? get compiledRegex {
    if (!isRegex || pattern.isEmpty) return null;
    try {
      return RegExp(pattern, multiLine: true);
    } on FormatException {
      return null;
    }
  }

  @override
  String toString() => 'NovelReplaceRule($name)';
}

/// 替换规则集合：按书籍管理多条替换规则 + 开/关状态。
class NovelReplaceRuleSet {
  final String bookId;
  bool enabled;
  List<NovelReplaceRule> rules;

  NovelReplaceRuleSet({
    required this.bookId,
    this.enabled = true,
    List<NovelReplaceRule>? rules,
  }) : rules = rules ?? [];

  Map<String, dynamic> toJson() => {
        'bookId': bookId,
        'enabled': enabled,
        'rules': rules.map((r) => r.toJson()).toList(),
      };

  factory NovelReplaceRuleSet.fromJson(Map<String, dynamic> json) =>
      NovelReplaceRuleSet(
        bookId: json['bookId'] as String,
        enabled: json['enabled'] as bool? ?? true,
        rules: (json['rules'] as List?)
                ?.map((e) => NovelReplaceRule.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [],
      );

  /// 对正文文本应用所有启用的替换规则。
  /// [scopeFilter] 限制规则作用范围（'content' / 'title' / 'all'）。
  String apply(String text, {String scopeFilter = 'content'}) {
    if (!enabled || rules.isEmpty) return text;
    final sorted = [...rules.where((r) => r.isEnabled && r.isValid())]
      ..sort((a, b) => a.order.compareTo(b.order));
    var result = text;
    for (final rule in sorted) {
      if (rule.scope != 'all' && rule.scope != scopeFilter) continue;
      if (rule.isRegex) {
        final re = rule.compiledRegex;
        if (re == null) continue;
        result = result.replaceAll(re, rule.replacement);
      } else {
        result = result.replaceAll(rule.pattern, rule.replacement);
      }
    }
    return result;
  }
}
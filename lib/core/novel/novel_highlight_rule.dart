/// 高亮规则模型：正文高亮规则（对标 legado HighlightRule）。
///
/// pattern 匹配正文段落，匹配到的文本按字色/背景/下划线/字号偏移等
/// 样式渲染。支持 scope 限定（标题/正文/全部），书籍级开关。
library;

class NovelHighlightRule {
  final String id;
  String name;
  String pattern;
  bool isRegex;
  String scope; // 'all' | 'title' | 'content'
  bool enabled;
  int order;

  /// 字色（ABGR 格式 int，null 表示不覆盖）。
  int? textColor;

  /// 背景色（ABGR 格式 int，null 表示不覆盖）。
  int? bgColor;

  /// 下划线模式：0=无, 1=实线, 2=虚线, 3=波浪线, 4=双线, 5=自定义 SVG。
  int underlineMode;

  /// 下划线颜色（null 表示不覆盖）。
  int? underlineColor;

  /// 字号偏移（正数增大，负数缩小）。
  int fontSizeOffset;

  NovelHighlightRule({
    String? id,
    this.name = '',
    this.pattern = '',
    this.isRegex = true,
    this.scope = 'content',
    this.enabled = true,
    this.order = 0,
    this.textColor,
    this.bgColor,
    this.underlineMode = 0,
    this.underlineColor,
    this.fontSizeOffset = 0,
  }) : id = id ?? _uuid();

  static String _uuid() => DateTime.now().microsecondsSinceEpoch.toRadixString(36);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'pattern': pattern,
        'isRegex': isRegex,
        'scope': scope,
        'enabled': enabled,
        'order': order,
        if (textColor != null) 'textColor': textColor,
        if (bgColor != null) 'bgColor': bgColor,
        if (underlineMode != 0) 'underlineMode': underlineMode,
        if (underlineColor != null) 'underlineColor': underlineColor,
        if (fontSizeOffset != 0) 'fontSizeOffset': fontSizeOffset,
      };

  factory NovelHighlightRule.fromJson(Map<String, dynamic> json) =>
      NovelHighlightRule(
        id: json['id'] as String?,
        name: json['name'] as String? ?? '',
        pattern: json['pattern'] as String? ?? '',
        isRegex: json['isRegex'] as bool? ?? true,
        scope: json['scope'] as String? ?? 'content',
        enabled: json['enabled'] as bool? ?? true,
        order: json['order'] as int? ?? 0,
        textColor: json['textColor'] as int?,
        bgColor: json['bgColor'] as int?,
        underlineMode: json['underlineMode'] as int? ?? 0,
        underlineColor: json['underlineColor'] as int?,
        fontSizeOffset: json['fontSizeOffset'] as int? ?? 0,
      );

  NovelHighlightRule copyWith({
    String? name,
    String? pattern,
    bool? isRegex,
    String? scope,
    bool? enabled,
    int? order,
    int? textColor,
    int? bgColor,
    int? underlineMode,
    int? underlineColor,
    int? fontSizeOffset,
  }) =>
      NovelHighlightRule(
        id: id,
        name: name ?? this.name,
        pattern: pattern ?? this.pattern,
        isRegex: isRegex ?? this.isRegex,
        scope: scope ?? this.scope,
        enabled: enabled ?? this.enabled,
        order: order ?? this.order,
        textColor: textColor ?? this.textColor,
        bgColor: bgColor ?? this.bgColor,
        underlineMode: underlineMode ?? this.underlineMode,
        underlineColor: underlineColor ?? this.underlineColor,
        fontSizeOffset: fontSizeOffset ?? this.fontSizeOffset,
      );

  bool isValid() => pattern.isNotEmpty;

  @override
  String toString() => 'NovelHighlightRule($name)';
}

/// 高亮规则集合：按书籍管理多条高亮规则 + 开/关状态。
class NovelHighlightRuleSet {
  final String bookId;
  bool enabled;
  List<NovelHighlightRule> rules;

  NovelHighlightRuleSet({
    required this.bookId,
    this.enabled = true,
    List<NovelHighlightRule>? rules,
  }) : rules = rules ?? [];

  Map<String, dynamic> toJson() => {
        'bookId': bookId,
        'enabled': enabled,
        'rules': rules.map((r) => r.toJson()).toList(),
      };

  factory NovelHighlightRuleSet.fromJson(Map<String, dynamic> json) =>
      NovelHighlightRuleSet(
        bookId: json['bookId'] as String,
        enabled: json['enabled'] as bool? ?? true,
        rules: (json['rules'] as List?)
                ?.map((e) => NovelHighlightRule.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [],
      );
}
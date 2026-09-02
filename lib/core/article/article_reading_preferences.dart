/// Article reading preferences and Hive-persisted notifier.
///
/// Stores font size, line height and night mode for the in-app article
/// reader. Persisted to the shared Hive `settings` box as JSON.
///
/// 排版项已对齐小说阅读器（[NovelReaderPreferences]）的核心渲染维度：字号、
/// 行距、段距、边距、字间距、对齐、加粗/斜体/下划线（含颜色/虚线/线宽）、
/// 背景预设/自定义背景、文字颜色、强调色、阴影、自定义字体文件、标题样式。
/// 滚动式 RSS 阅读不适配的分页/交互项（翻页动画、页眉页脚、点击分区等）
/// 不在此列。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

/// Article reading preferences value object.
class ArticleReadingPreferences {
  final double fontSize;
  final double lineHeight;
  final bool isNightMode;

  /// 正文两端对齐（justify）。默认左对齐。
  final bool justify;

  /// 段落间距（px）。默认 8。
  final double paragraphSpacing;

  /// 内容最大宽度档位：0=窄(480) / 1=标准(680) / 2=宽(840)。默认 1。
  final int contentWidthMode;

  /// 字体族档位：0=系统默认 / 1=衬线 / 2=等宽。默认 0。
  final int fontFamilyMode;

  /// 字间距（逻辑像素），可为负收紧。默认 0。
  final double letterSpacing;

  /// 左右边距（像素，对齐小说 [NovelReaderPreferences.margin]）。默认 16。
  final double margin;

  /// 正文加粗（与斜体/下划线可共存）。
  final bool fontBold;

  /// 正文斜体。
  final bool fontItalic;

  /// 正文下划线。
  final bool fontUnderline;

  /// 下划线颜色（ARGB int；null 跟随文字色）。
  final int? underlineColor;

  /// 下划线是否虚线。
  final bool underlineDashed;

  /// 下划线线宽（像素）。
  final double underlineThickness;

  /// 背景预设索引（引用 [ReaderTokens.bgPresets]）。默认 2=白。
  final int bgPresetIndex;

  /// 自定义背景色（ARGB int；null 时使用预设）。
  final int? customBgColor;

  /// 自定义正文文字色（ARGB int；null 时按背景亮度自动黑/白）。
  final int? customTextColor;

  /// 强调色（ARGB int；null 时用 [ReaderTokens.emphasisDefault]）。
  final int? emphasisColor;

  /// 是否启用文字阴影。
  final bool shadow;

  /// 阴影模糊半径（像素）。
  final double shadowBlur;

  /// 阴影 X 偏移（像素）。
  final double shadowOffsetX;

  /// 阴影 Y 偏移（像素）。
  final double shadowOffsetY;

  /// 自定义字体文件路径（.ttf/.otf；null 用 [fontFamily]）。
  final String? customFontPath;

  /// 标题字号相对正文的倍率（1.0 = 与正文同大）。
  final double titleFontScale;

  /// 标题加粗。
  final bool titleBold;

  /// 标题颜色（ARGB int；null 跟随强调色）。
  final int? titleColor;

  /// 标题对齐：0=左 / 1=中 / 2=右。
  final int titleAlign;

  /// 自定义字体加载后注册的字族名（与小说阅读器一致的做法）。
  static const String customLoadedFontFamily = 'nexhubCustomArticleFont';

  const ArticleReadingPreferences({
    this.fontSize = 16.0,
    this.lineHeight = 1.6,
    this.isNightMode = false,
    this.justify = false,
    this.paragraphSpacing = 8.0,
    this.contentWidthMode = 1,
    this.fontFamilyMode = 0,
    this.letterSpacing = 0.0,
    this.margin = 16.0,
    this.fontBold = false,
    this.fontItalic = false,
    this.fontUnderline = false,
    this.underlineColor,
    this.underlineDashed = false,
    this.underlineThickness = 1.0,
    this.bgPresetIndex = 2,
    this.customBgColor,
    this.customTextColor,
    this.emphasisColor,
    this.shadow = false,
    this.shadowBlur = 4.0,
    this.shadowOffsetX = 0.0,
    this.shadowOffsetY = 1.0,
    this.customFontPath,
    this.titleFontScale = 1.1,
    this.titleBold = true,
    this.titleColor,
    this.titleAlign = 0,
  });

  /// 生效的字体族：自定义字体文件已加载 → 注册字族名；否则按 [fontFamilyMode]
  /// 映射。系统默认不指定（跟随应用主题）。
  String? get fontFamily {
    if (customFontPath != null && customFontPath!.isNotEmpty) {
      return customLoadedFontFamily;
    }
    switch (fontFamilyMode) {
      case 1:
        return 'serif';
      case 2:
        return 'monospace';
      case 0:
      default:
        return null;
    }
  }

  /// 内容最大宽度（逻辑像素），按 [contentWidthMode] 映射。
  double get contentMaxWidth {
    switch (contentWidthMode) {
      case 0:
        return 480.0;
      case 2:
        return 840.0;
      case 1:
      default:
        return 680.0;
    }
  }

  ArticleReadingPreferences copyWith({
    double? fontSize,
    double? lineHeight,
    bool? isNightMode,
    bool? justify,
    double? paragraphSpacing,
    int? contentWidthMode,
    int? fontFamilyMode,
    double? letterSpacing,
    double? margin,
    bool? fontBold,
    bool? fontItalic,
    bool? fontUnderline,
    int? underlineColor,
    bool? underlineDashed,
    double? underlineThickness,
    int? bgPresetIndex,
    int? customBgColor,
    int? customTextColor,
    int? emphasisColor,
    bool? shadow,
    double? shadowBlur,
    double? shadowOffsetX,
    double? shadowOffsetY,
    String? customFontPath,
    double? titleFontScale,
    bool? titleBold,
    int? titleColor,
    int? titleAlign,
  }) =>
      ArticleReadingPreferences(
        fontSize: fontSize ?? this.fontSize,
        lineHeight: lineHeight ?? this.lineHeight,
        isNightMode: isNightMode ?? this.isNightMode,
        justify: justify ?? this.justify,
        paragraphSpacing: paragraphSpacing ?? this.paragraphSpacing,
        contentWidthMode: contentWidthMode ?? this.contentWidthMode,
        fontFamilyMode: fontFamilyMode ?? this.fontFamilyMode,
        letterSpacing: letterSpacing ?? this.letterSpacing,
        margin: margin ?? this.margin,
        fontBold: fontBold ?? this.fontBold,
        fontItalic: fontItalic ?? this.fontItalic,
        fontUnderline: fontUnderline ?? this.fontUnderline,
        underlineColor: underlineColor ?? this.underlineColor,
        underlineDashed: underlineDashed ?? this.underlineDashed,
        underlineThickness: underlineThickness ?? this.underlineThickness,
        bgPresetIndex: bgPresetIndex ?? this.bgPresetIndex,
        customBgColor: customBgColor ?? this.customBgColor,
        customTextColor: customTextColor ?? this.customTextColor,
        emphasisColor: emphasisColor ?? this.emphasisColor,
        shadow: shadow ?? this.shadow,
        shadowBlur: shadowBlur ?? this.shadowBlur,
        shadowOffsetX: shadowOffsetX ?? this.shadowOffsetX,
        shadowOffsetY: shadowOffsetY ?? this.shadowOffsetY,
        customFontPath: customFontPath ?? this.customFontPath,
        titleFontScale: titleFontScale ?? this.titleFontScale,
        titleBold: titleBold ?? this.titleBold,
        titleColor: titleColor ?? this.titleColor,
        titleAlign: titleAlign ?? this.titleAlign,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'fontSize': fontSize,
        'lineHeight': lineHeight,
        'isNightMode': isNightMode,
        'justify': justify,
        'paragraphSpacing': paragraphSpacing,
        'contentWidthMode': contentWidthMode,
        'fontFamilyMode': fontFamilyMode,
        'letterSpacing': letterSpacing,
        'margin': margin,
        'fontBold': fontBold,
        'fontItalic': fontItalic,
        'fontUnderline': fontUnderline,
        'underlineColor': underlineColor,
        'underlineDashed': underlineDashed,
        'underlineThickness': underlineThickness,
        'bgPresetIndex': bgPresetIndex,
        'customBgColor': customBgColor,
        'customTextColor': customTextColor,
        'emphasisColor': emphasisColor,
        'shadow': shadow,
        'shadowBlur': shadowBlur,
        'shadowOffsetX': shadowOffsetX,
        'shadowOffsetY': shadowOffsetY,
        'customFontPath': customFontPath,
        'titleFontScale': titleFontScale,
        'titleBold': titleBold,
        'titleColor': titleColor,
        'titleAlign': titleAlign,
      };

  factory ArticleReadingPreferences.fromJson(Map<String, dynamic> json) =>
      ArticleReadingPreferences(
        fontSize: (json['fontSize'] as num?)?.toDouble() ?? 16.0,
        lineHeight: (json['lineHeight'] as num?)?.toDouble() ?? 1.6,
        isNightMode: json['isNightMode'] as bool? ?? false,
        justify: json['justify'] as bool? ?? false,
        paragraphSpacing: (json['paragraphSpacing'] as num?)?.toDouble() ?? 8.0,
        contentWidthMode: json['contentWidthMode'] as int? ?? 1,
        fontFamilyMode: json['fontFamilyMode'] as int? ?? 0,
        letterSpacing: (json['letterSpacing'] as num?)?.toDouble() ?? 0.0,
        margin: (json['margin'] as num?)?.toDouble() ?? 16.0,
        fontBold: json['fontBold'] as bool? ?? false,
        fontItalic: json['fontItalic'] as bool? ?? false,
        fontUnderline: json['fontUnderline'] as bool? ?? false,
        underlineColor: json['underlineColor'] as int?,
        underlineDashed: json['underlineDashed'] as bool? ?? false,
        underlineThickness:
            (json['underlineThickness'] as num?)?.toDouble() ?? 1.0,
        bgPresetIndex: json['bgPresetIndex'] as int? ?? 2,
        customBgColor: json['customBgColor'] as int?,
        customTextColor: json['customTextColor'] as int?,
        emphasisColor: json['emphasisColor'] as int?,
        shadow: json['shadow'] as bool? ?? false,
        shadowBlur: (json['shadowBlur'] as num?)?.toDouble() ?? 4.0,
        shadowOffsetX: (json['shadowOffsetX'] as num?)?.toDouble() ?? 0.0,
        shadowOffsetY: (json['shadowOffsetY'] as num?)?.toDouble() ?? 1.0,
        customFontPath: json['customFontPath'] as String?,
        titleFontScale: (json['titleFontScale'] as num?)?.toDouble() ?? 1.1,
        titleBold: json['titleBold'] as bool? ?? true,
        titleColor: json['titleColor'] as int?,
        titleAlign: json['titleAlign'] as int? ?? 0,
      );
}

/// Provider-backed notifier persisting article reading prefs to Hive `settings` box.
class ArticleReadingPreferencesNotifier extends ChangeNotifier {
  ArticleReadingPreferencesNotifier() {
    _load();
  }

  ArticleReadingPreferences _prefs = const ArticleReadingPreferences();
  ArticleReadingPreferences get prefs => _prefs;

  static const _boxName = 'settings';
  static const _key = 'article_reading_prefs';

  void _load() {
    try {
      // Guard: the settings box is opened in main() before runApp, but be
      // defensive in case this notifier is constructed earlier in tests.
      if (!Hive.isBoxOpen(_boxName)) return;
      final box = Hive.box(_boxName);
      final raw = box.get(_key);
      if (raw is String) {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          _prefs = ArticleReadingPreferences.fromJson(decoded);
        }
      }
    } catch (_) {
      // Keep defaults on error.
    }
  }

  Future<void> _save() async {
    try {
      if (!Hive.isBoxOpen(_boxName)) return;
      final box = Hive.box(_boxName);
      await box.put(_key, jsonEncode(_prefs.toJson()));
    } catch (_) {
      // Ignore persistence errors.
    }
  }

  void _update(ArticleReadingPreferences next) {
    _prefs = next;
    _save();
    notifyListeners();
  }

  void setFontSize(double value) =>
      _update(_prefs.copyWith(fontSize: value));
  void setLineHeight(double value) =>
      _update(_prefs.copyWith(lineHeight: value));
  void toggleNightMode() =>
      _update(_prefs.copyWith(isNightMode: !_prefs.isNightMode));
  void setJustify(bool value) => _update(_prefs.copyWith(justify: value));
  void setParagraphSpacing(double value) =>
      _update(_prefs.copyWith(paragraphSpacing: value));
  void setContentWidthMode(int mode) =>
      _update(_prefs.copyWith(contentWidthMode: mode));
  void setFontFamilyMode(int mode) =>
      _update(_prefs.copyWith(fontFamilyMode: mode));
  void setLetterSpacing(double value) =>
      _update(_prefs.copyWith(letterSpacing: value));
  void setMargin(double value) => _update(_prefs.copyWith(margin: value));
  void setFontBold(bool v) => _update(_prefs.copyWith(fontBold: v));
  void setFontItalic(bool v) => _update(_prefs.copyWith(fontItalic: v));
  void setFontUnderline(bool v) => _update(_prefs.copyWith(fontUnderline: v));
  void setUnderlineColor(int? c) => _update(_prefs.copyWith(underlineColor: c));
  void setUnderlineDashed(bool v) =>
      _update(_prefs.copyWith(underlineDashed: v));
  void setUnderlineThickness(double v) =>
      _update(_prefs.copyWith(underlineThickness: v));
  void setBgPresetIndex(int i) => _update(_prefs.copyWith(bgPresetIndex: i));
  void setCustomBgColor(int? c) => _update(_prefs.copyWith(customBgColor: c));
  void setCustomTextColor(int? c) =>
      _update(_prefs.copyWith(customTextColor: c));
  void setEmphasisColor(int? c) => _update(_prefs.copyWith(emphasisColor: c));
  void setShadow(bool v) => _update(_prefs.copyWith(shadow: v));
  void setShadowBlur(double v) => _update(_prefs.copyWith(shadowBlur: v));
  void setShadowOffsetX(double v) =>
      _update(_prefs.copyWith(shadowOffsetX: v));
  void setShadowOffsetY(double v) =>
      _update(_prefs.copyWith(shadowOffsetY: v));
  void setCustomFontPath(String? p) =>
      _update(_prefs.copyWith(customFontPath: p));
  void setTitleFontScale(double v) =>
      _update(_prefs.copyWith(titleFontScale: v));
  void setTitleBold(bool v) => _update(_prefs.copyWith(titleBold: v));
  void setTitleColor(int? c) => _update(_prefs.copyWith(titleColor: c));
  void setTitleAlign(int v) => _update(_prefs.copyWith(titleAlign: v));
}

/// Article reading preferences and Hive-persisted notifier.
///
/// Stores font size, line height and night mode for the in-app article
/// reader. Persisted to the shared Hive `settings` box as JSON.
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

  const ArticleReadingPreferences({
    this.fontSize = 16.0,
    this.lineHeight = 1.6,
    this.isNightMode = false,
    this.justify = false,
    this.paragraphSpacing = 8.0,
    this.contentWidthMode = 1,
  });

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
  }) =>
      ArticleReadingPreferences(
        fontSize: fontSize ?? this.fontSize,
        lineHeight: lineHeight ?? this.lineHeight,
        isNightMode: isNightMode ?? this.isNightMode,
        justify: justify ?? this.justify,
        paragraphSpacing: paragraphSpacing ?? this.paragraphSpacing,
        contentWidthMode: contentWidthMode ?? this.contentWidthMode,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'fontSize': fontSize,
        'lineHeight': lineHeight,
        'isNightMode': isNightMode,
        'justify': justify,
        'paragraphSpacing': paragraphSpacing,
        'contentWidthMode': contentWidthMode,
      };

  factory ArticleReadingPreferences.fromJson(Map<String, dynamic> json) =>
      ArticleReadingPreferences(
        fontSize: (json['fontSize'] as num?)?.toDouble() ?? 16.0,
        lineHeight: (json['lineHeight'] as num?)?.toDouble() ?? 1.6,
        isNightMode: json['isNightMode'] as bool? ?? false,
        justify: json['justify'] as bool? ?? false,
        paragraphSpacing: (json['paragraphSpacing'] as num?)?.toDouble() ?? 8.0,
        contentWidthMode: json['contentWidthMode'] as int? ?? 1,
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

  void setFontSize(double value) {
    _prefs = _prefs.copyWith(fontSize: value);
    _save();
    notifyListeners();
  }

  void setLineHeight(double value) {
    _prefs = _prefs.copyWith(lineHeight: value);
    _save();
    notifyListeners();
  }

  void toggleNightMode() {
    _prefs = _prefs.copyWith(isNightMode: !_prefs.isNightMode);
    _save();
    notifyListeners();
  }

  void setJustify(bool value) {
    _prefs = _prefs.copyWith(justify: value);
    _save();
    notifyListeners();
  }

  void setParagraphSpacing(double value) {
    _prefs = _prefs.copyWith(paragraphSpacing: value);
    _save();
    notifyListeners();
  }

  void setContentWidthMode(int mode) {
    _prefs = _prefs.copyWith(contentWidthMode: mode);
    _save();
    notifyListeners();
  }
}

/// 小说导出自定义模板（F4：fonts.css / 封面 / 简介）。
///
/// 全局生效的 EPUB 导出模板配置：
/// - [customCss]：注入 `OEBPS/style.css` 并在每章 XHTML `<head>` 引用，
///   用户可自定义正文字体族（fonts.css 场景）、行距、页边距等；
/// - [intro]：书籍简介页内容，支持 `{book}` / `{author}` 占位符；
/// - [includeCover]：把网络封面嵌入 EPUB 并生成书首封面页；
/// - [includeIntro]：在封面后追加简介页。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 导出模板配置（不可变值对象）。
@immutable
class NovelExportTemplate {
  /// 自定义 CSS（EPUB style.css）。空串表示不生成样式表。
  final String customCss;

  /// 简介文本（纯文本段落，空行分段）。支持 `{book}` / `{author}` 占位符。
  final String intro;

  /// 是否嵌入网络封面并生成封面页。
  final bool includeCover;

  /// 是否生成简介页（[intro] 非空时才有内容）。
  final bool includeIntro;

  const NovelExportTemplate({
    this.customCss = '',
    this.intro = '',
    this.includeCover = true,
    this.includeIntro = true,
  });

  NovelExportTemplate copyWith({
    String? customCss,
    String? intro,
    bool? includeCover,
    bool? includeIntro,
  }) =>
      NovelExportTemplate(
        customCss: customCss ?? this.customCss,
        intro: intro ?? this.intro,
        includeCover: includeCover ?? this.includeCover,
        includeIntro: includeIntro ?? this.includeIntro,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'customCss': customCss,
        'intro': intro,
        'includeCover': includeCover,
        'includeIntro': includeIntro,
      };

  factory NovelExportTemplate.fromJson(Map<String, dynamic> json) =>
      NovelExportTemplate(
        customCss: json['customCss'] as String? ?? '',
        intro: json['intro'] as String? ?? '',
        includeCover: json['includeCover'] as bool? ?? true,
        includeIntro: json['includeIntro'] as bool? ?? true,
      );
}

/// 模板存储：SharedPreferences 单键 JSON（全局配置，非按书）。
class NovelExportTemplateStore {
  NovelExportTemplateStore._();

  static const String _kKey = 'novel_export_template_v1';

  static final NovelExportTemplateStore instance =
      NovelExportTemplateStore._();

  NovelExportTemplate _template = const NovelExportTemplate();
  bool _loaded = false;

  /// 当前模板（未调用 [load] 前为默认值）。
  NovelExportTemplate get template => _template;

  bool get loaded => _loaded;

  /// 从 SharedPreferences 载入（幂等；失败保持默认）。
  Future<NovelExportTemplate> load() async {
    if (_loaded) return _template;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kKey);
      if (raw != null && raw.isNotEmpty) {
        _template = NovelExportTemplate.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
      }
      _loaded = true;
    } on Object {
      // 读取失败保持默认模板。
    }
    return _template;
  }

  Future<void> save(NovelExportTemplate t) async {
    _template = t;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kKey, jsonEncode(t.toJson()));
    } on Object {
      // 写入失败保留内存值。
    }
  }
}

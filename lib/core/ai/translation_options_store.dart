/// 翻译链路可选偏好存储（F8 风格预设 / CoT 开关 / F10 导出排版）。
///
/// - **风格预设**：全局存 SharedPreferences；作品级覆盖存 Hive box
///   `translation_style_overrides`（键 novelId）——作品级优先于全局；
/// - **思维链（CoT）**：全局开关，默认关闭（控成本；仅低批量场景收益明显）；
/// - **小说导出排版**（F10）：译文优先 / 原文优先 / 双语对照。
library;

import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'prompt_builder.dart';

/// 翻译偏好存储（单例语义由调用方持有一个实例即可；内部均为静态键）。
class TranslationOptionsStore {
  TranslationOptionsStore();

  static const String _kStyle = 'translation_style_v1';
  static const String _kCot = 'translation_cot_v1';
  static const String _kExportLayout = 'novel_translation_export_layout_v1';
  static const String _kSubtitleLightweight = 'subtitle_translation_lightweight_v1';
  static const String _kPolish = 'translation_polish_v1';

  static const String _styleBoxName = 'translation_style_overrides';

  Box<dynamic>? _styleBox;

  // ─────────────────── 风格预设（F8）───────────────────

  /// 全局风格预设（默认标准）。
  Future<TranslationStyle> getStyle() async {
    final p = await SharedPreferences.getInstance();
    return TranslationStyle.fromStorage(p.getString(_kStyle));
  }

  Future<void> setStyle(TranslationStyle style) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kStyle, style.storageValue);
  }

  /// 作品级风格覆盖；无覆盖返回 null。
  Future<TranslationStyle?> getStyleOverride(String workId) async {
    final box = await _ensureStyleBox();
    final v = box.get(workId);
    if (v is! String || v.isEmpty) return null;
    return TranslationStyle.fromStorage(v);
  }

  Future<void> setStyleOverride(String workId, TranslationStyle? style) async {
    final box = await _ensureStyleBox();
    if (style == null) {
      await box.delete(workId);
      return;
    }
    await box.put(workId, style.storageValue);
  }

  /// 生效风格：作品级覆盖优先，否则全局。
  Future<TranslationStyle> effectiveStyle(String? workId) async {
    if (workId != null && workId.isNotEmpty) {
      final override = await getStyleOverride(workId);
      if (override != null) return override;
    }
    return getStyle();
  }

  Future<Box<dynamic>> _ensureStyleBox() async {
    if (_styleBox != null) return _styleBox!;
    if (Hive.isBoxOpen(_styleBoxName)) {
      _styleBox = Hive.box(_styleBoxName);
    } else {
      _styleBox = await Hive.openBox(_styleBoxName);
    }
    return _styleBox!;
  }

  // ─────────────────── 思维链（F8）───────────────────

  /// CoT 开关（默认关闭）。
  Future<bool> getCotEnabled() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_kCot) == '1';
  }

  Future<void> setCotEnabled(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kCot, v ? '1' : '0');
  }

  // ─────────────────── 字幕轻量格式（F8）───────────────────

  /// 字幕逐句轻量输出（默认开启：省 token，解析失败自动回退编号协议）。
  Future<bool> getSubtitleLightweight() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_kSubtitleLightweight) != '0';
  }

  Future<void> setSubtitleLightweight(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kSubtitleLightweight, v ? '1' : '0');
  }

  // ─────────────────── 润色（F5）───────────────────

  /// 翻译润色功能开关（默认关闭：润色会使目标章节产生一次额外请求）。
  Future<bool> getPolishEnabled() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_kPolish) == '1';
  }

  Future<void> setPolishEnabled(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kPolish, v ? '1' : '0');
  }

  // ─────────────────── 小说导出排版（F10）───────────────────

  /// 小说译文附录排版：translationFirst=译文优先（现状），
  /// sourceFirst=原文优先，bilingual=双语对照。
  Future<String> getNovelExportLayout() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_kExportLayout) ?? 'translationFirst';
  }

  Future<void> setNovelExportLayout(String layout) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
        _kExportLayout,
        const <String>['translationFirst', 'sourceFirst', 'bilingual']
                .contains(layout)
            ? layout
            : 'translationFirst');
  }
}

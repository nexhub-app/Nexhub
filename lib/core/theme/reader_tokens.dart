import 'package:flutter/material.dart';

/// 阅读器专用 Token（漫画 / 小说共用）。
///
/// 阅读器背景预设、强调色等局部视觉常量集中此处，仍遵循统一治理：
/// 不硬编码散落各处，统一从本文件取。
class ReaderTokens {
  ReaderTokens._();

  /// 夜间模式压暗系数：在所选预设 / 自定义背景基础上向黑色按此比例混合，
  /// 既保留各预设的视觉差异（避免夜间下所有预设看起来同色），又保证护眼。
  static const double nightDarkenFactor = 0.6;

  /// 阅读器背景预设（黑 / 深灰 / 白 / 护眼绿 / 羊皮纸 / 暖黄 / 浅褐 /
  /// 豆沙绿 / 淡青 / 暖杏 / 浅灰蓝）。新护眼色一律追加到末尾，
  /// 不打乱既有索引，避免已按 novelId 持久化的 bgPresetIndex 错位。
  static const List<Color> bgPresets = <Color>[
    Color(0xFF000000), // black
    Color(0xFF303030), // dark gray
    Color(0xFFF5F5F5), // white
    Color(0xFFC7EDCC), // eye-care green
    Color(0xFFF5E6C8), // parchment
    Color(0xFFFAF0E6), // warm linen
    Color(0xFFE8DCC8), // light brown
    Color(0xFFCCE8CF), // bean green（豆沙绿，经典护眼）
    Color(0xFFDFF0EA), // mint（淡青薄荷）
    Color(0xFFFBEED9), // apricot（暖杏）
    Color(0xFFDBE6EC), // gray blue（浅灰蓝）
    Color(0xFFE3E0D9), // e-ink（P2-10 / B3：近纸白低饱和，模拟墨水屏纸感）
  ];

  /// 背景预设名称 l10n key（与 bgPresets 一一对应）。
  static const List<String> bgPresetL10nKeys = <String>[
    'readerBgBlack',
    'readerBgDarkGray',
    'readerBgWhite',
    'readerBgEyeCare',
    'readerBgParchment',
    'readerBgWarmLinen',
    'readerBgLightBrown',
    'readerBgBeanGreen',
    'readerBgMint',
    'readerBgApricot',
    'readerBgGrayBlue',
    'readerBgEInk',
  ];

  /// 默认强调色（用于小说重点色、下划线等）。
  static const Color emphasisDefault = Color(0xFFF43F5E);

  /// 墨水屏背景预设索引（bgPresets 末位，P2-10 引入）。
  /// B3 主题化：选中该预设时文字 / 强调色联动切换为墨水屏配套色，
  /// 见 [NovelReaderPreferences.isEInkBackground]。
  static const int eInkPresetIndex = 11;

  /// 墨水屏主题正文色（炭灰 #3E3D3B）：比纯黑柔和，模拟墨水屏纸面显示、
  /// 降低高分辨率屏下的边缘锐利感；仅在浅色（日间）背景下生效。
  static const Color eInkTextColor = Color(0xFF3E3D3B);

  /// 墨水屏主题强调色（朱批暗红）：低饱和暖红替代默认荧光粉，
  /// 在近纸白背景上保持可辨识且不刺眼。
  static const Color eInkEmphasisColor = Color(0xFF9E4B3C);

  /// 反色滤镜（修复桌面全黑问题，见文档雷区）。
  static const ColorFilter invertFilter =
      ColorFilter.mode(Color(0xFFFFFFFF), BlendMode.difference);

  /// 夜览暖色盖层基础色（暖橙棕 0xFF2A1800：暗暖纸感色，非纯黑）。
  static const Color nightLightColor = Color(0xFF2A1800);
}

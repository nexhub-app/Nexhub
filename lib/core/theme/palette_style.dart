import 'package:material_ui/material_ui.dart';

/// 调色板风格（Palette Style）——基于 Material 3 `dynamicSchemeVariant` 的
/// 九种配色算法变体，与「Legado with MD3」一致的风格切换能力。
///
/// 同一 seed / 壁纸下切换风格，只改变色调映射算法：
/// - [tonalSpot]：标准（默认）。Material You 经典算法，随壁纸柔和取色。
/// - [fidelity]：保真。强调色尽量贴近 seed 本身的色相与饱和度。
/// - [content]：内容。以 seed 的色相为核心生成整套配色，饱和度略提。
/// - [neutral]：中性。表面几乎无彩，仅强调色保留少量色相。
/// - [monochrome]：单色。黑白灰极简，强调色也无彩。
/// - [vibrant]：鲜艳。强调色高饱和，整体观感浓烈。
/// - [expressive]：表现力。Material 3 Expressive 算法，色相偏移更大、更有个性。
/// - [rainbow]：彩虹。强调色全色相，中性色随 seed 偏色。
/// - [fruitSalad]：水果沙拉。强调色与中性色取不同色相，撞色感强。
///
/// 中文名称（设置页展示）走 l10n：`paletteStyle<Name>` 系列词条。
enum PaletteStyle {
  tonalSpot,
  fidelity,
  content,
  neutral,
  monochrome,
  vibrant,
  expressive,
  rainbow,
  fruitSalad;

  /// 映射到 `ColorScheme.fromSeed` 的 [DynamicSchemeVariant] 参数。
  DynamicSchemeVariant get variant => switch (this) {
        PaletteStyle.tonalSpot => DynamicSchemeVariant.tonalSpot,
        PaletteStyle.fidelity => DynamicSchemeVariant.fidelity,
        PaletteStyle.content => DynamicSchemeVariant.content,
        PaletteStyle.neutral => DynamicSchemeVariant.neutral,
        PaletteStyle.monochrome => DynamicSchemeVariant.monochrome,
        PaletteStyle.vibrant => DynamicSchemeVariant.vibrant,
        PaletteStyle.expressive => DynamicSchemeVariant.expressive,
        PaletteStyle.rainbow => DynamicSchemeVariant.rainbow,
        PaletteStyle.fruitSalad => DynamicSchemeVariant.fruitSalad,
      };
}

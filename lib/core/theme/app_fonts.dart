/// 全局界面字体（外观设置「字体」组）的内置开源字体注册表。
///
/// 三款字体均为 SIL OFL 1.1 开源协议，允许随应用免费分发；许可全文位于
/// `assets/licenses/fonts/`，由 main.dart 的 LicenseRegistry 注册进
/// 「关于 → 许可」页。字体文件在 pubspec.yaml 的 fonts 段声明，启动即可用，
/// 无需运行时加载。各字体仅内置 Regular 一个字重，粗体由渲染引擎合成。
class AppFontOption {
  const AppFontOption({
    required this.id,
    required this.family,
    required this.nameZh,
    required this.nameEn,
  });

  /// 设置存储用的稳定标识（theme_settings_v1 JSON 的 appFont 字段）。
  final String id;

  /// pubspec.yaml fonts 段注册的字族名（TextStyle.fontFamily 直接引用）。
  final String family;

  /// 中文名（中文界面显示）。
  final String nameZh;

  /// 英文名（英文界面显示）。
  final String nameEn;

  /// 按界面语言取显示名。
  String displayName(bool isZh) => isZh ? nameZh : nameEn;
}

/// 「跟随系统」选项的存储标识（不设 fontFamily，用平台默认字体）。
const String kAppFontSystemId = 'system';

/// 自定义字体选项的存储标识（字族名 / 文件路径另存于 ThemeController）。
const String kAppFontCustomId = 'custom';

/// 内置开源字体（全部 SIL OFL 1.1）。缺字（如生僻字、emoji）由引擎
/// 自动回退系统字体，不需要字体本身全字库覆盖。
const List<AppFontOption> kBuiltInAppFonts = <AppFontOption>[
  // 得意黑：倾斜窄体展示风（2.6MB）。
  AppFontOption(
    id: 'smileySans',
    family: 'Smiley Sans',
    nameZh: '得意黑',
    nameEn: 'Smiley Sans',
  ),
  // 霞鹜文楷（Lite）：楷体阅读风（13.9MB）。
  AppFontOption(
    id: 'lxgwWenKai',
    family: 'LXGW WenKai Lite',
    nameZh: '霞鹜文楷',
    nameEn: 'LXGW WenKai',
  ),
  // 思源黑体（CN 子集）：Adobe 开源黑体，风格接近安卓默认字形（8.4MB）。
  AppFontOption(
    id: 'sourceHanSans',
    family: 'Source Han Sans CN',
    nameZh: '思源黑体',
    nameEn: 'Source Han Sans',
  ),
];

/// 按存储标识查内置字体；非内置 id（含 system / custom）返回 null。
AppFontOption? builtInAppFontById(String? id) {
  for (final AppFontOption font in kBuiltInAppFonts) {
    if (font.id == id) return font;
  }
  return null;
}

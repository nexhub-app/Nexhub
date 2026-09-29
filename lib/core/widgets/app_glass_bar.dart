/// 玻璃栏位基础件 —— 桌面侧栏 / 移动端底栏共用的高斯模糊半透明容器。
///
/// 原理：BackdropFilter 会模糊「栏位身后已绘制的像素」。布局保持常规
/// （内容不穿栏），栏位身后是主框架铺的 `_AmbientSurface` 氛围底色
/// （带轻微明暗与主题色变化），模糊后即呈现柔和的毛玻璃质感。
/// 设置里关闭「毛玻璃效果」时退化为实色表面。
library;

import 'dart:ui' show ImageFilter;

import 'package:material_ui/material_ui.dart';

import '../settings/general_settings.dart';
import '../theme/app_tokens.dart';

/// 高斯模糊玻璃栏容器。
///
/// [border] 用于在栏位边缘画发丝线（底栏画顶边、侧栏画侧边），
/// 替代原实色栏的 elevation 阴影——半透明栏位上投影会显得脏，
/// 发丝线更干净。底色不透明度随深浅色主题自适应
/// （[AppTokens.glassTintLight] / [AppTokens.glassTintDark]），
/// 并监听通用设置：关闭毛玻璃后即时恢复实色。
class AppGlassBar extends StatelessWidget {
  const AppGlassBar({
    super.key,
    required this.child,
    this.border,
  });

  final Widget child;
  final Border? border;

  @override
  Widget build(BuildContext context) {
    // 监听设置变更：开关/强度/不透明度变化时栏位即时刷新。
    return ListenableBuilder(
      listenable: GeneralSettingsStore.instance,
      builder: (context, _) {
        final GeneralSettingsStore store = GeneralSettingsStore.instance;
        final ColorScheme cs = Theme.of(context).colorScheme;
        final bool glassOn = store.settings.glassEffectEnabled;
        final double sigma = store.settings.glassBlurSigma;
        // 不透明度由用户设定；深色主题自动减一档（见 AppTokens 偏移），
        // 保证深色背景下图标文字的对比度。
        final double tint = cs.brightness == Brightness.light
            ? store.settings.glassBarOpacity
            : (store.settings.glassBarOpacity +
                    (AppTokens.glassTintDark - AppTokens.glassTintLight))
                .clamp(0.35, 0.95);

        final Widget bar = glassOn
            ? ClipRect(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
                  child: Material(
                    color: cs.surface.withValues(alpha: tint),
                    child: child,
                  ),
                ),
              )
            : Material(color: cs.surface, child: child);

        if (border == null) return bar;
        return DecoratedBox(
          decoration: BoxDecoration(border: border),
          child: bar,
        );
      },
    );
  }
}

/// 玻璃底栏（移动端）的内容避让量。
///
/// 外层 Scaffold `extendBody` 会把底栏高度注入 body 的 MediaQuery：
/// 文字列表页用 [glassBarInset] 拼进显式 padding，收尾条目可完整滚出
/// 底栏遮挡区；封面网格页用 [glassBarBottomInset] 仅做底部避让，
/// 让封面在滚动中从玻璃底栏后穿透。
///
/// 注意：[AppBar] / [Scaffold] 会**原生**消费注入的 MediaQuery padding，
/// 页面里不要再手动给 AppBar 包一层避让，否则双重偏移。
/// （桌面端当前无任何注入，left 恒为 0，侧栏保持原版实色并排布局。）
extension GlassBarInset on BuildContext {
  /// 应叠加到滚动容器 padding 上的额外避让量（左侧 + 底部）。
  EdgeInsets get glassBarInset {
    final EdgeInsets padding = MediaQuery.paddingOf(this);
    return EdgeInsets.only(left: padding.left, bottom: padding.bottom);
  }

  /// 仅底部避让量（封面网格页：内容刻意滑到侧栏后面，只保证移动端
  /// 收尾条目能滚出底栏遮挡区）。
  double get glassBarBottomInset => MediaQuery.paddingOf(this).bottom;

  /// 推入的二级路由页（无 extendBody 注入）主列表的标准四边 padding：
  /// [all] 为设计留白，底部自动叠加系统导航条高度——edge-to-edge 下
  /// 内容延伸到手势条后面，收尾条目须能完整滚出遮挡区。
  /// （与 [glassBarInset] 的区别：后者面向主框架 Tab 页，底部含玻璃
  /// 底栏高度；本方法面向全屏路由页，底部仅系统导航条。）
  EdgeInsets pageInset(double all) => EdgeInsets.fromLTRB(
        all,
        all,
        all,
        all + MediaQuery.paddingOf(this).bottom,
      );
}

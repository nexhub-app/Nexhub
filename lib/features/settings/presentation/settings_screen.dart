/// 设置主页 —— 分类入口（动态取色 / 编辑式版面）。
///
/// 设计取向：色彩随用户选择的种子色（Monet / 预设 / 自定义）实时变化，
/// 不使用任何固定色值。顶部品牌头（monogram + 色板圆点）打破纯列表的单调感，
/// 下方 6 张分类卡用 primaryContainer 图标瓦 + outlineVariant 发丝边，
/// 克制而统一。整体风格取自 Linear / Vercel 的编辑式留白美学。
library;

import 'package:flutter/material.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_animations.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:nexhub/core/navigation/app_page_route.dart';
import '../../../core/settings/general_settings.dart';
import './widgets/hero_carousel.dart';
import './settings_hero_screen.dart';
import './settings_appearance_screen.dart';
import './settings_playback_screen.dart';
import './settings_content_screen.dart';
import './settings_data_screen.dart';
import './settings_privacy_security_screen.dart';
import './about_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);

    final List<_Category> categories = <_Category>[
      _Category(
        icon: Icons.palette_outlined,
        title: l10n.settingsCatAppearance,
        desc: l10n.settingsCatAppearanceDesc,
        builder: () => const SettingsAppearanceScreen(),
      ),
      _Category(
        icon: Icons.play_circle_outline,
        title: l10n.settingsCatPlayback,
        desc: l10n.settingsCatPlaybackDesc,
        builder: () => const SettingsPlaybackScreen(),
      ),
      _Category(
        icon: Icons.rss_feed,
        title: l10n.settingsCatContent,
        desc: l10n.settingsCatContentDesc,
        builder: () => const SettingsContentScreen(),
      ),
      _Category(
        icon: Icons.storage_outlined,
        title: l10n.settingsCatData,
        desc: l10n.settingsCatDataDesc,
        builder: () => const SettingsDataScreen(),
      ),
      _Category(
        icon: Icons.shield_outlined,
        title: l10n.settingsCatPrivacy,
        desc: l10n.settingsCatPrivacyDesc,
        builder: () => const SettingsPrivacySecurityScreen(),
      ),
      _Category(
        icon: Icons.info_outline,
        title: l10n.settingsCatAbout,
        desc: l10n.settingsCatAboutDesc,
        builder: () => const AboutScreen(),
      ),
    ];

    return AppShrinkTitleScaffold(
      title: Text(l10n.settingsTitle),
      body: ListView.separated(
        padding: const EdgeInsets.all(AppTokens.spaceLg),
        itemCount: categories.length + 1,
        separatorBuilder: (_, __) =>
            const SizedBox(height: AppTokens.spaceMd),
        itemBuilder: (BuildContext context, int i) {
          if (i == 0) {
            return const _HeroSection();
          }
          final c = categories[i - 1];
          return _CategoryCard(category: c, index: i);
        },
      ),
    );
  }
}

class _Category {
  final IconData icon;
  final String title;
  final String desc;
  final Widget Function() builder;

  const _Category({
    required this.icon,
    required this.title,
    required this.desc,
    required this.builder,
  });
}

/// 顶部 Hero 区：可左右滑动的自定义背景图轮播 + 品牌字 + 编辑入口。
///
/// 背景图来自 [GeneralSettingsStore] 的 `heroImageUrls`（默认二次元图，
/// 可在 Hero 设置页替换为任意网络/本地图）。右上角按钮跳转配置页；
/// 左上品牌字叠加暗化底纹保证在任意图片上可读。
class _HeroSection extends StatelessWidget {
  const _HeroSection();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final store = GeneralSettingsStore.instance;

    return AnimatedBuilder(
      animation: store,
      builder: (BuildContext context, _) {
        return Stack(
          children: <Widget>[
            HeroCarousel(imageUrls: store.settings.heroImageUrls),
            Positioned(
              top: AppTokens.spaceSm,
              right: AppTokens.spaceSm,
              child: _HeroEditButton(
                tooltip: l10n.heroSettingsTitle,
                onTap: () {
                  Navigator.of(context).push(
                    AppPageRoute<void>(
                      builder: (_) => const SettingsHeroScreen(),
                    ),
                  );
                },
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.all(AppTokens.spaceLg),
                decoration: BoxDecoration(
                  borderRadius: const BorderRadius.only(
                    bottomLeft: Radius.circular(AppTokens.radiusLg),
                    bottomRight: Radius.circular(AppTokens.radiusLg),
                  ),
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: <Color>[
                      Colors.black.withValues(alpha: 0.0),
                      Colors.black.withValues(alpha: 0.55),
                    ],
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'NexHub',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.5,
                          ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      l10n.settingsTagline,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(
                            color: Colors.white.withValues(alpha: 0.85),
                          ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Hero 区右上角的「自定义」按钮（半透明圆形）。
class _HeroEditButton extends StatelessWidget {
  final String tooltip;
  final VoidCallback onTap;

  const _HeroEditButton({
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.black.withValues(alpha: 0.4),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: const Padding(
            padding: EdgeInsets.all(AppTokens.spaceSm),
            child: Icon(Icons.tune, color: Colors.white, size: 20),
          ),
        ),
      ),
    );
  }
}

/// 单张分类卡（动态取色版）。
///
/// - 图标瓦：`primaryContainer` 底 + `onPrimaryContainer` 图标，随种子色变化。
/// - 发丝边：`outlineVariant`（主题感知），不喧宾夺主。
/// - [AppTapScale] 按压回弹；[Entrance] 按 index 轻交错淡入。
class _CategoryCard extends StatelessWidget {
  final _Category category;
  final int index;

  const _CategoryCard({required this.category, required this.index});

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final c = category;
    final TextTheme text = Theme.of(context).textTheme;

    final Widget card = Material(
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTokens.radiusLg),
        side: BorderSide(
          color: scheme.outlineVariant,
          width: 1,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTokens.radiusLg),
        onTap: () => Navigator.of(context).push(
          AppPageRoute<void>(builder: (_) => c.builder()),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppTokens.spaceLg),
          child: Row(
            children: <Widget>[
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(AppTokens.radiusMd),
                ),
                child: Icon(c.icon, color: scheme.onPrimaryContainer, size: 24),
              ),
              const SizedBox(width: AppTokens.spaceMd),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      c.title,
                      style: text.titleMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.3,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      c.desc,
                      style: text.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: scheme.onSurfaceVariant,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );

    return Entrance(
      index: index,
      onceKey: 'settings_cat_$index',
      offset: 10,
      fromScale: 0.985,
      duration: AppTokens.durBase,
      child: AppTapScale(
        scale: 0.975,
        child: card,
      ),
    );
  }
}

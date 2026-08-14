/// 首次启动引导页（项 9 / 项 5 扩展）：
///   1. 欢迎
///   2. 基础设置（主题 / 语言，引导期即可调整）
///   3. 添加源
///   4. 关联 Bangumi
///   5. 授予权限（Android 运行时权限；其他平台说明无需授权）
///   6. 隐私与合规
///
/// 走完（点「开始使用」或「跳过」）后回调 [onDone]，由调用方写入
/// `GeneralSettings.onboardingCompleted = true` 并切换到主界面。
/// 页面所需的 Provider（[ThemeController] / [LocaleController] / [BangumiAuth]）
/// 由上层 MultiProvider 注入，可直接取用。
library;

import 'package:flutter/material.dart';
import 'package:nexhub/core/local/import_permission.dart';
import 'package:nexhub/core/platform/platform_service.dart';
import 'package:nexhub/core/services/bangumi/bangumi_auth.dart';
import 'package:nexhub/core/theme/app_tokens.dart';
import 'package:nexhub/core/theme/theme_controller.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:nexhub/core/locale/locale_controller.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

class OnboardingScreen extends StatefulWidget {
  final VoidCallback onDone;

  const OnboardingScreen({super.key, required this.onDone});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pageController = PageController();
  int _page = 0;
  static const int _total = 6;
  bool _permissionsGranted = false;

  void _goNext() {
    if (_page < _total - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else {
      widget.onDone();
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _requestPermissions() async {
    if (!PlatformService.instance.isAndroid) return;
    await requestLocalImportPermission();
    final statuses = await Future.wait(<Future<PermissionStatus>>[
      Permission.storage.status,
      Permission.photos.status,
      Permission.videos.status,
      Permission.audio.status,
    ]);
    final allGranted = statuses.every((PermissionStatus s) => s.isGranted);
    if (mounted) setState(() => _permissionsGranted = allGranted);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;

    final pages = <_OnboardingPageData>[
      _OnboardingPageData(
        icon: Icons.rocket_launch_outlined,
        title: l10n.onboardingWelcomeTitle,
        body: l10n.onboardingWelcomeBody,
      ),
      _OnboardingPageData(
        icon: Icons.tune_outlined,
        title: l10n.onboardingSettingsTitle,
        body: l10n.onboardingSettingsBody,
        customBody: _buildSettingsBody(context, l10n),
      ),
      _OnboardingPageData(
        icon: Icons.extension_outlined,
        title: l10n.onboardingSourcesTitle,
        body: l10n.onboardingSourcesBody,
      ),
      _OnboardingPageData(
        icon: Icons.sync_outlined,
        title: l10n.onboardingBangumiTitle,
        body: l10n.onboardingBangumiBody,
        action: (ctx, loc) => FilledButton.icon(
          onPressed: () {
            // 引导页中直接发起 Bangumi 登录；失败不阻断引导。
            try {
              ctx.read<BangumiAuth>().loginWithOAuth(ctx);
            } catch (_) {
              // 忽略：用户可在设置页稍后登录。
            }
          },
          icon: const Icon(Icons.login),
          label: Text(loc.onboardingBangumiLogin),
        ),
      ),
      _OnboardingPageData(
        icon: Icons.security_outlined,
        title: l10n.onboardingPermissionTitle,
        body: l10n.onboardingPermissionBody,
        customBody: _buildPermissionBody(context, l10n),
      ),
      _OnboardingPageData(
        icon: Icons.shield_outlined,
        title: l10n.onboardingPrivacyTitle,
        body: l10n.onboardingPrivacyBody,
      ),
    ];

    final isLast = _page == _total - 1;

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        actions: <Widget>[
          TextButton(
            onPressed: widget.onDone,
            child: Text(l10n.onboardingSkip),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        bottom: true,
        child: Column(
          children: <Widget>[
            Expanded(
              child: PageView.builder(
              controller: _pageController,
              itemCount: pages.length,
              onPageChanged: (i) => setState(() => _page = i),
              itemBuilder: (context, i) => _buildPage(context, pages[i], l10n),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(AppTokens.spaceLg),
            child: Row(
              children: <Widget>[
                // 进度圆点
                Row(
                  children: <Widget>[
                    for (int i = 0; i < _total; i++)
                      Container(
                        margin: const EdgeInsets.only(right: AppTokens.spaceXs),
                        width: i == _page ? 22 : 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: i == _page
                              ? scheme.primary
                              : scheme.outlineVariant,
                          borderRadius:
                              BorderRadius.circular(AppTokens.radiusFull),
                        ),
                      ),
                  ],
                ),
                const Spacer(),
                FilledButton(
                  onPressed: _goNext,
                  child: Text(isLast ? l10n.onboardingGetStarted : l10n.onboardingNext),
                ),
              ],
            ),
          ),
        ],
      ),
      ),
    );
  }

  Widget _buildSettingsBody(BuildContext context, AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    final themeController = context.read<ThemeController>();
    final localeController = context.read<LocaleController>();
    final labelStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(l10n.onboardingThemeLabel, style: labelStyle),
        const SizedBox(height: AppTokens.spaceSm),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SegmentedButton<ThemeMode>(
            selected: <ThemeMode>{themeController.mode},
            onSelectionChanged: (Set<ThemeMode> sel) {
              themeController.setMode(sel.first);
              setState(() {});
            },
            segments: <ButtonSegment<ThemeMode>>[
              ButtonSegment<ThemeMode>(
                value: ThemeMode.system,
                label: Text(l10n.themeSystem),
                icon: const Icon(Icons.brightness_auto_outlined),
              ),
              ButtonSegment<ThemeMode>(
                value: ThemeMode.light,
                label: Text(l10n.themeLight),
                icon: const Icon(Icons.light_mode_outlined),
              ),
              ButtonSegment<ThemeMode>(
                value: ThemeMode.dark,
                label: Text(l10n.themeDark),
                icon: const Icon(Icons.dark_mode_outlined),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppTokens.spaceLg),
        Text(l10n.onboardingLanguageLabel, style: labelStyle),
        const SizedBox(height: AppTokens.spaceSm),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SegmentedButton<LocaleOption>(
            selected: <LocaleOption>{localeController.option},
            onSelectionChanged: (Set<LocaleOption> sel) {
              localeController.setOption(sel.first);
              setState(() {});
            },
            segments: <ButtonSegment<LocaleOption>>[
              ButtonSegment<LocaleOption>(
                value: LocaleOption.system,
                label: Text(l10n.languageFollowSystem),
              ),
              ButtonSegment<LocaleOption>(
                value: LocaleOption.chinese,
                label: Text(l10n.languageChinese),
              ),
              ButtonSegment<LocaleOption>(
                value: LocaleOption.english,
                label: Text(l10n.languageEnglish),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPermissionBody(BuildContext context, AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;

    if (!PlatformService.instance.isAndroid) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(Icons.check_circle_outline, color: scheme.primary),
          const SizedBox(width: AppTokens.spaceSm),
          Flexible(
            child: Text(
              l10n.onboardingPermissionNotNeeded,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      );
    }

    return Column(
      children: <Widget>[
        const SizedBox(height: AppTokens.spaceMd),
        FilledButton.icon(
          onPressed: _permissionsGranted ? null : _requestPermissions,
          icon: Icon(_permissionsGranted
              ? Icons.check_circle_outline
              : Icons.lock_open_outlined),
          label: Text(l10n.onboardingGrantPermission),
        ),
        if (_permissionsGranted) ...<Widget>[
          const SizedBox(height: AppTokens.spaceSm),
          Text(
            l10n.onboardingPermissionGranted,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.primary,
                ),
          ),
        ],
      ],
    );
  }

  Widget _buildPage(
    BuildContext context,
    _OnboardingPageData data,
    AppLocalizations l10n,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppTokens.spaceXl,
                vertical: AppTokens.spaceLg,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              borderRadius: BorderRadius.circular(AppTokens.radiusLg),
            ),
            child: Icon(
              data.icon,
              size: 48,
              color: scheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(height: AppTokens.spaceXl),
          Text(
            data.title,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppTokens.spaceMd),
          if (data.body.isNotEmpty) ...<Widget>[
            Text(
              data.body,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
              textAlign: TextAlign.center,
            ),
          ],
          if (data.customBody != null) ...<Widget>[
            const SizedBox(height: AppTokens.spaceLg),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: data.customBody!,
            ),
          ],
          if (data.action != null) ...<Widget>[
            const SizedBox(height: AppTokens.spaceLg),
            data.action!(context, l10n),
          ],
        ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _OnboardingPageData {
  final IconData icon;
  final String title;
  final String body;
  final Widget? customBody;
  final Widget Function(BuildContext, AppLocalizations)? action;

  const _OnboardingPageData({
    required this.icon,
    required this.title,
    required this.body,
    this.customBody,
    this.action,
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:provider/provider.dart';
import 'core/locale/locale_controller.dart';
import 'core/theme/theme_controller.dart';
import 'core/settings/general_settings.dart';
import 'core/services/software_announcement_service.dart';
import 'core/widgets/software_announcement_dialog.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'features/home/presentation/home_screen.dart';
import 'features/onboarding/presentation/onboarding_screen.dart';

/// 应用根：Material 3 + 莫奈动态色 + Provider 主题状态 + 统一 l10n。
class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    final ThemeController controller = context.watch<ThemeController>();
    final LocaleController localeController = context.watch<LocaleController>();
    return DynamicColorBuilder(
      builder: (ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
        return MaterialApp(
          title: 'nexhub',
          debugShowCheckedModeBanner: false,
          theme: controller.lightTheme(lightDynamic),
          darkTheme: controller.darkTheme(darkDynamic),
          themeMode: controller.mode,
          locale: localeController.effectiveLocale,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: const <Locale>[
            Locale('zh'),
            Locale('en'),
          ],
          home: const _AppBootstrap(),
        );
      },
    );
  }
}

/// 首屏闸门（项 8 / 项 9）。
///
/// 位于 [App] 的 [MaterialApp] 之内，故 [Theme] / [AppLocalizations] /
/// 各 Provider 均已就绪：
/// - 未完成首次引导 → 展示 [OnboardingScreen]，走完回调置
///   `GeneralSettings.onboardingCompleted = true` 后切到主界面；
/// - 已完成引导 → 直接进 [HomeScreen]，若有未读软件公告则首帧后弹窗（项 8）。
class _AppBootstrap extends StatefulWidget {
  const _AppBootstrap();

  @override
  State<_AppBootstrap> createState() => _AppBootstrapState();
}

class _AppBootstrapState extends State<_AppBootstrap> {
  late bool _onboardingDone =
      GeneralSettingsStore.instance.settings.onboardingCompleted;

  @override
  void initState() {
    super.initState();
    if (_onboardingDone) {
      _maybeShowAnnouncements();
    }
  }

  void _onOnboardingDone() {
    GeneralSettingsStore.instance.save(
      GeneralSettingsStore.instance.settings.copyWith(onboardingCompleted: true),
    );
    setState(() => _onboardingDone = true);
    _maybeShowAnnouncements();
  }

  Future<void> _maybeShowAnnouncements() async {
    final service = SoftwareAnnouncementService.instance;
    await service.load();
    final unseen = service.unseen();
    if (unseen.isEmpty || !mounted) return;
    // 等首帧构建完成，确保 dialog 的 context 已就绪且叠加在主界面之上。
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;
    await showSoftwareAnnouncements(context, unseen);
  }

  @override
  Widget build(BuildContext context) {
    if (!_onboardingDone) {
      return OnboardingScreen(onDone: _onOnboardingDone);
    }
    return const HomeScreen();
  }
}

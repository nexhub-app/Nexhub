import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_animations.dart';
import '../../../core/widgets/app_list_tile.dart';
import './widgets/settings_widgets.dart';
import '../../../core/scraper/http_fetcher.dart';
import '../../../core/settings/general_settings.dart';
import '../../../core/services/source_repository.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:nexhub/core/navigation/app_page_route.dart';
import './settings_privacy_screen.dart';
import './settings_advanced_screen.dart';

/// 隐私与安全汇总页：隐私设置 / 高级设置入口 + 内联清除缓存 + 年龄限制。
class SettingsPrivacySecurityScreen extends StatelessWidget {
  const SettingsPrivacySecurityScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AppShrinkTitleScaffold(
      title: Text(l10n.settingsCatPrivacy),
      body: Entrance(
        offset: 10,
        fromScale: 0.985,
        duration: AppTokens.durBase,
        child: ListView(
          padding: const EdgeInsets.all(AppTokens.spaceLg),
          children: <Widget>[
            AppListTile(
              leading: const SettingsLeadingIcon(icon:Icons.privacy_tip_outlined),
              title: Text(l10n.privacySettingsTitle),
              subtitle: Text(l10n.privacySettingsDesc),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                AppPageRoute<void>(
                  builder: (_) => const SettingsPrivacyScreen(),
                ),
              ),
            ),
            AppListTile(
              leading: const SettingsLeadingIcon(icon:Icons.tune),
              title: Text(l10n.advancedSettingsTitle),
              subtitle: Text(l10n.advancedSettingsDesc),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                AppPageRoute<void>(
                  builder: (_) => const SettingsAdvancedScreen(),
                ),
              ),
            ),
            const _AgeRestrictionSection(),
            AppListTile(
              leading: const SettingsLeadingIcon(icon:Icons.cleaning_services_outlined),
              title: Text(l10n.clearCache),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                HttpFetcher.instance.clearCookies();
                PaintingBinding.instance.imageCache.clear();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(l10n.cacheCleared)),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// 年龄限制开关：关闭需强制阅读并确认免责声明（10 秒倒计时 + 滚动到底）。
class _AgeRestrictionSection extends StatefulWidget {
  const _AgeRestrictionSection();

  @override
  State<_AgeRestrictionSection> createState() => _AgeRestrictionSectionState();
}

class _AgeRestrictionSectionState extends State<_AgeRestrictionSection> {
  late GeneralSettings _s;

  @override
  void initState() {
    super.initState();
    final store = GeneralSettingsStore.instance;
    _s = store.settings;
    if (!store.loaded) {
      store.load().then((s) {
        if (mounted) setState(() => _s = s);
      });
    }
  }

  void _update(GeneralSettings next) {
    setState(() => _s = next);
    GeneralSettingsStore.instance.save(next);
  }

  Future<bool> _showAgeRestrictionDisclaimer(AppLocalizations l10n) async {
    final bool? agreed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext ctx) =>
          _AgeRestrictionDisclaimerDialog(l10n: l10n),
    );
    return agreed ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AnimatedBuilder(
      animation: GeneralSettingsStore.instance,
      builder: (_, __) {
        _s = GeneralSettingsStore.instance.settings;
        return SwitchListTile(
          contentPadding:
              const EdgeInsets.symmetric(horizontal: AppTokens.spaceLg),
          secondary: const SettingsLeadingIcon(icon:Icons.no_adult_content),
          title: Text(l10n.ageRestriction),
          subtitle: Text(
            l10n.ageRestrictionHint,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          value: _s.ageRestrictionEnabled,
          onChanged: (bool v) async {
            if (!v) {
              final agreed = await _showAgeRestrictionDisclaimer(l10n);
              if (!agreed) return;
            }
            _update(_s.copyWith(ageRestrictionEnabled: v));
            if (mounted) {
              context.read<SourceRepository>().setAgeRestrictionEnabled(v);
            }
          },
        );
      },
    );
  }
}

class _AgeRestrictionDisclaimerDialog extends StatefulWidget {
  final AppLocalizations l10n;

  const _AgeRestrictionDisclaimerDialog({required this.l10n});

  @override
  State<_AgeRestrictionDisclaimerDialog> createState() =>
      _AgeRestrictionDisclaimerDialogState();
}

class _AgeRestrictionDisclaimerDialogState
    extends State<_AgeRestrictionDisclaimerDialog> {
  bool _reachedBottom = false;
  int _remaining = 10;
  Timer? _countdown;
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _countdown = Timer.periodic(const Duration(seconds: 1), (Timer t) {
      setState(() {
        if (_remaining <= 1) {
          t.cancel();
          _remaining = 0;
        } else {
          _remaining -= 1;
        }
      });
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients && _scroll.position.maxScrollExtent <= 0) {
        setState(() => _reachedBottom = true);
      }
    });
  }

  @override
  void dispose() {
    _countdown?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_reachedBottom &&
        _scroll.position.pixels >= _scroll.position.maxScrollExtent - 8) {
      setState(() => _reachedBottom = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = widget.l10n;
    final bool canConfirm = _reachedBottom && _remaining <= 0;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String hint = !_reachedBottom
        ? l10n.ageRestrictionDisclaimerScrollHint
        : _remaining > 0
            ? l10n.ageRestrictionDisclaimerCounting(_remaining)
            : '';
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(
        horizontal: AppTokens.spaceLg,
        vertical: AppTokens.spaceLg,
      ),
      titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      contentPadding: const EdgeInsets.fromLTRB(AppTokens.spaceXl, AppTokens.spaceMd,
          AppTokens.spaceXl, AppTokens.spaceLg),
      actionsPadding: const EdgeInsets.fromLTRB(AppTokens.spaceLg, AppTokens.spaceNone,
          AppTokens.spaceLg, AppTokens.spaceMd),
      title: Text(l10n.ageRestrictionDisclaimerTitle),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 420,
          maxHeight: MediaQuery.of(context).size.height * 0.55,
        ),
        child: SingleChildScrollView(
          controller: _scroll,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(l10n.ageRestrictionDisclaimerBody),
              const SizedBox(height: AppTokens.spaceSm),
              if (hint.isNotEmpty)
                Text(
                  hint,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: canConfirm ? () => Navigator.of(context).pop(true) : null,
          child: Text(canConfirm
              ? l10n.ageRestrictionDisclaimerConfirm
              : l10n.ageRestrictionDisclaimerWait(_remaining)),
        ),
      ],
    );
  }
}
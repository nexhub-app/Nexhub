/// 高级设置页（D 阶段）。
///
/// 提供：
/// - 崩溃日志（查看 / 复制 / 清空，入口到独立页）
/// - 详细日志开关（HttpFetcher 打印每个请求 / 响应）
/// - 清除爬取 Cookie
/// - 清除 WebView Cookie 与缓存
/// - 默认 UA（预设 + 自定义）
library;

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:nexhub/generated/app_localizations.dart';

import '../../../core/scraper/http_fetcher.dart';
import '../../../core/settings/advanced_settings.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_animations.dart';
import 'crash_log_screen.dart';
import 'widgets/settings_widgets.dart';

/// 内置 UA 预设：与 [HttpFetcher] 指纹档案 / 旧默认头保持一致。
class _UaPreset {
  const _UaPreset(this.label, this.ua);
  final String label;
  final String ua;
}

const List<_UaPreset> _kUaPresets = <_UaPreset>[
  _UaPreset('Chrome / Windows 131',
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'),
  _UaPreset('Chrome / Windows 124',
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'),
  _UaPreset('Edge / Windows 123',
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36 Edg/123.0.0.0'),
  _UaPreset('Chrome / macOS 120',
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'),
];

class SettingsAdvancedScreen extends StatefulWidget {
  const SettingsAdvancedScreen({super.key});

  @override
  State<SettingsAdvancedScreen> createState() => _SettingsAdvancedScreenState();
}

class _SettingsAdvancedScreenState extends State<SettingsAdvancedScreen> {
  late AdvancedSettings _s;

  @override
  void initState() {
    super.initState();
    _s = AdvancedSettingsStore.instance.settings;
    if (!AdvancedSettingsStore.instance.loaded) {
      AdvancedSettingsStore.instance.load().then((s) {
        if (mounted) setState(() => _s = s);
      });
    }
  }

  void _update(AdvancedSettings next) {
    setState(() => _s = next);
    AdvancedSettingsStore.instance.save(next);
  }

  Future<void> _setDetailedLogging(bool v) async {
    _update(_s.copyWith(detailedLogging: v));
    // 拦截器在 Dio 构建时挂载，需重建所有 Dio 使开关即时生效。
    HttpFetcher.instance.rebuildAll();
  }

  Future<void> _setUserAgent(String ua) async {
    _update(_s.copyWith(defaultUserAgent: ua));
    HttpFetcher.instance.rebuildAll();
  }

  Future<bool> _confirm(
      BuildContext context, AppLocalizations l10n, String title) async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(title),
            content: Text(l10n.confirmActionHint),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(l10n.cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(l10n.confirm),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _clearCookies(BuildContext context, AppLocalizations l10n) async {
    final ok = await _confirm(context, l10n, l10n.clearCookies);
    if (!ok || !context.mounted) return;
    HttpFetcher.instance.clearCookies();
    try {
      await CookieManager.instance().deleteAllCookies();
    } catch (_) {}
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.cookiesCleared)),
      );
    }
  }

  Future<void> _clearWebviewData(
      BuildContext context, AppLocalizations l10n) async {
    final ok = await _confirm(context, l10n, l10n.clearWebviewData);
    if (!ok || !context.mounted) return;
    try {
      await WebStorageManager.instance().deleteAllData();
    } catch (_) {}
    PaintingBinding.instance.imageCache.clear();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.webviewDataCleared)),
      );
    }
  }

  void _pickUserAgent(BuildContext context, AppLocalizations l10n) {
    final current = _s.defaultUserAgent;
    final TextEditingController customCtrl = TextEditingController(
      text: current.isNotEmpty &&
              !_kUaPresets.any((p) => p.ua == current)
          ? current
          : '',
    );
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(ctx).size.height * 0.85,
        ),
        child: AppSheetBody(
          child: ListView(
            shrinkWrap: true,
            padding: EdgeInsets.only(
              left: AppTokens.spaceLg,
              right: AppTokens.spaceLg,
              top: AppTokens.spaceLg,
              bottom: MediaQuery.of(ctx).viewInsets.bottom +
                  AppTokens.spaceLg,
            ),
            children: <Widget>[
              Text(
                l10n.defaultUserAgent,
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
              const SizedBox(height: AppTokens.spaceSm),
              // 自动
              RadioListTile<String>(
                value: '',
                groupValue: current,
                title: Text(l10n.userAgentAuto),
                subtitle: Text(l10n.userAgentAutoHint),
                onChanged: (v) {
                  _setUserAgent(v ?? '');
                  Navigator.pop(ctx);
                },
              ),
              for (final p in _kUaPresets)
                RadioListTile<String>(
                  value: p.ua,
                  groupValue: current,
                  title: Text(
                    p.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onChanged: (v) {
                    _setUserAgent(v ?? '');
                    Navigator.pop(ctx);
                  },
                ),
              const Divider(height: AppTokens.spaceLg),
              TextField(
                controller: customCtrl,
                maxLines: 2,
                decoration: InputDecoration(
                  labelText: l10n.userAgentCustom,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: AppTokens.spaceMd),
              FilledButton(
                onPressed: () {
                  final v = customCtrl.text.trim();
                  if (v.isNotEmpty) _setUserAgent(v);
                  Navigator.pop(ctx);
                },
                child: Text(l10n.confirm),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final uaLabel = _s.defaultUserAgent.isEmpty
        ? l10n.userAgentAuto
        : _s.defaultUserAgent;
    return AppShrinkTitleScaffold(
      title: Text(l10n.advancedSettingsTitle),
      body: ListView(
        padding: const EdgeInsets.all(AppTokens.spaceMd),
        children: <Widget>[
          // ── 日志 ──
          SettingsCard(
            title: l10n.advancedLogGroup,
            index: 0,
            children: <Widget>[
              SettingsSwitchTile(
                title: l10n.detailedLogging,
                subtitle: l10n.detailedLoggingHint,
                value: _s.detailedLogging,
                onChanged: _setDetailedLogging,
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  Icons.bug_report_outlined,
                  color: Theme.of(context).colorScheme.primary,
                ),
                title: Text(l10n.crashLog),
                subtitle: Text(l10n.crashLogDesc),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const CrashLogScreen(),
                  ),
                ),
              ),
            ],
          ),
          // ── 数据清理 ──
          SettingsCard(
            title: l10n.advancedCleanGroup,
            index: 1,
            children: <Widget>[
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  Icons.cookie_outlined,
                  color: Theme.of(context).colorScheme.primary,
                ),
                title: Text(l10n.clearCookies),
                subtitle: Text(l10n.clearCookiesDesc),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _clearCookies(context, l10n),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  Icons.cleaning_services_outlined,
                  color: Theme.of(context).colorScheme.primary,
                ),
                title: Text(l10n.clearWebviewData),
                subtitle: Text(l10n.clearWebviewDataDesc),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _clearWebviewData(context, l10n),
              ),
            ],
          ),
          // ── 请求指纹 ──
          SettingsCard(
            title: l10n.advancedRequestGroup,
            index: 2,
            children: <Widget>[
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  Icons.person_pin_circle_outlined,
                  color: Theme.of(context).colorScheme.primary,
                ),
                title: Text(l10n.defaultUserAgent),
                subtitle: Text(
                  uaLabel,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _pickUserAgent(context, l10n),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppTokens.spaceSm),
            child: Text(
              l10n.advancedPageHint,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

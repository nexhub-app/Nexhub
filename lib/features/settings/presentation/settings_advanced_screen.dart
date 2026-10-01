/// 高级设置页（D 阶段）。
///
/// 提供：
/// - 崩溃日志（查看 / 复制 / 清空，入口到独立页）
/// - 详细日志开关（HttpFetcher 打印每个请求 / 响应）
/// - 清除爬取 Cookie
/// - 清除 WebView Cookie 与缓存
/// - 图片磁盘缓存（占用统计 + 一键清理， 资源/内存）
/// - 默认 UA（预设 + 自定义）
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:nexhub/generated/app_localizations.dart';

import '../../../core/scraper/http_fetcher.dart';
import '../../../core/settings/advanced_settings.dart';
import '../../../core/storage/cache_inventory.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_animations.dart';
import '../../../core/utils/app_haptics.dart';
import '../../../core/widgets/app_glass_bar.dart';
import 'crash_log_screen.dart';
import 'log_viewer_screen.dart';
import 'settings_cache_manager_screen.dart';
import 'widgets/settings_widgets.dart';
import 'widgets/settings_search_target.dart';

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
    // 图片磁盘缓存占用（资源/内存）：进入页面异步统计。
    _refreshImageCacheSize();
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

  Future<void> _clearCookies(
      BuildContext context, AppLocalizations l10n) async {
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

  // ── 缓存管理（分类占用见 [SettingsCacheManagerScreen]）──────────────
  String _imageCacheSizeText = '';

  Future<void> _refreshImageCacheSize() async {
    final int total = await _computeImageCacheSize();
    if (mounted) {
      setState(() => _imageCacheSizeText = _formatBytes(total));
    }
  }

  /// 统计全部缓存类别总占用（与缓存管理页口径一致，避免两处数字打架）。
  Future<int> _computeImageCacheSize() async {
    try {
      return (await CacheInventory.snapshot()).totalBytes;
    } on Object {
      return 0;
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  void _pickUserAgent(BuildContext context, AppLocalizations l10n) {
    final current = _s.defaultUserAgent;
    final TextEditingController customCtrl = TextEditingController(
      text: current.isNotEmpty && !_kUaPresets.any((p) => p.ua == current)
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
              // 键盘弹起时贴键盘，收起时避让系统手势条。
              bottom: math.max(
                    MediaQuery.of(ctx).viewInsets.bottom,
                    MediaQuery.of(ctx).padding.bottom,
                  ) +
                  AppTokens.spaceLg,
            ),
            children: <Widget>[
              Text(
                l10n.defaultUserAgent,
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
              const SizedBox(height: AppTokens.spaceSm),
              // MD3「Selected」：单选选中 → tick。
              RadioGroup<String>(
                groupValue: current,
                onChanged: (v) {
                  AppHaptics.tick();
                  _setUserAgent(v ?? '');
                  Navigator.pop(ctx);
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    RadioListTile<String>(
                      value: '',
                      title: Text(l10n.userAgentAuto),
                      subtitle: Text(l10n.userAgentAutoHint),
                    ),
                    for (final p in _kUaPresets)
                      RadioListTile<String>(
                        value: p.ua,
                        title: Text(
                          p.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
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
    final uaLabel =
        _s.defaultUserAgent.isEmpty ? l10n.userAgentAuto : _s.defaultUserAgent;
    return AppShrinkTitleScaffold(
      title: Text(l10n.advancedSettingsTitle),
      body: SettingsAutoScroll(
        child: ListView(
          padding: context.pageInset(AppTokens.spaceMd),
          children: <Widget>[
            // ── 日志 ──
            SettingsCard(
              key: const ValueKey<String>('advanced.log'),
              title: l10n.advancedLogGroup,
              index: 0,
              children: <Widget>[
                SettingsSwitchTile(
                  key: const ValueKey<String>('advanced.detailedLogging'),
                  title: l10n.detailedLogging,
                  subtitle: l10n.detailedLoggingHint,
                  value: _s.detailedLogging,
                  onChanged: _setDetailedLogging,
                ),
                SettingsTile(
                  key: const ValueKey<String>('advanced.crashLog'),
                  icon: Icons.bug_report_rounded,
                  title: l10n.crashLog,
                  subtitle: l10n.crashLogDesc,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const CrashLogScreen(),
                    ),
                  ),
                ),
                SettingsTile(
                  key: const ValueKey<String>('advanced.runtimeLog'),
                  icon: Icons.article_rounded,
                  title: l10n.runtimeLog,
                  subtitle: l10n.runtimeLogDesc,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const LogViewerScreen(),
                    ),
                  ),
                ),
              ],
            ),
            // ── 数据清理 ──
            //
            // 缓存（含 WebView 数据）统一收口到缓存管理页的分类列表：此前这里
            // 另有独立的「清除 WebView 数据」项，与分类页里的 WebView 类别
            // 职责重复（两处都能清同一份数据，且提示文案不同），故合并为一处，
            // 避免用户困惑「到底该点哪个」。
            SettingsCard(
              key: const ValueKey<String>('advanced.clean'),
              title: l10n.advancedCleanGroup,
              index: 1,
              children: <Widget>[
                SettingsTile(
                  key: const ValueKey<String>('advanced.clearCookies'),
                  icon: Icons.cookie_rounded,
                  title: l10n.clearCookies,
                  subtitle: l10n.clearCookiesDesc,
                  onTap: () => _clearCookies(context, l10n),
                ),
                SettingsTile(
                  key: const ValueKey<String>('advanced.imageCache'),
                  icon: Icons.sd_storage_rounded,
                  title: l10n.cacheManagerTitle,
                  subtitle: _imageCacheSizeText.isEmpty
                      ? l10n.advancedImageCacheDesc
                      : '${l10n.advancedImageCacheDesc} · $_imageCacheSizeText',
                  onTap: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const SettingsCacheManagerScreen(),
                      ),
                    );
                    // 返回后刷新总占用（分类页可能已清理）。
                    unawaited(_refreshImageCacheSize());
                  },
                ),
              ],
            ),
            // ── 请求指纹 ──
            SettingsCard(
              key: const ValueKey<String>('advanced.request'),
              title: l10n.advancedRequestGroup,
              index: 2,
              children: <Widget>[
                SettingsTile(
                  key: const ValueKey<String>('advanced.userAgent'),
                  icon: Icons.person_pin_circle_rounded,
                  title: l10n.defaultUserAgent,
                  subtitle: uaLabel,
                  onTap: () => _pickUserAgent(context, l10n),
                ),
              ],
            ),
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: AppTokens.spaceSm),
              child: Text(
                l10n.advancedPageHint,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

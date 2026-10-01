/// 缓存管理页（缓存分类 + 自动清理）。
///
/// 从高级设置进入，按类别展示全应用可清理缓存的占用并提供单独清理：
/// 图片缓存 / 弹幕缓存 / 翻译缓存 / WebView 数据 / 临时文件 / 更新包残留；
/// 底部为自动清理设置（开关 + 年龄上限 + 容量上限 + 立即清理一次）。
///
/// 各类别清理后自动刷新占用；WebView 数据无稳定占用统计 API，显示「无法统计」
/// 但仍可清理（复用高级页既有的 WebStorageManager 清理路径）。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:nexhub/generated/app_localizations.dart';

import '../../../core/settings/advanced_settings.dart';
import '../../../core/storage/cache_auto_clean.dart';
import '../../../core/storage/cache_inventory.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/utils/app_haptics.dart';
import '../../../core/widgets/app_animations.dart';
import '../../../core/widgets/app_glass_bar.dart';
import 'widgets/settings_widgets.dart';
import 'widgets/settings_search_target.dart';

/// 类别 → 图标。
IconData _categoryIcon(CacheCategory c) => switch (c) {
      CacheCategory.images => Icons.image_rounded,
      CacheCategory.danmaku => Icons.subtitles_rounded,
      CacheCategory.translations => Icons.translate_rounded,
      CacheCategory.webview => Icons.public_rounded,
      CacheCategory.tempFiles => Icons.folder_delete_rounded,
      CacheCategory.updatePackages => Icons.system_update_alt_rounded,
    };

class SettingsCacheManagerScreen extends StatefulWidget {
  const SettingsCacheManagerScreen({super.key});

  @override
  State<SettingsCacheManagerScreen> createState() =>
      _SettingsCacheManagerScreenState();
}

class _SettingsCacheManagerScreenState
    extends State<SettingsCacheManagerScreen> {
  AdvancedSettings _settings = const AdvancedSettings();

  /// 占用快照；null 表示统计中。
  CacheUsageSnapshot? _snapshot;

  /// 正在清理的类别（禁用重复点击 + 显示进度）。
  final Set<CacheCategory> _clearing = <CacheCategory>{};

  bool _cleaningAll = false;

  @override
  void initState() {
    super.initState();
    _settings = AdvancedSettingsStore.instance.settings;
    if (!AdvancedSettingsStore.instance.loaded) {
      AdvancedSettingsStore.instance.load().then((s) {
        if (mounted) setState(() => _settings = s);
      });
    }
    _refresh();
  }

  Future<void> _refresh() async {
    final CacheUsageSnapshot snap = await CacheInventory.snapshot();
    if (mounted) setState(() => _snapshot = snap);
  }

  void _update(AdvancedSettings next) {
    setState(() => _settings = next);
    AdvancedSettingsStore.instance.save(next);
  }

  String _categoryLabel(AppLocalizations l10n, CacheCategory c) =>
      switch (c) {
        CacheCategory.images => l10n.cacheCatImages,
        CacheCategory.danmaku => l10n.cacheCatDanmaku,
        CacheCategory.translations => l10n.cacheCatTranslations,
        CacheCategory.webview => l10n.cacheCatWebview,
        CacheCategory.tempFiles => l10n.cacheCatTemp,
        CacheCategory.updatePackages => l10n.cacheCatUpdates,
      };

  String _usageText(AppLocalizations l10n, CacheCategoryUsage? u) {
    if (u == null) return l10n.imageCacheCalculating;
    if (u.unknown) return l10n.cacheSizeUnknown;
    return formatCacheBytes(u.bytes);
  }

  Future<bool> _confirm(String title) async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(title),
            content: Text(AppLocalizations.of(context).confirmActionHint),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(AppLocalizations.of(context).cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(AppLocalizations.of(context).confirm),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _clearCategory(CacheCategory c) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final bool ok = await _confirm(l10n.cacheClearCategoryConfirm(
        _categoryLabel(l10n, c)));
    if (!ok || !mounted) return;
    setState(() => _clearing.add(c));
    try {
      if (c == CacheCategory.webview) {
        try {
          await WebStorageManager.instance().deleteAllData();
        } on Object {
          // 平台不支持时忽略。
        }
      }
      await CacheInventory.clear(c);
      // 弹幕缓存按 ttl 精确过期（图片/临时文件按文件 mtime，不涉及 Hive）。
      if (c == CacheCategory.danmaku) {
        await cleanExpiredDanmakuCache();
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.cacheCategoryCleared)),
      );
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.cacheClearFailed)),
      );
    } finally {
      if (mounted) {
        setState(() => _clearing.remove(c));
        unawaited(_refresh());
      }
    }
  }

  /// 一键清理全部类别（保留用户数据；下载/收藏/源不在缓存类别内）。
  Future<void> _clearAll() async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final bool ok = await _confirm(l10n.cacheClearAllConfirm);
    if (!ok || !mounted) return;
    setState(() => _cleaningAll = true);
    try {
      try {
        await WebStorageManager.instance().deleteAllData();
      } on Object {
        // 忽略。
      }
      for (final CacheCategory c in CacheCategory.values) {
        await CacheInventory.clear(c);
      }
      await cleanExpiredDanmakuCache();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.cacheCategoryCleared)),
      );
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.cacheClearFailed)),
      );
    } finally {
      if (mounted) {
        setState(() => _cleaningAll = false);
        unawaited(_refresh());
      }
    }
  }

  /// 立即执行一次自动清理策略（年龄 + 容量），便于用户手动触发。
  Future<void> _runAutoCleanNow() async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    setState(() => _cleaningAll = true);
    try {
      final CacheCleanResult r = await CacheAutoCleaner.run(
        maxAge: Duration(days: _settings.cacheMaxAgeDays),
        maxTotalBytes: _settings.cacheMaxTotalBytes,
      );
      await cleanExpiredDanmakuCache();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(r.isEmpty
              ? l10n.cacheAutoCleanNothing
              : l10n.cacheAutoCleanDone(formatCacheBytes(r.freedBytes))),
        ),
      );
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.cacheClearFailed)),
      );
    } finally {
      if (mounted) {
        setState(() => _cleaningAll = false);
        unawaited(_refresh());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final CacheUsageSnapshot? snap = _snapshot;
    final ThemeData theme = Theme.of(context);
    return AppShrinkTitleScaffold(
      title: Text(l10n.cacheManagerTitle),
      body: SettingsAutoScroll(
        child: ListView(
          padding: context.pageInset(AppTokens.spaceMd),
          children: <Widget>[
            // ── 总占用 + 一键清理 ──
            SettingsCard(
              key: const ValueKey<String>('cache.total'),
              title: l10n.cacheManagerTotal,
              description: snap == null
                  ? l10n.imageCacheCalculating
                  : l10n.cacheManagerTotalDesc(
                      formatCacheBytes(snap.totalBytes)),
              index: 0,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppTokens.spaceLg,
                    0,
                    AppTokens.spaceLg,
                    AppTokens.spaceMd,
                  ),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _cleaningAll || snap == null
                              ? null
                              : _runAutoCleanNow,
                          icon: const Icon(Icons.auto_delete_rounded, size: 18),
                          label: Text(l10n.cacheAutoCleanNow),
                        ),
                      ),
                      const SizedBox(width: AppTokens.spaceSm),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _cleaningAll ? null : _clearAll,
                          icon: const Icon(Icons.delete_sweep_rounded,
                              size: 18),
                          label: Text(l10n.cacheClearAll),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            // ── 分类占用 ──
            SettingsCard(
              key: const ValueKey<String>('cache.categories'),
              title: l10n.cacheCategoryGroup,
              index: 1,
              children: <Widget>[
                for (final CacheCategory c in CacheCategory.values)
                  SettingsTile(
                    key: ValueKey<String>('cache.cat.${c.name}'),
                    icon: _categoryIcon(c),
                    title: _categoryLabel(l10n, c),
                    subtitle: _categorySubtitle(l10n, c),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          _usageText(l10n, snap?.usageOf(c)),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(width: AppTokens.spaceSm),
                        if (_clearing.contains(c))
                          const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        else
                          IconButton(
                            tooltip: l10n.cacheClearCategory,
                            onPressed: () => _clearCategory(c),
                            icon: const Icon(Icons.cleaning_services_rounded,
                                size: 20),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
            // ── 自动清理 ──
            SettingsCard(
              key: const ValueKey<String>('cache.auto'),
              title: l10n.cacheAutoCleanGroup,
              description: l10n.cacheAutoCleanGroupDesc,
              index: 2,
              children: <Widget>[
                SettingsSwitchTile(
                  key: const ValueKey<String>('cache.autoClean'),
                  title: l10n.cacheAutoClean,
                  subtitle: l10n.cacheAutoCleanDesc,
                  value: _settings.autoCacheCleanEnabled,
                  onChanged: (bool v) {
                    v ? AppHaptics.toggleOn() : AppHaptics.toggleOff();
                    _update(_settings.copyWith(autoCacheCleanEnabled: v));
                  },
                ),
                if (_settings.autoCacheCleanEnabled) ...<Widget>[
                  SettingsSliderTile(
                    key: const ValueKey<String>('cache.maxAge'),
                    label: l10n.cacheMaxAge,
                    value: _settings.cacheMaxAgeDays.toDouble(),
                    min: 1,
                    max: 365,
                    divisions: 364,
                    display: l10n.cacheMaxAgeValue(_settings.cacheMaxAgeDays),
                    onChanged: (double v) =>
                        _update(_settings.copyWith(cacheMaxAgeDays: v.round())),
                  ),
                  SettingsSliderTile(
                    key: const ValueKey<String>('cache.maxTotal'),
                    label: l10n.cacheMaxTotal,
                    value: _settings.cacheMaxTotalMb.toDouble(),
                    min: 128,
                    max: 10240,
                    divisions: 79, // 128MB 步进
                    display: _settings.cacheMaxTotalMb >= 1024
                        ? '${(_settings.cacheMaxTotalMb / 1024).toStringAsFixed(1)} GB'
                        : '${_settings.cacheMaxTotalMb} MB',
                    onChanged: (double v) {
                      // 128MB 步进对齐（避免 128 步长下的碎值）。
                      final int snapped = (v / 128).round() * 128;
                      _update(_settings.copyWith(
                          cacheMaxTotalMb: snapped.clamp(128, 10240)));
                    },
                  ),
                ],
              ],
            ),
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppTokens.spaceSm, vertical: AppTokens.spaceSm),
              child: Text(
                l10n.cacheManagerHint,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _categorySubtitle(AppLocalizations l10n, CacheCategory c) =>
      switch (c) {
        CacheCategory.images => l10n.cacheCatImagesDesc,
        CacheCategory.danmaku => l10n.cacheCatDanmakuDesc,
        CacheCategory.translations => l10n.cacheCatTranslationsDesc,
        CacheCategory.webview => l10n.cacheCatWebviewDesc,
        CacheCategory.tempFiles => l10n.cacheCatTempDesc,
        CacheCategory.updatePackages => l10n.cacheCatUpdatesDesc,
      };
}

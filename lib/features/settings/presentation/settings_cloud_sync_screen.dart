/// 云同步设置页 —— WebDAV 备份与多端同步配置。
///
/// 提供以下功能：
/// 1. WebDAV URL / 用户名 / 密码配置（密码用 secure storage 安全存储）
/// 2. 测试连接（显示延迟，按颜色分级）
/// 3. 自动同步开关与频率选择
/// 4. 同步范围（分类勾选）+ 立即同步（上传选中分类）
/// 5. 从云端恢复：先选「合并 / 覆盖」模式与范围，再拉取恢复
/// 6. 明确的中文错误提示（按语义码映射）
library;

import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/novel/novel_progress_conflict.dart';
import '../../../core/novel/novel_progress_manager.dart';
import '../../../core/services/backup_archive.dart';
import '../../../core/services/cloud_sync_service.dart';
import '../../../core/services/novel_progress_sync_service.dart';
import '../../../core/settings/general_settings.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_list_tile.dart';
import '../../../core/widgets/backup_category_selector.dart';
import '../../../core/widgets/app_alert_dialog.dart';
import './settings_import_export_screen.dart';
import 'package:nexhub/core/navigation/app_page_route.dart';

class SettingsCloudSyncScreen extends StatefulWidget {
  const SettingsCloudSyncScreen({super.key});

  @override
  State<SettingsCloudSyncScreen> createState() =>
      _SettingsCloudSyncScreenState();
}

class _SettingsCloudSyncScreenState extends State<SettingsCloudSyncScreen> {
  late final TextEditingController _urlController;
  late final TextEditingController _usernameController;
  final TextEditingController _passwordController = TextEditingController();
  bool _testing = false;
  bool _saving = false;
  bool _syncing = false;
  bool _pulling = false;
  bool _resolving = false;
  Set<BackupCategory> _selected = <BackupCategory>{
    BackupCategory.source,
    BackupCategory.bookmark,
    BackupCategory.progress,
    BackupCategory.settings,
    BackupCategory.download,
    BackupCategory.danmaku,
  };
  bool _pullMerge = true;

  @override
  void initState() {
    super.initState();
    final config = context.read<CloudSyncService>().config;
    _urlController = TextEditingController(text: config.url);
    _usernameController = TextEditingController(text: config.username);
  }

  @override
  void dispose() {
    _urlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  /// 延迟档位色。仅用于 SnackBar（反色表面），故取 onInverseSurface 档。
  Color _latencyColor(ColorScheme scheme, int ms) {
    if (ms < 300) return AppStatusColors.ok(scheme, onInverseSurface: true);
    if (ms < 800) return AppStatusColors.warn(scheme, onInverseSurface: true);
    return AppStatusColors.fail(scheme, onInverseSurface: true);
  }

  /// 语义错误码 → 中文提示。
  String _errorText(AppLocalizations l10n, String? code) {
    if (code == null) return '';
    if (code == 'no_config') return l10n.cloudSyncErrorNoConfig;
    if (code == 'no_remote_backup') return l10n.cloudSyncErrorNoRemote;
    if (code == 'encode_failed') return l10n.cloudSyncErrorEncode;
    if (code == 'network') return l10n.cloudSyncErrorNetwork;
    if (code.startsWith('unknown:')) {
      return l10n.cloudSyncErrorUnknown(code.substring('unknown:'.length));
    }
    return l10n.cloudSyncErrorUnknown(code);
  }

  Future<void> _testConnection(AppLocalizations l10n) async {
    final service = context.read<CloudSyncService>();
    final url = _urlController.text.trim();
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    final effectivePassword = password.isNotEmpty
        ? password
        : (await CloudSyncConfigStore().loadPassword()) ?? '';
    if (url.isEmpty || username.isEmpty || effectivePassword.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.cloudSyncConnectionFailed)),
        );
      }
      return;
    }
    setState(() => _testing = true);
    final (success, ms) = await service.testConnection(
      url: url,
      username: username,
      password: effectivePassword,
    );
    if (!mounted) return;
    setState(() => _testing = false);
    final messenger = ScaffoldMessenger.of(context);
    if (success) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            l10n.cloudSyncConnectionSuccess(ms),
            style: TextStyle(
              color: _latencyColor(Theme.of(context).colorScheme, ms),
            ),
          ),
        ),
      );
    } else {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.cloudSyncConnectionFailed)),
      );
    }
  }

  Future<void> _saveConfig(AppLocalizations l10n) async {
    final service = context.read<CloudSyncService>();
    final url = _urlController.text.trim();
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    setState(() => _saving = true);
    final newConfig = service.config.copyWith(
      url: url,
      username: username,
    );
    await service.updateConfig(
        newConfig, password.isNotEmpty ? password : null);
    _passwordController.clear();
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.save)),
    );
  }

  Future<void> _syncNow(AppLocalizations l10n) async {
    final service = context.read<CloudSyncService>();
    if (_selected.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.backupScopeNone)),
      );
      return;
    }
    setState(() => _syncing = true);
    final ok = await service.syncNow(scope: _selected);
    if (!mounted) return;
    setState(() => _syncing = false);
    final messenger = ScaffoldMessenger.of(context);
    if (ok) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.cloudSyncSyncSuccess)),
      );
    } else {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            service.lastError != null
                ? _errorText(l10n, service.lastError)
                : l10n.cloudSyncSyncFailed,
          ),
        ),
      );
    }
  }

  /// 手动同步阅读进度。拉取远端 → 逐书裁决：
  /// - 本地领先自动上传、本地无记录自动应用云端；
  /// - 云端领先且本地有记录 → 弹确认框，确认后写回本地。
  ///
  /// 本地进度来源：SharedPreferences 前缀扫描（NovelProgressManager.prefix）。
  Future<void> _syncNovelProgress(AppLocalizations l10n) async {
    final messenger = ScaffoldMessenger.of(context);
    // 1) 汇总本地全部小说进度为快照。
    final prefs = await SharedPreferences.getInstance();
    final manager = NovelProgressManager();
    final local = <String, NovelProgressPoint>{};
    for (final key in prefs.getKeys()) {
      if (!key.startsWith(NovelProgressManager.prefix)) continue;
      final novelId = key.substring(NovelProgressManager.prefix.length);
      final p = await manager.get(novelId);
      if (p == null) continue;
      local[novelId] = NovelProgressPoint(
        novelId: novelId,
        chapterIndex: p.chapterIndex,
        charOffset: p.charOffset,
        page: p.currentPage,
      );
    }

    // 2) 全量裁决。
    final progressService = NovelProgressSyncService();
    final result = await progressService.syncAll(local);
    if (!mounted) return;

    // 3) 远端领先且本地有记录 → 需确认。
    if (result.requireConfirmation.isNotEmpty) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l10n.novelProgressConflictTitle),
          content: Text(
            l10n.novelProgressConflictBody(result.requireConfirmation.length),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l10n.novelProgressUseRemote),
            ),
          ],
        ),
      );
      if (confirmed == true && mounted) {
        // 4) 写回本地（被确认的 novelId 全量 applyRemote 后逐个落盘）。
        final applied = await progressService.applyRemote(
          local,
          confirmedIds: result.requireConfirmation,
        );
        if (mounted) {
          for (final id in applied) {
            final rp = local[id];
            if (rp == null) continue;
            await manager.save(
              id,
              '',
              rp.page,
              rp.chapterIndex,
              charOffset: rp.charOffset,
            );
          }
        }
      }
    }

    // 5) 汇总提示。
    if (!mounted) return;
    final parts = <String>[
      if (result.uploaded > 0)
        l10n.novelProgressSyncedUploaded(result.uploaded),
      if (result.autoAppliedFromRemote.isNotEmpty)
        l10n.novelProgressSyncedRestored(result.autoAppliedFromRemote.length),
      if (result.requireConfirmation.isNotEmpty)
        l10n.novelProgressSyncedConflicted(result.requireConfirmation.length),
      if (!result.hasChanges) l10n.novelProgressSyncedNone,
    ];
    messenger.showSnackBar(SnackBar(content: Text(parts.join(' '))));
  }

  Future<void> _pullRemote(AppLocalizations l10n) async {
    final service = context.read<CloudSyncService>();
    if (_selected.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.backupScopeNone)),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AppAlertDialog(
        title: Text(l10n.pullNow),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(_pullMerge ? l10n.backupMergeDesc : l10n.backupReplaceDesc),
            const SizedBox(height: AppTokens.spaceSm),
            Text(
              '${l10n.backupSelectScope}：${_selected.map((c) => backupCategoryLabel(l10n, c)).join('、')}',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(MaterialLocalizations.of(ctx).cancelButtonLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.confirmImport),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _pulling = true);
    final ok = await service.pullRemote(merge: _pullMerge, scope: _selected);
    if (!mounted) return;
    setState(() => _pulling = false);
    final messenger = ScaffoldMessenger.of(context);
    if (ok) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.cloudSyncSyncSuccess)),
      );
    } else {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            service.lastError != null
                ? _errorText(l10n, service.lastError)
                : l10n.cloudSyncSyncFailed,
          ),
        ),
      );
    }
  }

  /// 拉取前预览冲突，并在底部弹窗中按 box 选择保留云端/本地/合并，再恢复。
  Future<void> _resolveConflicts(AppLocalizations l10n) async {
    final service = context.read<CloudSyncService>();
    if (_selected.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.backupScopeNone)),
      );
      return;
    }
    setState(() => _resolving = true);
    final report = await service.previewConflicts(scope: _selected);
    if (!mounted) return;
    setState(() => _resolving = false);
    if (report == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            service.lastError != null
                ? _errorText(l10n, service.lastError)
                : l10n.cloudSyncSyncFailed,
          ),
        ),
      );
      return;
    }
    if (report.total == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.cloudSyncConflictNone)),
      );
      return;
    }
    final choices = await showModalBottomSheet<Map<String, bool>?>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _ConflictResolveSheet(report: report),
    );
    if (choices == null || !mounted) return;
    setState(() => _pulling = true);
    final ok = await service.pullRemote(
      merge: true,
      scope: _selected,
      conflictChoices: choices,
    );
    if (!mounted) return;
    setState(() => _pulling = false);
    final messenger = ScaffoldMessenger.of(context);
    if (ok) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.cloudSyncSyncSuccess)),
      );
    } else {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            service.lastError != null
                ? _errorText(l10n, service.lastError)
                : l10n.cloudSyncSyncFailed,
          ),
        ),
      );
    }
  }

  String _formatTime(int ts) =>
      GeneralSettingsStore.instance.settings.dateFormat
          .format(DateTime.fromMillisecondsSinceEpoch(ts), withTime: true);

  /// 同步状态明细卡片：展示上次备份 / 恢复的时间、成功与否、数据条数、范围。
  Widget _buildStatusCard(CloudSyncConfig config, AppLocalizations l10n) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.spaceMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.insights,
                    size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: AppTokens.spaceSm),
                Text(l10n.cloudSyncStatusSection,
                    style: theme.textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: AppTokens.spaceSm),
            _statusRow(
                l10n, l10n.cloudSyncStatusUpload, config.lastUpload, theme),
            const SizedBox(height: AppTokens.spaceXs),
            _statusRow(
                l10n, l10n.cloudSyncStatusRestore, config.lastRestore, theme),
            if (config.nextSyncTimestamp != null) ...<Widget>[
              const SizedBox(height: AppTokens.spaceXs),
              Row(
                children: <Widget>[
                  Icon(Icons.schedule, size: 16, color: theme.hintColor),
                  const SizedBox(width: AppTokens.spaceSm),
                  Expanded(
                    child: Text(
                      l10n.cloudSyncNextSync(
                          _formatTime(config.nextSyncTimestamp!)),
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _statusRow(
    AppLocalizations l10n,
    String title,
    SyncStatusEntry? e,
    ThemeData theme,
  ) {
    if (e == null) {
      return Row(
        children: <Widget>[
          Expanded(child: Text(title, style: theme.textTheme.bodyMedium)),
          Text(
            l10n.cloudSyncStatusNotRun,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
        ],
      );
    }
    final bool ok = e.success == true;
    final String statusText = e.noChanges
        ? l10n.cloudSyncStatusNoChanges
        : (ok ? l10n.cloudSyncStatusSuccess : l10n.cloudSyncStatusFailed);
    final Color statusColor = ok
        ? AppStatusColors.ok(theme.colorScheme)
        : AppStatusColors.fail(theme.colorScheme);
    final IconData statusIcon = e.noChanges
        ? Icons.check_circle_outline
        : (ok ? Icons.check_circle : Icons.error);
    final String timeText =
        e.timestamp != null ? _formatTime(e.timestamp!) : '';
    return Row(
      children: <Widget>[
        Expanded(child: Text(title, style: theme.textTheme.bodyMedium)),
        Icon(statusIcon, size: 16, color: statusColor),
        const SizedBox(width: AppTokens.spaceXs),
        Text(statusText,
            style: theme.textTheme.bodySmall?.copyWith(color: statusColor)),
        if (e.itemCount > 0) ...<Widget>[
          const SizedBox(width: AppTokens.spaceXs),
          Text('· ${l10n.cloudSyncStatusItems(e.itemCount)}',
              style: theme.textTheme.bodySmall),
        ],
        if (timeText.isNotEmpty) ...<Widget>[
          const SizedBox(width: AppTokens.spaceXs),
          Text(timeText,
              style:
                  theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final service = context.watch<CloudSyncService>();
    final config = service.config;
    final hasError = service.lastError != null;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.cloudSync)),
      body: ListView(
        padding: const EdgeInsets.all(AppTokens.spaceLg),
        children: <Widget>[
          TextField(
            controller: _urlController,
            decoration: InputDecoration(
              labelText: l10n.cloudSyncWebdavUrl,
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.link),
            ),
            keyboardType: TextInputType.url,
          ),
          const SizedBox(height: AppTokens.spaceMd),
          TextField(
            controller: _usernameController,
            decoration: InputDecoration(
              labelText: l10n.cloudSyncWebdavUsername,
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.person),
            ),
          ),
          const SizedBox(height: AppTokens.spaceMd),
          TextField(
            controller: _passwordController,
            decoration: InputDecoration(
              labelText: l10n.cloudSyncWebdavPassword,
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.lock),
            ),
            obscureText: true,
          ),
          const SizedBox(height: AppTokens.spaceMd),
          FilledButton.icon(
            onPressed: _testing ? null : () => _testConnection(l10n),
            icon: _testing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.wifi_find),
            label: Text(l10n.cloudSyncTestConnection),
          ),
          const SizedBox(height: AppTokens.spaceSm),
          OutlinedButton.icon(
            onPressed: _saving ? null : () => _saveConfig(l10n),
            icon: const Icon(Icons.save),
            label: Text(l10n.cloudSyncSaveConfig),
          ),
          const SizedBox(height: AppTokens.spaceLg),
          SwitchListTile(
            title: Text(l10n.cloudSyncAutoSync),
            value: config.autoSync,
            onChanged: (v) async {
              await service.updateConfig(
                config.copyWith(autoSync: v),
                null,
              );
            },
          ),
          const SizedBox(height: AppTokens.spaceSm),
          SegmentedButton<SyncFrequency>(
            segments: <ButtonSegment<SyncFrequency>>[
              ButtonSegment<SyncFrequency>(
                value: SyncFrequency.manual,
                label: Text(l10n.cloudSyncSyncFrequencyManual),
              ),
              ButtonSegment<SyncFrequency>(
                value: SyncFrequency.daily,
                label: Text(l10n.cloudSyncSyncFrequencyDaily),
              ),
              ButtonSegment<SyncFrequency>(
                value: SyncFrequency.weekly,
                label: Text(l10n.cloudSyncSyncFrequencyWeekly),
              ),
            ],
            selected: <SyncFrequency>{config.frequency},
            onSelectionChanged: config.autoSync
                ? (Set<SyncFrequency> selection) async {
                    final f = selection.first;
                    await service.updateConfig(
                      config.copyWith(frequency: f),
                      null,
                    );
                  }
                : null,
          ),
          const SizedBox(height: AppTokens.spaceLg),

          // ── F6：小说导出自动上传 WebDAV ──
          SwitchListTile(
            key: const ValueKey<String>('cloud.novelAutoUpload'),
            title: Text(l10n.cloudSyncAutoUploadNovelExports),
            subtitle: Text(l10n.cloudSyncAutoUploadNovelExportsDesc),
            value: config.autoUploadNovelExports,
            onChanged: (v) async {
              await service.updateConfig(
                config.copyWith(autoUploadNovelExports: v),
                null,
              );
              if (context.mounted) setState(() {});
            },
          ),
          const SizedBox(height: AppTokens.spaceSm),

          // ── 同步范围（分类勾选） ──
          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppTokens.spaceMd),
              child: BackupCategorySelector(
                selected: _selected,
                onChanged: (next) => setState(() => _selected = next),
              ),
            ),
          ),
          const SizedBox(height: AppTokens.spaceMd),

          // ── 立即同步（上传） ──
          FilledButton.icon(
            onPressed:
                (_syncing || service.isSyncing) ? null : () => _syncNow(l10n),
            icon: (_syncing || service.isSyncing)
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.cloud_sync),
            label: Text(l10n.cloudSyncSyncNow),
          ),
          const SizedBox(height: AppTokens.spaceSm),
          // 逐书进度冲突裁决同步（含确认框）。
          OutlinedButton.icon(
            onPressed: _syncing ? null : () => _syncNovelProgress(l10n),
            icon: const Icon(Icons.menu_book_outlined, size: 18),
            label: Text(l10n.novelProgressSyncNow),
          ),
          const SizedBox(height: AppTokens.spaceMd),
          _buildStatusCard(config, l10n),

          const SizedBox(height: AppTokens.spaceLg),
          const Divider(),
          const SizedBox(height: AppTokens.spaceMd),

          // ── 从云端恢复 ──
          Text(
            l10n.cloudSyncPullMode,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: AppTokens.spaceSm),
          SegmentedButton<bool>(
            segments: <ButtonSegment<bool>>[
              ButtonSegment<bool>(
                value: true,
                label: Text(l10n.backupMerge),
              ),
              ButtonSegment<bool>(
                value: false,
                label: Text(l10n.backupReplace),
              ),
            ],
            selected: <bool>{_pullMerge},
            onSelectionChanged: (sel) => setState(() => _pullMerge = sel.first),
          ),
          const SizedBox(height: AppTokens.spaceSm),
          OutlinedButton.icon(
            onPressed: (_pulling || service.isSyncing)
                ? null
                : () => _pullRemote(l10n),
            icon: (_pulling || service.isSyncing)
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.cloud_download_outlined),
            label: Text(l10n.pullNow),
          ),
          const SizedBox(height: AppTokens.spaceSm),
          OutlinedButton.icon(
            onPressed: (_resolving || service.isSyncing)
                ? null
                : () => _resolveConflicts(l10n),
            icon: (_resolving || service.isSyncing)
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.merge_type),
            label: Text(l10n.cloudSyncResolveConflicts),
          ),

          // ── 错误横幅 ──
          if (hasError) ...<Widget>[
            const SizedBox(height: AppTokens.spaceLg),
            Container(
              padding: const EdgeInsets.all(AppTokens.spaceMd),
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .errorContainer
                    .withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(AppTokens.radiusMd),
                border: Border.all(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
              child: Row(
                children: <Widget>[
                  Icon(
                    Icons.error_outline,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  const SizedBox(width: AppTokens.spaceSm),
                  Expanded(
                    child: Text(
                      _errorText(l10n, service.lastError),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color:
                                Theme.of(context).colorScheme.onErrorContainer,
                          ),
                    ),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: AppTokens.spaceXl),
          AppListTile(
            leading: const Icon(Icons.swap_vert),
            title: Text(l10n.dataImportExport),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              AppPageRoute<void>(
                builder: (_) => const SettingsImportExportScreen(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ConflictResolveSheet extends StatefulWidget {
  final SyncConflictReport report;

  const _ConflictResolveSheet({required this.report});

  @override
  State<_ConflictResolveSheet> createState() => _ConflictResolveSheetState();
}

class _ConflictResolveSheetState extends State<_ConflictResolveSheet> {
  late final Map<String, _Choice> _choices;

  @override
  void initState() {
    super.initState();
    _choices = <String, _Choice>{};
    for (final box in widget.report.byBox.keys) {
      _choices[box] = _Choice.merge;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      maxChildSize: 0.92,
      minChildSize: 0.4,
      expand: false,
      builder: (ctx, scroll) => Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(AppTokens.spaceMd),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(l10n.cloudSyncConflictTitle,
                    style: theme.textTheme.titleMedium),
                const SizedBox(height: AppTokens.spaceXs),
                Text(l10n.cloudSyncConflictIntro,
                    style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              controller: scroll,
              padding: const EdgeInsets.all(AppTokens.spaceMd),
              children: <Widget>[
                for (final entry in widget.report.byBox.entries)
                  ..._boxCard(entry.key, entry.value, l10n, theme),
              ],
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(AppTokens.spaceMd),
              child: FilledButton(
                onPressed: () {
                  final map = <String, bool>{};
                  for (final e in _choices.entries) {
                    if (e.value == _Choice.remote) {
                      map[e.key] = true;
                    } else if (e.value == _Choice.local) {
                      map[e.key] = false;
                    }
                  }
                  Navigator.pop(context, map);
                },
                child: Text(l10n.cloudSyncConflictApply),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _boxCard(
    String box,
    List<SyncConflict> conflicts,
    AppLocalizations l10n,
    ThemeData theme,
  ) {
    final category = conflicts.first.category;
    final choice = _choices[box] ?? _Choice.merge;
    return <Widget>[
      Card(
        child: Padding(
          padding: const EdgeInsets.all(AppTokens.spaceMd),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(backupCategoryLabel(l10n, category),
                        style: theme.textTheme.titleSmall),
                  ),
                  Text(
                    l10n.cloudSyncConflictCount(conflicts.length),
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.hintColor),
                  ),
                ],
              ),
              const SizedBox(height: AppTokens.spaceSm),
              SegmentedButton<_Choice>(
                segments: <ButtonSegment<_Choice>>[
                  ButtonSegment<_Choice>(
                    value: _Choice.remote,
                    label: Text(l10n.cloudSyncConflictUseRemote),
                  ),
                  ButtonSegment<_Choice>(
                    value: _Choice.local,
                    label: Text(l10n.cloudSyncConflictKeepLocal),
                  ),
                  ButtonSegment<_Choice>(
                    value: _Choice.merge,
                    label: Text(l10n.cloudSyncConflictMerge),
                  ),
                ],
                selected: <_Choice>{choice},
                onSelectionChanged: (sel) =>
                    setState(() => _choices[box] = sel.first),
              ),
              const SizedBox(height: AppTokens.spaceSm),
              for (final c in conflicts.take(3)) _sampleRow(c, l10n, theme),
            ],
          ),
        ),
      ),
      const SizedBox(height: AppTokens.spaceMd),
    ];
  }

  Widget _sampleRow(
    SyncConflict c,
    AppLocalizations l10n,
    ThemeData theme,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTokens.spaceXs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(c.key,
              style: theme.textTheme.bodySmall
                  ?.copyWith(fontWeight: FontWeight.w600)),
          Row(
            children: <Widget>[
              Icon(Icons.phone_android, size: 12, color: theme.hintColor),
              const SizedBox(width: AppTokens.spaceXs),
              Expanded(
                child: Text(
                  '${l10n.cloudSyncConflictLocal}：${c.localPreview}',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
          Row(
            children: <Widget>[
              Icon(Icons.cloud, size: 12, color: theme.hintColor),
              const SizedBox(width: AppTokens.spaceXs),
              Expanded(
                child: Text(
                  '${l10n.cloudSyncConflictRemote}：${c.remotePreview}',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

enum _Choice { remote, local, merge }

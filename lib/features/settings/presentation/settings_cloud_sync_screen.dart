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

import '../../../core/services/backup_archive.dart';
import '../../../core/services/cloud_sync_service.dart';
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

  Color _latencyColor(int ms) {
    if (ms < 300) return Colors.green;
    if (ms < 800) return Colors.orange;
    return Colors.red;
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
            style: TextStyle(color: _latencyColor(ms)),
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
    await service.updateConfig(newConfig, password.isNotEmpty ? password : null);
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
            onPressed: (_syncing || service.isSyncing)
                ? null
                : () => _syncNow(l10n),
            icon: (_syncing || service.isSyncing)
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.cloud_sync),
            label: Text(l10n.cloudSyncSyncNow),
          ),
          const SizedBox(height: AppTokens.spaceMd),
          _LastSyncText(config: config),

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
            onSelectionChanged: (sel) =>
                setState(() => _pullMerge = sel.first),
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
                            color: Theme.of(context).colorScheme.onErrorContainer,
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

class _LastSyncText extends StatelessWidget {
  final CloudSyncConfig config;

  const _LastSyncText({required this.config});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: GeneralSettingsStore.instance,
      builder: (context, _) {
        String text;
        if (config.lastSyncTimestamp == null) {
          text = l10n.cloudSyncNeverSynced;
        } else {
          final dt = DateTime.fromMillisecondsSinceEpoch(
            config.lastSyncTimestamp!,
          );
          final formatted =
              GeneralSettingsStore.instance.settings.dateFormat.format(
            dt,
            withTime: true,
          );
          text = l10n.cloudSyncLastSyncTime(formatted);
        }
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppTokens.spaceSm),
          child: Text(
            text,
            style: theme.textTheme.bodyMedium,
          ),
        );
      },
    );
  }
}

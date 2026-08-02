/// 数据导入 / 导出屏幕 —— 基于统一备份归档模块 [backup_archive]。
///
/// 与云同步共用同一 bundle 结构，支持：
/// - 导出时按分类勾选（源与订阅 / 收藏书签 / 进度历史 / 设置偏好 / 下载 / 弹幕缓存）；
/// - 导入时预览数据条数，并选择「合并（保留本地）」或「覆盖（以备份为准）」。
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/services/backup_archive.dart';
import '../../../core/settings/data_export_config.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_alert_dialog.dart';
import '../../../core/widgets/app_list_tile.dart';
import '../../../core/widgets/backup_category_selector.dart';

class SettingsImportExportScreen extends StatefulWidget {
  const SettingsImportExportScreen({super.key});

  @override
  State<SettingsImportExportScreen> createState() =>
      _SettingsImportExportScreenState();
}

class _SettingsImportExportScreenState
    extends State<SettingsImportExportScreen> {
  String _exportFolder = '';
  final DataExportConfigStore _store = DataExportConfigStore();
  Set<BackupCategory> _selected = <BackupCategory>{
    BackupCategory.source,
    BackupCategory.bookmark,
    BackupCategory.progress,
    BackupCategory.settings,
    BackupCategory.download,
    BackupCategory.danmaku,
  };

  @override
  void initState() {
    super.initState();
    _store.load().then((config) {
      if (mounted) setState(() => _exportFolder = config.exportFolder);
    });
  }

  Future<String?> _pickExportFolder() async {
    final result = await FilePicker.platform.getDirectoryPath(
      initialDirectory: _exportFolder.isNotEmpty ? _exportFolder : null,
    );
    if (result != null && mounted) {
      setState(() => _exportFolder = result);
      await _store.save(DataExportConfig(exportFolder: result));
      return result;
    }
    return null;
  }

  // ── 导入 ───────────────────────────────────────────────────────────────

  Future<void> _pickImportFile() async {
    final l10n = AppLocalizations.of(context);
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['json'],
    );
    if (result == null || !mounted) return;

    final filePath = result.files.single.path;
    if (filePath == null) {
      _snack(l10n.importDataInvalidFormat);
      return;
    }

    _snack(l10n.importDataParsing);
    try {
      final text = await File(filePath).readAsString();
      final bundle = decodeBackupBundle(text);
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      if (bundle == null || !isValidBackupBundle(bundle)) {
        _snack(l10n.importDataInvalidFormat);
        return;
      }
      await _showImportPreview(bundle);
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      _snack(l10n.importDataFailed);
    }
  }

  Future<void> _showImportPreview(Map<String, dynamic> bundle) async {
    final l10n = AppLocalizations.of(context);
    final count = countBundleEntries(bundle);
    var merge = true; // 默认合并（更安全）

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setInner) => AppAlertDialog(
          title: Text(l10n.backupPreviewTitle(count)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(l10n.backupImportMode),
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
                selected: <bool>{merge},
                onSelectionChanged: (sel) => setInner(() => merge = sel.first),
              ),
              const SizedBox(height: AppTokens.spaceXs),
              Text(
                merge ? l10n.backupMergeDesc : l10n.backupReplaceDesc,
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
      ),
    );

    if (confirmed != true || !mounted) return;
    try {
      await applyBackupBundle(bundle, merge: merge);
      if (!mounted) return;
      _snack(l10n.importDataSuccess);
    } on Object {
      if (!mounted) return;
      _snack(l10n.importDataFailed);
    }
  }

  // ── 导出 ───────────────────────────────────────────────────────────────

  Future<void> _showExportSheet() async {
    final l10n = AppLocalizations.of(context);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppTokens.radiusXl),
        ),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        maxChildSize: 0.9,
        minChildSize: 0.5,
        expand: false,
        builder: (sheetCtx, _) => Padding(
          padding: EdgeInsets.only(
            left: AppTokens.spaceLg,
            right: AppTokens.spaceLg,
            top: AppTokens.spaceMd,
            bottom: MediaQuery.of(sheetCtx).viewInsets.bottom + AppTokens.spaceLg,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Center(
                child: Container(
                  margin: const EdgeInsets.only(top: AppTokens.spaceMd),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Theme.of(sheetCtx)
                        .colorScheme
                        .onSurfaceVariant
                        .withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(AppTokens.radiusFull),
                  ),
                ),
              ),
              const SizedBox(height: AppTokens.spaceMd),
              BackupCategorySelector(
                selected: _selected,
                onChanged: (next) => setState(() => _selected = next),
              ),
              const SizedBox(height: AppTokens.spaceMd),
              FilledButton.icon(
                onPressed: _selected.isEmpty
                    ? null
                    : () {
                        Navigator.pop(sheetCtx);
                        _showFolderThenExport();
                      },
                icon: const Icon(Icons.file_upload_outlined),
                label: Text(l10n.exportData),
              ),
              if (_selected.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: AppTokens.spaceSm),
                  child: Text(
                    l10n.backupScopeNone,
                    style: Theme.of(sheetCtx)
                        .textTheme
                        .bodySmall
                        ?.copyWith(
                          color: Theme.of(sheetCtx).colorScheme.error,
                        ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showFolderThenExport() async {
    final l10n = AppLocalizations.of(context);
    String? folder = _exportFolder.isNotEmpty ? _exportFolder : null;
    if (folder == null) {
      // 未设置自定义目录：询问默认 or 自定义
      final choice = await showModalBottomSheet<String>(
        context: context,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppTokens.radiusXl),
          ),
        ),
        builder: (ctx) => Padding(
          padding: const EdgeInsets.all(AppTokens.spaceLg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.folder_special),
                title: Text(l10n.exportFolderDefault),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.pop(ctx, 'default'),
              ),
              ListTile(
                leading: const Icon(Icons.save_outlined),
                title: Text(l10n.exportFolderCustom),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.pop(ctx, 'custom'),
              ),
            ],
          ),
        ),
      );
      if (choice == 'default') {
        final dir = await getApplicationDocumentsDirectory();
        final exportDir = Directory('${dir.path}/NexHub/Exports');
        if (!exportDir.existsSync()) exportDir.createSync(recursive: true);
        folder = exportDir.path;
      } else if (choice == 'custom') {
        folder = await _pickExportFolder();
      }
    } else {
      // 已设置自定义目录：直接询问是否改用默认
      final choice = await showModalBottomSheet<String>(
        context: context,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppTokens.radiusXl),
          ),
        ),
        builder: (ctx) => Padding(
          padding: const EdgeInsets.all(AppTokens.spaceLg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.folder_special),
                title: Text(l10n.exportFolderDefault),
                subtitle: _exportFolder.isNotEmpty ? Text(_exportFolder) : null,
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.pop(ctx, 'default'),
              ),
              ListTile(
                leading: const Icon(Icons.save_outlined),
                title: Text(l10n.exportFolderCustom),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.pop(ctx, 'custom'),
              ),
            ],
          ),
        ),
      );
      if (choice == 'default') {
        final dir = await getApplicationDocumentsDirectory();
        final exportDir = Directory('${dir.path}/NexHub/Exports');
        if (!exportDir.existsSync()) exportDir.createSync(recursive: true);
        folder = exportDir.path;
      } else if (choice == 'custom') {
        folder = await _pickExportFolder();
      }
    }
    if (folder == null || !mounted) return;
    await _doExport(folder);
  }

  Future<void> _doExport(String folder) async {
    final l10n = AppLocalizations.of(context);
    if (_selected.isEmpty) {
      _snack(l10n.backupScopeNone);
      return;
    }
    _snack(l10n.exportDataInProgress);
    try {
      final bundle = await buildBackupBundle(categories: _selected);
      final count = countBundleEntries(bundle);
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .replaceAll('.', '-');
      final filePath = '$folder/nexhub_backup_$stamp.json';
      final json = encodeBackupBundle(bundle);
      await File(filePath).writeAsString(json);
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      _snack(l10n.backupExported(count));
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      _snack(l10n.exportDataFailed);
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.dataImportExportTitle)),
      body: ListView(
        padding: const EdgeInsets.all(AppTokens.spaceLg),
        children: <Widget>[
          _ImportExportGroupHeader(label: l10n.importData),
          AppListTile(
            leading: const Icon(Icons.file_open_outlined),
            title: Text(l10n.importData),
            subtitle: Text(l10n.importDataDesc),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickImportFile(),
          ),
          const SizedBox(height: AppTokens.spaceXl),
          _ImportExportGroupHeader(label: l10n.exportData),
          AppListTile(
            leading: const Icon(Icons.download_outlined),
            title: Text(l10n.exportData),
            subtitle: Text(l10n.exportDataDesc),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showExportSheet(),
          ),
          const SizedBox(height: AppTokens.spaceXl),
          Padding(
            padding: const EdgeInsets.all(AppTokens.spaceMd),
            child: Container(
              padding: const EdgeInsets.all(AppTokens.spaceMd),
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .surfaceContainerHighest
                    .withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(AppTokens.radiusMd),
                border: Border.all(
                  color: Theme.of(context)
                      .colorScheme
                      .outlineVariant
                      .withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                children: <Widget>[
                  Icon(
                    Icons.info_outline,
                    size: 18,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: AppTokens.spaceSm),
                  Expanded(
                    child: Text(
                      l10n.selectExportFolder,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Reusable group header for import/export sections.
// ─────────────────────────────────────────────────────────────────────────────

class _ImportExportGroupHeader extends StatelessWidget {
  final String label;
  const _ImportExportGroupHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTokens.spaceSm),
      child: Text(
        label,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:provider/provider.dart';

import '../../../core/local/folder_import_dialog.dart';
import '../../../core/local/import_permission.dart';
import '../../../core/local/local_content_manager.dart';
import '../../../core/local/saf_bridge.dart';
import 'package:path/path.dart' as p;
import '../../../core/models/plugin_config.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_empty_state.dart';
import '../../../core/widgets/app_icon_button.dart';
import '../../../core/widgets/app_list_tile.dart';
import 'dart:async' show unawaited;
import 'package:nexhub/core/local/local_content_actions.dart';

/// 统一内容导入（浏览页占位功能之一）。
///
/// 选取本地文件（小说 / 漫画 / 媒体）并写入 [LocalContentManager] 持久化，
/// 导入历史可重新打开到 [LocalMediaViewer]。支持按 [SourceType] 聚焦某一类格式。
class ContentImportScreen extends StatefulWidget {
  final SourceType? sourceType;
  const ContentImportScreen({super.key, this.sourceType});

  @override
  State<ContentImportScreen> createState() => _ContentImportScreenState();
}

class _ContentImportScreenState extends State<ContentImportScreen> {
  bool _picking = false;

  Future<void> _pick() async {
    final granted = await requestLocalImportPermission();
    if (!granted) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).storagePermissionDenied)),
      );
      return;
    }
    setState(() => _picking = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.any,
      );
      if (result == null || !mounted) return;
      for (final f in result.files) {
        if (f.path == null) {
          if (!mounted) continue;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(AppLocalizations.of(context).pickFileNoPath)),
          );
          continue;
        }
        final kind = classifyByPath(f.path!);
        if (kind == null) {
          if (!mounted) continue;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(AppLocalizations.of(context).unrecognizedFile(f.name))),
          );
          continue;
        }
        await context.read<LocalContentManager>().add(LocalContentEntry(
          id: f.path!,
          title: f.name,
          path: f.path!,
          kind: kind,
          addedAt: DateTime.now().millisecondsSinceEpoch,
        ));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).importFailed(e.toString()))),
      );
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  /// 选择文件夹导入（bug 117）：小说文件夹聚合为一本书、每文件=一章；
  /// 图片文件夹作为整部漫画（目录）导入；其余提示空文件夹。
  Future<void> _pickFolder() async {
    final granted = await requestLocalImportPermission();
    if (!granted) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).storagePermissionDenied)),
      );
      return;
    }
    final dir = await FilePicker.platform.getDirectoryPath();
    if (dir == null || !mounted) return;
    final saf = isAndroidSafUri(dir);
    final folderTitle = saf ? await safFolderName(dir) : p.basename(dir);
    setState(() => _picking = true);
    try {
      // 小说（txt/epub）文件夹：聚合为一本书，每文件=一章（bug 117 / 112）。
      final textFiles = saf
          ? await listFolderFilesByKindSaf(dir, LocalMediaKind.text)
          : listFolderFilesByKind(dir, LocalMediaKind.text);
      if (textFiles.isNotEmpty) {
        if (textFiles.length > 1) {
          final mode = await showFolderImportChoiceDialog(
            context,
            folderName: folderTitle,
            typeLabel: AppLocalizations.of(context).importNovelTitle,
          );
          if (!mounted) return;
          if (mode == null) return;
          if (mode == FolderImportMode.merge) {
            await context.read<LocalContentManager>().add(LocalContentEntry(
              id: dir,
              title: folderTitle,
              path: dir,
              kind: LocalMediaKind.text,
              addedAt: DateTime.now().millisecondsSinceEpoch,
              filePaths: textFiles,
            ));
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(AppLocalizations.of(context).novelDirImported(folderTitle, textFiles.length))),
              );
            }
            return;
          }
        }
        for (final f in textFiles) {
          await context.read<LocalContentManager>().add(LocalContentEntry(
            id: f,
            title: safBaseName(f),
            path: f,
            kind: LocalMediaKind.text,
            addedAt: DateTime.now().millisecondsSinceEpoch,
          ));
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${textFiles.length} ${AppLocalizations.of(context).contentImportOpened}')),
          );
        }
        return;
      }
      // 图片文件夹：作为整部漫画（目录）导入，阅读器按文件名读取。
      final imageFiles = saf
          ? await listFolderFilesByKindSaf(dir, LocalMediaKind.images)
          : listFolderFilesByKind(dir, LocalMediaKind.images);
      if (imageFiles.isNotEmpty) {
        await context.read<LocalContentManager>().add(LocalContentEntry(
          id: dir,
          title: folderTitle,
          path: dir,
          kind: LocalMediaKind.images,
          addedAt: DateTime.now().millisecondsSinceEpoch,
        ));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(AppLocalizations.of(context).comicDirImported(folderTitle))),
          );
        }
        return;
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).emptyFolder)),
      );
    } on FileSystemException catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).folderScanFailed)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).importFailed(e.toString()))),
      );
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  IconData _iconFor(LocalMediaKind kind) => switch (kind) {
        LocalMediaKind.video => Icons.movie_outlined,
        LocalMediaKind.images => Icons.auto_stories_outlined,
        LocalMediaKind.text => Icons.menu_book_outlined,
        LocalMediaKind.pdf => Icons.picture_as_pdf_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final LocalContentManager manager = context.watch<LocalContentManager>();
    final List<LocalContentEntry> items = manager.items;

    final String title;
    if (widget.sourceType == SourceType.animeSource) {
      title = l10n.contentImportMediaFormats;
    } else if (widget.sourceType == SourceType.mangaSource) {
      title = l10n.contentImportComicFormats;
    } else if (widget.sourceType == SourceType.novelSource) {
      title = l10n.contentImportNovelFormats;
    } else {
      title = l10n.contentImportTitle;
    }

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      floatingActionButton: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          FloatingActionButton.extended(
            onPressed: _picking ? null : _pickFolder,
            icon: const Icon(Icons.folder_outlined),
            label: Text(l10n.importNovelPickFolder),
          ),
          const SizedBox(height: AppTokens.spaceMd),
          FloatingActionButton.extended(
            onPressed: _picking ? null : _pick,
            icon: _picking
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.file_open_outlined),
            label: Text(l10n.contentImportSelectFile),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppTokens.spaceLg),
        children: <Widget>[
          Card(
            elevation: 0,
            color: scheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(AppTokens.spaceLg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(l10n.contentImportSupportedFormats,
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: AppTokens.spaceMd),
                  _formatRow(l10n.contentImportNovelFormats, Icons.menu_book_outlined),
                  _formatRow(l10n.contentImportComicFormats, Icons.auto_stories_outlined),
                  _formatRow(l10n.contentImportMediaFormats, Icons.movie_outlined),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppTokens.spaceLg),
          Text(l10n.contentImportHistory, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AppTokens.spaceMd),
          if (items.isEmpty)
            AppEmptyState(icon: Icons.inbox_outlined, message: l10n.contentImportEmpty)
          else
            ...items.map((e) => AppListTile(
                  leading: Icon(_iconFor(e.kind), color: scheme.primary),
                  title: Text(e.title),
                  subtitle: Text(e.path, maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert_outlined),
                    tooltip: l10n.contentImportActions,
                    onSelected: (action) {
                      switch (action) {
                        case 'open':
                          openLocalEntry(context, e);
                        case 'rename':
                          unawaited(renameLocalEntry(context, e));
                        case 'delete':
                          unawaited(deleteLocalEntry(context, e));
                      }
                    },
                    itemBuilder: (ctx) => <PopupMenuEntry<String>>[
                      PopupMenuItem<String>(
                        value: 'open',
                        child: ListTile(
                          leading: const Icon(Icons.open_in_new_outlined),
                          title: Text(l10n.contentImportOpened),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                      PopupMenuItem<String>(
                        value: 'rename',
                        child: ListTile(
                          leading: const Icon(Icons.edit_outlined),
                          title: Text(l10n.renameGroup),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                      PopupMenuItem<String>(
                        value: 'delete',
                        child: ListTile(
                          leading: const Icon(Icons.delete_outline),
                          title: Text(l10n.delete),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    ],
                  ),
                )),
        ],
      ),
    );
  }

  Widget _formatRow(String text, IconData icon) => Padding(
        padding: const EdgeInsets.symmetric(vertical: AppTokens.spaceXs),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: AppTokens.spaceSm),
            Expanded(child: Text(text, style: Theme.of(context).textTheme.bodyMedium)),
          ],
        ),
      );
}

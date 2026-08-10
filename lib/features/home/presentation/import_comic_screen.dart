/// 漫画导入页面 —— 专用于漫画文件的本地导入。
///
/// 支持 cbz / cbr / cbt 等常见漫画压缩格式，
/// 提供单文件选取和目录批量导入两种方式。
library;

import 'dart:io' show Directory, File, FileSystemException;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../../core/local/import_permission.dart';
import '../../../core/local/local_content_manager.dart';
import '../../../core/platform/platform_service.dart';
import '../../../core/theme/app_tokens.dart';

class ImportComicScreen extends StatefulWidget {
  const ImportComicScreen({super.key});

  @override
  State<ImportComicScreen> createState() => _ImportComicScreenState();
}

class _ImportComicScreenState extends State<ImportComicScreen> {
  bool _picking = false;

  Future<void> _pickFiles() async {
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
      // Android SAF 无法按 cbz/cbr/cbt 等无标准 MIME 的扩展名稳定过滤（用户根本
      // 看不到这些文件），统一用 FileType.any 再由 classifyByPath 校验；桌面保留 custom。
      final isAndroid = PlatformService.instance.isAndroid;
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: isAndroid ? FileType.any : FileType.custom,
        allowedExtensions: isAndroid
            ? null
            : const <String>['cbz', 'cbr', 'cbt', 'zip', 'rar', 'pdf'],
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
        // Android 走 FileType.any，需校验是否为漫画（图片）或 PDF 类型。
        final kind = classifyByPath(f.path!);
        if (kind == null ||
            (kind != LocalMediaKind.images && kind != LocalMediaKind.pdf)) {
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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${result.files.length} ${AppLocalizations.of(context).contentImportOpened}')),
        );
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

  Future<void> _pickDirectory() async {
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
    // Android SAF 返回 content:// tree URI，dart:io 无法列举，直接给出明确提示。
    if (isAndroidSafUri(dir)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).folderPickUnsupportedSaf)),
      );
      return;
    }
    // 递归校验目录内是否含图片（漫画按图片目录导入），但整目录视为「一部漫画」。
    setState(() => _picking = true);
    try {
      final dirObj = Directory(dir);
      final hasImages = dirObj
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .any((f) => classifyByPath(f.path) == LocalMediaKind.images);
      if (!hasImages) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).emptyFolder)),
        );
        return;
      }
      // 整目录作为「一部漫画」导入：阅读器会按文件名顺序依次读取目录内图片。
      final kind = classifyFolderByContent(dir) ?? LocalMediaKind.images;
      await context.read<LocalContentManager>().add(LocalContentEntry(
        id: dir,
        title: p.basename(dir),
        path: dir,
        kind: kind,
        addedAt: DateTime.now().millisecondsSinceEpoch,
      ));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context).comicDirImported(p.basename(dir))),
          ),
        );
      }
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.importComicTitle)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppTokens.spaceXl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              // 上传图标
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: scheme.primaryContainer.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(AppTokens.radiusLg),
                ),
                child: Icon(
                  Icons.upload_file_outlined,
                  size: 40,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(height: AppTokens.spaceLg),

              // 格式说明
              Text(
                l10n.importComicFormatsHint,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: scheme.onSurface,
                    ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppTokens.spaceXl),

              // 选择文件按钮
              SizedBox(
                width: 200,
                child: FilledButton.icon(
                  onPressed: _picking ? null : _pickFiles,
                  icon: _picking
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.photo_album_outlined),
                  label: Text(l10n.importComicPickFile),
                ),
              ),
              const SizedBox(height: AppTokens.spaceMd),

              // 选择目录按钮（Outlined）
              SizedBox(
                width: 200,
                child: OutlinedButton.icon(
                  onPressed: _picking ? null : _pickDirectory,
                  icon: const Icon(Icons.folder_outlined, size: 18),
                  label: Text(l10n.importComicPickFolder),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

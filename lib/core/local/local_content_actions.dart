/// 本地导入内容的通用操作（打开 / 重命名 / 删除）。
///
/// 供导入历史列表（[ContentImportScreen]）与各媒体书架「本地」分段
/// （[bookshelf_content] 的 [_LocalBookshelf]）复用，避免重复实现弹窗逻辑。
library;

import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:nexhub/core/download/download_manager.dart';
import 'package:nexhub/core/download/download_task.dart';
import 'package:nexhub/core/local/local_content_manager.dart';
import 'package:nexhub/core/navigation/app_page_route.dart';
import 'package:nexhub/features/home/presentation/local_media_viewer.dart';
import 'package:nexhub/generated/app_localizations.dart';

/// 打开本地导入内容到 [LocalMediaViewer]。
void openLocalEntry(BuildContext context, LocalContentEntry e) {
  Navigator.of(context).push(
    AppPageRoute<void>(
      builder: (_) => LocalMediaViewer(
        title: e.title,
        kind: e.kind,
        uri: e.path,
      ),
    ),
  );
}

/// 重命名本地导入条目（仅改记录中的标题，不影响磁盘文件名）。
Future<void> renameLocalEntry(BuildContext context, LocalContentEntry e) async {
  final l10n = AppLocalizations.of(context);
  final controller = TextEditingController(text: e.title);
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(l10n.renameGroup),
      content: TextField(
        controller: controller,
        decoration: InputDecoration(hintText: l10n.renameHint),
        autofocus: true,
        onSubmitted: (v) => Navigator.of(ctx).pop(v),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(controller.text),
          child: Text(l10n.ok),
        ),
      ],
    ),
  );
  if (result != null && result.trim().isNotEmpty) {
    await context.read<LocalContentManager>().rename(e.id, result.trim());
  }
}

/// 删除本地导入条目：仅删记录，或连同磁盘文件一起删。
Future<void> deleteLocalEntry(BuildContext context, LocalContentEntry e) async {
  final l10n = AppLocalizations.of(context);
  final choice = await showDialog<bool?>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(l10n.deleteConfirmTitle),
      content: Text(e.title),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(l10n.deleteRecordOnly),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(l10n.deleteRecordAndFile),
        ),
      ],
    ),
  );
  if (choice != null) {
    await context
        .read<LocalContentManager>()
        .remove(e.id, deleteFile: choice);
  }
}

/// 长按弹出的操作菜单（打开 / 重命名 / 删除）。
///
/// 用底部抽屉承载，符合应用弹层规范（[isScrollControlled] + 限高）。
void showLocalEntryActions(BuildContext context, LocalContentEntry e) {
  final l10n = AppLocalizations.of(context);
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          ListTile(
            leading: const Icon(Icons.open_in_new_outlined),
            title: Text(l10n.contentImportOpened),
            onTap: () {
              Navigator.of(ctx).pop();
              openLocalEntry(context, e);
            },
          ),
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: Text(l10n.renameGroup),
            onTap: () {
              Navigator.of(ctx).pop();
              unawaited(renameLocalEntry(context, e));
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: Text(l10n.delete),
            onTap: () {
              Navigator.of(ctx).pop();
              unawaited(deleteLocalEntry(context, e));
            },
          ),
        ],
      ),
    ),
  );
}

/// 已下载完成任务的通用操作菜单（书架「本地」段：下载项用）。
///
/// 提供「打开 / 重命名 / 删除」，删除支持「仅删记录 / 记录+文件」。
/// [onOpen] 由调用方决定打开方式（本地阅读器 / 在线详情页）。
void showDownloadedEntryActions(
  BuildContext context,
  DownloadTask t, {
  required VoidCallback onOpen,
}) {
  final l10n = AppLocalizations.of(context);
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          ListTile(
            leading: const Icon(Icons.open_in_new_outlined),
            title: Text(l10n.contentImportOpened),
            onTap: () {
              Navigator.of(ctx).pop();
              onOpen();
            },
          ),
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: Text(l10n.renameGroup),
            onTap: () {
              Navigator.of(ctx).pop();
              unawaited(renameDownloadedEntry(context, t));
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: Text(l10n.delete),
            onTap: () {
              Navigator.of(ctx).pop();
              unawaited(confirmDeleteDownloaded(context, t));
            },
          ),
        ],
      ),
    ),
  );
}

/// 重命名已下载任务的显示标题（仅改记录，不动磁盘文件）。
Future<void> renameDownloadedEntry(BuildContext context, DownloadTask t) async {
  final l10n = AppLocalizations.of(context);
  final controller = TextEditingController(text: t.title);
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(l10n.renameGroup),
      content: TextField(
        controller: controller,
        decoration: InputDecoration(hintText: l10n.renameHint),
        autofocus: true,
        onSubmitted: (v) => Navigator.of(ctx).pop(v),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(controller.text),
          child: Text(l10n.ok),
        ),
      ],
    ),
  );
  if (result != null && result.trim().isNotEmpty) {
    await context
        .read<DownloadManager>()
        .renameCompleted(t.id, result.trim());
  }
}

/// 删除已下载任务前的二次确认（仅删记录 / 记录+文件）。
Future<void> confirmDeleteDownloaded(BuildContext context, DownloadTask t) async {
  final l10n = AppLocalizations.of(context);
  final choice = await showDialog<bool?>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(l10n.deleteConfirmTitle),
      content: Text(t.title),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(l10n.deleteRecordOnly),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(l10n.deleteRecordAndFile),
        ),
      ],
    ),
  );
  if (choice != null) {
    await context
        .read<DownloadManager>()
        .removeCompleted(t.id, deleteFiles: choice);
  }
}

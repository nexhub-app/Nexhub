/// 本地导入内容的通用操作（打开 / 重命名 / 删除）。
///
/// 供导入历史列表（[ContentImportScreen]）与各媒体书架「本地」分段
/// （[bookshelf_content] 的 [_LocalBookshelf]）复用，避免重复实现弹窗逻辑。
library;

import 'dart:async' show unawaited;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:nexhub/core/download/download_manager.dart';
import 'package:nexhub/core/download/download_task.dart';
import 'package:nexhub/core/local/local_content_manager.dart';
import 'package:nexhub/core/models/episode.dart';
import 'package:nexhub/core/navigation/app_page_route.dart';
import 'package:nexhub/core/settings/general_settings.dart';
import 'package:nexhub/features/home/presentation/local_media_viewer.dart';
import 'package:nexhub/features/manga/presentation/comic_reader_screen.dart';
import 'package:nexhub/features/novel/presentation/novel_reader_screen.dart';
import 'package:nexhub/generated/app_localizations.dart';

/// 收集本地漫画图片路径：目录→按名排序的图片列表；单图文件→单元素列表。
/// 不含 cbz/zip（交给漫画阅读器内部解压）。无图片返回空列表。
List<String> gatherLocalComicImages(String path) {
  final f = File(path);
  if (f.existsSync()) return <String>[path];
  final dir = Directory(path);
  if (dir.existsSync()) {
    return dir
        .listSync()
        .whereType<File>()
        .where((x) => isImageFile(x.path))
        .map((x) => x.path)
        .toList()
      ..sort();
  }
  return const <String>[];
}

/// 由聚合文件夹的子文件列表构造合成章节列表（每文件 = 一章/一话）。
///
/// 标题取文件名（去扩展名），id 用文件路径，url 留空（本地），
/// number 为 1-based。供本地聚合条目（`LocalContentEntry.filePaths` /
/// 浏览本地聚合文件）传给阅读器，复用其在线章节导航（目录/上下章）。
List<Episode> buildLocalChapterList(List<String> paths) {
  final List<Episode> chapters = <Episode>[];
  for (int i = 0; i < paths.length; i++) {
    final path = paths[i];
    final title = p.basenameWithoutExtension(path);
    chapters.add(Episode(
      id: path,
      title: title.isEmpty ? path : title,
      url: '',
      number: i + 1,
    ));
  }
  return chapters;
}

/// 打开本地导入内容。
///
/// 路由规则（与浏览本地 [BrowseLocalScreen._openFile] 保持一致）：
/// - PDF → 漫画阅读器（逐页渲染成图）。
/// - 漫画图片（文件夹散图 / 单图 / .cbz/.cbr/.cbt/.zip/.rar/.7z/.cb7）→ 漫画阅读器
///   （多格式解压，[extractArchiveImages] 支持 RAR 系与 7z）；目录走 [LocalMediaViewer]。
/// - 小说 .txt → 小说阅读器；.epub → 小说阅读器（解析章节）；其余文本格式走通用查看器。
/// - 其它 → 通用 [LocalMediaViewer]。
void openLocalEntry(BuildContext context, LocalContentEntry e) {
  final bool remember = GeneralSettingsStore.instance.settings.rememberPosition;
  // 聚合文件夹：每个文件=一章/一话，传合成章节列表给阅读器（B 阶段）。
  if (e.filePaths != null && e.filePaths!.isNotEmpty) {
    final chapters = buildLocalChapterList(e.filePaths!);
    if (e.kind == LocalMediaKind.text) {
      Navigator.of(context).push(
        AppPageRoute<void>(
          builder: (_) => NovelReaderScreen(
            novelId: e.id,
            title: e.title,
            sourceId: '',
            chapters: chapters,
            localChapterPaths: e.filePaths,
            restoreProgress: remember,
          ),
        ),
      );
      return;
    }
    if (e.kind == LocalMediaKind.images) {
      _pushComicReader(
        context,
        e,
        remember,
        localArchivePaths: e.filePaths,
        chapters: chapters,
      );
      return;
    }
  }
  if (e.kind == LocalMediaKind.pdf) {
    _pushComicReader(context, e, remember, localPdfPath: e.path);
    return;
  }
  if (e.kind == LocalMediaKind.images) {
    final lower = e.path.toLowerCase();
    // 漫画归档（cbz/cbr/cbt/zip/rar/7z/cb7）全部交给阅读器多格式解压，不再把
    // .cbr/.rar 当「不支持」甩给兜底查看器。
    if (const <String>[
      '.cbz',
      '.cbr',
      '.cbt',
      '.zip',
      '.rar',
      '.7z',
      '.cb7',
    ].any((ext) => lower.endsWith(ext))) {
      _pushComicReader(context, e, remember, localCbzPath: e.path);
    } else {
      final imgs = gatherLocalComicImages(e.path);
      if (imgs.isNotEmpty) {
        _pushComicReader(context, e, remember, localImages: imgs);
      } else {
        _pushLocalMediaViewer(context, e);
      }
    }
    return;
  }
  if (e.kind == LocalMediaKind.text) {
    final lower = e.path.toLowerCase();
    if (lower.endsWith('.txt')) {
      Navigator.of(context).push(
        AppPageRoute<void>(
          builder: (_) => NovelReaderScreen(
            novelId: e.id,
            title: e.title,
            sourceId: '',
            chapters: const <Episode>[],
            localTextPath: e.path,
            restoreProgress: remember,
          ),
        ),
      );
      return;
    }
    if (lower.endsWith('.epub')) {
      Navigator.of(context).push(
        AppPageRoute<void>(
          builder: (_) => NovelReaderScreen(
            novelId: e.id,
            title: e.title,
            sourceId: '',
            chapters: const <Episode>[],
            localEpubPath: e.path,
            restoreProgress: remember,
          ),
        ),
      );
      return;
    }
  }
  _pushLocalMediaViewer(context, e);
}

/// 将书架透传的 kind 名（[LocalMediaKind.name]）解析回枚举；无效返回 null。
LocalMediaKind? parseLocalMediaKind(String? name) {
  if (name == null) return null;
  for (final k in LocalMediaKind.values) {
    if (k.name == name) return k;
  }
  return null;
}

/// 打开聚合本地条目（B 阶段：文件夹导入，多文件 = 多章/多话）。
///
/// 供首页各模块书架 onItemTap 复用，避免在每个 home 屏重复路由。
void openLocalAggregatedEntry(
  BuildContext context, {
  required String id,
  required String title,
  required LocalMediaKind kind,
  required List<String> filePaths,
}) {
  final remember = GeneralSettingsStore.instance.settings.rememberPosition;
  final chapters = buildLocalChapterList(filePaths);
  if (kind == LocalMediaKind.text) {
    Navigator.of(context).push(
      AppPageRoute<void>(
        builder: (_) => NovelReaderScreen(
          novelId: id,
          title: title,
          sourceId: '',
          chapters: chapters,
          localChapterPaths: filePaths,
          restoreProgress: remember,
        ),
      ),
    );
    return;
  }
  if (kind == LocalMediaKind.images || kind == LocalMediaKind.pdf) {
    _pushComicReader(
      context,
      LocalContentEntry(
        id: id,
        title: title,
        path: filePaths.first,
        kind: kind,
        addedAt: DateTime.now().millisecondsSinceEpoch,
        filePaths: filePaths,
      ),
      remember,
      localArchivePaths: filePaths,
      chapters: chapters,
    );
    return;
  }
  _pushLocalMediaViewer(
    context,
    LocalContentEntry(
      id: id,
      title: title,
      path: filePaths.first,
      kind: kind,
      addedAt: DateTime.now().millisecondsSinceEpoch,
      filePaths: filePaths,
    ),
  );
}

void _pushComicReader(
  BuildContext context,
  LocalContentEntry e,
  bool remember, {
  List<String>? localImages,
  String? localCbzPath,
  String? localPdfPath,
  List<String>? localArchivePaths,
  List<Episode> chapters = const <Episode>[],
}) {
  Navigator.of(context).push(
    AppPageRoute<void>(
      builder: (_) => ComicReaderScreen(
        comicId: e.id,
        title: e.title,
        sourceId: '',
        chapters: chapters,
        localImages: localImages,
        localCbzPath: localCbzPath,
        localPdfPath: localPdfPath,
        localArchivePaths: localArchivePaths,
        restoreProgress: remember,
      ),
    ),
  );
}

void _pushLocalMediaViewer(BuildContext context, LocalContentEntry e) {
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

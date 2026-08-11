import 'dart:io' show File;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../../../core/widgets/app_animations.dart';
import 'package:nexhub/generated/app_localizations.dart';

import '../../../core/local/folder_import_dialog.dart';
import '../../../core/local/import_permission.dart';
import '../../../core/settings/general_settings.dart';
import '../../../core/local/local_content_manager.dart';
import '../../../core/local/local_content_actions.dart';
import '../../../core/local/saf_bridge.dart';
import '../../../core/utils/app_log.dart';
import '../../../core/models/episode.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_empty_state.dart';
import '../../../core/widgets/app_icon_button.dart';
import '../../../core/widgets/app_segmented_tabs.dart';
import '../../manga/presentation/comic_reader_screen.dart';
import '../../novel/presentation/novel_reader_screen.dart';
import '../../player/presentation/video_player_screen.dart';
import 'local_media_viewer.dart';
import 'package:nexhub/core/navigation/app_page_route.dart';

/// 本地文件筛选维度（区别于 SourceType，语义更贴合本地媒体）。
enum _LocalFilter { all, novel, comic, video }

/// 本地文件浏览（浏览页占位功能之一）。
///
/// 通过 file_picker 选取文件 / 文件夹，按扩展名分类为小说 / 漫画 / 视频，
/// 点击进入 [LocalMediaViewer] 播放或阅读。筛选态、加载态、空态统一处理。
class BrowseLocalScreen extends StatefulWidget {
  const BrowseLocalScreen({super.key});

  @override
  State<BrowseLocalScreen> createState() => _BrowseLocalScreenState();
}

class _BrowseLocalScreenState extends State<BrowseLocalScreen> {
  final List<_LocalFile> _files = <_LocalFile>[];
  _LocalFilter _filter = _LocalFilter.all;
  bool _scanning = false;

  /// 本地文件封面缓存（路径 → 封面图绝对路径），由 [_addFile] 异步填充。
  final Map<String, String?> _covers = <String, String?>{};

  List<_LocalFile> get _filtered {
    if (_filter == _LocalFilter.all) return _files;
    return _files.where((f) {
      switch (_filter) {
        case _LocalFilter.novel:
          return f.kind == LocalMediaKind.text;
        case _LocalFilter.comic:
          // 漫画分类同时包含图片集与 PDF（PDF 走漫画阅读器渲染看图）。
          return f.kind == LocalMediaKind.images ||
              f.kind == LocalMediaKind.pdf;
        case _LocalFilter.video:
          return f.kind == LocalMediaKind.video;
        case _LocalFilter.all:
          return true;
      }
    }).toList();
  }

  Future<void> _pickFiles() async {
    final granted = await requestLocalImportPermission();
    if (!granted) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).storagePermissionDenied)),
      );
      return;
    }
    setState(() => _scanning = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.any,
      );
      if (result != null && mounted) {
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
          _addFile(_LocalFile(
            path: f.path!,
            name: f.name,
            kind: kind,
          ));
        }
        setState(() {});
      }
    } catch (e) {
      AppLog.instance.eWithStack('[本地导入失败] 单文件选择', e);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).importFailed(e.toString()))),
      );
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

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
    // Android 上 file_picker 返回 content:// SAF tree URI，由 saf_bridge 枚举/读取
    // （C 阶段）；桌面/其它平台为真实路径，走 dart:io。
    final saf = isAndroidSafUri(dir);
    setState(() => _scanning = true);
    try {
      final kind = saf
          ? await classifyFolderByContentSaf(dir)
          : classifyFolderByContent(dir);
      if (kind == null) {
        AppLog.instance.w('[本地导入] 文件夹无法识别类型/为空: $dir');
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).emptyFolder)),
        );
        return;
      }
      final folderName = saf
          ? await safFolderName(dir)
          : dir.split(RegExp(r'[/\\]')).last;
      // 文本文件夹：每个文件=一章，可聚合（B 阶段第 4 点）。
      if (kind == LocalMediaKind.text) {
        final files = saf
            ? await listFolderFilesByKindSaf(dir, LocalMediaKind.text)
            : listFolderFilesByKind(dir, LocalMediaKind.text);
        if (files.isEmpty) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(AppLocalizations.of(context).emptyFolder)),
          );
          return;
        }
        if (files.length > 1) {
          final mode = await showFolderImportChoiceDialog(
            context,
            folderName: folderName,
            typeLabel: AppLocalizations.of(context).importNovelTitle,
          );
          if (!mounted) return;
          if (mode == null) return; // 用户取消
          if (mode == FolderImportMode.merge) {
            _addFile(_LocalFile(
              path: dir,
              name: folderName,
              kind: kind,
              filePaths: files,
            ));
            setState(() {});
            return;
          }
        } else {
          _addFile(_LocalFile(path: files.first, name: p.basename(files.first), kind: kind));
          setState(() {});
          return;
        }
        // 逐文件导入。
        for (final f in files) {
          _addFile(_LocalFile(path: f, name: p.basename(f), kind: kind));
        }
        setState(() {});
        return;
      }
      // 漫画文件夹：含归档则每归档=一话（可聚合，第 5 点）；否则整部散图。
      if (kind == LocalMediaKind.images) {
        final scanned = saf
            ? await scanComicFolderSaf(dir)
            : scanComicFolder(dir);
        // 章节文件 = 已知漫画归档 + 其它非图片文件，每个文件 = 一话（bug 113）。
        final chapterFiles =
            <String>[...scanned.archives, ...scanned.others];
        if (chapterFiles.isNotEmpty) {
          if (chapterFiles.length > 1) {
            final mode = await showFolderImportChoiceDialog(
              context,
              folderName: folderName,
              typeLabel: AppLocalizations.of(context).importComicTitle,
            );
            if (!mounted) return;
            if (mode == null) return;
            if (mode == FolderImportMode.merge) {
              _addFile(_LocalFile(
                path: dir,
                name: folderName,
                kind: kind,
                filePaths: chapterFiles,
              ));
              setState(() {});
              return;
            }
            for (final f in chapterFiles) {
              _addFile(_LocalFile(path: f, name: p.basename(f), kind: kind));
            }
            setState(() {});
            return;
          }
          _addFile(_LocalFile(
            path: dir,
            name: folderName,
            kind: kind,
            filePaths: chapterFiles,
          ));
          setState(() {});
          return;
        }
        // 仅散图：整目录作为一部漫画（每图=一页）。
        _addFile(_LocalFile(path: dir, name: folderName, kind: kind));
        setState(() {});
        return;
      }
      // 视频 / 其它：单条导入（当前行为）。
      _addFile(_LocalFile(path: dir, name: folderName, kind: kind));
      setState(() {});
    } on Object catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).folderScanFailed)),
      );
    } finally {
      if (!mounted) setState(() => _scanning = false);
    }
  }

  void _addFile(_LocalFile file) {
    if (_files.any((f) => f.path == file.path)) return;
    _files.add(file);
    // 异步计算封面（取第一张图片并落盘），完成后刷新网格显示封面。
    computeLocalCover(file.path, file.kind).then((cover) {
      if (!mounted) return;
      setState(() => _covers[file.path] = cover);
    });
  }

  /// 网格单元：有封面则铺满封面图 + 底部标题，否则回退图标 + 标题。
  Widget _buildLocalTile(ColorScheme scheme, _LocalFile file) {
    final cover = _covers[file.path];
    if (cover != null) {
      return Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Image.file(File(cover), fit: BoxFit.cover),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              color: Colors.black54,
              padding: const EdgeInsets.all(AppTokens.spaceXs),
              child: Text(
                file.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
          ),
        ],
      );
    }
    return Padding(
      padding: const EdgeInsets.all(AppTokens.spaceMd),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(_iconFor(file.kind), size: 36, color: scheme.primary),
          const SizedBox(height: AppTokens.spaceSm),
          Text(
            file.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }

  IconData _iconFor(LocalMediaKind kind) => switch (kind) {
        LocalMediaKind.video => Icons.movie_outlined,
        LocalMediaKind.images => Icons.auto_stories_outlined,
        LocalMediaKind.text => Icons.menu_book_outlined,
        LocalMediaKind.pdf => Icons.picture_as_pdf_outlined,
      };

  /// 按 [file.kind] 与扩展名分流到专用阅读器或兜底 [LocalMediaViewer]（Task O4.B.4）。
  ///
  /// - 漫画 .cbz/.cbr/.cbt/.zip/.rar/.7z/.cb7 → [ComicReaderScreen]（本地多格式解压取图）
  /// - 单图 / 目录 → [ComicReaderScreen]（散图）或 [LocalMediaViewer]（兜底）
  /// - 视频 → [VideoPlayerScreen]（本地模式，直接打开）
  /// - 小说 .txt/.epub → [NovelReaderScreen]（本地模式，读取文本 / 解析 EPUB）
  /// - 小说 .umd/.mobi/.fb2/.azw3 → [LocalMediaViewer]（暂不支持提示）
  void _openFile(_LocalFile file) {
    final lower = file.path.toLowerCase();
    // 聚合文件夹：每个文件=一章/一话，传合成章节列表给阅读器（B 阶段）。
    if (file.filePaths != null && file.filePaths!.isNotEmpty) {
      final chapters = buildLocalChapterList(file.filePaths!);
      if (file.kind == LocalMediaKind.text) {
        Navigator.of(context).push(
          AppPageRoute<void>(
            builder: (_) => NovelReaderScreen(
              novelId: 'local_${file.path.hashCode}',
              title: file.name,
              sourceId: '',
              chapters: chapters,
              localChapterPaths: file.filePaths,
              restoreProgress:
                  GeneralSettingsStore.instance.settings.rememberPosition,
            ),
          ),
        );
        return;
      }
      if (file.kind == LocalMediaKind.images) {
        Navigator.of(context).push(
          AppPageRoute<void>(
            builder: (_) => ComicReaderScreen(
              comicId: 'local_${file.path.hashCode}',
              title: file.name,
              sourceId: '',
              chapters: chapters,
              localArchivePaths: file.filePaths,
              restoreProgress:
                  GeneralSettingsStore.instance.settings.rememberPosition,
            ),
          ),
        );
        return;
      }
    }
    switch (file.kind) {
      case LocalMediaKind.pdf:
        // PDF：逐页渲染成图片后进入漫画阅读器看图。
        Navigator.of(context).push(
          AppPageRoute<void>(
            builder: (_) => ComicReaderScreen(
              comicId: 'local_${file.path.hashCode}',
              title: file.name,
              sourceId: '',
              chapters: const <Episode>[],
              localPdfPath: file.path,
              restoreProgress:
                  GeneralSettingsStore.instance.settings.rememberPosition,
            ),
          ),
        );
        return;
      case LocalMediaKind.images:
        // 漫画归档（cbz/cbr/cbt/zip/rar/7z/cb7）：交给阅读器内部多格式解压。
        // 不再把 .cbr/.rar 当「不支持」甩给兜底查看器——[extractArchiveImages]
        // 已支持 RAR 系与 7z。
        if (const <String>[
          '.cbz',
          '.cbr',
          '.cbt',
          '.zip',
          '.rar',
          '.7z',
          '.cb7',
        ].any((e) => lower.endsWith(e))) {
          Navigator.of(context).push(
            AppPageRoute<void>(
              builder: (_) => ComicReaderScreen(
                comicId: 'local_${file.path.hashCode}',
                title: file.name,
                sourceId: '',
                chapters: const <Episode>[],
                localCbzPath: file.path,
                restoreProgress:
                    GeneralSettingsStore.instance.settings.rememberPosition,
              ),
            ),
          );
          return;
        }
        // 目录（散图）或单图：收集图片列表交给漫画阅读器（支持缩放/翻页/进度）。
        final imgs = gatherLocalComicImages(file.path);
        if (imgs.isNotEmpty) {
          Navigator.of(context).push(
            AppPageRoute<void>(
              builder: (_) => ComicReaderScreen(
                comicId: 'local_${file.path.hashCode}',
                title: file.name,
                sourceId: '',
                chapters: const <Episode>[],
                localImages: imgs,
                restoreProgress:
                    GeneralSettingsStore.instance.settings.rememberPosition,
              ),
            ),
          );
          return;
        }
        _openLocalMediaViewer(file);
      case LocalMediaKind.video:
        Navigator.of(context).push(
          AppPageRoute<void>(
            builder: (_) => VideoPlayerScreen(
              title: file.name,
              episode: Episode(id: 'local', title: file.name, url: file.path),
              sourceId: '',
              itemId: 'local_${file.path.hashCode}',
              localUri: file.path,
              restoreProgress:
                  GeneralSettingsStore.instance.settings.rememberPosition,
            ),
          ),
        );
      case LocalMediaKind.text:
        // .txt 走纯文本阅读器；.epub 走 EPUB 解析阅读器。
        if (lower.endsWith('.txt')) {
          Navigator.of(context).push(
            AppPageRoute<void>(
              builder: (_) => NovelReaderScreen(
                novelId: 'local_${file.path.hashCode}',
                title: file.name,
                sourceId: '',
                chapters: const <Episode>[],
                localTextPath: file.path,
                restoreProgress:
                    GeneralSettingsStore.instance.settings.rememberPosition,
              ),
            ),
          );
          return;
        }
        if (lower.endsWith('.epub')) {
          Navigator.of(context).push(
            AppPageRoute<void>(
              builder: (_) => NovelReaderScreen(
                novelId: 'local_${file.path.hashCode}',
                title: file.name,
                sourceId: '',
                chapters: const <Episode>[],
                localEpubPath: file.path,
                restoreProgress:
                    GeneralSettingsStore.instance.settings.rememberPosition,
              ),
            ),
          );
          return;
        }
        _openLocalMediaViewer(file);
    }
  }

  /// 兜底：打开 [LocalMediaViewer]（保持 O4.A 既有行为）。
  void _openLocalMediaViewer(_LocalFile file) {
    Navigator.of(context).push(
      AppPageRoute<void>(
        builder: (_) => LocalMediaViewer(
          title: file.name,
          kind: file.kind,
          uri: file.path,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.browseLocalTitle),
        actions: <Widget>[
          AppIconButton(
            icon: Icons.folder_outlined,
            tooltip: l10n.browseLocalSelectFolder,
            onPressed: _pickFolder,
          ),
        ],
      ),
      floatingActionButton: AppTapScale(
        child: FloatingActionButton.extended(
        onPressed: _scanning ? null : _pickFiles,
        icon: _scanning
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.file_open_outlined),
        label: Text(l10n.browseLocalScan),
      ),
      ),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(AppTokens.spaceLg),
            child: AppSegmentedTabs<_LocalFilter>(
              selected: <_LocalFilter>{_filter},
              onSelectionChanged: (s) => setState(() => _filter = s.first),
              segments: <ButtonSegment<_LocalFilter>>[
                ButtonSegment<_LocalFilter>(value: _LocalFilter.all, label: Text(l10n.browseLocalFileTypeAll)),
                ButtonSegment<_LocalFilter>(value: _LocalFilter.novel, label: Text(l10n.browseLocalFileTypeNovel)),
                ButtonSegment<_LocalFilter>(value: _LocalFilter.comic, label: Text(l10n.browseLocalFileTypeComic)),
                ButtonSegment<_LocalFilter>(value: _LocalFilter.video, label: Text(l10n.browseLocalFileTypeVideo)),
              ],
            ),
          ),
          Expanded(
            child: _files.isEmpty
                ? AppEmptyState(icon: Icons.folder_open_outlined, message: l10n.browseLocalEmpty)
                : GridView.builder(
                    padding: const EdgeInsets.all(AppTokens.spaceLg),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      mainAxisSpacing: AppTokens.spaceMd,
                      crossAxisSpacing: AppTokens.spaceMd,
                      mainAxisExtent: 120,
                    ),
                    itemCount: _filtered.length,
                    itemBuilder: (ctx, i) {
                      final file = _filtered[i];
                      return Card(
                        elevation: 0,
                        color: scheme.surfaceContainerHighest,
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () => _openFile(file),
                          child: _buildLocalTile(scheme, file),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _LocalFile {
  final String path;
  final String name;
  final LocalMediaKind kind;
  /// 聚合文件夹的子文件列表（B 阶段）：非空表示文件夹=一部作品，
  /// 内部每个文件=一章/一话；阅读器据此展示目录并可点选。
  final List<String>? filePaths;
  const _LocalFile({
    required this.path,
    required this.name,
    required this.kind,
    this.filePaths,
  });
}

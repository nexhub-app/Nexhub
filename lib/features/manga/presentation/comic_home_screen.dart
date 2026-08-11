import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:provider/provider.dart';

import '../../../core/settings/general_settings.dart';
import '../../../core/local/local_content_manager.dart';
import '../../../core/local/local_content_actions.dart';
import '../../../core/models/bookshelf_filter.dart';
import '../../../core/models/episode.dart';
import '../../../core/models/media_item.dart';
import '../../../core/models/plugin_config.dart';
import '../../../core/services/source_repository.dart';
import '../../../core/widgets/bookshelf_content.dart';
import '../../../core/widgets/library_shell.dart';
import '../../../core/widgets/module_source_search_screen.dart';
import '../../../core/widgets/online_source_browser_screen.dart';
import '../../home/presentation/import_comic_screen.dart';
import '../../home/presentation/local_media_viewer.dart';
import '../../media/presentation/content_detail_screen.dart';
import '../../rss/presentation/rss_feed_list_screen.dart';
import '../../sources/presentation/collect_api_import_screen.dart';
import '../../sources/presentation/source_manager_screen.dart';
import 'comic_reader_screen.dart';
import 'manga_online_list_screen.dart';
import 'package:nexhub/core/navigation/app_page_route.dart';

/// Comic module home — 4-tab layout backed by [LibraryShell].
///
/// The sources tab is rendered inline (source list + collect-API import FAB)
/// rather than pushing a separate [SourceManagerScreen].
class ComicHomeScreen extends StatelessWidget {
  const ComicHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);

    void navigateToCollectApiImport() {
      Navigator.of(context).push(AppPageRoute<void>(
        builder: (_) => const CollectApiImportScreen(),
      ));
    }

    // 源管理预览模式时通知外层 LibraryShell 隐藏 FAB（避免遮挡确认条）。
    final fabSuppressed = ValueNotifier<bool>(false);

    return LibraryShell(
      title: l10n.tabLibrary,
      emptyIcon: Icons.auto_stories,
      emptyMessage: l10n.emptyLocalComic,
      emptyActionLabel: l10n.emptyLocalComicAction,
      onEmptyAction: () => Navigator.of(context).push(
        AppPageRoute<void>(
          builder: (_) => const ImportComicScreen(),
        ),
      ),
      onSearch: () => Navigator.of(context).push(
        AppPageRoute<void>(
          builder: (_) => ModuleSourceSearchScreen(
            sourceType: SourceType.mangaSource,
            title: l10n.search,
            onItemTap: (MediaItem item, String? heroTag) => Navigator.of(context).push(
              AppHeroPageRoute<void>(
                builder: (_) => ContentDetailScreen(item: item, heroTag: heroTag),
              ),
            ),
          ),
        ),
      ),
      libraryBodyBuilder: (LibrarySubTab subTab, BookshelfFilter filter) => BookshelfContent(
        sourceType: SourceType.mangaSource,
        subTab: subTab,
        filter: filter,
        emptyIcon: Icons.auto_stories,
        emptyMessage: l10n.emptyLocalComic,
        emptyActionLabel: l10n.emptyLocalComicAction,
        onEmptyAction: () => Navigator.of(context).push(
          AppPageRoute<void>(
            builder: (_) => const ImportComicScreen(),
          ),
        ),
        onItemTap: (MediaItem item) {
          // R3 修复：本地导入/下载的漫画优先走阅读器本地模式，不再误跳在线详情页。
          final extra = item.extra;
          final localPath = extra == null ? null : extra['localPath'] as String?;
          final localKind = extra == null ? null : extra['localKind'] as String?;
          final filePaths =
              extra == null ? null : extra['filePaths'] as List<String>?;
          // B 阶段：聚合文件夹（多文件=多话），复用统一路由进入阅读器（目录/上下话可用）。
          if (filePaths != null && filePaths.isNotEmpty) {
            final kind = parseLocalMediaKind(localKind);
            if (kind != null) {
              openLocalAggregatedEntry(
                context,
                id: item.id,
                title: item.title,
                kind: kind,
                filePaths: filePaths,
              );
              return;
            }
          }
          if (localPath != null && localPath.isNotEmpty && localKind == 'pdf') {
            // PDF 本地漫画：逐页渲染成图片后进入漫画阅读器看图。
            Navigator.of(context).push(
              AppPageRoute<void>(
                builder: (_) => ComicReaderScreen(
                  comicId: item.id,
                  title: item.title,
                  sourceId: item.sourceId ?? '',
                  chapters: const <Episode>[],
                  localPdfPath: localPath,
                  restoreProgress:
                      GeneralSettingsStore.instance.settings.rememberPosition,
                ),
              ),
            );
            return;
          }
          if (localPath != null && localPath.isNotEmpty && localKind == 'images') {
            final lower = localPath.toLowerCase();
            // 漫画归档（cbz/cbr/cbt/zip/rar/7z/cb7）交给阅读器内部多格式解压。
            // 不再把 .cbr/.rar 当「不支持」甩给兜底查看器——解压已支持 RAR 系与 7z。
            if (const <String>[
              '.cbz',
              '.cbr',
              '.cbt',
              '.zip',
              '.rar',
              '.7z',
              '.cb7',
            ].any((ext) => lower.endsWith(ext))) {
              Navigator.of(context).push(
                AppPageRoute<void>(
                  builder: (_) => ComicReaderScreen(
                    comicId: item.id,
                    title: item.title,
                    sourceId: item.sourceId ?? '',
                    chapters: const <Episode>[],
                    localCbzPath: localPath,
                    restoreProgress:
                        GeneralSettingsStore.instance.settings.rememberPosition,
                  ),
                ),
              );
              return;
            }
            // 目录（散图）或单图：收集图片列表交给漫画阅读器（支持缩放/翻页/进度）。
            final imgs = gatherLocalComicImages(localPath);
            if (imgs.isNotEmpty) {
              Navigator.of(context).push(
                AppPageRoute<void>(
                  builder: (_) => ComicReaderScreen(
                    comicId: item.id,
                    title: item.title,
                    sourceId: item.sourceId ?? '',
                    chapters: const <Episode>[],
                    localImages: imgs,
                    restoreProgress:
                        GeneralSettingsStore.instance.settings.rememberPosition,
                  ),
                ),
              );
              return;
            }
            // 实在没有图片（如损坏目录）才走兜底查看器。
            Navigator.of(context).push(
              AppPageRoute<void>(
                builder: (_) => LocalMediaViewer(
                  title: item.title,
                  kind: LocalMediaKind.images,
                  uri: localPath,
                ),
              ),
            );
            return;
          }
          Navigator.of(context).push(
            AppPageRoute<void>(
              builder: (_) => ContentDetailScreen(item: item),
            ),
          );
        },
      ),
      onlineBody: OnlineSourceBrowserScreen(
        sourceType: SourceType.mangaSource,
        onAddSource: navigateToCollectApiImport,
        onEnableRecommended:
            () => context.read<SourceRepository>().enableRecommendedSources(),
        onSourceTap: (PluginConfig source) => Navigator.of(context).push(
          AppPageRoute<void>(
            builder: (_) => MangaOnlineListScreen(
              initialSource: source,
              onAddSource: navigateToCollectApiImport,
              onEnableRecommended:
                  () => context.read<SourceRepository>().enableRecommendedSources(),
            ),
          ),
        ),
      ),
      subscribeBody:
          const RssFeedListScreen(moduleType: SourceType.mangaSource),
      sourcesBody: _ComicSourcesBody(
        filterType: SourceType.mangaSource,
        fabSuppressed: fabSuppressed,
      ),
      categoryProvider: (LibrarySubTab subTab) =>
          BookshelfContent.categoriesFor(
              context, SourceType.mangaSource, subTab),
      historySourceType: SourceType.mangaSource,
      favoriteSourceType: SourceType.mangaSource,
      fabSuppressedNotifier: fabSuppressed,
    );
  }
}

class _ComicSourcesBody extends StatelessWidget {
  final SourceType filterType;
  final ValueNotifier<bool> fabSuppressed;

  const _ComicSourcesBody({
    required this.filterType,
    required this.fabSuppressed,
  });

  @override
  Widget build(BuildContext context) {
    return SourceManagerScreen(
      filterType: filterType,
      embedded: true,
      onPreviewModeChanged: (v) => fabSuppressed.value = v,
    );
  }
}

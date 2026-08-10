import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:provider/provider.dart';

import '../../../core/settings/general_settings.dart';
import '../../../core/local/local_content_manager.dart';
import '../../../core/models/bookshelf_filter.dart';
import '../../../core/models/episode.dart';
import '../../../core/models/media_item.dart';
import '../../../core/models/plugin_config.dart';
import '../../../core/services/source_repository.dart';
import '../../../core/widgets/bookshelf_content.dart';
import '../../../core/widgets/library_shell.dart';
import '../../../core/widgets/module_source_search_screen.dart';
import '../../../core/widgets/online_source_browser_screen.dart';
import '../../home/presentation/import_novel_screen.dart';
import '../../home/presentation/local_media_viewer.dart';
import '../../rss/presentation/rss_feed_list_screen.dart';
import '../../sources/presentation/collect_api_import_screen.dart';
import '../../sources/presentation/source_manager_screen.dart';
import '../../media/presentation/content_detail_screen.dart';
import 'novel_online_list_screen.dart';
import 'novel_reader_screen.dart';
import 'package:nexhub/core/navigation/app_page_route.dart';

/// Novel module home — 4-tab layout backed by [LibraryShell].
///
/// The sources tab is rendered inline (source list + collect-API import FAB)
/// rather than pushing a separate [SourceManagerScreen].
class NovelHomeScreen extends StatelessWidget {
  const NovelHomeScreen({super.key});

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
      emptyIcon: Icons.menu_book,
      emptyMessage: l10n.emptyLocalNovel,
      emptyActionLabel: l10n.emptyLocalNovelAction,
      onEmptyAction: () => Navigator.of(context).push(
        AppPageRoute<void>(
          builder: (_) => const ImportNovelScreen(),
        ),
      ),
      onSearch: () => Navigator.of(context).push(
        AppPageRoute<void>(
          builder: (_) => ModuleSourceSearchScreen(
            sourceType: SourceType.novelSource,
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
        sourceType: SourceType.novelSource,
        subTab: subTab,
        filter: filter,
        emptyIcon: Icons.menu_book,
        emptyMessage: l10n.emptyLocalNovel,
        emptyActionLabel: l10n.emptyLocalNovelAction,
        onEmptyAction: () => Navigator.of(context).push(
          AppPageRoute<void>(
            builder: (_) => const ImportNovelScreen(),
          ),
        ),
        onItemTap: (MediaItem item) {
          // R3 修复（小说段）：本地导入/下载的小说优先走本地阅读，不跳在线详情页。
          final extra = item.extra;
          final localPath = extra == null ? null : extra['localPath'] as String?;
          final localKind = extra == null ? null : extra['localKind'] as String?;
          if (localPath != null && localPath.isNotEmpty && localKind == 'text') {
            final lower = localPath.toLowerCase();
            if (lower.endsWith('.txt')) {
              Navigator.of(context).push(
                AppPageRoute<void>(
                  builder: (_) => NovelReaderScreen(
                    novelId: item.id,
                    title: item.title,
                    sourceId: item.sourceId ?? '',
                    chapters: const <Episode>[],
                    localTextPath: localPath,
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
                    novelId: item.id,
                    title: item.title,
                    sourceId: item.sourceId ?? '',
                    chapters: const <Episode>[],
                    localEpubPath: localPath,
                    restoreProgress:
                        GeneralSettingsStore.instance.settings.rememberPosition,
                  ),
                ),
              );
              return;
            }
            // umd/mobi 等走兜底查看器。
            Navigator.of(context).push(
              AppPageRoute<void>(
                builder: (_) => LocalMediaViewer(
                  title: item.title,
                  kind: LocalMediaKind.text,
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
        sourceType: SourceType.novelSource,
        onAddSource: navigateToCollectApiImport,
        onEnableRecommended:
            () => context.read<SourceRepository>().enableRecommendedSources(),
        onSourceTap: (PluginConfig source) => Navigator.of(context).push(
          AppPageRoute<void>(
            builder: (_) => NovelOnlineListScreen(
              initialSource: source,
              onAddSource: navigateToCollectApiImport,
              onEnableRecommended:
                  () => context.read<SourceRepository>().enableRecommendedSources(),
            ),
          ),
        ),
      ),
      subscribeBody:
          const RssFeedListScreen(moduleType: SourceType.novelSource),
      sourcesBody: _NovelSourcesBody(
        filterType: SourceType.novelSource,
        fabSuppressed: fabSuppressed,
      ),
      categoryProvider: (LibrarySubTab subTab) =>
          BookshelfContent.categoriesFor(
              context, SourceType.novelSource, subTab),
      historySourceType: SourceType.novelSource,
      favoriteSourceType: SourceType.novelSource,
      fabSuppressedNotifier: fabSuppressed,
    );
  }
}

class _NovelSourcesBody extends StatelessWidget {
  final SourceType filterType;
  final ValueNotifier<bool> fabSuppressed;

  const _NovelSourcesBody({
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

/// 本地内容读完自动接续在线内容（无缝续读）。
///
/// 小说 / 漫画阅读器在「本地下载内容读到最后一章、请求下一章」时调用：
/// 重新抓取在线章节目录，以「本地最后一章标题」匹配在线目录定位续读点
/// （标题未命中则按「本地章节数 = 在线前 N 章」近似），
/// 然后 pushReplacement 替换当前阅读器为在线模式（从续读点开始）。
///
/// 返回 true 表示已发起切换；false = 无需切换（无在线源 / 已是最新 / 失败），
/// 调用方保留原「已读完」提示行为。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../features/manga/presentation/comic_reader_screen.dart';
import '../../features/novel/presentation/novel_reader_screen.dart';
import '../../generated/app_localizations.dart';
import '../models/episode.dart' show Episode;
import '../models/plugin_config.dart' show PluginConfig, SourceType;
import '../navigation/app_page_route.dart';
import '../scraper/media_api_service.dart';
import '../services/source_repository.dart';
import '../theme/app_tokens.dart';

/// 无缝续读公共入口。详情见库注释。
Future<bool> continueOnlineAfterLocal(
  BuildContext context, {
  required SourceType sourceType,
  required String contentId,
  required String title,
  required String sourceId,
  required List<Episode> localChapters,
  required int localLastIndex,
}) async {
  if (sourceId.isEmpty) return false;
  if (localChapters.isEmpty) return false;
  final l10n = AppLocalizations.of(context);

  final SourceRepository? repo;
  final MediaApiService? service;
  try {
    repo = context.read<SourceRepository>();
    service = context.read<MediaApiService>();
  } on Object {
    return false;
  }
  final PluginConfig? source =
      repo == null ? null : repo.getById(sourceId);
  if (source == null || service == null) return false;

  // 加载指示：抓在线目录期间让用户知道正在无缝接续。
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext ctx) => AlertDialog(
      content: Row(
        children: <Widget>[
          const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          const SizedBox(width: AppTokens.spaceMd),
          Expanded(child: Text(l10n.localReadContinueOnline)),
        ],
      ),
    ),
  );

  List<Episode>? online;
  Object? error;
  try {
    online = sourceType == SourceType.mangaSource
        ? await service.fetchChapters(source, contentId)
        : await service.fetchNovelChapters(source, contentId);
  } on Object catch (e) {
    error = e;
  }
  if (context.mounted) Navigator.of(context).pop(); // 关闭加载指示
  if (!context.mounted) return false;

  if (online == null || online.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${l10n.localContinueOnlineFailed}: '
            '${error ?? ''}'),
        duration: const Duration(seconds: 5),
      ),
    );
    return false;
  }

  // 定位续读点：标题精确匹配本地最后一章；未命中回退「本地章数 = 在线前 N 章」。
  final String lastTitle =
      localChapters[localLastIndex.clamp(0, localChapters.length - 1)].title;
  int start = 0;
  for (int i = 0; i < online.length; i++) {
    if (online[i].title == lastTitle) {
      start = i + 1;
      break;
    }
  }
  if (start == 0) start = localChapters.length;
  if (start >= online.length) {
    // 本地已含全部在线章节：没有更新的内容。
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l10n.localContinueOnlineUpToDate),
        duration: const Duration(seconds: 5),
      ),
    );
    return false;
  }
  final int initialIndex = start;

  // 无缝替换：pushReplacement 把本地阅读器换为在线阅读器（从续读点开始，
  // restoreProgress: false 避免旧存档把用户拽回之前的位置）。
  Navigator.of(context).pushReplacement(
    AppPageRoute<void>(
      builder: (_) {
        if (sourceType == SourceType.mangaSource) {
          return ComicReaderScreen(
            comicId: contentId,
            title: title,
            sourceId: sourceId,
            chapters: online!,
            initialChapterIndex: initialIndex,
            // 在线阅读继续使用「记住位置」全局开关（旧逻辑：点选入口不恢复）。
            // 这里为续读语义固定从 initialIndex 开始，后续翻页再存档。
            restoreProgress: false,
          );
        }
        return NovelReaderScreen(
          novelId: contentId,
          title: title,
          sourceId: sourceId,
          chapters: online!,
          initialChapterIndex: initialIndex,
          restoreProgress: false,
        );
      },
    ),
  );
  return true;
}
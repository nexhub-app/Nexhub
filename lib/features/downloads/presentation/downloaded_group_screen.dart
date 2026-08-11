import 'dart:io';

import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:provider/provider.dart';

import '../../../core/download/download_manager.dart';
import '../../../core/download/download_task.dart';
import '../../../core/local/local_content_manager.dart';
import '../../../core/local/saf_bridge.dart' show resolveSafVideoFile;
import '../../../core/models/episode.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/utils/app_log.dart';
import '../../../core/widgets/app_cover_image.dart';
import '../../../core/widgets/app_icon_button.dart';
import '../../../core/widgets/app_list_tile.dart';
import '../../home/presentation/local_media_viewer.dart';
import '../../novel/presentation/novel_reader_screen.dart';
import '../../player/presentation/video_player_screen.dart';
import 'package:nexhub/core/navigation/app_page_route.dart';
import 'package:nexhub/core/widgets/app_alert_dialog.dart';

/// 已下载内容分组详情（下载页 → 点击已完成项）。
///
/// 展示封面与元信息，逐章列出并可打开本地产物。根据 [DownloadFormat]
/// 映射到 [LocalMediaKind] 复用 [LocalMediaViewer]，避免重复造轮子。
class DownloadedGroupScreen extends StatelessWidget {
  final DownloadTask task;
  const DownloadedGroupScreen({super.key, required this.task});

  LocalMediaKind _kindFor(DownloadFormat f) => switch (f) {
        DownloadFormat.cbz => LocalMediaKind.images,
        DownloadFormat.folder => LocalMediaKind.images,
        DownloadFormat.jpg => LocalMediaKind.images,
        DownloadFormat.png => LocalMediaKind.images,
        DownloadFormat.epub => LocalMediaKind.text,
        DownloadFormat.txt => LocalMediaKind.text,
        DownloadFormat.video => LocalMediaKind.video,
      };

  /// 视频格式按集命名（直链 001.mp4 / HLS 拼接 001.ts …），其他格式直接用产物路径。
  ///
  /// SAF 分支返回 `NNN.mp4` 占位（扩展名未知），由 [resolveSafVideoFile] 在打开时
  /// 枚举目录按 `NNN.<videoExt>` 命中真实文件；非 SAF 分支若 `NNN.mp4` 不存在则扫描
  /// 目录下首个视频文件回退（含 .ts，避免单集路径变化/扩展名差异导致打不开）。
  String _pathForChapter(DownloadTask task, int index) {
    if (task.format == DownloadFormat.video && task.localPath != null) {
      final localPath = task.localPath!;
      // SAF 下载路径（content:// 编码 `<treeUri>␟<rel>`）无法用 dart:io 直读，
      // 直接构造按集命名的编码子路径，由 LocalMediaViewer 经 resolveSafUri 落缓存后播放。
      if (isAndroidSafUri(localPath)) {
        final padded = (index + 1).toString().padLeft(3, '0');
        return '$localPath/$padded.mp4';
      }
      final padded = (index + 1).toString().padLeft(3, '0');
      final expected = '$localPath/$padded.mp4';
      final f = File(expected);
      if (f.existsSync()) return expected;
      // 回退：扫描目录下首个视频文件
      final fallback = _findVideoFile(localPath);
      if (fallback != null) return fallback;
    }
    return task.localPath!;
  }

  /// 扫描目录下首个视频文件（按文件名排序），无则返回 null。
  String? _findVideoFile(String dirPath) {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return null;
    const videoExts = <String>[
      '.ts', '.mp4', '.mkv', '.avi', '.mov', '.webm', '.m4v', '.flv',
    ];
    try {
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) {
            final lower = f.path.toLowerCase();
            return videoExts.any((ext) => lower.endsWith(ext));
          })
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      return files.isEmpty ? null : files.first.path;
    } catch (_) {
      return null;
    }
  }

  String _pathForFirstChapter(DownloadTask task) => _pathForChapter(task, 0);

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;

    final chapters = task.chapterTitles;
    final hasFile = task.localPath != null && task.localPath!.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text(task.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: <Widget>[
          AppIconButton(
            icon: Icons.delete_outline,
            tooltip: l10n.delete,
            onPressed: () => _confirmDelete(context, l10n),
          ),
        ],
      ),
      body: CustomScrollView(
        slivers: <Widget>[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(AppTokens.spaceLg),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SizedBox(
                    width: 110,
                    child: AppCoverImage(coverUrl: task.coverUrl, fit: BoxFit.cover),
                  ),
                  const SizedBox(width: AppTokens.spaceMd),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(task.title, style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: AppTokens.spaceSm),
                        Text(
                          '${l10n.downloadedGroupChapters}：${chapters.length}',
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                        ),
                        const SizedBox(height: AppTokens.spaceXs),
                        Text(
                          '${l10n.downloadedGroupFormat}：${task.format.label}',
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                        ),
                        if (!hasFile) ...<Widget>[
                          const SizedBox(height: AppTokens.spaceXs),
                          Text(
                            l10n.downloadedGroupFileMissing,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: scheme.error,
                                ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (hasFile)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppTokens.spaceLg),
                child: FilledButton.icon(
                  onPressed: () => _open(context, _pathForFirstChapter(task)),
                  icon: const Icon(Icons.play_arrow_outlined),
                  label: Text(l10n.downloadedGroupOpen),
                ),
              ),
            ),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (ctx, i) {
                final title = chapters[i];
                return AppListTile(
                  leading: CircleAvatar(
                    backgroundColor: scheme.primaryContainer,
                    foregroundColor: scheme.primary,
                    child: Text('${i + 1}'),
                  ),
                  title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
                  trailing: hasFile
                      ? AppIconButton(
                          icon: Icons.open_in_new_outlined,
                          tooltip: l10n.downloadedGroupOpen,
                          onPressed: () => _open(context, _pathForChapter(task, i)),
                        )
                      : null,
                );
              },
              childCount: chapters.length,
            ),
          ),
        ],
      ),
    );
  }

  void _open(BuildContext context, String path) {
    final LocalMediaKind kind = _kindFor(task.format);
    // 小说下载（epub/txt 为整本单文件）走小说阅读器：可解析章节、目录、朗读与进度，
    // 且内部已用 resolveSafUri 兼容 SAF 编码路径（修复下载后小说打不开）。
    if (kind == LocalMediaKind.text) {
      final String lower = path.toLowerCase();
      Navigator.of(context).push(
        AppPageRoute<void>(
          builder: (_) => NovelReaderScreen(
            novelId: task.contentId,
            title: task.title,
            sourceId: '',
            chapters: const <Episode>[],
            localTextPath: lower.endsWith('.txt') ? path : null,
            localEpubPath: lower.endsWith('.epub') ? path : null,
            restoreProgress: true,
          ),
        ),
      );
      return;
    }
    // 视频：路由到已验证可用的全功能播放器（VideoPlayerScreen 本地模式），
    // 它内部使用与在线播放一致的 PlayerController，能稳定播放本地 / SAF 缓存文件。
    // 早期 LocalMediaViewer 自带的裸 Player() 在打开 SAF 解析出的缓存文件时
    // 会出现「无限加载」，故此统一走 VideoPlayerScreen。
    if (kind == LocalMediaKind.video) {
      _openVideo(context, path);
      return;
    }
    Navigator.of(context).push(
      AppPageRoute<void>(
        builder: (_) => LocalMediaViewer(
          title: task.title,
          kind: kind,
          uri: path,
        ),
      ),
    );
  }

  /// SAF 视频：先把编码路径解析为真实缓存文件，校验有效性后，再交给全功能播放器打开。
  ///
  /// 直链写出 `.mp4`、HLS 拼接写出 `.ts`，打开时只能拿到按集序号（硬编码 `.mp4`），
  /// 故先枚举目录按 `NNN.<videoExt>` 命中真实扩展名；命中不到则退而求其次扫描
  /// 目录里任意视频文件，避免 HLS 的 `.ts` 被错当成不存在的 `.mp4` 而打开失败。
  ///
  /// 任何一步失败（解析不到 / 文件为空 / 不是有效视频）都**明确报错并弹提示**，
  /// 不再「点开无反应 / 无限缓冲」让用户摸不着头脑。
  Future<void> _openVideo(BuildContext context, String path) async {
    try {
      final String localPath;
      if (isAndroidSafUri(path)) {
        // 目录感知解析：`NNN.<videoExt>` 命中真实文件（HLS `.ts` / 直链 `.mp4`），
        // 任务文件夹形态则取目录内首个视频文件，再落盘为可播放的真实路径。
        localPath = await resolveSafVideoFile(path);
      } else {
        localPath = path;
      }
      // 校验：文件存在 + 大小 + 视频魔数，给出明确错误而非进入播放器后无限缓冲。
      final file = File(localPath);
      if (!await file.exists()) {
        throw Exception('下载的视频文件读取失败（不存在）：$localPath');
      }
      final size = await file.length();
      final head = await file.openRead(0, 16).first;
      AppLog.instance.i('[本地视频打开] $localPath 大小=${size}B '
          '首字节=0x${_hex(head)}');
      if (size == 0) {
        throw Exception('下载的视频文件为空（0 字节），可能下载未完成或被源拦截');
      }
      if (!_looksLikeVideo(head)) {
        throw Exception('下载的文件不是有效视频（大小 ${size}B，开头 '
            '0x${_hex(head)}），可能被源拦截成了网页/错误页');
      }
      if (!context.mounted) return;
      Navigator.of(context).push(
        AppPageRoute<void>(
          builder: (_) => VideoPlayerScreen(
            title: task.title,
            episode: Episode(id: 'local', title: task.title, url: localPath),
            sourceId: '',
            itemId: 'local_${localPath.hashCode}',
            localUri: localPath,
          ),
        ),
      );
    } catch (e) {
      AppLog.instance.eWithStack('[下载视频打开失败] $path', e);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('无法播放：${e.toString()}')),
        );
      }
    }
  }

  /// 首字节转 16 进制（用于日志/报错展示视频魔数）。
  static String _hex(List<int> b) =>
      b.map((v) => v.toRadixString(16).padLeft(2, '0')).join('');

  /// 粗判首字节是否为常见视频封装魔数（避免把 HTML/错误页当视频送进播放器）。
  static bool _looksLikeVideo(List<int> h) {
    if (h.length < 4) return false;
    // TS（MPEG-2 TS）：首字节 0x47
    if (h[0] == 0x47) return true;
    // MP4 / MOV / M4V：'ftyp' (0x66 74 79 70)
    if (h[0] == 0x66 && h[1] == 0x74 && h[2] == 0x79 && h[3] == 0x70) {
      return true;
    }
    // MKV / WebM（EBML）：0x1A 45 DF A3
    if (h.length >= 4 &&
        h[0] == 0x1A && h[1] == 0x45 && h[2] == 0xDF && h[3] == 0xA3) {
      return true;
    }
    // AVI：'RIFF' (0x52 49 46 46)
    if (h[0] == 0x52 && h[1] == 0x49 && h[2] == 0x46 && h[3] == 0x46) {
      return true;
    }
    // FLV：'FLV' (0x46 4C 56)
    if (h[0] == 0x46 && h[1] == 0x4C && h[2] == 0x56) return true;
    // MPEG-PS：00 00 01 BA / 00 00 01 B3
    if (h.length >= 4 &&
        h[0] == 0x00 && h[1] == 0x00 && h[2] == 0x01 &&
        (h[3] == 0xBA || h[3] == 0xB3)) {
      return true;
    }
    return false;
  }

  Future<void> _confirmDelete(BuildContext context, AppLocalizations l10n) async {
    final manager = context.read<DownloadManager>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AppAlertDialog(
        title: Text(l10n.delete),
        content: Text(l10n.downloadedGroupDeleteConfirm),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.deleteRecordAndFile),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      await manager.cancel(task.id, deleteFiles: true);
      if (context.mounted) Navigator.of(context).pop();
    }
  }
}

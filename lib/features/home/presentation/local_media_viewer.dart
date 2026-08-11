import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:nexhub/core/local/archive_extractor.dart';
import 'package:nexhub/core/local/saf_bridge.dart';
import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../core/local/local_content_manager.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_empty_state.dart';
import '../../../core/widgets/app_error_state.dart';
import '../../../core/utils/app_log.dart';

/// 本地媒体查看器无法处理的打开格式类型。
enum _UnsupportedFormat { rar, epub, other }

/// 本地 / 网络媒体查看器（浏览页 → 本地文件 / 网络文件）。
///
/// 统一承载三类本地媒体，避免为每个类型各写一个页面（重复造轮子）：
/// - [LocalMediaKind.video]：视频播放（本地文件 / 网络地址）
/// - [LocalMediaKind.images]：图片集（本地目录 / CBZ / 单图 / 网络图集）
/// - [LocalMediaKind.text]：纯文本阅读（本地 .txt）
///
/// 颜色与字号统一取自 [Theme]，间距取 [AppTokens]。
class LocalMediaViewer extends StatefulWidget {
  final String title;
  final LocalMediaKind kind;
  /// 本地文件路径或 http(s) 地址。
  final String uri;
  /// 显式图集（主要用于网络图片多张场景）。
  final List<String>? gallery;

  const LocalMediaViewer({
    super.key,
    required this.title,
    required this.kind,
    required this.uri,
    this.gallery,
  });

  @override
  State<LocalMediaViewer> createState() => _LocalMediaViewerState();
}

class _LocalMediaViewerState extends State<LocalMediaViewer> {
  bool get _isNetwork =>
      widget.uri.startsWith('http://') || widget.uri.startsWith('https://');

  // 视频（media_kit）
  Player? _player;
  VideoController? _videoController;

  // 图片
  List<String> _images = const <String>[];
  int _imagePage = 0;

  // 文本
  String? _text;

  bool _loading = true;
  String? _error;
  _UnsupportedFormat? _unsupportedFormat;

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  Future<void> _init() async {
    _unsupportedFormat = null;
    try {
      switch (widget.kind) {
        case LocalMediaKind.video:
          _player = Player();
          _videoController = VideoController(_player!);
          // SAF 下载/导入路径（content:// 或 `<treeUri>␟<rel>`）需先落缓存再播放，
          // media_kit 无法直读 content://。普通路径原样返回。
          final resolved = await resolveSafUri(widget.uri);
          await _player!.open(Media(resolved));
          break;
        case LocalMediaKind.images:
          _images = await _resolveImages();
          break;
        case LocalMediaKind.text:
          if (_isNetwork) {
            throw Exception('text network unsupported');
          }
          final lower = widget.uri.toLowerCase();
          if (lower.endsWith('.epub')) {
            _unsupportedFormat = _UnsupportedFormat.epub;
            break;
          }
          if (lower.endsWith('.umd') ||
              lower.endsWith('.mobi') ||
              lower.endsWith('.fb2') ||
              lower.endsWith('.azw3')) {
            _unsupportedFormat = _UnsupportedFormat.other;
            break;
          }
          _text = await _readTextFile(await resolveSafUri(widget.uri));
          break;
        case LocalMediaKind.pdf:
          // PDF 由漫画阅读器处理，此处不承接（仅作兜底，避免穷尽性报错）。
          break;
      }
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      AppLog.instance.eWithStack(
          '[本地文件打开失败] ${widget.title} uri=${widget.uri}', e);
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }

  /// 读取文本文件，兼容 UTF-8 / GBK 等常见编码。
  ///
  /// 先识别 UTF-8 BOM；再尝试 UTF-8 严格解码；失败时回退 latin1（保证能打开，
  /// GBK 等双字节编码可能显示为乱码，但不会再崩溃）。完整中文编码识别可后续
  /// 引入 charset 检测包。
  Future<String> _readTextFile(String path) async {
    final bytes = await File(path).readAsBytes();
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      return utf8.decode(bytes.sublist(3));
    }
    try {
      return utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      return latin1.decode(bytes);
    }
  }

  Future<List<String>> _resolveImages() async {
    if (widget.gallery != null && widget.gallery!.isNotEmpty) return widget.gallery!;
    if (_isNetwork) return <String>[widget.uri];
    return _gatherLocalImages(widget.uri);
  }

  Future<List<String>> _gatherLocalImages(String path) async {
    final lower = path.toLowerCase();
    // 漫画归档（cbz/cbr/cbt/zip/rar/7z/cb7）全部走多格式解压，不再标记 RAR 不支持。
    if (const <String>[
      '.cbz',
      '.cbr',
      '.cbt',
      '.zip',
      '.rar',
      '.7z',
      '.cb7',
    ].any((e) => lower.endsWith(e))) {
      return _extractCbz(path);
    }
    // SAF 路径（本地导入 content:// 树，或下载编码 `<treeUri>␟<rel>`）：dart:io
    // 无法直接列举/读取，走 SAF 管线逐图落缓存（修复 Android 下载后图片打不开）。
    if (isAndroidSafUri(path)) {
      return gatherSafImages(path);
    }
    final f = File(path);
    if (await f.exists()) return <String>[path];
    final dir = Directory(path);
    if (await dir.exists()) {
      final files = dir
          .listSync()
          .whereType<File>()
          .where((x) => isImageFile(x.path))
          .map((x) => x.path)
          .toList()
        ..sort();
      return files;
    }
    return const <String>[];
  }

  /// 解压漫画归档取图片路径（多格式：ZIP/CBZ、TAR/CBT、7z/CB7、RAR/CBR 含 RAR5）。
  ///
  /// 委托 [extractArchiveImages]（基于 [koni_archive]，纯 Dart 无需原生库）。
  /// SAF 感知：content:// URI 先经 [resolveSafUri] 落缓存再解压（C 阶段）。
  Future<List<String>> _extractCbz(String path) async {
    final local = await resolveSafUri(path);
    return extractArchiveImages(local);
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: _buildBody(l10n),
    );
  }

  Widget _buildBody(AppLocalizations l10n) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return AppErrorState(
        message: l10n.loadFailed,
        onRetry: () {
          setState(() => _loading = true);
          _init();
        },
        retryLabel: l10n.retry,
      );
    }
    if (_unsupportedFormat != null) {
      final String message = switch (_unsupportedFormat!) {
        _UnsupportedFormat.rar => l10n.unsupportedRarFormat,
        _UnsupportedFormat.epub => l10n.unsupportedEpubFormat,
        _UnsupportedFormat.other => l10n.unsupportedFormat,
      };
      return AppErrorState(message: message);
    }
    switch (widget.kind) {
      case LocalMediaKind.video:
        if (_videoController == null) return AppErrorState(message: l10n.loadFailed, onRetry: _init, retryLabel: l10n.retry);
        return Center(
          child: Video(
            controller: _videoController!,
            controls: AdaptiveVideoControls,
          ),
        );
      case LocalMediaKind.images:
        if (_images.isEmpty) {
          return AppEmptyState(icon: Icons.image, message: l10n.browseLocalEmpty);
        }
        return Stack(
          children: <Widget>[
            PageView.builder(
              itemCount: _images.length,
              onPageChanged: (i) => setState(() => _imagePage = i),
              itemBuilder: (ctx, i) {
                final uri = _images[i];
                final network = uri.startsWith('http://') || uri.startsWith('https://');
                return InteractiveViewer(
                  child: Center(
                    child: network
                        ? Image.network(uri)
                        : Image.file(File(uri)),
                  ),
                );
              },
            ),
            Positioned(
              bottom: AppTokens.spaceLg,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppTokens.spaceMd,
                    vertical: AppTokens.spaceXs,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.scrim.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(AppTokens.radiusFull),
                  ),
                  child: Text(
                    '${_imagePage + 1} / ${_images.length}',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onInverseSurface,
                        ),
                  ),
                ),
              ),
            ),
          ],
        );
      case LocalMediaKind.text:
        if (_text == null || _text!.isEmpty) {
          return AppEmptyState(icon: Icons.article, message: l10n.browseLocalEmpty);
        }
        return SingleChildScrollView(
          padding: const EdgeInsets.all(AppTokens.spaceLg),
          child: SelectableText(
            _text!,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        );
      case LocalMediaKind.pdf:
        // PDF 不走通用查看器（由漫画阅读器渲染看图），此处仅兜底提示。
        return AppErrorState(message: l10n.unsupportedFormat);
    }
  }
}

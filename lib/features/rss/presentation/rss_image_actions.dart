/// RSS 文章图片操作：保存 / 复制 / 分享（B2 增强，对齐漫画阅读器图片功能）。
///
/// 正文图片长按菜单与全屏画廊共用本模块。请求头与 [SourceImage] 一致——
/// Referer=所在文章页（防盗链校验「被哪个页面引用」）+ 浏览器 UA，否则防盗链
/// 站点裸请求一律 403，图片根本下不下来。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nexhub/core/network/dio_image_file_service.dart';
import 'package:nexhub/core/scraper/http_fetcher.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:super_clipboard/super_clipboard.dart';

/// 构造与 [SourceImage] 一致的防盗链请求头。
Map<String, String>? _buildHeaders(String? pageUrl, String url) {
  final Map<String, String> headers = <String, String>{
    'User-Agent': HttpFetcher.instance.userAgentForUrl(url),
  };
  if (pageUrl != null && pageUrl.isNotEmpty) {
    headers['Referer'] = pageUrl;
  }
  return headers;
}

/// 解析图片本地文件：HTTP URL 走 [NexImageCacheManager]（必要时下载，带防盗链
/// 头，与 SourceImage 同一磁盘缓存）；本地路径直接返回。
Future<File?> _resolveImageFile(String url, String? pageUrl) async {
  if (url.startsWith('http://') || url.startsWith('https://')) {
    try {
      return await NexImageCacheManager.instance
          .getSingleFile(url, headers: _buildHeaders(pageUrl, url));
    } on Object {
      return null;
    }
  }
  final File f = File(url);
  return await f.exists() ? f : null;
}

/// 取 URL 路径中的扩展名，缺省回退到 .jpg。
String _pickExt(String url) {
  final String ext = p.extension(url.split('?').first).toLowerCase();
  if (ext.isEmpty) return '.jpg';
  return ext;
}

/// 长按正文图片弹菜单：保存到本地 / 复制图片 / 分享（复制路径）。
Future<void> showRssImageActions(
  BuildContext context, {
  required String url,
  String? pageUrl,
}) async {
  final AppLocalizations l10n = AppLocalizations.of(context);
  final ColorScheme scheme = Theme.of(context).colorScheme;

  await showModalBottomSheet<void>(
    context: context,
    builder: (BuildContext ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          ListTile(
            leading: Icon(Icons.download_outlined, color: scheme.primary),
            title: Text(l10n.saveImage),
            onTap: () {
              Navigator.of(ctx).pop();
              unawaited(_saveImage(context, url, pageUrl, l10n));
            },
          ),
          ListTile(
            leading: Icon(Icons.copy_outlined, color: scheme.primary),
            title: Text(l10n.copyImage),
            onTap: () {
              Navigator.of(ctx).pop();
              unawaited(_copyImage(context, url, pageUrl, l10n));
            },
          ),
          ListTile(
            leading: Icon(Icons.share_outlined, color: scheme.primary),
            title: Text(l10n.shareImage),
            onTap: () {
              Navigator.of(ctx).pop();
              unawaited(_shareImage(context, url, pageUrl, l10n));
            },
          ),
          ListTile(
            leading: Icon(Icons.close, color: scheme.onSurfaceVariant),
            title: Text(l10n.cancel),
            onTap: () => Navigator.of(ctx).pop(),
          ),
        ],
      ),
    ),
  );
}

Future<void> _saveImage(
  BuildContext context,
  String url,
  String? pageUrl,
  AppLocalizations l10n,
) async {
  final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final File? file = await _resolveImageFile(url, pageUrl);
  if (file == null) {
    messenger.showSnackBar(SnackBar(content: Text(l10n.imageLoadFailed)));
    return;
  }
  try {
    final Directory dir = await getApplicationDocumentsDirectory();
    final String name =
        '${DateTime.now().millisecondsSinceEpoch}${_pickExt(url)}';
    final String dest = p.join(dir.path, 'reader_images', name);
    await Directory(p.dirname(dest)).create(recursive: true);
    await file.copy(dest);
    messenger.showSnackBar(SnackBar(content: Text(l10n.imageSavedTo(dest))));
  } on Object {
    messenger.showSnackBar(SnackBar(content: Text(l10n.imageSaveFailed)));
  }
}

Future<void> _copyImage(
  BuildContext context,
  String url,
  String? pageUrl,
  AppLocalizations l10n,
) async {
  final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final File? file = await _resolveImageFile(url, pageUrl);
  if (file == null) {
    messenger.showSnackBar(SnackBar(content: Text(l10n.imageLoadFailed)));
    return;
  }
  try {
    final Uint8List bytes = await file.readAsBytes();
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) {
      await Clipboard.setData(ClipboardData(text: file.path));
      messenger.showSnackBar(SnackBar(content: Text(l10n.imagePathCopied)));
      return;
    }
    final item = DataWriterItem();
    final ext = _pickExt(url).toLowerCase();
    if (ext == '.jpg' || ext == '.jpeg') {
      item.add(Formats.jpeg(bytes));
    } else {
      item.add(Formats.png(bytes));
    }
    await clipboard.write(<DataWriterItem>[item]);
    messenger.showSnackBar(SnackBar(content: Text(l10n.copyImageSuccess)));
  } on Object {
    await Clipboard.setData(ClipboardData(text: file.path));
    messenger.showSnackBar(SnackBar(content: Text(l10n.copyImageFailed)));
  }
}

Future<void> _shareImage(
  BuildContext context,
  String url,
  String? pageUrl,
  AppLocalizations l10n,
) async {
  final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final File? file = await _resolveImageFile(url, pageUrl);
  if (file == null) {
    messenger.showSnackBar(SnackBar(content: Text(l10n.imageLoadFailed)));
    return;
  }
  // share_plus 未引入依赖，回退为复制本地路径到剪贴板。
  await Clipboard.setData(ClipboardData(text: file.path));
  messenger.showSnackBar(SnackBar(content: Text(l10n.imagePathCopied)));
}

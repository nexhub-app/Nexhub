/// 图片保存到「外部存储」的统一入口（长按图片菜单「保存图片」等）。
///
/// 目标是保存到用户在系统相册 / 文件管理器直接可见的公共目录，而不是应用
/// 内部存储（原实现写 `getApplicationDocumentsDirectory/reader_images`，
/// Android 上落在 `/data/user/0/<pkg>/`，用户在相册里根本找不到）：
/// - Android 10+（API 29+，分区存储）：经 MethodChannel 走 MediaStore 写入
///   公共相册 `Pictures/NexHub`，无需任何存储权限；
/// - Android 9-（API 24-28）：先经 permission_handler 运行时申请
///   WRITE_EXTERNAL_STORAGE（manifest 已按 maxSdkVersion=28 声明），再由原生
///   直写公共 `Pictures/NexHub` 并触发媒体扫描；
/// - 桌面（Windows/macOS/Linux）：系统「下载」目录（`getDownloadsDirectory`，
///   不可用时回退应用文档目录）；
/// - iOS / Web：维持旧行为——应用文档目录（iOS 相册授权流程不在此展开）。
library;

import 'dart:io' show Directory, File, Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

/// 存储权限被拒绝（Android 9- 才会走到）；调用方据此给出可操作的提示。
class ImageSavePermissionDeniedException implements Exception {
  const ImageSavePermissionDeniedException();

  @override
  String toString() => 'ImageSavePermissionDeniedException';
}

class ImageSaver {
  ImageSaver._();

  static const MethodChannel _channel = MethodChannel('nexhub/media_store');

  /// 保存图片字节到公共外部存储，返回保存位置（用于 SnackBar 展示）。
  ///
  /// [fileName] 形如 `nexhub_1729000000.jpg`；MIME 按扩展名推断。
  /// 失败抛异常，由调用方决定提示文案（[ImageSavePermissionDeniedException]
  /// 表示用户拒绝了存储权限，仅 Android 9- 可能出现）。
  static Future<String> saveImage({
    required Uint8List bytes,
    required String fileName,
  }) async {
    if (kIsWeb) {
      throw UnsupportedError('ImageSaver.saveImage is not supported on web');
    }
    if (Platform.isAndroid) {
      // Android 10+ 走 MediaStore（免权限）；旧版本先申请写存储权限。
      if (await _androidSdkInt() < 29) {
        final PermissionStatus status = await Permission.storage.request();
        if (!status.isGranted) {
          throw const ImageSavePermissionDeniedException();
        }
      }
      final String? saved = await _channel.invokeMethod<String>(
        'saveImage',
        <String, dynamic>{
          'bytes': bytes,
          'fileName': fileName,
          'mime': _mimeFor(fileName),
        },
      );
      if (saved == null || saved.isEmpty) {
        throw StateError('saveImage returned empty path');
      }
      return saved;
    }
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      final Directory? downloads = await getDownloadsDirectory();
      final Directory dir = downloads ??
          await getApplicationDocumentsDirectory();
      final String dest = p.join(dir.path, 'NexHub', fileName);
      final File f = File(dest);
      await f.create(recursive: true);
      await f.writeAsBytes(bytes);
      return dest;
    }
    return _saveToAppDocuments(bytes, fileName);
  }

  /// 旧行为兜底：应用文档目录 `reader_images/`（iOS / 未知平台）。
  static Future<String> _saveToAppDocuments(
    Uint8List bytes,
    String fileName,
  ) async {
    final Directory dir = await getApplicationDocumentsDirectory();
    final String dest = p.join(dir.path, 'reader_images', fileName);
    final File f = File(dest);
    await f.create(recursive: true);
    await f.writeAsBytes(bytes);
    return dest;
  }

  /// 读取 Android SDK 版本（经原生通道，避免引入 device_info_plus 依赖）。
  static Future<int> _androidSdkInt() async {
    final int? sdk = await _channel.invokeMethod<int>('sdkInt');
    return sdk ?? 0;
  }

  /// 按文件扩展名推断 MIME（MediaStore 落库用；未知类型回退 image/jpeg）。
  static String _mimeFor(String fileName) {
    final String ext = p.extension(fileName).toLowerCase();
    return switch (ext) {
      '.png' => 'image/png',
      '.webp' => 'image/webp',
      '.gif' => 'image/gif',
      '.bmp' => 'image/bmp',
      '.avif' => 'image/avif',
      _ => 'image/jpeg',
    };
  }
}

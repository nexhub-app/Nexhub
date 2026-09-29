/// 云同步存储后端抽象 —— WebDAV / OneDrive 等统一按「备份文件」维度操作。
///
/// [CloudSyncService] 的增量同步 / 冲突解决逻辑只面向本接口：
/// - [prepare]：同步前准备（WebDAV 建目录 / OneDrive 预取有效 token）；
/// - [listBackups]：列出云端备份文件；
/// - [uploadBackup] / [downloadBackup] / [deleteBackup]：按文件名读写删。
///
/// 新增云后端时实现本接口并接入 [CloudSyncService._activeBackend] 即可。
library;

import 'dart:typed_data';

/// 云备份后端类型。
enum CloudBackendKind { webdav, onedrive }

/// 远端备份文件条目。
class RemoteBackupFile {
  final String name;

  /// 字节数；后端无法提供时为 null。
  final int? size;

  /// 最后修改时间（毫秒）；后端无法提供时为 null。
  final int? modifiedMs;

  const RemoteBackupFile({required this.name, this.size, this.modifiedMs});
}

/// 云端鉴权失败（未登录 / token 过期且刷新失败）。
///
/// 由 [CloudSyncService] 捕获并映射为语义错误码 `onedrive_auth` 供 UI 提示。
class CloudAuthException implements Exception {
  final String message;

  const CloudAuthException(this.message);

  @override
  String toString() => message;
}

/// 云端存储后端接口。
abstract interface class CloudSyncBackend {
  /// 同步前准备（建目录 / 预取 token 等）。失败抛异常。
  Future<void> prepare();

  /// 列出云端目录下的文件（不含子目录）。
  Future<List<RemoteBackupFile>> listBackups();

  /// 上传备份（同名覆盖）。
  Future<void> uploadBackup(String fileName, List<int> bytes);

  /// 下载备份字节流。
  Future<Uint8List> downloadBackup(String fileName);

  /// 删除云端备份文件（文件不存在时静默成功）。
  Future<void> deleteBackup(String fileName);
}

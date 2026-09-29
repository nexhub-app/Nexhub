/// 云同步服务 —— 多后端（WebDAV / OneDrive）备份与多端同步。
///
/// 数据范围（spec J.2）：
/// 1. 书源/媒体源/订阅源：book_sources / rss_feeds / article_feeds / sources
/// / source_mirrors / chapter_fetch_times / source_library_* Hive box
/// 2. 书签/收藏/书架：favorites / comic_bookmarks / novel_bookmarks /
/// bangumi_subject_links Hive box
/// 3. 阅读/播放历史与进度：media_watched / media_playback_position /
/// comic_progress / novel_progress / media_progress Hive box
/// 4. 其它：download_tasks / danmaku_cache / settings Hive box
/// 5. 阅读器/播放器偏好：PlayerSettings / ReaderDefaultSettings / LayoutSettings
/// / DanmakuSettings 持久化的 SharedPreferences
///
/// ⚠️ 备份白名单统一从 [kStorageBoxNames] 读取（单一事实源），与 splash
/// 启动时打开的 box 严格 1:1 —— 任何 box 增删只需改 storage_boxes.dart。
///
/// Round 2（完整重设计）能力：
/// - 增量同步：记录每 box 内容 sha256，仅上传变化的 box / 偏好。
/// - 冲突解决：拉取前预览本地与云端冲突项，按 box 选择保留云端或本地。
/// - 状态明细：记录上次备份 / 恢复的时间、成功与否、数据条数、范围。
///
/// 多后端：文件操作统一走 [CloudSyncBackend] 接口（[WebDavBackend] /
/// [OneDriveBackend]），同步逻辑后端无关。切换后端会清空增量哈希基线
/// （新云端视为空，首次同步全量上传）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../storage/storage_boxes.dart';
import 'backup_archive.dart';
import 'cloud_sync_backend.dart';
import 'onedrive/onedrive_auth_service.dart';
import 'onedrive/onedrive_backend.dart';
import 'webdav_backend.dart';

/// 同步频率
enum SyncFrequency { manual, daily, weekly }

/// 一次同步（备份或恢复）的结果明细，用于「状态明细」展示。
class SyncStatusEntry {
  /// 时间戳（毫秒）；null 表示从未执行。
  final int? timestamp;

  /// 是否成功；null 表示从未执行。
  final bool? success;

  /// 涉及的数据条数（0 表示「无变化」或失败未统计）。
  final int itemCount;

  /// 涉及的 box 名列表（空表示全部 / 无）。
  final List<String> scope;

  /// 是否为「无变化，无需同步」。
  final bool noChanges;

  const SyncStatusEntry({
    this.timestamp,
    this.success,
    this.itemCount = 0,
    this.scope = const <String>[],
    this.noChanges = false,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (timestamp != null) 'timestamp': timestamp,
        if (success != null) 'success': success,
        'itemCount': itemCount,
        'scope': scope,
        'noChanges': noChanges,
      };

  factory SyncStatusEntry.fromJson(Map<String, dynamic> json) =>
      SyncStatusEntry(
        timestamp: json['timestamp'] as int?,
        success: json['success'] as bool?,
        itemCount: (json['itemCount'] as int?) ?? 0,
        scope: (json['scope'] as List?)?.map((e) => e as String).toList() ??
            const <String>[],
        noChanges: (json['noChanges'] as bool?) ?? false,
      );
}

/// 单个冲突项（同一 key 在本地与云端取值不同）。
class SyncConflict {
  final String boxName;
  final BackupCategory category;
  final String key;
  final String localPreview;
  final String remotePreview;

  const SyncConflict({
    required this.boxName,
    required this.category,
    required this.key,
    required this.localPreview,
    required this.remotePreview,
  });
}

/// 冲突预览报告：按 box 归组的冲突列表 + 总数。
class SyncConflictReport {
  final Map<String, List<SyncConflict>> byBox;

  SyncConflictReport({required this.byBox});

  int get total => byBox.values.fold(0, (sum, list) => sum + list.length);
}

/// 云同步配置（URL/用户名/密码除外，密码用 secure storage）
class CloudSyncConfig {
  final String url;
  final String username;

  /// 备份后端（默认 WebDAV）。
  final CloudBackendKind backend;

  final bool autoSync;
  final SyncFrequency frequency;
  final int? lastSyncTimestamp; // null = never synced

  /// 上次备份（上传）明细。
  final SyncStatusEntry? lastUpload;

  /// 上次恢复（下载）明细。
  final SyncStatusEntry? lastRestore;

  /// 各 box（及 `__prefs__`）的内容 sha256，用于增量同步。
  final Map<String, String>? boxHashes;

  /// 小说导出完成后自动把 EPUB 产物上传到 WebDAV `nexhub/exports/`。
  /// 独立于整包备份的 autoSync（导出上传与备份节奏无关）。
  final bool autoUploadNovelExports;

  const CloudSyncConfig({
    this.url = '',
    this.username = '',
    this.backend = CloudBackendKind.webdav,
    this.autoSync = false,
    this.frequency = SyncFrequency.manual,
    this.lastSyncTimestamp,
    this.lastUpload,
    this.lastRestore,
    this.boxHashes,
    this.autoUploadNovelExports = false,
  });

  /// 下次自动同步时间戳（毫秒）；不满足自动同步条件时返回 null。
  int? get nextSyncTimestamp {
    if (!autoSync ||
        frequency == SyncFrequency.manual ||
        lastUpload?.timestamp == null) {
      return null;
    }
    final delta = frequency == SyncFrequency.daily
        ? const Duration(days: 1)
        : const Duration(days: 7);
    return lastUpload!.timestamp! + delta.inMilliseconds;
  }

  CloudSyncConfig copyWith({
    String? url,
    String? username,
    CloudBackendKind? backend,
    bool? autoSync,
    SyncFrequency? frequency,
    int? lastSyncTimestamp,
    SyncStatusEntry? lastUpload,
    SyncStatusEntry? lastRestore,
    Map<String, String>? boxHashes,
    bool? autoUploadNovelExports,
  }) {
    return CloudSyncConfig(
      url: url ?? this.url,
      username: username ?? this.username,
      backend: backend ?? this.backend,
      autoSync: autoSync ?? this.autoSync,
      frequency: frequency ?? this.frequency,
      lastSyncTimestamp: lastSyncTimestamp ?? this.lastSyncTimestamp,
      lastUpload: lastUpload ?? this.lastUpload,
      lastRestore: lastRestore ?? this.lastRestore,
      boxHashes: boxHashes ?? this.boxHashes,
      autoUploadNovelExports:
          autoUploadNovelExports ?? this.autoUploadNovelExports,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'url': url,
        'username': username,
        'backend': backend.name,
        'autoSync': autoSync,
        'frequency': frequency.name,
        if (lastSyncTimestamp != null) 'lastSyncTimestamp': lastSyncTimestamp,
        if (lastUpload != null) 'lastUpload': lastUpload!.toJson(),
        if (lastRestore != null) 'lastRestore': lastRestore!.toJson(),
        if (boxHashes != null) 'boxHashes': boxHashes,
        'autoUploadNovelExports': autoUploadNovelExports,
      };

  factory CloudSyncConfig.fromJson(Map<String, dynamic> json) {
    SyncFrequency parseFrequency(String? name) {
      switch (name) {
        case 'daily':
          return SyncFrequency.daily;
        case 'weekly':
          return SyncFrequency.weekly;
        case 'manual':
        default:
          return SyncFrequency.manual;
      }
    }

    SyncStatusEntry? parseStatus(dynamic raw) =>
        raw is Map<String, dynamic> ? SyncStatusEntry.fromJson(raw) : null;

    Map<String, String>? parseHashes(dynamic raw) {
      if (raw is! Map) return null;
      return raw.map((k, v) => MapEntry(k as String, v as String));
    }

    final backendName = json['backend'] as String?;
    return CloudSyncConfig(
      url: (json['url'] as String?) ?? '',
      username: (json['username'] as String?) ?? '',
      backend: backendName == 'onedrive'
          ? CloudBackendKind.onedrive
          : CloudBackendKind.webdav,
      autoSync: (json['autoSync'] as bool?) ?? false,
      frequency: parseFrequency(json['frequency'] as String?),
      lastSyncTimestamp: json['lastSyncTimestamp'] as int?,
      lastUpload: parseStatus(json['lastUpload']),
      lastRestore: parseStatus(json['lastRestore']),
      boxHashes: parseHashes(json['boxHashes']),
      autoUploadNovelExports:
          (json['autoUploadNovelExports'] as bool?) ?? false,
    );
  }
}

class CloudSyncConfigStore {
  static const String _prefsKey = 'cloud_sync_config_v1';
  static const String _passwordKey = 'cloud_sync_webdav_password';

  Future<CloudSyncConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return const CloudSyncConfig();
    try {
      return CloudSyncConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const CloudSyncConfig();
    }
  }

  Future<void> save(CloudSyncConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(config.toJson()));
  }

  Future<String?> loadPassword() async {
    const storage = FlutterSecureStorage();
    return await storage.read(key: _passwordKey);
  }

  Future<void> savePassword(String password) async {
    const storage = FlutterSecureStorage();
    await storage.write(key: _passwordKey, value: password);
  }

  Future<void> clearPassword() async {
    const storage = FlutterSecureStorage();
    await storage.delete(key: _passwordKey);
  }
}

/// 导入结果：写入条数 + 被应用的 box 远程哈希（用于更新增量基线）。
class _ImportResult {
  final int appliedItems;
  final Map<String, String> remoteHashes;

  const _ImportResult({this.appliedItems = 0, this.remoteHashes = const {}});
}

/// 云同步服务 —— 基于 [CloudSyncBackend] 的备份与多端同步。
///
/// WebDAV / OneDrive 文件操作分别见 [WebDavBackend] 与 [OneDriveBackend]；
/// OneDrive 登录凭证由 [oneDrive]（[OneDriveAuthService]）管理，凭证变化会
/// 转发为本服务的通知。配置仅持久化非敏感字段，密码与 token 走安全存储。
class CloudSyncService extends ChangeNotifier {
  static const int _maxBackups = 5;
  static const String _prefsHashKey = '__prefs__';

  /// 备份文件名前缀 / 后缀（各后端共用同一命名规则）。
  static const String _backupPrefix = 'nexhub-backup-';
  static const String _backupSuffix = '.zip';

  final OneDriveAuthService oneDrive = OneDriveAuthService();

  CloudSyncConfig _config = const CloudSyncConfig();
  String? _password;
  bool _syncing = false;
  String? _lastError;

  CloudSyncConfig get config => _config;
  bool get isSyncing => _syncing;
  String? get lastError => _lastError;

  CloudSyncService() {
    oneDrive.addListener(_onAuthChanged);
  }

  void _onAuthChanged() {
    notifyListeners();
  }

  Future<void> init() async {
    final store = CloudSyncConfigStore();
    _config = await store.load();
    _password = await store.loadPassword();
    await oneDrive.init();
  }

  Future<void> updateConfig(CloudSyncConfig config, String? password) async {
    final store = CloudSyncConfigStore();
    _config = config;
    if (password != null) {
      _password = password;
      await store.savePassword(password);
    }
    await store.save(config);
    notifyListeners();
  }

  /// 切换备份后端。切换时清空增量哈希基线：新云端按空处理，首次同步全量上传。
  Future<void> switchBackend(CloudBackendKind kind) async {
    if (_config.backend == kind) return;
    _config = _config.copyWith(
      backend: kind,
      boxHashes: const <String, String>{},
    );
    _lastError = null;
    await CloudSyncConfigStore().save(_config);
    notifyListeners();
  }

  /// 当前后端是否就绪（WebDAV 已配置 / OneDrive 已登录）。
  bool get isReady {
    switch (_config.backend) {
      case CloudBackendKind.webdav:
        return _config.url.isNotEmpty && _password != null;
      case CloudBackendKind.onedrive:
        return oneDrive.isLoggedIn;
    }
  }

  /// 按当前配置构造后端实例（轻量对象，每次同步新建）。
  CloudSyncBackend _activeBackend() {
    switch (_config.backend) {
      case CloudBackendKind.webdav:
        return WebDavBackend(
          baseUrl: _config.url,
          username: _config.username,
          password: _password ?? '',
        );
      case CloudBackendKind.onedrive:
        return OneDriveBackend(oneDrive);
    }
  }

  /// 测试 OneDrive 连接（校验 token 与 AppFolder 权限）。返回 (success, latencyMs)。
  Future<(bool, int)> testOneDriveConnection() =>
      OneDriveBackend.testConnection(oneDrive);

  /// 测试 WebDAV 连接（PROPFIND Depth:0）。返回 (success, latencyMs)。
  Future<(bool, int)> testConnection({
    required String url,
    required String username,
    required String password,
  }) =>
      WebDavBackend.testConnection(
          url: url, username: username, password: password);

  /// 异常 → 语义错误码。
  String _mapError(Object e) {
    if (e is DioException) return 'network';
    if (e is CloudAuthException) return 'onedrive_auth';
    return 'unknown:$e';
  }

  /// 是否为备份文件（统一命名规则）。
  static bool _isBackupFile(RemoteBackupFile f) =>
      f.name.startsWith(_backupPrefix) && f.name.endsWith(_backupSuffix);

  /// 内容哈希（sha256 hex），用于增量同步基线比对。
  String _sha256(String s) => crypto.sha256.convert(utf8.encode(s)).toString();

  /// 深度相等：对两端 encode 后的结构做 JSON 字符串比对（可靠且无需额外依赖）。
  bool _valuesEqual(dynamic a, dynamic b) => jsonEncode(a) == jsonEncode(b);

  /// 把任意值压成一行预览文本（用于冲突界面展示）。
  String _preview(dynamic v) {
    final s = v is String ? v : jsonEncode(v);
    return s.length > 60 ? '${s.substring(0, 60)}…' : s;
  }

  /// 计算给定 box（及偏好）的当前内容哈希。
  Future<Map<String, String>> _computeHashes(
    Set<String> boxNames,
    bool includePrefs,
  ) async {
    final hashes = <String, String>{};
    for (final name in boxNames) {
      if (Hive.isBoxOpen(name)) {
        final box = Hive.box(name);
        final data = box
            .toMap()
            .map((k, v) => MapEntry(k.toString(), _encodeHiveValue(v)));
        hashes[name] = _sha256(jsonEncode(data));
      }
    }
    if (includePrefs) {
      final prefs = await SharedPreferences.getInstance();
      final prefsData = <String, dynamic>{};
      for (final key in prefs.getKeys()) {
        final v = prefs.get(key);
        if (v != null) prefsData[key] = v;
      }
      hashes[_prefsHashKey] = _sha256(jsonEncode(prefsData));
    }
    return hashes;
  }

  /// 立即同步：导出本地 → 打包 ZIP → 上传到当前后端（WebDAV / OneDrive）。
  ///
  /// [scope] 为 null 时导出全部；否则只导出选中分类对应的 box（含「设置与偏好」
  /// 时才包含 SharedPreferences）。
  /// 增量：仅上传相对上次同步发生变化的 box / 偏好；无变化则直接成功（标记无变化）。
  Future<bool> syncNow({Set<BackupCategory>? scope}) async {
    if (_syncing) return false;
    if (!isReady) {
      _lastError = 'no_config';
      return false;
    }
    _syncing = true;
    _lastError = null;
    notifyListeners();
    final resolvedBoxes =
        scope == null ? kStorageBoxNames.toSet() : resolveBoxNames(scope);
    final includePrefs =
        scope == null || scope.contains(BackupCategory.settings);
    try {
      final prevHashes = _config.boxHashes ?? const <String, String>{};
      final currentHashes = await _computeHashes(resolvedBoxes, includePrefs);

      final changedBoxes = <String>{};
      for (final name in resolvedBoxes) {
        if (prevHashes[name] != currentHashes[name]) changedBoxes.add(name);
      }
      final prefsChanged = includePrefs &&
          prevHashes[_prefsHashKey] != currentHashes[_prefsHashKey];

      if (changedBoxes.isEmpty && !prefsChanged) {
        // 无变化：记录「无变化」状态，保留既有哈希基线。
        final ts = DateTime.now().millisecondsSinceEpoch;
        _config = _config.copyWith(
          lastSyncTimestamp: ts,
          lastUpload: SyncStatusEntry(
            timestamp: ts,
            success: true,
            itemCount: 0,
            scope: resolvedBoxes.toList(),
            noChanges: true,
          ),
        );
        await CloudSyncConfigStore().save(_config);
        _syncing = false;
        notifyListeners();
        return true;
      }

      final archive = await _exportToArchive(
        boxNames: changedBoxes,
        includePrefs: prefsChanged,
      );
      final zipBytes = ZipEncoder().encode(archive);
      if (zipBytes == null) {
        _lastError = 'encode_failed';
        _syncing = false;
        notifyListeners();
        return false;
      }
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final filename = '$_backupPrefix$timestamp$_backupSuffix';

      // 上传到当前后端（WebDAV：MKCOL+PUT；OneDrive：token+PUT/分片会话）
      final backend = _activeBackend();
      await backend.prepare();
      await backend.uploadBackup(filename, zipBytes);
      // 清理旧备份（保留最近 5 份）
      await _cleanupOldBackups(backend);

      // 统计上传条数 + 更新哈希基线
      var itemCount = 0;
      for (final name in changedBoxes) {
        if (Hive.isBoxOpen(name)) itemCount += Hive.box(name).length;
      }
      if (prefsChanged) {
        final prefs = await SharedPreferences.getInstance();
        itemCount += prefs.getKeys().length;
      }
      final newHashes = <String, String>{...prevHashes};
      for (final name in changedBoxes) {
        newHashes[name] = currentHashes[name]!;
      }
      if (prefsChanged) {
        newHashes[_prefsHashKey] = currentHashes[_prefsHashKey]!;
      }

      _config = _config.copyWith(
        lastSyncTimestamp: timestamp,
        lastUpload: SyncStatusEntry(
          timestamp: timestamp,
          success: true,
          itemCount: itemCount,
          scope: changedBoxes.toList(),
        ),
        boxHashes: newHashes,
      );
      await CloudSyncConfigStore().save(_config);
      _syncing = false;
      notifyListeners();
      return true;
    } catch (e) {
      final ts = DateTime.now().millisecondsSinceEpoch;
      _config = _config.copyWith(
        lastSyncTimestamp: ts,
        lastUpload: SyncStatusEntry(
          timestamp: ts,
          success: false,
          scope: resolvedBoxes.toList(),
        ),
      );
      await CloudSyncConfigStore().save(_config);
      _lastError = _mapError(e);
      _syncing = false;
      notifyListeners();
      return false;
    }
  }

  /// 预览本地与云端最新备份之间的冲突项（按 box 归组）。
  ///
  /// 返回 null 表示未配置 / 无远程备份 / 出错（详见 [lastError]）。
  Future<SyncConflictReport?> previewConflicts(
      {Set<BackupCategory>? scope}) async {
    if (!isReady) {
      _lastError = 'no_config';
      return null;
    }
    try {
      final backend = _activeBackend();
      final files = (await backend.listBackups()).where(_isBackupFile).toList();
      if (files.isEmpty) {
        _lastError = 'no_remote_backup';
        return null;
      }
      files.sort((a, b) => b.name.compareTo(a.name));
      final latest = files.first;
      final bytes = await backend.downloadBackup(latest.name);
      final archive = ZipDecoder().decodeBytes(bytes);
      final hiveFile = archive.findFile('hive_boxes.json');
      if (hiveFile == null) return SyncConflictReport(byBox: const {});
      final remoteRaw = jsonDecode(utf8.decode(hiveFile.content as List<int>))
          as Map<String, dynamic>;
      final allowedBoxes = scope == null ? null : resolveBoxNames(scope);
      final reverseCat = <String, BackupCategory>{};
      for (final e in kBackupCategoryBoxes.entries) {
        for (final b in e.value) {
          reverseCat[b] = e.key;
        }
      }
      final byBox = <String, List<SyncConflict>>{};
      for (final entry in remoteRaw.entries) {
        final name = entry.key;
        if (allowedBoxes != null && !allowedBoxes.contains(name)) continue;
        final data = entry.value;
        if (data is! Map) continue;
        if (!Hive.isBoxOpen(name)) continue;
        final box = Hive.box(name);
        final remoteData = data.map(
          (k, v) => MapEntry(k.toString(), _encodeHiveValue(v)),
        );
        for (final rk in remoteData.keys) {
          if (!box.containsKey(rk)) continue; // 云端独有，非冲突
          final localEnc = _encodeHiveValue(box.get(rk));
          final remoteEnc = remoteData[rk];
          if (!_valuesEqual(localEnc, remoteEnc)) {
            byBox.putIfAbsent(name, () => <SyncConflict>[]).add(SyncConflict(
                  boxName: name,
                  category: reverseCat[name] ?? BackupCategory.other,
                  key: rk,
                  localPreview: _preview(localEnc),
                  remotePreview: _preview(remoteEnc),
                ));
          }
        }
      }
      return SyncConflictReport(byBox: byBox);
    } catch (e) {
      _lastError = _mapError(e);
      return null;
    }
  }

  /// 从当前后端拉最新 ZIP 并恢复到本地。
  ///
  /// [merge] = true 合并（保留本地其它键）；false 覆盖（先清空目标 box 再写入）。
  /// [scope] 非空时只恢复这些分类对应的 box。
  /// [conflictChoices] 非空（冲突解决模式）：键为 box 名，值为「是否采用云端」。
  /// - true：该 box 整体以云端为准（清空后写入云端数据）。
  /// - false：跳过该 box（保留本地）。
  /// - 未列出：按 [merge] 合并（云端键覆盖本地同键，保留本地独有键）。
  Future<bool> pullRemote({
    bool merge = true,
    Set<BackupCategory>? scope,
    Map<String, bool>? conflictChoices,
  }) async {
    if (_syncing) return false;
    if (!isReady) {
      _lastError = 'no_config';
      return false;
    }
    _syncing = true;
    _lastError = null;
    notifyListeners();
    final resolvedBoxes =
        scope == null ? kStorageBoxNames.toSet() : resolveBoxNames(scope);
    try {
      final backend = _activeBackend();
      final files = (await backend.listBackups()).where(_isBackupFile).toList();
      if (files.isEmpty) {
        _lastError = 'no_remote_backup';
        _syncing = false;
        notifyListeners();
        return false;
      }
      // 取最新（按文件名降序，timestamp 大的在前）
      files.sort((a, b) => b.name.compareTo(a.name));
      final latest = files.first;
      final bytes = await backend.downloadBackup(latest.name);
      final archive = ZipDecoder().decodeBytes(bytes);
      final result = await _importFromArchive(
        archive,
        merge: merge,
        categories: scope,
        conflictChoices: conflictChoices,
      );

      // 更新上次恢复状态 + 增量哈希基线
      final ts = DateTime.now().millisecondsSinceEpoch;
      final newHashes = <String, String>{...?_config.boxHashes};
      newHashes.addAll(result.remoteHashes);
      _config = _config.copyWith(
        lastSyncTimestamp: ts,
        lastRestore: SyncStatusEntry(
          timestamp: ts,
          success: true,
          itemCount: result.appliedItems,
          scope: resolvedBoxes.toList(),
        ),
        boxHashes: newHashes,
      );
      await CloudSyncConfigStore().save(_config);
      _syncing = false;
      notifyListeners();
      return true;
    } catch (e) {
      final ts = DateTime.now().millisecondsSinceEpoch;
      _config = _config.copyWith(
        lastSyncTimestamp: ts,
        lastRestore: SyncStatusEntry(
          timestamp: ts,
          success: false,
          scope: resolvedBoxes.toList(),
        ),
      );
      await CloudSyncConfigStore().save(_config);
      _lastError = _mapError(e);
      _syncing = false;
      notifyListeners();
      return false;
    }
  }

  /// 清理旧备份（保留最近 [_maxBackups] 份）。
  Future<void> _cleanupOldBackups(CloudSyncBackend backend) async {
    final files = (await backend.listBackups()).where(_isBackupFile).toList()
      ..sort((a, b) => b.name.compareTo(a.name)); // 新到旧
    for (var i = _maxBackups; i < files.length; i++) {
      await backend.deleteBackup(files[i].name);
    }
  }

  /// 导出指定 box 为 ZIP 归档（hive_boxes.json + 可选 preferences.json）。
  Future<Archive> _exportToArchive({
    required Set<String> boxNames,
    required bool includePrefs,
  }) async {
    final archive = Archive();
    final hiveData = <String, dynamic>{};
    for (final name in boxNames) {
      if (Hive.isBoxOpen(name)) {
        final box = Hive.box(name);
        hiveData[name] = box
            .toMap()
            .map((k, v) => MapEntry(k.toString(), _encodeHiveValue(v)));
      }
    }
    final hiveBytes = Uint8List.fromList(utf8.encode(jsonEncode(hiveData)));
    archive.addFile(ArchiveFile(
      'hive_boxes.json',
      hiveBytes.length,
      hiveBytes,
    ));
    // 2. SharedPreferences → JSON（仅当 includePrefs 时包含）
    if (includePrefs) {
      final prefs = await SharedPreferences.getInstance();
      final prefsData = <String, dynamic>{};
      for (final key in prefs.getKeys()) {
        final v = prefs.get(key);
        if (v != null) prefsData[key] = v;
      }
      final prefsBytes = Uint8List.fromList(utf8.encode(jsonEncode(prefsData)));
      archive.addFile(ArchiveFile(
        'preferences.json',
        prefsBytes.length,
        prefsBytes,
      ));
    }
    return archive;
  }

  dynamic _encodeHiveValue(dynamic v) {
    if (v == null) return null;
    if (v is String || v is num || v is bool) return v;
    if (v is List) return v.map(_encodeHiveValue).toList();
    if (v is Map) {
      return v.map((k, v) => MapEntry(k.toString(), _encodeHiveValue(v)));
    }
    // Hive 自定义对象：尝试 toJson
    try {
      final toJson = (v as dynamic).toJson;
      if (toJson != null) return toJson.call();
    } catch (_) {}
    return v.toString();
  }

  /// 从 ZIP 归档恢复到本地。
  ///
  /// 返回写入条数与被应用 box 的远程哈希（用于更新增量基线）。
  Future<_ImportResult> _importFromArchive(
    Archive archive, {
    required bool merge,
    Set<BackupCategory>? categories,
    Map<String, bool>? conflictChoices,
  }) async {
    var appliedItems = 0;
    final remoteHashes = <String, String>{};
    final allowedBoxes =
        categories == null ? null : resolveBoxNames(categories);
    // 1. 合并 / 覆盖 Hive boxes
    final hiveFile = archive.findFile('hive_boxes.json');
    if (hiveFile != null) {
      final content = hiveFile.content as List<int>;
      final raw = jsonDecode(utf8.decode(content)) as Map<String, dynamic>;
      for (final entry in raw.entries) {
        final name = entry.key;
        if (allowedBoxes != null && !allowedBoxes.contains(name)) continue;
        final data = entry.value;
        if (data is! Map) continue;
        if (!Hive.isBoxOpen(name)) continue;
        final choice = conflictChoices?[name];
        final box = Hive.box(name);
        if (choice == false) continue; // 采用本地：跳过该 box
        if (choice == true) {
          // 采用云端：整体以远程覆盖（清空后写入）
          try {
            await box.clear();
          } on Object {}
          for (final kv in data.entries) {
            try {
              await box.put(kv.key, _decodeHiveValue(kv.value));
              appliedItems++;
            } on Object {}
          }
        } else if (!merge) {
          // 覆盖模式：先清空再写入
          try {
            await box.clear();
          } on Object {}
          for (final kv in data.entries) {
            try {
              await box.put(kv.key, _decodeHiveValue(kv.value));
              appliedItems++;
            } on Object {}
          }
        } else {
          // 合并模式：逐键写入（云端键覆盖本地同键）
          for (final kv in data.entries) {
            try {
              await box.put(kv.key, _decodeHiveValue(kv.value));
              appliedItems++;
            } on Object {}
          }
        }
        // 记录该 box 远程哈希（无论采用哪侧，恢复后本地与远程一致）
        remoteHashes[name] = _sha256(jsonEncode(data));
      }
    }
    // 2. 合并 / 覆盖 SharedPreferences
    final prefsFile = archive.findFile('preferences.json');
    if (prefsFile != null) {
      if (categories != null && !categories.contains(BackupCategory.settings)) {
        return _ImportResult(
            appliedItems: appliedItems, remoteHashes: remoteHashes);
      }
      final content = prefsFile.content as List<int>;
      final raw = jsonDecode(utf8.decode(content)) as Map<String, dynamic>;
      final prefs = await SharedPreferences.getInstance();
      for (final entry in raw.entries) {
        final v = entry.value;
        try {
          if (v is String) {
            await prefs.setString(entry.key, v);
            appliedItems++;
          } else if (v is int) {
            await prefs.setInt(entry.key, v);
            appliedItems++;
          } else if (v is double) {
            await prefs.setDouble(entry.key, v);
            appliedItems++;
          } else if (v is bool) {
            await prefs.setBool(entry.key, v);
            appliedItems++;
          } else if (v is List) {
            await prefs.setStringList(
                entry.key, v.map((e) => e.toString()).toList());
            appliedItems++;
          }
        } on Object {
          // 跳过无法写入的项
        }
      }
      remoteHashes[_prefsHashKey] = _sha256(jsonEncode(raw));
    }
    return _ImportResult(
        appliedItems: appliedItems, remoteHashes: remoteHashes);
  }

  dynamic _decodeHiveValue(dynamic v) {
    if (v == null) return null;
    if (v is String || v is num || v is bool) return v;
    if (v is List) return v.map(_decodeHiveValue).toList();
    if (v is Map) return v.map((k, v) => MapEntry(k, _decodeHiveValue(v)));
    return v;
  }
}

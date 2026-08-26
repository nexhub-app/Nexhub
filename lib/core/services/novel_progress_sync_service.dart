/// 小说阅读进度 WebDAV 云同步服务（P2-8 / P2-5 细粒度增强）。
///
/// 远端存储（两代并存，读取时细粒度优先、整文件兜底迁移）：
/// - **P2-5 逐书细粒度**：`nexhub/progress/<编码后 novelId>.json`，
///   一本书一个 JSON 文件；单书 push/pull 只碰自己那一个文件，
///   阅读器退后台/切章即可低开销同步；
/// - P2-8 整文件：WebDAV 根下的 `nexhub/novel-progress.json`
///   （novelId → 快照 map，与整包 ZIP 备份并存）。全量 [syncAll] 仍会
///   维护一份整文件快照，兼容旧版本客户端与首次迁移种子。
///
/// 同步语义（纯函数裁决见 `novel_progress_conflict.dart`）：
/// - **本地领先**（localWins）→ 直接把本地快照合并进上传集合；
/// - **云端领先且本地有记录**（remoteWins + 本地非空）→ 列入
///   [NovelProgressSyncResult.requireConfirmation]，由调用方弹确认框后
///   经 [applyRemote] 写回本地（防多端回退覆盖）；
/// - **云端领先且本地无记录**（remoteWins + 本地为空）→ 自动应用云端
///   （首次换机/重装的无冲突恢复）；
/// - **双维度一致**（equal）→ 两端不动。
///
/// 触发点：阅读器退出 / 退后台静默上传当前书（[pushOne]）、阅读器启动
/// 静默拉取合并（[pullOne]）、设置云同步页手动全量同步（[syncAll]）。
///
/// 注：网络层不经可测抽象——本服务直接复用 `cloud_sync_service` 的
/// 配置/密码通道；单测覆盖纯函数裁决与 JSON 编解码。
library;

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xml/xml.dart';

import '../novel/novel_progress_conflict.dart';
import '../novel/novel_progress_manager.dart';
import 'cloud_sync_service.dart';

/// 一次全量同步的结果。
class NovelProgressSyncResult {
  /// 已上传的本地领先数。
  final int uploaded;

  /// 云端领先且本地无记录 → 自动应用的条数。
  final List<String> autoAppliedFromRemote;

  /// 云端领先且本地有记录 → 需用户确认的 novelId 列表
  /// （确认后 [NovelProgressSyncService.applyRemote] 写回本地）。
  final List<String> requireConfirmation;

  /// 双维度一致未改动的条数。
  final int unchanged;

  const NovelProgressSyncResult({
    required this.uploaded,
    required this.autoAppliedFromRemote,
    required this.requireConfirmation,
    required this.unchanged,
  });

  bool get hasChanges =>
      uploaded > 0 ||
      autoAppliedFromRemote.isNotEmpty ||
      requireConfirmation.isNotEmpty;
}

/// 小说进度 WebDAV 同步服务。
///
/// 与整包备份（cloud_sync_service）共享 WebDAV 配置与密码，
/// 但进度按单文件逐书 JSON 独立同步，不参与增量哈希基线。
class NovelProgressSyncService {
  NovelProgressSyncService({CloudSyncConfigStore? store})
      : _store = store ?? CloudSyncConfigStore();

  final CloudSyncConfigStore _store;

  /// 远端进度 JSON 文件名（位于 WebDAV 根目录，与 `nexhub-backup-*.zip` 并存）。
  static const String remoteProgressName = 'nexhub/novel-progress.json';

  String? _password;

  /// 读取配置与密码（失败返回 null，调用方视为「未配置云同步」）。
  Future<({String url, String username, String? password})?>
      _loadConfig() async {
    final config = await _store.load();
    if (config.url.isEmpty) return null;
    final pw = _password ??= await _store.loadPassword();
    return (url: config.url, username: config.username, password: pw);
  }

  String _buildUrl(String base, String path) {
    var b = base;
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    return '$b/$path';
  }

  Dio _dio(String username, String password) {
    final creds = base64Encode(utf8.encode('$username:$password'));
    return Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      sendTimeout: const Duration(seconds: 30),
      headers: <String, String>{'Authorization': 'Basic $creds'},
    ));
  }

  /// 拉取远端进度 JSON。无远端文件 / 网络失败返回空 map（不抛错，
  /// 由裁决方当成「首次同步」）。
  Future<Map<String, NovelProgressPoint>> _fetchRemote(String url,
      String username, String password) async {
    final dio = _dio(username, password);
    try {
      final resp = await dio.get<String>(_buildUrl(url, remoteProgressName),
          options: Options(
            responseType: ResponseType.plain,
            validateStatus: (s) => s != null && (s == 200 || s == 404),
          ));
      if (resp.statusCode != 200 || resp.data == null) {
        return <String, NovelProgressPoint>{};
      }
      final decoded = jsonDecode(resp.data!) as Map<String, dynamic>;
      return <String, NovelProgressPoint>{
        for (final entry in decoded.entries)
          if (entry.value is Map<String, dynamic>)
            entry.key:
                NovelProgressPoint.fromJson(entry.key, entry.value as Map<String, dynamic>),
      };
    } on Object {
      return <String, NovelProgressPoint>{};
    } finally {
      dio.close(force: true);
    }
  }

  /// 上传远端进度 JSON（PUT；失败返回 false）。
  Future<bool> _uploadRemote(String url, String username, String password,
      Map<String, NovelProgressPoint> points) async {
    final dio = _dio(username, password);
    try {
      final body = jsonEncode(<String, dynamic>{
        for (final p in points.values) p.novelId: p.toJson(),
      });
      final resp = await dio.put<String>(_buildUrl(url, remoteProgressName),
          data: body,
          options: Options(
            headers: <String, String>{'Content-Type': 'application/json'},
            validateStatus: (s) => s != null && s >= 200 && s < 300,
          ));
      return resp.statusCode != null &&
          resp.statusCode! >= 200 &&
          resp.statusCode! < 300;
    } on Object {
      return false;
    } finally {
      dio.close(force: true);
    }
  }

  // ── P2-5：逐书细粒度远端存取 ──────────────────────────────────

  /// 细粒度远端目录（相对 WebDAV 根，每本书一个文件）。
  static const String remoteProgressDir = 'nexhub/progress';

  /// novelId → 远端文件名：白名单字符外替换为 `_`，并追加 hash 后缀
  /// 防不同 id 清洗后同名碰撞。novelId 原样保存在文件内容里作主键。
  static String remoteBookFileName(String novelId) {
    final safe = novelId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return '${safe}_${novelId.hashCode.abs()}.json';
  }

  /// 确保远端目录存在（逐级 MKCOL；已存在的 405/301 视为成功）。
  Future<void> _ensureProgressDirs(Dio dio, String url) async {
    for (final dir in const <String>['nexhub', remoteProgressDir]) {
      try {
        await dio.request<void>(
          '${_buildUrl(url, dir)}/',
          data: '',
          options: Options(
            method: 'MKCOL',
            validateStatus: (s) => s != null && s < 500,
          ),
        );
      } on Object {
        // MKCOL 失败不阻断：部分服务器自动创建父目录。
      }
    }
  }

  /// 拉取单本书的细粒度快照；无文件 / 失败返回 null。
  Future<NovelProgressPoint?> _fetchBook(
      Dio dio, String url, String novelId) async {
    try {
      final resp = await dio.get<String>(
        _buildUrl(url, '$remoteProgressDir/${remoteBookFileName(novelId)}'),
        options: Options(
          responseType: ResponseType.plain,
          validateStatus: (s) => s != null && (s == 200 || s == 404),
        ),
      );
      if (resp.statusCode != 200 || resp.data == null) return null;
      final decoded = jsonDecode(resp.data!) as Map<String, dynamic>;
      return NovelProgressPoint.fromJson(novelId, decoded);
    } on Object {
      return null;
    }
  }

  /// 上传单本书的细粒度快照（PUT 一个文件）。内容带 `novelId` 字段：
  /// 全量拉取时文件名不可反解原始 id（编码 + hash），以内容为准作主键。
  Future<bool> _putBook(Dio dio, String url, NovelProgressPoint point) async {
    try {
      final resp = await dio.put<String>(
        _buildUrl(
            url, '$remoteProgressDir/${remoteBookFileName(point.novelId)}'),
        data: jsonEncode(<String, dynamic>{
          ...point.toJson(),
          'novelId': point.novelId,
        }),
        options: Options(
          headers: <String, String>{'Content-Type': 'application/json'},
          validateStatus: (s) => s != null && s >= 200 && s < 300,
        ),
      );
      return resp.statusCode != null &&
          resp.statusCode! >= 200 &&
          resp.statusCode! < 300;
    } on Object {
      return false;
    }
  }

  /// 全量拉取细粒度目录：PROPFIND 列出 `nexhub/progress/` 后逐个 GET。
  /// 文件内容里的 `novelId` 字段作为合并键；失败项跳过（不阻断整体）。
  Future<Map<String, NovelProgressPoint>> _fetchRemoteBooks(
      Dio dio, String url) async {
    final names = await _listRemoteBookFiles(dio, url);
    if (names.isEmpty) return <String, NovelProgressPoint>{};
    final result = <String, NovelProgressPoint>{};
    for (final name in names) {
      try {
        final resp = await dio.get<String>(
          _buildUrl(url, '$remoteProgressDir/$name'),
          options: Options(
            responseType: ResponseType.plain,
            validateStatus: (s) => s != null && s == 200,
          ),
        );
        if (resp.statusCode != 200 || resp.data == null) continue;
        // 快照 JSON 与整文件条目同构：{novelId?, chapterIndex, charOffset?, page}；
        // 兼容无 novelId 字段的文件——从文件名反解不可靠，跳过该文件。
        final decoded = jsonDecode(resp.data!) as Map<String, dynamic>;
        final id = decoded['novelId'] as String?;
        if (id == null || id.isEmpty) continue;
        result[id] = NovelProgressPoint.fromJson(id, decoded);
      } on Object {
        // 单文件损坏 / 网络抖动跳过。
      }
    }
    return result;
  }

  /// PROPFIND 列出细粒度目录下的 .json 文件名。
  Future<List<String>> _listRemoteBookFiles(Dio dio, String url) async {
    const propfindBody = '<?xml version="1.0" encoding="utf-8"?>'
        '<D:propfind xmlns:D="DAV:">'
        '<D:prop><D:resourcetype/></D:prop>'
        '</D:propfind>';
    try {
      final resp = await dio.request<String>(
        '${_buildUrl(url, remoteProgressDir)}/',
        data: propfindBody,
        options: Options(
          method: 'PROPFIND',
          headers: <String, String>{
            'Depth': '1',
            'Content-Type': 'application/xml; charset=utf-8',
          },
          responseType: ResponseType.plain,
          validateStatus: (s) => s != null && s >= 200 && s < 400,
        ),
      );
      final body = resp.data ?? '';
      if (body.isEmpty) return <String>[];
      final doc = XmlDocument.parse(body);
      final names = <String>[];
      for (final response in doc.findAllElements('response', namespace: '*')) {
        final href =
            response.findElements('href', namespace: '*').firstOrNull?.value;
        if (href == null || href.isEmpty) continue;
        final decoded = Uri.decodeFull(href.trim());
        if (decoded.endsWith('/')) continue; // 目录自身
        final lastSlash = decoded.lastIndexOf('/');
        final name = lastSlash >= 0 ? decoded.substring(lastSlash + 1) : decoded;
        if (name.endsWith('.json')) names.add(name);
      }
      return names;
    } on Object {
      // 目录不存在（首次使用）或服务器不支持 PROPFIND → 按空处理。
      return <String>[];
    }
  }

  /// 全量同步：拉取远端 → 逐书裁决 → 上传本地领先 → 返回需确认清单。
  ///
  /// [local] 为本地全部小说进度快照（novelId → 快照）。本地空 / 云端空
  /// 各自的首次同步语义由裁决自动处理。
  Future<NovelProgressSyncResult> syncAll(
      Map<String, NovelProgressPoint> local) async {
    final cfg = await _loadConfig();
    if (cfg == null || cfg.password == null || cfg.password!.isEmpty) {
      return const NovelProgressSyncResult(
        uploaded: 0,
        autoAppliedFromRemote: <String>[],
        requireConfirmation: <String>[],
        unchanged: 0,
      );
    }
    final remoteLegacy =
        await _fetchRemote(cfg.url, cfg.username, cfg.password!);
    // P2-5：细粒度目录与整文件合并为「远端视图」。同一本书两边都有时按
    // 冲突裁决取优（细粒度文件是新版写入路径，通常更新）。
    final dio = _dio(cfg.username, cfg.password!);
    final Map<String, NovelProgressPoint> remote;
    try {
      final remoteBooks = await _fetchRemoteBooks(dio, cfg.url);
      remote = <String, NovelProgressPoint>{...remoteLegacy};
      for (final entry in remoteBooks.entries) {
        final legacy = remote[entry.key];
        if (legacy == null) {
          remote[entry.key] = entry.value;
          continue;
        }
        remote[entry.key] = switch (
            decideProgressConflict(local: legacy, remote: entry.value)) {
          ProgressConflictDecision.localWins => legacy,
          _ => entry.value,
        };
      }
    } finally {
      dio.close(force: true);
    }
    final allIds = <String>{...local.keys, ...remote.keys};
    final merged = <String, NovelProgressPoint>{};
    final autoApplied = <String>[];
    final needConfirm = <String>[];
    final uploadedIds = <String>[];
    var unchanged = 0;
    for (final id in allIds) {
      final l = local[id];
      final r = remote[id];
      if (l == null) {
        // 本地无记录：远端有 → 自动采用（首次同步恢复）。
        if (r != null) {
          autoApplied.add(id);
          merged[id] = r;
        }
        continue;
      }
      if (r == null) {
        // 远端无记录：本地上传。
        merged[id] = l;
        uploadedIds.add(id);
        continue;
      }
      switch (decideProgressConflict(local: l, remote: r)) {
        case ProgressConflictDecision.localWins:
          merged[id] = l;
          uploadedIds.add(id);
        case ProgressConflictDecision.remoteWins:
          merged[id] = r;
          needConfirm.add(id);
        case ProgressConflictDecision.equal:
          merged[id] = l; // 两端一致，任取；不需要动。
          unchanged++;
      }
    }

    var uploadedOk = 0;
    if (uploadedIds.isNotEmpty || needConfirm.isNotEmpty) {
      // 只要有任何本地领先或云端领先需确认，都写回远端（云端领先值本
      // 就应在远端，写回保证 merged 与远端一致）。
      final ok = await _uploadRemote(cfg.url, cfg.username, cfg.password!, merged);
      uploadedOk = ok ? uploadedIds.length : 0;
      if (!ok && uploadedIds.isNotEmpty) {
        // 上传失败：本地领先项不视为已同步。
        return NovelProgressSyncResult(
          uploaded: 0,
          autoAppliedFromRemote: autoApplied,
          requireConfirmation: needConfirm,
          unchanged: unchanged,
        );
      }
      // P2-5：本地领先项同时写入细粒度目录（每本书一个文件；单文件失败
      // 不回滚——整文件快照仍保证旧版客户端可读）。
      if (ok) {
        final dioPut = _dio(cfg.username, cfg.password!);
        try {
          await _ensureProgressDirs(dioPut, cfg.url);
          for (final id in uploadedIds) {
            await _putBook(dioPut, cfg.url, local[id]!);
          }
        } finally {
          dioPut.close(force: true);
        }
      }
    }
    return NovelProgressSyncResult(
      uploaded: uploadedOk,
      autoAppliedFromRemote: autoApplied,
      requireConfirmation: needConfirm,
      unchanged: unchanged,
    );
  }

  /// 单书静默拉取合并（阅读器启动 / 网络恢复）：本地无记录 → 自动应用
  /// 云端；本地领先 → 上传；云端领先且本地有记录 → **不自动覆盖**（返回
  /// false 表示存在需确认的冲突，避免阅读器启动时静默吃掉用户本地进度）。
  ///
  /// P2-5：只读写本书的细粒度文件（`nexhub/progress/<id>.json`）；
  /// 细粒度文件缺失时回退读整文件中的该书条目（旧版迁移种子），命中后
  /// 本地裁决结果照常写回细粒度文件。
  ///
  /// 返回 (应用了云端, 是否上传了本地)。出现需确认冲突时两个都 false 且
  /// [conflict] 置 true。
  Future<({bool appliedRemote, bool uploadedLocal, bool conflict})> pullOne(
      String novelId, NovelProgressPoint local) async {
    final cfg = await _loadConfig();
    if (cfg == null || cfg.password == null || cfg.password!.isEmpty) {
      return (appliedRemote: false, uploadedLocal: false, conflict: false);
    }
    final dio = _dio(cfg.username, cfg.password!);
    try {
      NovelProgressPoint? r =
          await _fetchBook(dio, cfg.url, novelId) ??
          (await _fetchRemote(cfg.url, cfg.username, cfg.password!))[novelId];
      if (r == null) {
        return (appliedRemote: false, uploadedLocal: false, conflict: false);
      }
      switch (decideProgressConflict(local: local, remote: r)) {
        case ProgressConflictDecision.localWins:
          await _putBook(dio, cfg.url, local);
          return (appliedRemote: false, uploadedLocal: true, conflict: false);
        case ProgressConflictDecision.remoteWins:
          if (local.inChapterMetric == 0 && local.chapterIndex <= 0) {
            // 本地其实是空进度（未读）= 视为无记录，安全应用云端。
            return (appliedRemote: true, uploadedLocal: false, conflict: false);
          }
          return (appliedRemote: false, uploadedLocal: false, conflict: true);
        case ProgressConflictDecision.equal:
          return (appliedRemote: false, uploadedLocal: false, conflict: false);
      }
    } finally {
      dio.close(force: true);
    }
  }

  /// 单书静默上传（阅读器退出 / 退后台触发）。P2-5：只 PUT 本书一个文件，
  /// 不再拉取/写回整文件——多端「退后台即同步」的低开销路径。
  /// 云端领先时不覆盖（防回退）。
  Future<bool> pushOne(String novelId, NovelProgressPoint local) async {
    final cfg = await _loadConfig();
    if (cfg == null || cfg.password == null || cfg.password!.isEmpty) {
      return false;
    }
    final dio = _dio(cfg.username, cfg.password!);
    try {
      final r =
          await _fetchBook(dio, cfg.url, novelId) ??
          (await _fetchRemote(cfg.url, cfg.username, cfg.password!))[novelId];
      final decision = r == null
          ? ProgressConflictDecision.localWins
          : decideProgressConflict(local: local, remote: r);
      if (decision == ProgressConflictDecision.remoteWins) {
        // 云端领先：不覆盖（防回退）。
        return false;
      }
      await _ensureProgressDirs(dio, cfg.url);
      return _putBook(dio, cfg.url, local);
    } finally {
      dio.close(force: true);
    }
  }

  /// 用户确认采用云端后，把确认清单中的远端快照写回本地。
  ///
  /// [confirmedIds] 为用户勾选采用云端的 novelId；未知/未确认的直接跳过。
  /// 同时把本地落后项从远端删除？不需要——远端本就是云端快照。
  /// 返回实际写回的 novelId（供 UI 提示）。
  Future<List<String>> applyRemote(
    Map<String, NovelProgressPoint> local, {
    required List<String> confirmedIds,
  }) async {
    final cfg = await _loadConfig();
    if (cfg == null || cfg.password == null || cfg.password!.isEmpty) {
      return const <String>[];
    }
    final remote = await _fetchRemote(cfg.url, cfg.username, cfg.password!);
    final applied = <String>[];
    for (final id in confirmedIds) {
      final r = remote[id];
      if (r == null) continue;
      // 写回本地进度（本地进度管理由调用方同步——这里仅记录哪些被确认，
      // 避免本服务直接耦合 SharedPreferences；调用方拿到返回后逐个落盘）。
      applied.add(id);
    }
    return applied;
  }
}
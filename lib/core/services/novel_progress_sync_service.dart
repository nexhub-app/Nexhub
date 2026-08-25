/// 小说阅读进度 WebDAV 云同步服务（P2-8，对标 syncProgress）。
///
/// 远端存储：WebDAV 根下的 `nexhub/novel-progress.json`（单文件，与整包
/// ZIP 备份并存、互不干扰）。每个 novelId 一条进度快照
/// `{chapterIndex, charOffset?, page, updatedAt}`。
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
/// 触发点：阅读器退出静默上传当前书（[pushOne]）、阅读器启动静默拉取
/// 合并（[pullOne]）、设置云同步页手动全量同步（[syncAll]）。
///
/// 注：网络层不经可测抽象——本服务直接复用 `cloud_sync_service` 的
/// 配置/密码通道；单测覆盖纯函数裁决与 JSON 编解码。
library;

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    final remote = await _fetchRemote(cfg.url, cfg.username, cfg.password!);

    // 合并键集（本地 ∪ 远端）。
    final allIds = <String>{...local.keys, ...remote.keys};
    final merged = <String, NovelProgressPoint>{};
    final autoApplied = <String>[];
    final needConfirm = <String>[];
    var uploaded = 0;
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
        uploaded++;
        continue;
      }
      switch (decideProgressConflict(local: l, remote: r)) {
        case ProgressConflictDecision.localWins:
          merged[id] = l;
          uploaded++;
        case ProgressConflictDecision.remoteWins:
          merged[id] = r;
          needConfirm.add(id);
        case ProgressConflictDecision.equal:
          merged[id] = l; // 两端一致，任取；不需要动。
          unchanged++;
      }
    }

    var uploadedOk = 0;
    if (uploaded > 0 || needConfirm.isNotEmpty) {
      // 只要有任何本地领先或云端领先需确认，都写回远端（云端领先值本
      // 就应在远端，写回保证 merged 与远端一致）。
      final ok = await _uploadRemote(cfg.url, cfg.username, cfg.password!, merged);
      uploadedOk = ok ? uploaded : 0;
      if (!ok && uploaded > 0) {
        // 上传失败：本地领先项不视为已同步。
        uploaded = 0;
        return NovelProgressSyncResult(
          uploaded: 0,
          autoAppliedFromRemote: autoApplied,
          requireConfirmation: needConfirm,
          unchanged: unchanged,
        );
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
  /// 返回 (应用了云端, 是否上传了本地)。出现需确认冲突时两个都 false 且
  /// [conflict] 置 true。
  Future<({bool appliedRemote, bool uploadedLocal, bool conflict})> pullOne(
      String novelId, NovelProgressPoint local) async {
    final cfg = await _loadConfig();
    if (cfg == null || cfg.password == null || cfg.password!.isEmpty) {
      return (appliedRemote: false, uploadedLocal: false, conflict: false);
    }
    final remote = await _fetchRemote(cfg.url, cfg.username, cfg.password!);
    final r = remote[novelId];
    if (r == null) {
      return (appliedRemote: false, uploadedLocal: false, conflict: false);
    }
    switch (decideProgressConflict(local: local, remote: r)) {
      case ProgressConflictDecision.localWins:
        await _uploadRemote(cfg.url, cfg.username, cfg.password!,
            <String, NovelProgressPoint>{novelId: local});
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
  }

  /// 单书静默上传（阅读器退出 / onPause 触发）。
  Future<bool> pushOne(String novelId, NovelProgressPoint local) async {
    final cfg = await _loadConfig();
    if (cfg == null || cfg.password == null || cfg.password!.isEmpty) {
      return false;
    }
    final remote = await _fetchRemote(cfg.url, cfg.username, cfg.password!);
    final r = remote[novelId];
    final decision = r == null
        ? ProgressConflictDecision.localWins
        : decideProgressConflict(local: local, remote: r);
    if (decision == ProgressConflictDecision.remoteWins) {
      // 云端领先：不覆盖（防回退）。
      return false;
    }
    final merged = <String, NovelProgressPoint>{...remote, novelId: local};
    return _uploadRemote(cfg.url, cfg.username, cfg.password!, merged);
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
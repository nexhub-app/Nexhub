/// 小说目录（TOC）本地缓存（按 sourceId + novelId 持久化到文件）。
///
/// 镜像 [NovelProgressManager] 的静默容错风格：读写失败一律吞掉，
/// 缓存仅作"当次抓取被验证/网络失败"时的兜底展示，不参与主数据链路。
///
/// novelId 通常是完整 URL（可能超长且含非法文件名字符），因此以
/// `sha1(sourceId|novelId)` 作为文件名，写入应用支持目录
/// `novel_toc_cache/<hash>.json`；不使用 SharedPreferences，避免超长目录
/// 撑爆偏好存储。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/episode.dart';

/// 小说目录缓存存储（可注入根目录：默认应用支持目录，测试用临时目录）。
class NovelTocCache {
  NovelTocCache({Directory? baseDirOverride}) : _baseDirOverride = baseDirOverride;

  final Directory? _baseDirOverride;

  static const String _dirName = 'novel_toc_cache';

  /// 解析缓存目录（不存在则创建）；失败返回 null（静默）。
  Future<Directory?> _cacheDir() async {
    try {
      final base = _baseDirOverride ?? await getApplicationSupportDirectory();
      final dir = Directory(p.join(base.path, _dirName));
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    } on Object {
      return null;
    }
  }

  /// 缓存文件名：`sha1(sourceId|novelId).json`。
  String _fileNameFor(String sourceId, String novelId) {
    final digest = sha1.convert(utf8.encode('$sourceId|$novelId'));
    return '$digest.json';
  }

  /// 读取最近一次成功缓存的章节列表；无缓存 / 损坏 / IO 失败均返回 null。
  Future<List<Episode>?> read(String sourceId, String novelId) async {
    try {
      final dir = await _cacheDir();
      if (dir == null) return null;
      final file = File(p.join(dir.path, _fileNameFor(sourceId, novelId)));
      if (!await file.exists()) return null;
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final list = json['chapters'] as List<dynamic>?;
      if (list == null || list.isEmpty) return null;
      return <Episode>[
        for (final e in list.cast<Map<String, dynamic>>())
          Episode(
            id: e['id'] as String? ?? '',
            title: e['title'] as String? ?? '',
            url: e['url'] as String? ?? '',
          ),
      ];
    } on Object {
      return null;
    }
  }

  /// 覆盖写入章节列表（空列表不写，避免坏数据顶掉可用缓存）；失败静默。
  Future<void> write(
    String sourceId,
    String novelId,
    List<Episode> chapters,
  ) async {
    if (chapters.isEmpty) return;
    try {
      final dir = await _cacheDir();
      if (dir == null) return;
      final file = File(p.join(dir.path, _fileNameFor(sourceId, novelId)));
      final payload = <String, dynamic>{
        'sourceId': sourceId,
        'novelId': novelId,
        'savedAt': DateTime.now().toIso8601String(),
        'chapters': <Map<String, dynamic>>[
          for (final c in chapters)
            <String, dynamic>{'id': c.id, 'title': c.title, 'url': c.url},
        ],
      };
      await file.writeAsString(jsonEncode(payload));
    } on Object {
      // 静默失败：缓存不可用不影响主流程。
    }
  }
}

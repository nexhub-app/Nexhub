/// 软件级公告（区别于源级公告 [SourceAnnouncementBanner]）。
///
/// 公告内容来自远程 GitHub 仓库的 JSON（raw 文件），随版本/运营随时更新；
/// 网络不可用时回退到打包资源 `assets/announcements.json`。已读过的公告 id
/// 持久化到 `shared_preferences`，下次启动不再弹窗——只有新增/未读的公告才会弹出。
library;

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

/// 单条软件公告。
class SoftwareAnnouncement {
  final String id;
  final String date;
  final String title;
  final String titleEn;
  final String body;
  final String bodyEn;
  final String url;
  final String urlText;
  final String urlTextEn;

  const SoftwareAnnouncement({
    required this.id,
    required this.date,
    required this.title,
    required this.titleEn,
    required this.body,
    required this.bodyEn,
    this.url = '',
    this.urlText = '',
    this.urlTextEn = '',
  });

  factory SoftwareAnnouncement.fromJson(Map<String, dynamic> json) {
    return SoftwareAnnouncement(
      id: (json['id'] as String?) ?? '',
      date: (json['date'] as String?) ?? '',
      title: (json['title'] as String?) ?? '',
      titleEn: (json['titleEn'] as String?) ?? (json['title'] as String?) ?? '',
      body: (json['body'] as String?) ?? '',
      bodyEn: (json['bodyEn'] as String?) ?? (json['body'] as String?) ?? '',
      url: (json['url'] as String?) ?? '',
      urlText: (json['urlText'] as String?) ?? '',
      urlTextEn: (json['urlTextEn'] as String?) ?? (json['urlText'] as String?) ?? '',
    );
  }
}

/// 加载并追踪软件公告是否已读。
class SoftwareAnnouncementService {
  static const String _seenKey = 'software_announcement_seen_v1';

  /// 远程公告地址（jsDelivr 加速，对应 GitHub 仓库文件）。
  ///
  /// 默认指向本项目仓库的 `assets/announcements.json`：把公告文件推到仓库后，
  /// 应用即通过 jsDelivr 拉取最新版。若 jsDelivr 不可用，内部会再回退到 GitHub raw。
  /// 若要托管到自己的仓库，改这里（或后续接入设置项）即可。
  static const String remoteUrl =
      'https://cdn.jsdelivr.net/gh/nexhub-app/nexhub@main/assets/announcements.json';

  /// GitHub raw 回退地址（jsDelivr 失败时使用）。
  static const String _rawFallbackUrl =
      'https://raw.githubusercontent.com/nexhub-app/nexhub/main/assets/announcements.json';

  /// 网络不可用时的本地兜底资源。
  static const String _fallbackAsset = 'assets/announcements.json';

  static final SoftwareAnnouncementService instance =
      SoftwareAnnouncementService._();

  List<SoftwareAnnouncement> _all = const <SoftwareAnnouncement>[];
  Set<String> _seen = const <String>{};

  SoftwareAnnouncementService._();

  /// 优先拉取远程 JSON；失败（离线 / 404 / 解析异常）则回退到打包资源。
  Future<void> load() async {
    List<SoftwareAnnouncement>? parsed;
    try {
      parsed = await _fetchRemote();
    } on Object {
      // 远程失败：静默回退。
      parsed = null;
    }
    if (parsed == null) {
      try {
        parsed = await _loadAsset();
      } on Object {
        parsed = const <SoftwareAnnouncement>[];
      }
    }
    _all = parsed ?? const <SoftwareAnnouncement>[];

    final prefs = await SharedPreferences.getInstance();
    _seen = (prefs.getStringList(_seenKey) ?? const <String>[]).toSet();
  }

  /// 从远程解析公告清单：先走 jsDelivr 加速，失败再回退 GitHub raw。
  Future<List<SoftwareAnnouncement>> _fetchRemote() async {
    List<SoftwareAnnouncement>? result;
    try {
      result = await _fetchFromUrl(remoteUrl);
    } on Object {
      result = null;
    }
    if (result == null) {
      result = await _fetchFromUrl(_rawFallbackUrl);
    }
    return result;
  }

  Future<List<SoftwareAnnouncement>> _fetchFromUrl(String url) async {
    final resp = await Dio().get<String>(
      url,
      options: Options(
        receiveTimeout: const Duration(seconds: 8),
        sendTimeout: const Duration(seconds: 8),
      ),
    );
    final data = resp.data;
    if (data == null || data.trim().isEmpty) {
      throw Exception('empty remote announcement');
    }
    final decoded = jsonDecode(data);
    if (decoded is! List<dynamic>) {
      throw Exception('remote announcement is not a list');
    }
    return decoded
        .map((e) => SoftwareAnnouncement.fromJson(e as Map<String, dynamic>))
        .where((a) => a.id.isNotEmpty)
        .toList();
  }

  /// 从打包资源解析公告清单（回退用）。
  Future<List<SoftwareAnnouncement>> _loadAsset() async {
    final raw = await rootBundle.loadString(_fallbackAsset);
    final decoded = jsonDecode(raw);
    if (decoded is! List<dynamic>) return const <SoftwareAnnouncement>[];
    return decoded
        .map((e) => SoftwareAnnouncement.fromJson(e as Map<String, dynamic>))
        .where((a) => a.id.isNotEmpty)
        .toList();
  }

  /// 返回尚未读过的公告（按资源顺序）。
  List<SoftwareAnnouncement> unseen() =>
      _all.where((a) => !_seen.contains(a.id)).toList();

  /// 将指定公告标记为已读并持久化。
  Future<void> markSeen(List<String> ids) async {
    if (ids.isEmpty) return;
    final merged = <String>{..._seen, ...ids};
    _seen = merged;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_seenKey, merged.toList());
  }
}

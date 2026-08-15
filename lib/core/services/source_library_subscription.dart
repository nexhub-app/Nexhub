/// 源库订阅（库导入 / 库收藏）持久化存储。
///
/// 一个「源库」是一份源订阅：填写其原始 JSON 订阅地址后，可一次性拉取并导入其中
/// 的全部源；订阅本身会被持久化保留，形成「库收藏」列表，可随时「更新并导入」。
///
/// 内置官方库 [officialHomepage] 在首次启动时预置，且不可被取消订阅。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

/// 单个源库订阅。
class SourceLibrary {
  final String id;
  final String name;
  final String url; // 原始 JSON 订阅地址（拉取并导入源用）
  final String? homepage; // 如 GitHub 仓库页（仅展示/外链用）
  final bool isOfficial;
  final int addedAt;

  const SourceLibrary({
    required this.id,
    required this.name,
    required this.url,
    this.homepage,
    this.isOfficial = false,
    required this.addedAt,
  });

  SourceLibrary copyWith({String? name, String? url, String? homepage}) =>
      SourceLibrary(
        id: id,
        name: name ?? this.name,
        url: url ?? this.url,
        homepage: homepage ?? this.homepage,
        isOfficial: isOfficial,
        addedAt: addedAt,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'url': url,
        'homepage': homepage,
        'isOfficial': isOfficial,
        'addedAt': addedAt,
      };

  factory SourceLibrary.fromJson(Map<String, dynamic> json) => SourceLibrary(
        id: json['id'] as String,
        name: json['name'] as String,
        url: json['url'] as String,
        homepage: json['homepage'] as String?,
        isOfficial: json['isOfficial'] as bool? ?? false,
        addedAt: json['addedAt'] as int? ?? 0,
      );
}

/// 源库订阅列表（ChangeNotifier，供 UI 监听刷新）。
class SourceLibrarySubscription extends ChangeNotifier {
  SourceLibrarySubscription();

  static const String boxName = 'source_library_subs';
  static const String _key = 'list';

  /// 内置官方库 id（不可取消订阅）。
  static const String officialId = 'official_nexhub';

  /// 内置官方库：GitHub 仓库页（展示 / 外链）。
  static const String officialHomepage =
      'https://github.com/nexhub-app/sources';

  /// 内置官方库：manifest 订阅地址。
  /// 仓库以 `index.json` 暴露全部源（清单形态：`{"sources":[{id,name,rawUrl,...}]}`），
  /// 各源经 `rawUrl`（jsDelivr CDN）拉取。优先用 jsDelivr CDN（README 注明国内可达）。
  static const String officialUrl =
      'https://cdn.jsdelivr.net/gh/nexhub-app/sources@main/index.json';

  static const String officialName = 'NexHub 官方源库';

  Box<dynamic>? _box;
  List<SourceLibrary> _libs = const <SourceLibrary>[];

  Future<Box<dynamic>> _openBox() async {
    if (_box != null) return _box!;
    _box = Hive.isBoxOpen(boxName)
        ? Hive.box(boxName)
        : await Hive.openBox(boxName);
    return _box!;
  }

  /// 启动加载：从 Hive 读取订阅列表，并确保内置官方库始终存在。
  Future<void> load() async {
    final box = await _openBox();
    final raw = box.get(_key);
    List<SourceLibrary> list = const <SourceLibrary>[];
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          list = decoded
              .whereType<Map<dynamic, dynamic>>()
              .map((m) => SourceLibrary.fromJson(Map<String, dynamic>.from(m)))
              .toList();
        }
      } on Object {
        // 损坏数据忽略
      }
    }
    // 预置官方库（始终置顶、不可取消订阅）。
    if (!list.any((l) => l.id == officialId)) {
      list = <SourceLibrary>[
        const SourceLibrary(
          id: officialId,
          name: officialName,
          url: officialUrl,
          homepage: officialHomepage,
          isOfficial: true,
          addedAt: 0,
        ),
        ...list,
      ];
      await box.put(_key, jsonEncode(list.map((l) => l.toJson()).toList()));
    }
    _libs = list;
    notifyListeners();
  }

  /// 当前订阅列表（不可变视图）。
  List<SourceLibrary> all() => List<SourceLibrary>.unmodifiable(_libs);

  /// 是否已订阅某 url（去重）。
  bool containsUrl(String url) =>
      _libs.any((l) => l.url.trim() == url.trim());

  /// 订阅一个新源库（去重：同 id 或同 url 忽略）。
  Future<void> add(SourceLibrary lib) async {
    if (_libs.any((l) => l.id == lib.id || l.url.trim() == lib.url.trim())) {
      return;
    }
    _libs = <SourceLibrary>[..._libs, lib];
    await _persist();
    notifyListeners();
  }

  /// 取消订阅（官方库受保护，忽略）。
  Future<void> remove(String id) async {
    if (id == officialId) return;
    _libs = _libs.where((l) => l.id != id).toList();
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    final box = await _openBox();
    await box.put(_key, jsonEncode(_libs.map((l) => l.toJson()).toList()));
  }
}

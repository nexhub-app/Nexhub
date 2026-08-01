/// 源配置加载器（运行时态）。
///
/// 按源无痕模式（per-source incognito）：
/// - [isIncognito] 返回某源的无痕状态：优先运行时覆盖（用户在源管理页切换），
///   否则回退到 `PluginConfig.stealthMode`（缺省 false）。
/// - [setIncognito] 写入运行时覆盖并持久化到 Hive box `source_stealth`
///   （key=sourceId，value=bool）。开启后 HistoryManager 跳过该源历史写入，
///   单源搜索跳过搜索记录；进度记忆不受影响。
/// - [getStealthMode] / [setStealthMode] 为全局请求隐身延迟开关（供 HttpFetcher
///   打散请求节拍），默认 true，不再是恒 true 的硬约束。
///
/// 每个源可记录「当前激活镜像」，parser/route/baseUrl/referer 统一指向它。
///
/// 镜像选择持久化到 Hive box `source_mirrors`（P8.2.2 §廿二）。
/// 用户自定义镜像持久化到 Hive box `source_custom_mirrors`
/// （key=sourceId，value=JSON-encoded `List<Map>` of mirrors）。
library;

import 'dart:convert';

import 'package:hive/hive.dart';

import '../models/plugin_config.dart';

class ConfigLoader {
  ConfigLoader._();

  static final ConfigLoader instance = ConfigLoader._();

  final Map<String, String> _activeMirror = {};
  final Map<String, String> _cookies = {};
  bool _loaded = false;
  Box<dynamic>? _box;

  /// 自定义镜像 Hive box（key=sourceId，value=JSON-encoded List<Map>）。
  Box<dynamic>? _customMirrorsBox;

  /// 自定义镜像内存缓存：sourceId → 镜像列表。
  final Map<String, List<MirrorConfig>> _customMirrorsCache = {};

  /// 按源无痕覆盖 Hive box（key=sourceId，value=bool）。
  Box<dynamic>? _sourceStealthBox;

  /// 按源无痕内存缓存：sourceId → 是否无痕（运行时覆盖）。
  final Map<String, bool> _incognitoCache = {};

  /// 全局请求隐身延迟开关（HttpFetcher 用）。默认 true，可被 [setStealthMode] 关闭。
  bool _globalStealthDelay = true;

  /// 全局无痕浏览开关：开启后所有源都不记录浏览历史与搜索记录
  /// （per-source 覆盖仍生效，[isIncognito] 恒返回 true）。
  bool _globalIncognito = false;

  /// Hive box 名。
  static const String boxName = 'source_mirrors';

  /// 自定义镜像 Hive box 名。
  static const String customMirrorsBoxName = 'source_custom_mirrors';

  /// 按源无痕 Hive box 名。
  static const String sourceStealthBoxName = 'source_stealth';

  /// 全局无痕开关在 [boxName] 中的保留键（不与任何 sourceId 冲突）。
  static const String globalIncognitoKey = '__global_incognito__';

  /// 从 Hive 加载持久化的镜像选择（P8.2.2 §廿二）。
  Future<void> init() async {
    if (_loaded) return;
    _box = await Hive.openBox(boxName);
    for (final key in _box!.keys) {
      if (key is! String) continue;
      final val = _box!.get(key);
      if (val is String && val.isNotEmpty) {
        _activeMirror[key] = val;
      }
    }
    _customMirrorsBox = await Hive.openBox(customMirrorsBoxName);
    _sourceStealthBox = await Hive.openBox(sourceStealthBoxName);
    for (final key in _sourceStealthBox!.keys) {
      if (key is! String) continue;
      final val = _sourceStealthBox!.get(key);
      if (val is bool) {
        _incognitoCache[key] = val;
      }
    }
    final g = _box?.get(globalIncognitoKey);
    if (g is bool) _globalIncognito = g;
    _loaded = true;
  }

  /// 全局请求隐身延迟开关（HttpFetcher 打散请求节拍用）。默认 true。
  bool getStealthMode() => _globalStealthDelay;

  /// 设置全局请求隐身延迟开关。
  void setStealthMode(bool value) {
    _globalStealthDelay = value;
  }

  // --- 全局无痕浏览（总开关） ---

  /// 全局无痕浏览是否开启。开启后所有源都视为无痕，不记录浏览历史与搜索记录。
  /// per-source 覆盖值仍被保留，仅在该总开关关闭时生效。
  bool get isGlobalIncognito => _globalIncognito;

  /// 设置全局无痕浏览总开关并持久化到 Hive box（保留键 [globalIncognitoKey]）。
  Future<void> setGlobalIncognito(bool value) async {
    _globalIncognito = value;
    await _box?.put(globalIncognitoKey, value);
  }

  // --- 按源无痕模式（per-source incognito） ---

  /// 某源是否处于无痕模式。
  ///
  /// 全局无痕总开关开启时恒返回 true（所有源无痕）。否则优先返回运行时覆盖
  /// （用户在源管理页切换的值）；无覆盖时回退到 `source.stealthMode`（缺省 false）。
  /// 开启后该源的浏览历史与单源搜索记录不写入；进度记忆不受影响。
  bool isIncognito(PluginConfig source) {
    if (_globalIncognito) return true;
    final override = _incognitoCache[source.id];
    if (override != null) return override;
    return source.stealthMode;
  }

  /// 仅按 [sourceId] 判断无痕（无 PluginConfig 时用，如 HistoryManager）。
  ///
  /// 全局总开关开启时恒返回 true。否则有运行时覆盖则用之，否则返回 false。
  /// sourceId 为空时返回 false。
  bool isIncognitoBySourceId(String? sourceId) {
    if (_globalIncognito) return true;
    if (sourceId == null || sourceId.isEmpty) return false;
    return _incognitoCache[sourceId] ?? false;
  }

  /// 设置某源的无痕覆盖并持久化到 Hive box `source_stealth`。
  Future<void> setIncognito(String sourceId, bool value) async {
    _incognitoCache[sourceId] = value;
    await _sourceStealthBox?.put(sourceId, value);
  }

  /// 获取某源当前激活镜像基址（缺省回退 site.baseUrl）。
  String getActiveMirror(PluginConfig source) {
    final mirror = _activeMirror[source.id];
    if (mirror != null) return mirror;
    return source.site.baseUrl;
  }

  /// 设置镜像并持久化到 Hive（P8.2.2 §廿二）。
  void setActiveMirror(String sourceId, String baseUrl) {
    _activeMirror[sourceId] = baseUrl;
    // fire-and-forget 持久化
    _box?.put(sourceId, baseUrl);
  }

  /// 编辑源主域名时，若当前激活镜像仍是旧主域名（用户未手动切到自定义镜像），
  /// 则把激活镜像重定向到新主域名，使编辑立即生效；若已选自定义镜像则保持不变。
  void retargetActiveMirrorIfDefault(
    String sourceId,
    String oldBaseUrl,
    String newBaseUrl,
  ) {
    final cur = _activeMirror[sourceId];
    if (cur == null || cur == oldBaseUrl) {
      _activeMirror[sourceId] = newBaseUrl;
      _box?.put(sourceId, newBaseUrl);
    }
  }

  void setCookies(String host, String cookieHeader) {
    _cookies[host] = cookieHeader;
  }

  String? getCookies(String host) => _cookies[host];

  // --- 自定义镜像（用户导入 / 从发布页提取） ---

  /// 读取某源的用户自定义镜像列表。
  ///
  /// 从内存缓存返回（首次访问时从 Hive 解码并缓存）。
  List<MirrorConfig> getCustomMirrors(String sourceId) {
    final cached = _customMirrorsCache[sourceId];
    if (cached != null) return cached;
    final raw = _customMirrorsBox?.get(sourceId);
    if (raw is! String || raw.isEmpty) {
      _customMirrorsCache[sourceId] = const <MirrorConfig>[];
      return const <MirrorConfig>[];
    }
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      final mirrors = list
          .whereType<Map>()
          .map((e) => MirrorConfig.fromJson(Map<String, dynamic>.from(e)))
          .toList(growable: false);
      _customMirrorsCache[sourceId] = mirrors;
      return mirrors;
    } catch (_) {
      _customMirrorsCache[sourceId] = const <MirrorConfig>[];
      return const <MirrorConfig>[];
    }
  }

  /// 追加一条自定义镜像（按 baseUrl 去重）并持久化。
  Future<void> addCustomMirror(String sourceId, MirrorConfig mirror) async {
    final mirrors = List<MirrorConfig>.from(getCustomMirrors(sourceId));
    if (mirrors.any((m) => m.baseUrl == mirror.baseUrl)) return;
    mirrors.add(mirror);
    _customMirrorsCache[sourceId] = List<MirrorConfig>.unmodifiable(mirrors);
    await _customMirrorsBox?.put(sourceId, _encodeMirrors(mirrors));
  }

  /// 删除匹配 baseUrl 的自定义镜像并持久化。
  Future<void> removeCustomMirror(String sourceId, String baseUrl) async {
    final mirrors = List<MirrorConfig>.from(getCustomMirrors(sourceId));
    mirrors.removeWhere((m) => m.baseUrl == baseUrl);
    _customMirrorsCache[sourceId] = List<MirrorConfig>.unmodifiable(mirrors);
    await _customMirrorsBox?.put(sourceId, _encodeMirrors(mirrors));
  }

  String _encodeMirrors(List<MirrorConfig> mirrors) =>
      jsonEncode(mirrors.map((e) => e.toJson()).toList());
}

/// Bangumi 代理 / 镜像（反代）配置。
///
/// 用途：当官方域名（api.bgm.tv / next.bgm.tv / bgm.tv / lain.bgm.tv）
/// 在用户网络下不可直连时，可切换到「镜像 / 反代」模式，分别指定三类域名：
///
/// - 主站域名（[mainSite]）：替换 `next.bgm.tv` 与 `bgm.tv`
///   （吐槽 p1 接口、OAuth 授权端点走主站）；
/// - API 域名（[api]）：替换 `api.bgm.tv`（v0 公开 / 收藏接口）；
/// - 图片域名（[image]）：替换 `lain.bgm.tv`（条目封面、角色头像、吐槽头像）。
///
/// 「直连」模式（[BangumiProxyMode.direct]）下全部走官方默认域名。
///
/// 该配置为全局单例（[instance]），由 [load] 在启动期从本地存储载入，
/// 随后 [BangumiClient] 在每次请求时实时读取，无需重建客户端即可生效。
library;

import 'dart:convert';

import 'package:nexhub/core/comic/models/reader_preferences.dart';

/// 代理模式：直连 / 镜像反代。
enum BangumiProxyMode {
  /// 直连官方域名。
  direct,

  /// 走用户自建镜像 / 反向代理。
  mirror,
}

/// Bangumi 代理 / 镜像配置。
class BangumiProxyConfig {
  static const String _key = 'bangumi_proxy_config_v1';

  /// 代理模式。
  final BangumiProxyMode mode;

  /// 主站 / 反代域名：替换 `next.bgm.tv` 与 `bgm.tv`。
  final String mainSite;

  /// API 域名：替换 `api.bgm.tv`。
  final String api;

  /// 图片域名：替换 `lain.bgm.tv`。
  final String image;

  const BangumiProxyConfig({
    this.mode = BangumiProxyMode.direct,
    this.mainSite = '',
    this.api = '',
    this.image = '',
  });

  factory BangumiProxyConfig.fromJson(Map<String, dynamic> json) {
    final modeName = json['mode'] as String? ?? 'direct';
    final mode = BangumiProxyMode.values.firstWhere(
      (e) => e.name == modeName,
      orElse: () => BangumiProxyMode.direct,
    );
    return BangumiProxyConfig(
      mode: mode,
      mainSite: (json['mainSite'] as String?) ?? '',
      api: (json['api'] as String?) ?? '',
      image: (json['image'] as String?) ?? '',
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'mode': mode.name,
        'mainSite': mainSite,
        'api': api,
        'image': image,
      };

  // ── 官方默认域名 ──
  static const String _defaultApi = 'https://api.bgm.tv';
  static const String _defaultNext = 'https://next.bgm.tv';
  static const String _defaultOAuth = 'https://bgm.tv';
  static const String _defaultImage = 'https://lain.bgm.tv';

  /// v0 API 基址（替换 api.bgm.tv）。
  String get apiBaseUrl =>
      (mode == BangumiProxyMode.mirror && api.trim().isNotEmpty)
          ? _withScheme(api.trim())
          : _defaultApi;

  /// 主站基址（替换 next.bgm.tv / bgm.tv）。
  String get nextBaseUrl =>
      (mode == BangumiProxyMode.mirror && mainSite.trim().isNotEmpty)
          ? _withScheme(mainSite.trim())
          : _defaultNext;

  /// OAuth 授权基址（替换 bgm.tv）。
  String get oauthBaseUrl =>
      (mode == BangumiProxyMode.mirror && mainSite.trim().isNotEmpty)
          ? _withScheme(mainSite.trim())
          : _defaultOAuth;

  /// 图片基址（替换 lain.bgm.tv）。
  String get imageBaseUrl =>
      (mode == BangumiProxyMode.mirror && image.trim().isNotEmpty)
          ? _withScheme(image.trim())
          : _defaultImage;

  /// 确保域名带 https:// 前缀、去掉结尾斜杠。
  static String _withScheme(String host) {
    final h = host.trim();
    if (h.startsWith('http://') || h.startsWith('https://')) {
      return h.replaceAll(RegExp(r'/+$'), '');
    }
    return 'https://$h';
  }

  /// 提取基址中的 host（用于替换图片 URL 的 authority）。
  static String _hostOf(String base) {
    final uri = Uri.parse(base);
    return uri.host;
  }

  /// 将 Bangumi 图片 URL 重写到镜像域名（仅替换 host，保留 path/query）。
  ///
  /// 直连模式或图片域名为空时原样返回。
  String resolveImageUrl(String? url) {
    if (url == null || url.isEmpty) return url ?? '';
    if (mode != BangumiProxyMode.mirror || image.trim().isEmpty) return url;
    try {
      final uri = Uri.parse(url);
      if (!uri.hasAuthority) return url;
      return uri.replace(host: _hostOf(imageBaseUrl)).toString();
    } catch (_) {
      return url;
    }
  }

  // ── 持久化与单例 ──
  static BangumiProxyConfig _instance = const BangumiProxyConfig();

  /// 全局实例（请求时实时读取）。
  static BangumiProxyConfig get instance => _instance;

  /// 载入本地存储的配置；不存在或损坏时回退默认直连。
  static Future<BangumiProxyConfig> load() async {
    const backend = SharedPrefsBackend();
    final raw = await backend.get(_key);
    if (raw == null || raw.isEmpty) {
      _instance = const BangumiProxyConfig();
      return _instance;
    }
    try {
      _instance = BangumiProxyConfig.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      _instance = const BangumiProxyConfig();
    }
    return _instance;
  }

  /// 持久化当前配置并同步全局实例。
  Future<void> save() async {
    const backend = SharedPrefsBackend();
    await backend.set(_key, jsonEncode(toJson()));
    _instance = this;
  }
}

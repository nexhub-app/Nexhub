/// 嗅探过滤规则：从 [assets/sniffer/sniffer_rules.json] 加载，按扩展名 / 关键字
/// 放行或屏蔽广告、缩略图、分析 beacon 等噪声。规则可编辑，不写死任何站点。
library;

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

/// 嗅探规则（单例）。
class SnifferRules {
  SnifferRules._();

  static final SnifferRules instance = SnifferRules._();

  /// 内置兜底规则（资源未加载前也能用，与 JSON 默认一致）。
  static const List<String> _defaultAllowExt = <String>[
    'm3u8', 'm3u', 'mpd', 'mp4', 'ts', 'm4s', 'mov', 'webm', 'flv',
    'mkv', 'avi', '3gp', 'mp3', 'aac', 'wav', 'ogg', 'm4a', 'oga'
  ];
  static const List<String> _defaultBlockExt = <String>[
    'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'svg', 'css', 'js',
    'json', 'woff', 'woff2', 'ttf', 'eot', 'ico', 'html', 'htm', 'php'
  ];
  static const List<String> _defaultAllowKw = <String>[
    'm3u8', 'mp4', 'play', 'video', 'media', 'source', 'segment',
    'chunk', 'index', 'playlist', 'manifest', 'blob:', 'mediasource:'
  ];
  static const List<String> _defaultBlockKw = <String>[
    'ad', 'ads', 'advert', 'pixel', 'beacon', 'analytics', 'tracker',
    'stat', 'count', 'impression', 'banner', 'pop', 'thumb', 'thumbnail',
    'preview', 'avatar', 'logo', 'sprite', 'emoji', 'spinner', 'loading',
    'placeholder', 'favicon', 'cloudflare', 'cdn-cgi'
  ];
  static const List<String> _defaultAllowMime = <String>[
    'video/',
    'audio/',
    'application/vnd.apple.mpegurl',
    'application/x-mpegurl',
    'application/dash+xml',
  ];

  List<String> _allowExt = _defaultAllowExt;
  List<String> _blockExt = _defaultBlockExt;
  List<String> _allowKw = _defaultAllowKw;
  List<String> _blockKw = _defaultBlockKw;
  List<String> _allowMime = _defaultAllowMime;

  bool _loaded = false;

  /// 媒体扩展名在 URL 任意位置的精确匹配（`.ext` 后跟结尾或 ?/#/&/、/），
  /// 覆盖路径与查询串两种形态；用精确边界避免 `.ts` 误命中 `.tsx` 等。
  static final RegExp _mediaExtAnywhereRe = RegExp(
      r'\.(m3u8|m3u|mpd|mp4|ts|m4s|mov|webm|flv|mkv|avi|3gp|mp3|aac|wav|ogg|m4a|oga)(?=$|[?#&/])');

  /// 从资源加载规则（幂等）。失败则保留内置兜底规则。
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true; // 防并发重复加载
    try {
      final raw = await rootBundle.loadString('assets/sniffer/sniffer_rules.json');
      final data = jsonDecode(raw) as Map<String, dynamic>;
      _allowExt = List<String>.from(data['allowExtensions'] ?? _defaultAllowExt);
      _blockExt = List<String>.from(data['blockExtensions'] ?? _defaultBlockExt);
      _allowKw = List<String>.from(data['allowKeywords'] ?? _defaultAllowKw);
      _blockKw = List<String>.from(data['blockKeywords'] ?? _defaultBlockKw);
      _allowMime = List<String>.from(data['allowMime'] ?? _defaultAllowMime);
    } catch (_) {
      // 用内置兜底，不阻塞嗅探。
    }
  }

  /// 判断 [url] 是否应被保留。
  ///
  /// [kind] 为钩子提供的来源类型（fetch/xhr/media/blob/mse/resource），
  /// 可作为强信号提升召回。
  bool isAllowed(String url, [String? kind, String? mime]) {
    final lower = url.toLowerCase();
    if (lower.startsWith('blob:') || lower.startsWith('mediasource:')) {
      return true;
    }
    // 响应 MIME（JS 钩子在响应阶段读 Content-Type 回传）：猫爪 onResponseStarted
    // 的等价物，用于识别「无扩展名但确为媒体」的串流（如经 .php 或无后缀分发的 m3u8/mp4）。
    if (mime != null && _isMediaMime(mime)) return true;

    // 媒体扩展名精确命中（含查询串，如 player.php?url=xxx.m3u8）优先放行——
    // 必须在 blockExt/blockKw 之前，否则中转 URL 会先被 .php / 关键字误杀。
    if (_mediaExtAnywhereRe.hasMatch(lower)) return true;

    final ext = _extractExt(lower);
    if (ext.isNotEmpty && _blockExt.contains(ext)) return false;

    // 按 token 边界匹配屏蔽关键字，避免误伤（如 broadcast 含 ad 子串）。
    final tokens = lower.split(RegExp(r'[^a-z0-9]+'));
    for (final kw in _blockKw) {
      if (tokens.contains(kw)) return false;
    }

    if (ext.isNotEmpty && _allowExt.contains(ext)) return true;
    for (final kw in _allowKw) {
      if (lower.contains(kw)) return true;
    }
    // 钩子明确标记的来源类型（媒体元素 / blob / MSE）可信度较高。
    if (kind == 'media' || kind == 'blob' || kind == 'mse') return true;
    return false;
  }

  /// 判断 MIME 是否为媒体类型（猫爪 onResponseStarted 的 MIME 终判等价物）。
  bool _isMediaMime(String mime) {
    final lower = mime.toLowerCase().trim();
    for (final a in _allowMime) {
      if (lower.startsWith(a) || lower == a) return true;
    }
    return false;
  }

  /// 取 URL 扩展名（不含点，截到 ?/# 之前）。
  String _extractExt(String lower) {
    var s = lower;
    final q = s.indexOf('?');
    if (q >= 0) s = s.substring(0, q);
    final h = s.indexOf('#');
    if (h >= 0) s = s.substring(0, h);
    final dot = s.lastIndexOf('.');
    if (dot < 0 || dot >= s.length - 1) return '';
    final ext = s.substring(dot + 1);
    // 仅保留纯字母数字扩展名。
    if (RegExp(r'^[a-z0-9]+$').hasMatch(ext)) return ext;
    return '';
  }
}

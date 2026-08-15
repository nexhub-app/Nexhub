/// 嗅探引擎：收集钩子 / 被动拦截上报的 URL，去重、按规则过滤、分类，
/// 并向 UI 暴露筛选后的列表。与具体站点无关。
library;

import 'dart:convert' show base64, utf8;

import 'package:flutter/foundation.dart' show VoidCallback;
import 'package:nexhub/core/sniffer/sniffer_models.dart'
    show MediaKind, SniffFilter, SniffedMedia;
import 'package:nexhub/core/sniffer/sniffer_rules.dart' show SnifferRules;

/// 嗅探结果收集器。
class SnifferEngine {
  /// 进程级共享实例：嗅探页与源视频路由 WebView 共用，使捕获结果跨屏累积。
  static final SnifferEngine shared = SnifferEngine();

  /// 已捕获且通过过滤的媒体（保持插入顺序）。
  final List<SniffedMedia> items = <SniffedMedia>[];

  /// 已成功入库的 URL。
  final Set<String> _seen = <String>{};

  /// 被规则过滤的 URL（可在后续拿到媒体 MIME 时“翻案”重新评估——
  /// 猫爪以响应 MIME 为最终裁决的等价机制）。
  final Set<String> _rejected = <String>{};

  /// 列表变化回调（用于通知 State 刷新）。
  VoidCallback? onUpdate;

  /// 规则是否已尝试加载（幂等）。
  bool _rulesReady = false;

  /// 捕获数。
  int get count => items.length;

  /// 上报一个 URL。返回是否成功入库（false 表示重复 / 被规则过滤 / 非法）。
  ///
  /// [kind] 来源类型（fetch/xhr/media/blob/mse/resource），[referer] 为可选防盗链。
  Future<bool> add(
    String url, {
    String? kind,
    String? referer,
    String? mime,
  }) async {
    final u = url.trim();
    if (u.isEmpty) return false;
    final lower = u.toLowerCase();
    // 仅接受可播放 / 可追踪的协议；拒绝 data:/javascript: 等。
    if (!lower.startsWith('http://') &&
        !lower.startsWith('https://') &&
        !lower.startsWith('blob:') &&
        !lower.startsWith('mediasource:')) {
      return false;
    }
    if (_seen.contains(u)) {
      // 已入库但这次带来了 MIME：若能纠正原先的分类/标签则原位更新。
      if (mime != null && mime.isNotEmpty) _refineWithMime(u, mime);
      return false;
    }
    // 已被过滤过的 URL：仅当这次带来了新的 MIME 信息时才重新评估（翻案）。
    if (_rejected.contains(u) && (mime == null || mime.isEmpty)) return false;

    // 「中转壳」拆解：player.php?url=https://cdn/x.m3u8（或 base64 编码参数）
    // 这类地址本体是网页，播它必失败——挖出内嵌真链入库，壳本身不进列表。
    // 壳页面通常正是 CDN 校验的 Referer，故 referer 缺省时用壳地址兜底。
    final inner = _unwrapEmbedded(u);
    if (inner != null && inner != u) {
      _seen.add(u);
      return add(inner, kind: kind, referer: referer ?? u);
    }

    if (!_rulesReady) {
      await SnifferRules.instance.ensureLoaded();
      _rulesReady = true;
    }
    if (!SnifferRules.instance.isAllowed(u, kind, mime)) {
      _rejected.add(u); // 记下来，避免同一噪声反复走过滤逻辑；带 MIME 可翻案。
      return false;
    }
    _rejected.remove(u);

    final media = SniffedMedia(
      url: u,
      kind: SniffedMedia.inferKind(u, mime),
      typeLabel: SniffedMedia.inferTypeLabel(u, mime),
      sourceTag: (kind == null || kind.isEmpty) ? null : kind,
      referer: (referer == null || referer.isEmpty) ? null : referer,
      seenAt: DateTime.now(),
    );
    _seen.add(u);
    items.add(media);
    onUpdate?.call();
    return true;
  }

  /// 媒体扩展名精确边界匹配（与 SniffedMedia/SnifferRules 同口径）。
  static final RegExp _mediaExtRe = RegExp(
      r'\.(m3u8|m3u|mpd|mp4|ts|m4s|mov|webm|flv|mkv|avi|3gp|mp3|aac|wav|ogg|m4a|oga)(?=$|[?#&/])');

  /// 从查询串中提取内嵌的真实媒体直链；提取不到返回 null。
  ///
  /// 覆盖两种常见形态：明文 `?url=https://cdn/x.m3u8`、base64 `?url=aHR0cHM6...`。
  /// 本体路径已是媒体直链（如 `https://cdn/x.m3u8?sign=..`）则不拆。
  String? _unwrapEmbedded(String u) {
    final lower = u.toLowerCase();
    if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
      return null;
    }
    final uri = Uri.tryParse(u);
    if (uri == null) return null;
    if (_mediaExtRe.hasMatch(uri.path.toLowerCase())) return null;
    Map<String, String> params;
    try {
      params = uri.queryParameters;
    } catch (_) {
      return null; // 非法编码的查询串
    }
    if (params.isEmpty) return null;
    for (final v in params.values) {
      var cand = v.trim();
      if (cand.isEmpty) continue;
      if (!cand.contains('://')) {
        final decoded = _tryBase64Url(cand);
        if (decoded == null) continue;
        cand = decoded;
      }
      final cl = cand.toLowerCase();
      if ((cl.startsWith('http://') || cl.startsWith('https://')) &&
          _mediaExtRe.hasMatch(cl)) {
        return cand;
      }
    }
    return null;
  }

  /// 尝试把 base64/base64url 字符串解成 http(s) 地址；失败返回 null。
  String? _tryBase64Url(String s) {
    if (s.length < 16 || !RegExp(r'^[A-Za-z0-9+/_=-]+$').hasMatch(s)) {
      return null;
    }
    try {
      var t = s.replaceAll('-', '+').replaceAll('_', '/');
      final pad = t.length % 4;
      if (pad == 1) return null;
      if (pad > 0) t += '=' * (4 - pad);
      final out = utf8.decode(base64.decode(t));
      return out.startsWith('http') ? out : null;
    } catch (_) {
      return null;
    }
  }

  /// 用后到的响应 MIME 纠正已入库条目的分类 / 标签（MIME 比 URL 更可信）。
  void _refineWithMime(String url, String mime) {
    final idx = items.indexWhere((m) => m.url == url);
    if (idx < 0) return;
    final old = items[idx];
    final newKind = SniffedMedia.inferKind(url, mime);
    final newLabel = SniffedMedia.inferTypeLabel(url, mime);
    if (newKind == old.kind && newLabel == old.typeLabel) return;
    items[idx] = SniffedMedia(
      url: old.url,
      kind: newKind,
      typeLabel: newLabel,
      contentLength: old.contentLength,
      sourceTag: old.sourceTag,
      referer: old.referer,
      seenAt: old.seenAt,
    );
    onUpdate?.call();
  }

  /// 按筛选维度返回子集。
  List<SniffedMedia> filtered(SniffFilter filter) {
    switch (filter) {
      case SniffFilter.all:
        return items;
      case SniffFilter.video:
        return items.where((m) => m.kind == MediaKind.video).toList();
      case SniffFilter.audio:
        return items.where((m) => m.kind == MediaKind.audio).toList();
      case SniffFilter.other:
        return items.where((m) => m.kind == MediaKind.other).toList();
    }
  }

  /// 清空全部。
  void clear() {
    items.clear();
    _seen.clear();
    _rejected.clear();
    onUpdate?.call();
  }
}

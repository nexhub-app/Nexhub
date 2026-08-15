/// 嗅探结果数据模型（源即插件架构：与具体站点无关）。
library;

/// 捕获到的媒体类型。
enum MediaKind {
  video,
  audio,
  other,
}

/// 结果列表筛选维度。
enum SniffFilter {
  all,
  video,
  audio,
  other,
}

/// 单条嗅探到的媒体资源。
class SniffedMedia {
  /// 资源地址（http(s) / blob: / mediasource:）。
  final String url;

  /// 媒体大类（由 [ext]/[typeLabel] 推断）。
  final MediaKind kind;

  /// 展示用类型标签（M3U8 / MP4 / TS / …）。
  final String typeLabel;

  /// 字节大小（可选；HEAD 探测失败时为空）。
  final int? contentLength;

  /// 捕获来源标签（fetch / xhr / media / blob / mse / resource）。
  final String? sourceTag;

  /// 可选的防盗链 Referer（从 fetch 请求头提取）。
  final String? referer;

  /// 首次捕获时间。
  final DateTime seenAt;

  const SniffedMedia({
    required this.url,
    required this.kind,
    required this.typeLabel,
    this.contentLength,
    this.sourceTag,
    this.referer,
    required this.seenAt,
  });

  /// 媒体扩展名精确匹配：`.ext` 后必须是结尾或 ?/#/&/、/ 边界，
  /// 避免 `.ts` 误命中 `.tsx`、`getStats` 等（旧 contains 匹配的误标根因）。
  static final RegExp _mediaExtRe = RegExp(
      r'\.(m3u8|m3u|mpd|mp4|ts|m4s|mov|webm|flv|mkv|avi|3gp|mp3|aac|wav|ogg|m4a|oga)(?=$|[?#&/])');

  static const Set<String> _videoExt = {
    'm3u8', 'm3u', 'mpd', 'mp4', 'ts', 'm4s', 'mov', 'webm', 'flv',
    'mkv', 'avi', '3gp'
  };
  static const Set<String> _audioExt = {'mp3', 'aac', 'wav', 'ogg', 'm4a', 'oga'};

  /// 取 URL 中第一个精确命中的媒体扩展名（含查询串中转，如 ?url=xxx.m3u8）。
  static String? _matchExt(String lower) =>
      _mediaExtRe.firstMatch(lower)?.group(1);

  /// 由响应 MIME 推断标签（比 URL 更可信，猫爪的终判依据）。
  static String? _labelFromMime(String? mime) {
    if (mime == null || mime.isEmpty) return null;
    final m = mime.toLowerCase();
    if (m.contains('mpegurl')) return 'M3U8';
    if (m.contains('dash+xml')) return 'DASH';
    if (m.startsWith('video/') || m.startsWith('audio/')) {
      final sub = m.split('/')[1].split(';')[0].trim();
      if (sub.isEmpty) return null;
      if (sub == 'mp2t') return 'TS';
      if (sub == 'mpeg') return m.startsWith('audio/') ? 'MP3' : 'MPEG';
      return sub.toUpperCase();
    }
    return null;
  }

  /// 由 MIME 优先、URL 扩展名兜底推断展示类型标签；无法确定时回退 'OTHER'
  /// （旧版回退 'VIDEO' 是「不是视频标成视频」的根因之一）。
  static String inferTypeLabel(String url, [String? mime]) {
    final lower = url.toLowerCase();
    if (lower.startsWith('blob:')) return 'BLOB';
    if (lower.startsWith('mediasource:')) return 'MSE';
    final fromMime = _labelFromMime(mime);
    if (fromMime != null) return fromMime;
    final ext = _matchExt(lower);
    if (ext != null) return ext == 'mpd' ? 'DASH' : ext.toUpperCase();
    if (lower.contains('m3u8')) return 'M3U8';
    return 'OTHER';
  }

  /// 由 MIME 优先、URL 扩展名兜底推断媒体大类；不确定的归 other，不再乱猜。
  static MediaKind inferKind(String url, [String? mime]) {
    final lower = url.toLowerCase();
    if (lower.startsWith('blob:') || lower.startsWith('mediasource:')) {
      return MediaKind.video;
    }
    if (mime != null && mime.isNotEmpty) {
      final m = mime.toLowerCase();
      if (m.startsWith('video/') || m.contains('mpegurl') || m.contains('dash+xml')) {
        return MediaKind.video;
      }
      if (m.startsWith('audio/')) return MediaKind.audio;
    }
    final ext = _matchExt(lower);
    if (ext != null) {
      if (_videoExt.contains(ext)) return MediaKind.video;
      if (_audioExt.contains(ext)) return MediaKind.audio;
    }
    if (lower.contains('m3u8')) return MediaKind.video;
    return MediaKind.other;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SniffedMedia &&
          runtimeType == other.runtimeType &&
          url == other.url;

  @override
  int get hashCode => url.hashCode;
}

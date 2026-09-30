/// 内置媒体服务器（Jellyfin / Emby）数据模型。
///
/// 字段为两家 API 的公共子集草案，最终以真机实测返回修正；
/// 模型层保持纯数据 + （反）序列化，不含网络与存储副作用。
/// Hive 持久化采用 JSON 字符串方案（同 SubjectLinkStore 惯例）。
library;

/// 服务器类型。
enum ServerType {
  jellyfin,
  emby;

  /// 由探测返回的 ProductName 识别类型（无法识别返回 null，由上层提示手选）。
  static ServerType? fromProductName(String? productName) {
    if (productName == null) return null;
    final p = productName.toLowerCase();
    if (p.contains('jellyfin')) return ServerType.jellyfin;
    if (p.contains('emby')) return ServerType.emby;
    return null;
  }

  /// 探测兜底：实测部分服务器（Emby 4.9）的 /System/Info/Public 不返回
  /// ProductName，按版本号推断（Jellyfin 恒为 10.x，Emby 为 3.x/4.x）。
  static ServerType? fromVersion(String? version) {
    if (version == null || version.isEmpty) return null;
    return version.startsWith('10.') ? ServerType.jellyfin : ServerType.emby;
  }

  String toJson() => name;

  static ServerType fromJson(String raw) => ServerType.values.firstWhere(
        (t) => t.name == raw,
        orElse: () => ServerType.jellyfin,
      );
}

/// 规范化服务器地址：去首尾空白、无 scheme 时补 `http://`、去结尾斜杠。
///
/// 内网自建服务多为 http，故缺省补 http 而非 https；
/// https / 反代地址请显式带 scheme 输入。
String normalizeBaseUrl(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return s;
  if (!s.startsWith('http://') && !s.startsWith('https://')) {
    s = 'http://$s';
  }
  while (s.length > 1 && s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

/// 一台服务器的本地档案（Hive box `media_servers` 持久化，非敏感字段）。
class MediaServerInfo {
  final String id;

  /// 服务器类型。
  final ServerType type;

  /// 用户可见别名；默认取探测返回的 ServerName，缺省回退地址。
  final String name;

  /// 规范化后的服务地址（含 scheme、去尾斜杠），见 [normalizeBaseUrl]。
  final String baseUrl;

  /// 登录返回的 User.Id；未登录时为空串。
  final String userId;
  final String username;

  /// 服务器报告名（探测返回，展示用）。
  final String? serverName;

  /// 服务器版本（探测返回，展示用）。
  final String? version;

  const MediaServerInfo({
    required this.id,
    required this.type,
    required this.name,
    required this.baseUrl,
    this.userId = '',
    this.username = '',
    this.serverName,
    this.version,
  });

  MediaServerInfo copyWith({
    String? id,
    ServerType? type,
    String? name,
    String? baseUrl,
    String? userId,
    String? username,
    String? serverName,
    String? version,
  }) =>
      MediaServerInfo(
        id: id ?? this.id,
        type: type ?? this.type,
        name: name ?? this.name,
        baseUrl: baseUrl ?? this.baseUrl,
        userId: userId ?? this.userId,
        username: username ?? this.username,
        serverName: serverName ?? this.serverName,
        version: version ?? this.version,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'type': type.toJson(),
        'name': name,
        'baseUrl': baseUrl,
        'userId': userId,
        'username': username,
        if (serverName != null) 'serverName': serverName,
        if (version != null) 'version': version,
      };

  factory MediaServerInfo.fromJson(Map<String, dynamic> json) =>
      MediaServerInfo(
        id: json['id'] as String? ?? '',
        type: ServerType.fromJson(json['type'] as String? ?? 'jellyfin'),
        name: json['name'] as String? ?? '',
        baseUrl: json['baseUrl'] as String? ?? '',
        userId: json['userId'] as String? ?? '',
        username: json['username'] as String? ?? '',
        serverName: json['serverName'] as String?,
        version: json['version'] as String?,
      );

  /// 是否已完成登录（探测添加后、登录前 userId 为空）。
  bool get loggedIn => userId.isNotEmpty;
}

/// 探测结果（`GET /System/Info/Public` 的归一化载荷）。
///
/// 由 API 客户端层实现探测接缝时构造。
class MediaServerProbeResult {
  final ServerType type;
  final String? serverName;
  final String? version;

  const MediaServerProbeResult({
    required this.type,
    this.serverName,
    this.version,
  });
}

/// 登录结果（`POST /Users/AuthenticateByName` 的归一化载荷）。
///
/// 由 API 客户端层实现登录接缝时构造。
class MediaServerLoginResult {
  final String accessToken;
  final String userId;
  final String username;

  const MediaServerLoginResult({
    required this.accessToken,
    required this.userId,
    required this.username,
  });
}

/// 媒体库（UserViews 条目）。
class ServerLibrary {
  final String id;
  final String name;

  /// movies / tvshows / music / ...；首版只展示 movies 与 tvshows。
  final String? collectionType;

  const ServerLibrary({
    required this.id,
    required this.name,
    this.collectionType,
  });
}

/// 分页列表结果（Items 列表 / Resume 通用）。
class ServerItemPage {
  final List<ServerMediaItem> items;

  /// 服务器报告的总量（Latest 等裸数组响应时与 items.length 一致）。
  final int total;
  final int startIndex;

  const ServerItemPage({
    required this.items,
    required this.total,
    this.startIndex = 0,
  });
}

/// 媒体条目（电影 / 剧集 / 集），独立于源的 MediaItem 通用模型。
class ServerMediaItem {
  final String id;
  final String name;

  /// Movie / Series / Episode / Folder。
  final String type;
  final int? productionYear;
  final String? overview;

  /// 时长（100ns 单位，与两家 API 的 RunTimeTicks 一致）。
  final int? runTimeTicks;

  /// 以下仅 Episode 有效。
  final String? seriesName;
  final String? seriesId;
  final String? seasonId;
  final int? parentIndexNumber;
  final int? indexNumber;

  final ServerUserData? userData;

  /// 媒体容器（PlaybackInfo 协商后补全，用于直连可行性判定）。
  final String? container;

  /// 字幕轨道编码列表（来自 MediaStreams，直连播放可行性判定用）。
  final List<String>? subtitleCodecs;

  /// 是否含图形字幕（PGS / VOBSub 等）——直连无法渲染，详情页需提示。
  ///
  /// 实测：部分条目同时含 PGSSUB 与 srt/ass 文本轨——有文本轨时直连可正常
  /// 渲染字幕，仅在「纯图形字幕」（无任何文本轨）时才提示需转码。
  bool get hasGraphicSubtitle {
    final codecs = subtitleCodecs;
    if (codecs == null) return false;
    const graphic = <String>{
      'pgs', 'pgssub', 'hdmv_pgs_subtitle', 'dvd_subtitle', 'dvbsub',
      'vobsub', 'sub',
    };
    const text = <String>{
      'srt', 'subrip', 'ass', 'ssa', 'webvtt', 'vtt', 'txt', 'smi', 'sami',
    };
    final lower = codecs.map((c) => c.toLowerCase()).toSet();
    if (!lower.any(graphic.contains)) return false;
    return !lower.any(text.contains);
  }

  const ServerMediaItem({
    required this.id,
    required this.name,
    required this.type,
    this.productionYear,
    this.overview,
    this.runTimeTicks,
    this.seriesName,
    this.seriesId,
    this.seasonId,
    this.parentIndexNumber,
    this.indexNumber,
    this.userData,
    this.container,
    this.subtitleCodecs,
  });
}

/// 用户对条目的观看状态（UserData 子集）。
class ServerUserData {
  final bool played;

  /// 仅文件夹 / 剧集有效：未看数量。
  final int? unplayedItemCount;

  /// 未看完时的进度（100ns 单位）。
  final int? playbackPositionTicks;

  const ServerUserData({
    required this.played,
    this.unplayedItemCount,
    this.playbackPositionTicks,
  });
}

/// 播放方式（A1 三段决策树：直连 → 直接流 → 转码）。
enum MediaServerPlayMethod {
  directPlay,
  directStream,
  transcode;

  /// 会话上报 /Sessions/Playing 的 PlayMethod 字段值。
  String get reportName => switch (this) {
        MediaServerPlayMethod.directPlay => 'DirectPlay',
        MediaServerPlayMethod.directStream => 'DirectStream',
        MediaServerPlayMethod.transcode => 'Transcode',
      };
}

/// 媒体流信息（MediaStreams 中音轨子集，A3 音轨选择用）。
class ServerMediaStream {
  final int index;
  final String? codec;
  final String? displayTitle;
  final String? language;
  final bool isDefault;

  const ServerMediaStream({
    required this.index,
    this.codec,
    this.displayTitle,
    this.language,
    this.isDefault = false,
  });

  /// 展示名：显示标题优先，缺省回落「语言 + 编码」。
  String label() {
    if (displayTitle != null && displayTitle!.isNotEmpty) return displayTitle!;
    final parts = <String>[
      if (language != null && language!.isNotEmpty) language!,
      if (codec != null && codec!.isNotEmpty) codec!.toUpperCase(),
    ];
    return parts.isEmpty ? 'Track $index' : parts.join(' · ');
  }
}

/// 直连播放协商结果（PlaybackInfo 的归一化载荷）。
class PlaybackInfoResult {
  /// 上报 /Sessions/Playing 时随 ItemId 一起带。
  final String playSessionId;

  /// 拼好的完整播放 URL（直连 / 直接流 / 转码 HLS，均已拼 baseUrl 并附鉴权）。
  final String playUrl;

  /// 播放请求头（含 token，喂给播放器 httpHeaders）。
  final Map<String, String> headers;
  final int? runTimeTicks;
  final String? container;

  /// 本次协商选定的播放方式。
  final MediaServerPlayMethod playMethod;

  /// 可选音轨列表（转码流切音轨需带 AudioStreamIndex 重新协商）。
  final List<ServerMediaStream> audioStreams;

  /// true → 走的是转码路径（调用方按码率档位决定放行或报错）。
  bool get requiresTranscode => playMethod == MediaServerPlayMethod.transcode;

  const PlaybackInfoResult({
    required this.playSessionId,
    required this.playUrl,
    required this.headers,
    this.runTimeTicks,
    this.container,
    required this.playMethod,
    this.audioStreams = const <ServerMediaStream>[],
  });
}

/// 媒体服务器 API 异常（客户端层统一抛出）。
class MediaServerApiException implements Exception {
  final int? statusCode;
  final String? message;

  const MediaServerApiException(this.statusCode, [this.message]);

  /// 401 → UI 标「需重新登录」。
  bool get isUnauthorized => statusCode == 401;

  @override
  String toString() =>
      'MediaServerApiException(statusCode: $statusCode, message: $message)';
}

/// 播放流探针结果：用于把「无限加载」分辨为可行动的失败原因。
class MediaServerStreamProbe {
  final int statusCode;

  /// 响应 Content-Type（null = 网络错误未建立连接）。
  final String? contentType;

  /// 探针自身网络错误（连接超时 / 拒绝等，未拿到 HTTP 状态）。
  final bool networkError;

  const MediaServerStreamProbe({
    required this.statusCode,
    this.contentType,
    this.networkError = false,
  });

  /// Cloudflare / WAF 质询：403/503 + HTML 页面（播放器拿到的是网页不是视频）。
  bool get isChallenge =>
      !networkError &&
      (statusCode == 403 || statusCode == 503) &&
      (contentType ?? '').toLowerCase().contains('text/html');
}

/// Bangumi 同步数据模型（对齐 api.bgm.tv v0 OpenAPI）。
///
/// 仅保留同步链路需要的最小字段集合：条目（subject）、剧集（episode）、
/// 收藏变更 payload 与同步日志条目。
library;

/// Bangumi 收藏状态常量（v0 collection type）。
abstract final class BangumiCollectionType {
  /// 想看 / 想读。
  static const int wish = 1;

  /// 看过 / 读过。
  static const int collect = 2;

  /// 在看 / 在读。
  static const int doing = 3;

  /// 搁置。
  static const int onHold = 4;

  /// 抛弃。
  static const int dropped = 5;
}

/// 当前用户信息（GET /v0/me）。
///
/// username 为登录名（API 路径用，必须为字符串用户名而非数字 UID），
/// nickname 为展示昵称，id 为数字 UID。
class BangumiMe {
  final String username;
  final String nickname;
  final int id;

  const BangumiMe({required this.username, this.nickname = '', this.id = 0});

  /// 展示名：优先昵称，缺省回退登录名。
  String get displayName => nickname.isNotEmpty ? nickname : username;

  factory BangumiMe.fromJson(Map<String, dynamic> json) => BangumiMe(
        // 部分账号 username 可能以 JSON 数字回传（数字用户名），
        // 统一 toString 避免 `as String` 在登录解析阶段抛错。
        username: json['username']?.toString() ?? '',
        nickname: json['nickname']?.toString() ?? '',
        id: (json['id'] as num?)?.toInt() ?? 0,
      );
}

/// Bangumi 条目类型常量（v0 subject type）。
abstract final class BangumiSubjectType {
  /// 书籍（漫画 / 小说）。
  static const int book = 1;

  /// 动画。
  static const int anime = 2;

  /// 三次元（影视剧）。
  static const int real = 6;
}

/// Bangumi 条目（搜索结果 / 详情通用的简版模型）。
class BangumiSubject {
  final int id;
  final String name;
  final String nameCn;
  final int type;
  final String? date;

  /// 本篇话数（0 表示未知）。
  final int eps;

  /// 封面（grid 尺寸）。
  final String? image;

  const BangumiSubject({
    required this.id,
    required this.name,
    required this.nameCn,
    required this.type,
    this.date,
    this.eps = 0,
    this.image,
  });

  /// 优先中文名，缺省回退原名。
  String get displayName => nameCn.isNotEmpty ? nameCn : name;

  factory BangumiSubject.fromJson(Map<String, dynamic> json) {
    // 搜索接口 images 为对象，某些响应为扁平 image 字段，两者兼容。
    String? image;
    final images = json['images'];
    if (images is Map<String, dynamic>) {
      image = (images['grid'] ?? images['common'] ?? images['medium'])
          as String?;
    } else if (json['image'] is String) {
      image = json['image'] as String;
    }
    return BangumiSubject(
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: json['name'] as String? ?? '',
      nameCn: json['name_cn'] as String? ?? '',
      type: (json['type'] as num?)?.toInt() ?? 0,
      date: json['date'] as String?,
      eps: (json['eps'] as num?)?.toInt() ?? 0,
      image: image,
    );
  }
}

/// Bangumi 条目评分（GET /v0/subjects/{id} 的 rating 子对象）。
///
/// [score] 为站点平均分（0-10），[total] 为参与评分人数，
/// [rank] 为条目排名（0 表示无排名），[count] 为 1-10 分各档人数分布。
class BangumiSubjectRating {
  final double score;
  final int total;
  final int rank;
  final Map<int, int> count;

  const BangumiSubjectRating({
    this.score = 0,
    this.total = 0,
    this.rank = 0,
    this.count = const <int, int>{},
  });

  bool get hasScore => total > 0 && score > 0;

  factory BangumiSubjectRating.fromJson(Map<String, dynamic> json) {
    final rawCount = json['count'];
    final count = <int, int>{};
    if (rawCount is Map) {
      rawCount.forEach((key, value) {
        final score = int.tryParse('$key');
        final votes = (value as num?)?.toInt();
        if (score != null && votes != null) count[score] = votes;
      });
    }
    return BangumiSubjectRating(
      score: (json['score'] as num?)?.toDouble() ?? 0,
      total: (json['total'] as num?)?.toInt() ?? 0,
      rank: (json['rank'] as num?)?.toInt() ?? 0,
      count: count,
    );
  }
}

/// Bangumi 条目详情（GET /v0/subjects/{id}），供详情页展示站点评分与评价。
///
/// 仅保留展示需要的字段：评分、简介、标签（用户标签即站点「评价」侧写）。
class BangumiSubjectDetail {
  final int id;
  final String name;
  final String nameCn;
  final int type;
  final String summary;
  final String? image;
  final BangumiSubjectRating rating;

  /// 用户标签（按热度降序），最多保留前若干项供展示。
  final List<String> tags;

  const BangumiSubjectDetail({
    required this.id,
    required this.name,
    required this.nameCn,
    required this.type,
    this.summary = '',
    this.image,
    this.rating = const BangumiSubjectRating(),
    this.tags = const <String>[],
  });

  /// 优先中文名，缺省回退原名。
  String get displayName => nameCn.isNotEmpty ? nameCn : name;

  factory BangumiSubjectDetail.fromJson(Map<String, dynamic> json) {
    String? image;
    final images = json['images'];
    if (images is Map<String, dynamic>) {
      image = (images['common'] ?? images['medium'] ?? images['grid'])
          as String?;
    } else if (json['image'] is String) {
      image = json['image'] as String;
    }
    final rawTags = json['tags'];
    final tags = <String>[];
    if (rawTags is List) {
      for (final t in rawTags) {
        if (t is Map && t['name'] is String) {
          tags.add(t['name'] as String);
        } else if (t is String) {
          tags.add(t);
        }
      }
    }
    final rawRating = json['rating'];
    return BangumiSubjectDetail(
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: json['name'] as String? ?? '',
      nameCn: json['name_cn'] as String? ?? '',
      type: (json['type'] as num?)?.toInt() ?? 0,
      summary: json['summary'] as String? ?? '',
      image: image,
      rating: rawRating is Map<String, dynamic>
          ? BangumiSubjectRating.fromJson(rawRating)
          : const BangumiSubjectRating(),
      tags: tags,
    );
  }
}

/// Bangumi 剧集（仅同步需要的字段）。
class BangumiEpisode {
  final int id;

  /// 集序号（本篇内从 1 开始的 sort 值，可能为小数集，取整比较）。
  final double sort;

  /// 剧集类型：0=本篇 1=SP 2=OP 3=ED。
  final int type;

  const BangumiEpisode({
    required this.id,
    required this.sort,
    required this.type,
  });

  factory BangumiEpisode.fromJson(Map<String, dynamic> json) => BangumiEpisode(
        id: (json['id'] as num?)?.toInt() ?? 0,
        sort: (json['sort'] as num?)?.toDouble() ?? 0,
        type: (json['type'] as num?)?.toInt() ?? 0,
      );
}

/// 用户当前收藏状态（GET /v0/users/-/collections/{subject_id}
/// 与 GET /v0/users/{username}/collections 列表项共用）。
class BangumiUserCollection {
  final int subjectId;
  final int subjectType;
  final int type;
  final int rate;
  final String comment;

  /// 已看集数 / 已读章节数（书籍类条目可写）。
  final int epStatus;

  /// 已读卷数（仅书籍）。
  final int volStatus;

  /// 用户标签。
  final List<String> tags;

  /// 是否私有收藏。
  final bool isPrivate;

  /// 条目原名 / 中文名（列表接口附带 subject，单条接口为空）。
  final String subjectName;
  final String subjectNameCn;

  /// 条目封面（列表接口附带 subject.images，单条接口为空）。
  final String? subjectImage;

  /// 条目站点平均分（列表接口附带 subject.score / subject.rating.score，
  /// 0 表示无评分或单条接口未附带）。
  final double subjectScore;

  const BangumiUserCollection({
    required this.subjectId,
    required this.type,
    this.subjectType = 0,
    this.rate = 0,
    this.comment = '',
    this.epStatus = 0,
    this.volStatus = 0,
    this.tags = const <String>[],
    this.isPrivate = false,
    this.subjectName = '',
    this.subjectNameCn = '',
    this.subjectImage,
    this.subjectScore = 0,
  });

  /// 展示名：优先中文名，缺省回退原名，再缺省回退 `#id`。
  String get displayName => subjectNameCn.isNotEmpty
      ? subjectNameCn
      : (subjectName.isNotEmpty ? subjectName : '#$subjectId');

  factory BangumiUserCollection.fromJson(Map<String, dynamic> json) {
    final subject = json['subject'];
    final subjectMap =
        subject is Map<String, dynamic> ? subject : const <String, dynamic>{};

    // 封面：subject.images 的 common / medium / grid 任一。
    String? subjectImage;
    final images = subjectMap['images'];
    if (images is Map<String, dynamic>) {
      subjectImage = (images['common'] ??
          images['medium'] ??
          images['grid'] ??
          images['large']) as String?;
    }

    // 站点评分：subject.score（SlimSubject）优先，回退 subject.rating.score。
    double subjectScore = (subjectMap['score'] as num?)?.toDouble() ?? 0;
    if (subjectScore == 0) {
      final rating = subjectMap['rating'];
      if (rating is Map<String, dynamic>) {
        subjectScore = (rating['score'] as num?)?.toDouble() ?? 0;
      }
    }

    return BangumiUserCollection(
      subjectId: (json['subject_id'] as num?)?.toInt() ?? 0,
      subjectType: (json['subject_type'] as num?)?.toInt() ?? 0,
      type: (json['type'] as num?)?.toInt() ?? 0,
      rate: (json['rate'] as num?)?.toInt() ?? 0,
      comment: json['comment'] as String? ?? '',
      epStatus: (json['ep_status'] as num?)?.toInt() ?? 0,
      volStatus: (json['vol_status'] as num?)?.toInt() ?? 0,
      tags: (json['tags'] as List?)?.whereType<String>().toList() ??
          const <String>[],
      isPrivate: json['private'] as bool? ?? false,
      subjectName: subjectMap['name'] as String? ?? '',
      subjectNameCn: subjectMap['name_cn'] as String? ?? '',
      subjectImage: subjectImage,
      subjectScore: subjectScore,
    );
  }
}

/// 收藏变更 payload（POST/PATCH /v0/users/-/collections/{subject_id}）。
///
/// 所有字段均可选（null / 0 / 空不携带），支持 PATCH 部分更新。
class CollectionPayload {
  /// 收藏状态，null 表示不变更。
  final int? type;

  /// 评分 1-10，0 表示不携带。
  final int rate;

  /// 短评，null 表示不携带。
  final String? comment;

  /// 已看集 / 已读章节数（仅书籍类条目可写），null 表示不携带。
  final int? epStatus;

  /// 标签全量替换，null 表示不变更（空数组为清空）。
  final List<String>? tags;

  /// 私有收藏，null 表示不变更。
  final bool? private;

  const CollectionPayload({
    this.type,
    this.rate = 0,
    this.comment,
    this.epStatus,
    this.tags,
    this.private,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (type != null) 'type': type,
        if (rate > 0) 'rate': rate,
        if (comment != null && comment!.isNotEmpty) 'comment': comment,
        if (epStatus != null) 'ep_status': epStatus,
        if (tags != null) 'tags': tags,
        if (private != null) 'private': private,
      };
}

/// 同步日志条目状态。
enum SyncLogStatus { success, skipped, failed, pendingBind }

/// OAuth 令牌（授权码换取 / 刷新）。
///
/// [accessToken] 即后续 API 请求用的 Bearer token；
/// [refreshToken] 用于 [BangumiClient.refreshToken] 续期（Bangumi 返回 7 天有效）；
/// [expiresIn] 为有效期秒数（本地据此计算过期时刻）；
/// [scope] 为实际授予的权限范围。
class BangumiToken {
  final String accessToken;
  final String? refreshToken;
  final int? expiresIn;
  final String? scope;

  const BangumiToken({
    required this.accessToken,
    this.refreshToken,
    this.expiresIn,
    this.scope,
  });
}

/// 单条同步日志。
class SyncLogItem {
  final String title;
  final SyncLogStatus status;

  /// 附加说明（失败原因 / 跳过原因），可为空。
  final String detail;

  const SyncLogItem({
    required this.title,
    required this.status,
    this.detail = '',
  });
}

/// 小说阅读进度云同步冲突裁决（，对标 syncProgress 语义）。
///
/// 双维度比较：章节索引优先，章内字符偏移（回退页码）次之；
/// 双维度相等不覆盖任何一方（防多端回退互相覆盖）。
/// 纯函数，便于单测与在阅读器/设置页复用。
library;

/// 单条进度的冲突裁决结果。
enum ProgressConflictDecision {
  /// 本地更靠前：应上传本地覆盖云端。
  localWins,

  /// 云端更靠前：应采用云端覆盖本地。
  remoteWins,

  /// 完全一致（或维度不足）：不覆盖，维持两端。
  equal,
}

/// 某本书在某端的进度快照（参与比较的最小子集）。
class NovelProgressPoint {
  final String novelId;

  /// 章节索引（主维度）。
  final int chapterIndex;

  /// 章内字符串偏移（次维度；优先级高于 [page]）。
  final int? charOffset;

  /// 章内页码（次维度回退）。
  final int page;

  const NovelProgressPoint({
    required this.novelId,
    required this.chapterIndex,
    this.charOffset,
    this.page = 0,
  });

  int get inChapterMetric => charOffset ?? page;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'chapterIndex': chapterIndex,
        if (charOffset != null) 'charOffset': charOffset,
        'page': page,
      };

  factory NovelProgressPoint.fromJson(
    String novelId,
    Map<String, dynamic> json,
  ) {
    return NovelProgressPoint(
      novelId: novelId,
      chapterIndex: (json['chapterIndex'] as num?)?.toInt() ?? 0,
      charOffset: (json['charOffset'] as num?)?.toInt(),
      page: (json['page'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 纯函数裁决：比较本地与云端快照，返回应采用哪方。
///
/// 章节索引大者胜；同章时 `charOffset ?? page` 大者胜；完全相等 → equal。
ProgressConflictDecision decideProgressConflict({
  required NovelProgressPoint local,
  required NovelProgressPoint remote,
}) {
  if (local.chapterIndex != remote.chapterIndex) {
    return local.chapterIndex > remote.chapterIndex
        ? ProgressConflictDecision.localWins
        : ProgressConflictDecision.remoteWins;
  }
  final lm = local.inChapterMetric;
  final rm = remote.inChapterMetric;
  if (lm != rm) {
    return lm > rm ? ProgressConflictDecision.localWins : ProgressConflictDecision.remoteWins;
  }
  return ProgressConflictDecision.equal;
}
/// 小说阅读器点按九区动作（N2）。
///
/// 屏幕按 3×3 划分为九个区域，每区可配置一个动作；动作全集对齐
/// 阅读器内已有的可复用能力（菜单/翻页/翻章/朗读/书签/净化/同步等）。
/// 偏好以 9 个动作名的字符串列表持久化（行优先：0..2 第一行、3..5 中行、
/// 6..8 末行）；未配置（长度 ≠ 9）时回退旧的布局预设解析。
library;

import 'dart:ui' show Offset, Size;

/// 九区可配置动作。
enum NovelTapAction {
  /// 无操作。
  none,

  /// 呼出 / 收起菜单。
  menu,

  /// 上一页。
  prevPage,

  /// 下一页。
  nextPage,

  /// 上一章。
  prevChapter,

  /// 下一章。
  nextChapter,

  /// 加书签。
  addBookmark,

  /// 书签列表。
  bookmarkList,

  /// 目录。
  toc,

  /// 书内搜索。
  search,

  /// 朗读开 / 关。
  ttsToggle,

  /// 朗读暂停 / 继续。
  ttsPauseResume,

  /// 夜间模式。
  nightMode,

  /// 自动翻页暂停 / 继续。
  autoPagePause,

  /// 同步阅读进度（拉取云端，云端领先时确认后应用）。
  syncProgress,

  /// 正文净化（替换净化）开关快捷翻转。
  purifyToggle;

  /// 从持久化字符串解析；未知值返回 null。
  static NovelTapAction? tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    for (final v in NovelTapAction.values) {
      if (v.name == raw) return v;
    }
    return null;
  }
}

/// 经典三区布局的九区等价映射：左列上一页、中列菜单、右列下一页
/// （与旧 `ReaderTapZoneLayout.lShape` 默认行为一致）。
const List<NovelTapAction> kNovelTapZoneClassic = <NovelTapAction>[
  NovelTapAction.prevPage,
  NovelTapAction.menu,
  NovelTapAction.nextPage,
  NovelTapAction.prevPage,
  NovelTapAction.menu,
  NovelTapAction.nextPage,
  NovelTapAction.prevPage,
  NovelTapAction.menu,
  NovelTapAction.nextPage,
];

/// 由点击位置换算九区索引（行优先 0..8）。
int novelTapGridIndexOf(Offset pos, Size size) {
  final int col =
      (size.width <= 0 ? 1 : (pos.dx / size.width * 3)).clamp(0, 2).floor();
  final int row =
      (size.height <= 0 ? 1 : (pos.dy / size.height * 3)).clamp(0, 2).floor();
  return row * 3 + col;
}

/// 小说目录（TOC）的共享内存数据源（按 sourceId + novelId 维系的单一真源）。
///
/// 背景：详情页与小说阅读器各自持有目录快照、互不通知，导致「阅读器解析出的
/// 目录无法回流详情页、详情页目录不随阅读器刷新而更新」。引入本 [ChangeNotifier]
/// 作为两者共享的目录源，详情页每次更新目录都写回此处，阅读器打开目录时从此处
/// 读取「更完整」的那一份，从而实现两侧目录实时一致。
///
/// 采用「保留更长目录」语义：同 key 多次写入时，只保留章节数更多的那份，避免
/// 阅读器早期拿到的部分快照覆盖详情页渐进加载出的完整目录。
library;

import 'package:flutter/foundation.dart';

import '../models/episode.dart';

class NovelTocStore extends ChangeNotifier {
  final Map<String, List<Episode>> _cache = <String, List<Episode>>{};

  static String _key(String sourceId, String novelId) => '$sourceId|$novelId';

  /// 读取某小说的当前目录（无则空列表，调用方不应修改返回值）。
  List<Episode> chaptersFor(String sourceId, String novelId) =>
      List.unmodifiable(_cache[_key(sourceId, novelId)] ?? const <Episode>[]);

  /// 是否已缓存该小说的目录。
  bool hasChapters(String sourceId, String novelId) =>
      (_cache[_key(sourceId, novelId)]?.isNotEmpty ?? false);

  /// 写入目录；与现有目录相比章节数更多时才更新并通知，避免回退到更短的快照。
  void setChapters(String sourceId, String novelId, List<Episode> chapters) {
    final k = _key(sourceId, novelId);
    final existing = _cache[k];
    if (existing != null && existing.length >= chapters.length) return;
    _cache[k] = List<Episode>.of(chapters);
    notifyListeners();
  }
}

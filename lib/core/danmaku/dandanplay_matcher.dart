/// 弹弹play 弹幕自动匹配器。
///
/// 核心策略：优先调用官方 `/api/v2/match` 文件识别接口，直接用
/// 「番剧名 + 集标题」作为文件名匹配，返回最可能的 episodeId。
/// match 无果时回退到标题搜索 + 剧集列表选择。
library;

import '../models/episode.dart';
import '../settings/danmaku_config.dart';
import 'dandanplay_service.dart';
import 'danmaku_source.dart';

class DandanplayMatcher {
  DandanplayMatcher({required DandanplayService dandanplay})
      : _dandanplay = dandanplay;

  final DandanplayService _dandanplay;

  static DandanplayMatcher? _default;

  /// 默认实例（懒加载，使用共享弹幕配置）。
  /// 供 [BuiltinResolver] 在未显式注入 matcher 时使用。
  static DandanplayMatcher get defaultInstance {
    return _default ??= DandanplayMatcher(
      dandanplay: DandanplayService(configStore: DanmakuConfigStore()),
    );
  }

  /// 仅供测试重置默认实例。
  static void resetDefault() => _default = null;

  /// 按番剧名匹配所有剧集，返回 `{剧集索引: dandanplayEpisodeId}`。
  ///
  /// 对每个 episode 构造文件名 `番剧名 + 集标题` 调用 match；
  /// 若 match 无结果，用标题搜索 + 剧集列表映射作为兜底。
  Future<Map<int, int>> matchEpisodes(
    String title,
    List<Episode> episodes,
  ) async {
    if (title.isEmpty || episodes.isEmpty) return const <int, int>{};
    try {
      await _dandanplay.refreshAvailability();
      final map = <int, int>{};

      // 1) match 文件识别：逐集构造文件名。
      for (int i = 0; i < episodes.length; i++) {
        final fileName = _buildFileName(title, episodes[i].title);
        final matches = await _dandanplay.matchFile(fileName: fileName);
        if (matches.isNotEmpty) {
          final id = int.tryParse(matches.first.episodeId);
          if (id != null) map[i] = id;
        }
      }
      if (map.isNotEmpty) return map;

      // 2) 回退：标题搜索 → 剧集列表映射。
      return await _fallbackBySearch(title, episodes);
    } on Object {
      return const <int, int>{};
    }
  }

  /// 单集即时匹配（播放器兜底用）：用标题做 match，返回首个候选 episodeId。
  Future<int?> matchSingle(String title) async {
    if (title.isEmpty) return null;
    try {
      await _dandanplay.refreshAvailability();
      final matches = await _dandanplay.matchFile(fileName: _cleanTitle(title));
      if (matches.isNotEmpty) {
        return int.tryParse(matches.first.episodeId);
      }
      // match 无果时，搜索后取首集。
      final results = await _dandanplay.search(_cleanTitle(title));
      if (results.isEmpty) return null;
      final eps = await _dandanplay.getEpisodes(results.first.title);
      if (eps.isEmpty) return null;
      return int.tryParse(eps.first.episodeId);
    } on Object {
      return null;
    }
  }

  /// 标题搜索兜底：用番剧名搜索 → 拉剧集列表 → 按集数/标题映射。
  Future<Map<int, int>> _fallbackBySearch(
    String title,
    List<Episode> episodes,
  ) async {
    final cleaned = _cleanTitle(title);
    final results = await _dandanplay.search(cleaned);
    if (results.isEmpty) return const <int, int>{};

    final dandanEps = await _dandanplay.getEpisodes(results.first.title);
    if (dandanEps.isEmpty) return const <int, int>{};

    return _buildMapping(episodes, dandanEps);
  }

  /// 构造用于 match 的文件名：番剧名 + 集标题。
  String _buildFileName(String animeTitle, String episodeTitle) {
    final a = _cleanTitle(animeTitle);
    final e = _cleanTitle(episodeTitle);
    if (a.isEmpty && e.isEmpty) return '';
    if (a.isEmpty) return e;
    if (e.isEmpty) return a;
    return '$a $e';
  }

  /// 构建剧集索引 → dandanplayEpisodeId 映射。
  Map<int, int> _buildMapping(
    List<Episode> sourceEps,
    List<DanmakuEpisode> dandanEps,
  ) {
    final byNumber = <int, int>{};
    final byTitle = <String, int>{};
    final orderedIds = <int>[];

    for (final de in dandanEps) {
      final id = int.tryParse(de.episodeId);
      if (id == null) continue;
      orderedIds.add(id);
      if (de.episodeNumber != null) byNumber[de.episodeNumber!] = id;
      final t = _normalizeTitle(de.title);
      if (t.isNotEmpty) byTitle[t] = id;
    }

    return _mapSource(sourceEps, orderedIds, byNumber, byTitle);
  }

  Map<int, int> _mapSource(
    List<Episode> sourceEps,
    List<int> orderedIds,
    Map<int, int> byNumber,
    Map<String, int> byTitle,
  ) {
    final map = <int, int>{};

    // 1) 按集数。
    for (int i = 0; i < sourceEps.length; i++) {
      final epNum = _extractEpisodeNumber(sourceEps[i].title);
      if (epNum != null && byNumber.containsKey(epNum)) {
        map[i] = byNumber[epNum]!;
      }
    }
    if (map.isNotEmpty) return map;

    // 2) 按标题归一化。
    for (int i = 0; i < sourceEps.length; i++) {
      final t = _normalizeTitle(sourceEps[i].title);
      if (t.isNotEmpty && byTitle.containsKey(t)) {
        map[i] = byTitle[t]!;
      }
    }
    if (map.isNotEmpty) return map;

    // 3) 顺序兜底。
    if (sourceEps.length <= orderedIds.length) {
      for (int i = 0; i < sourceEps.length; i++) {
        map[i] = orderedIds[i];
      }
    }
    return map;
  }

  /// 清洗番剧标题：去除括号内容、分辨率、常见画质/来源标签，保留核心名称。
  static String _cleanTitle(String title) {
    var t = title;
    t = t.replaceAll(RegExp(r'[（(\[【][^）)\]】]*[)）\]】]'), '');
    t = t.replaceAll(RegExp(r'\b\d{3,4}[pP]\b'), '');
    t = t.replaceAll(RegExp(r'\b[4４][KkＫ]\b'), '');
    t = t.replaceAll(
      RegExp(r'(高清|双语|压制|内嵌|外挂|中字|简体|繁体|全集|合集|完结|无修|Raw|RAW)'),
      '',
    );
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t;
  }

  /// 归一化剧集标题：去除「第N集/话/回」、空白与分隔符，便于模糊比较。
  static String _normalizeTitle(String title) {
    var t = title.toLowerCase();
    t = t.replaceAll(RegExp(r'第\s*\d+\s*[集話话回]'), '');
    t = t.replaceAll(RegExp(r'[\s\-_·•]'), '');
    return t;
  }

  /// 从剧集标题中提取集数。
  ///
  /// 支持格式：`第3集` / `第3话` / `第3回` / `EP12` / `E12` / `12`。
  static int? _extractEpisodeNumber(String title) {
    final patterns = <RegExp>[
      RegExp(r'\u7B2C\s*(\d+)\s*[\u96C6\u8BDD\u56DE\u8A71]'),
      RegExp(r'[Ee][Pp]?\.?\s*(\d+)'),
      RegExp(r'^\s*(\d+)\s*$'),
    ];
    for (final p in patterns) {
      final m = p.firstMatch(title);
      if (m != null) return int.tryParse(m.group(1)!);
    }
    return null;
  }
}

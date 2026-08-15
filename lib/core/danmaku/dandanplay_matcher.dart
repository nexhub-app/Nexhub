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
      // 候选仅在服务端精确匹配（isMatched）或作品标题相似时采纳，
      // 避免弹弹play 对无对应作品的查询返回无关候选造成跨标题误匹配。
      for (int i = 0; i < episodes.length; i++) {
        final fileName = _buildFileName(title, episodes[i].title);
        final matches = await _dandanplay.matchFile(fileName: fileName);
        if (matches.isNotEmpty) {
          final candidate = matches.first;
          if (candidate.isMatched ||
              isTitleSimilar(candidate.animeTitle, title)) {
            final id = int.tryParse(candidate.episodeId);
            if (id != null) map[i] = id;
          }
        }
      }
      if (map.isNotEmpty) return map;

      // 2) 回退：标题搜索 → 剧集列表映射。
      return await _fallbackBySearch(title, episodes);
    } on Object {
      return const <int, int>{};
    }
  }

  /// 单集即时匹配（播放器兜底用）。
  ///
  /// [title] 为完整查询标题（可含集数信息）；[animeTitle] 为分离出的
  /// 作品标题（可选），用于相似度校验，未提供时退化为用 [title] 校验。
  ///
  /// 候选仅在服务端精确匹配（isMatched）或作品标题相似时采纳；
  /// 搜索回退同样要求作品标题相似，且选集按集数匹配而非盲取首集。
  /// 无法确认对应关系时返回 null（不显示弹幕）。
  ///
  /// 凭据未配置（[StateError]）时向上抛出，由调用方提示用户；
  /// 其余异常静默返回 null。
  Future<int?> matchSingle(String title, {String? animeTitle}) async {
    if (title.isEmpty) return null;
    try {
      await _dandanplay.refreshAvailability();
      final verifyTitle = (animeTitle != null && animeTitle.isNotEmpty)
          ? animeTitle
          : title;
      final matches = await _dandanplay.matchFile(fileName: _cleanTitle(title));
      if (matches.isNotEmpty) {
        final candidate = matches.first;
        if (candidate.isMatched ||
            isTitleSimilar(candidate.animeTitle, verifyTitle)) {
          return int.tryParse(candidate.episodeId);
        }
      }
      // match 无果或候选不可信：搜索回退（仅采纳标题相似的作品）。
      final cleaned = _cleanTitle(title);
      final results = await _dandanplay.search(cleaned);
      DanmakuSearchResult? similar;
      for (final r in results) {
        if (isTitleSimilar(r.title, cleaned) ||
            isTitleSimilar(r.title, _cleanTitle(verifyTitle))) {
          similar = r;
          break;
        }
      }
      if (similar == null) return null;
      final eps = await _dandanplay.getEpisodes(similar.title);
      if (eps.isEmpty) return null;
      // 选集：按标题中的集数匹配，而非盲取首集。
      final epNum = extractEpisodeNumber(title);
      if (epNum != null) {
        for (final e in eps) {
          if (e.episodeNumber == epNum) return int.tryParse(e.episodeId);
        }
        return null;
      }
      // 无集数信息：仅当剧集列表恰好只有 1 集（剧场版/电影）才取首集。
      if (eps.length == 1) return int.tryParse(eps.first.episodeId);
      return null;
    } on StateError {
      // 凭据未配置等致命错误，向上抛出。
      rethrow;
    } on Object {
      return null;
    }
  }

  /// 标题搜索兜底：用番剧名搜索 → 校验作品标题相似 → 拉剧集列表 →
  /// 按集数/标题映射。
  ///
  /// 无标题相似的搜索结果时返回空 map（不显示弹幕），
  /// 不再盲取首个搜索结果，避免跨标题误匹配。
  Future<Map<int, int>> _fallbackBySearch(
    String title,
    List<Episode> episodes,
  ) async {
    final cleaned = _cleanTitle(title);
    final results = await _dandanplay.search(cleaned);
    if (results.isEmpty) return const <int, int>{};

    DanmakuSearchResult? similar;
    for (final r in results) {
      if (isTitleSimilar(r.title, cleaned)) {
        similar = r;
        break;
      }
    }
    if (similar == null) return const <int, int>{};

    final dandanEps = await _dandanplay.getEpisodes(similar.title);
    if (dandanEps.isEmpty) return const <int, int>{};

    return _buildMapping(episodes, dandanEps);
  }

  /// 判断两个作品标题是否相似。
  ///
  /// 两侧经归一化（小写、去括号内容、去画质标签、去空白与标点）后，
  /// 相等或互相包含判为相似；任一侧归一化后为空返回 false。
  static bool isTitleSimilar(String a, String b) {
    final na = _normalizeForCompare(a);
    final nb = _normalizeForCompare(b);
    if (na.isEmpty || nb.isEmpty) return false;
    return na == nb || na.contains(nb) || nb.contains(na);
  }

  /// 标题相似度比较用的归一化：清洗 + 小写 + 去空白与标点。
  static String _normalizeForCompare(String title) {
    var t = _cleanTitle(title).toLowerCase();
    t = t.replaceAll(
      RegExp(r'''[\s\-_·•.,:;!?~/\\|+*#@&%$^()\[\]{}<>'"，。：；！？、～·…—「」『』《》〈〉“”‘’]'''),
      '',
    );
    return t;
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
      final epNum = extractEpisodeNumber(sourceEps[i].title);
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

  /// 从剧集标题中提取集数（公开供 [DanmakuRepository] 等复用）。
  ///
  /// 支持格式：`第3集` / `第3话` / `第3回` / `EP12` / `E12` / `12`。
  static int? extractEpisodeNumber(String title) {
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

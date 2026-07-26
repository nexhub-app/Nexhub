/// 书源解析器：实现 [SourceResolver]，桥接 PluginConfig →
/// XiaoshuoBookSource → WebBook，让书源能被 MediaApiService
/// 统一调度。
///
/// 触发条件：当 PluginConfig.selectors['xiaoshuo'] 为 Map 时（由
/// [ShuyuanAdapter] 写入），ResolverRegistry.find() 返回本解析器。
///
/// API 映射：
/// - `search`：WebBook.searchBook(key=vars['keyword'])
/// - `explore`/`latest`：WebBook.exploreBook / exploreCategory
/// - `detail`：WebBook.getBookInfo(bookUrl=vars['id'])
/// - `toc`/`chapters`：WebBook.getChapterList(book=by id)
/// - `content`：WebBook.getContent(chapterUrl=vars['url'])
library;

import '../../../core/models/episode.dart';
import '../../../core/models/media_item.dart';
import '../../../core/models/novel_block.dart';
import '../../../core/models/plugin_config.dart';
import '../../../core/resolver/source_resolver.dart';
import '../../../core/resolver/resolver_registry.dart';
import '../../../core/scraper/verification_detector.dart';
import '../web_book/book_list.dart';
import '../model/book_source.dart';
import '../model/search_book.dart';
import '../model/xiaoshuo_book.dart';
import '../shuyuan_adapter.dart';
import '../web_book/web_book.dart';

class ShuyuanNovelResolver implements SourceResolver, RenderedHtmlCapable {
  ShuyuanNovelResolver();

  final WebBook _webBook = WebBook();

  @override
  Future<dynamic> resolve(
    PluginConfig source,
    String apiName, {
    Map<String, String> vars = const {},
    void Function(List<dynamic>)? onProgress,
  }) async {
    final shuyuanSource = ShuyuanAdapter.fromPluginConfig(source);
    if (shuyuanSource == null) {
      throw StateError(
        'ShuyuanNovelResolver received a non-shuyuan source: ${source.id}',
      );
    }
    final bookSource = shuyuanSource.toBookSource();

    switch (apiName) {
      case 'search':
        return _handleSearch(source, bookSource, vars);
      case 'explore':
        return _handleExplore(source, bookSource, vars);
      case 'category':
        // 动态筛选 Sheet 可能发 __route='category'（被 MediaApiService 剔除后
        // 不影响源 URL）；本源 routes 不含 'category'，通常已被忽略并沿用原
        // apiName。此处兜底，避免极端情况下抛 UnsupportedError。
        return _handleExplore(source, bookSource, vars);
      case 'latest':
        return _handleLatest(source, bookSource, vars);
      case 'detail':
        return _handleDetail(source, bookSource, vars);
      case 'toc':
      case 'chapters':
        return _handleChapterList(source, bookSource, vars, onProgress: onProgress);
      case 'content':
        return _handleContent(source, bookSource, vars);
        default:
          throw UnsupportedError(
            'ShuyuanNovelResolver does not support apiName: $apiName',
          );
      }
  }

  /// 渲染后 HTML 回灌：WebView 过验证后拿回的整页 HTML 直接走 WebBook 规则解析，
  /// 不再重新发起直连请求（否则会再次撞 Cloudflare）。覆盖 search/explore/latest
  /// （列表类，用 [BookList] 解析）；detail/chapters/content 在真机极少被反爬拦截，
  /// 回退到普通直连 [resolve]（重抓），保持行为兼容。
  @override
  Future<dynamic> resolveRenderedHtml(
    PluginConfig source,
    String apiName,
    String html, {
    Map<String, String> vars = const {},
  }) async {
    final shuyuanSource = ShuyuanAdapter.fromPluginConfig(source);
    if (shuyuanSource == null) {
      throw StateError(
        'ShuyuanNovelResolver received a non-shuyuan source: ${source.id}',
      );
    }
    final bookSource = shuyuanSource.toBookSource();
    switch (apiName) {
      case 'search':
      case 'explore':
      case 'category':
      case 'latest':
        final isSearch = apiName == 'search';
        final books = BookList.analyzeBookList(
          bookSource: bookSource,
          baseUrl: bookSource.bookSourceUrl,
          body: html,
          isSearch: isSearch,
        );
        return books
            .map((sb) => _searchBookToMediaItem(sb, source.id))
            .toList();
      default:
        // detail / chapters / content：真机极少被反爬拦截（详情页/正文已可正常抓取），
        // 回退到普通直连 resolve（重抓），保持行为兼容。
        return resolve(source, apiName, vars: vars);
    }
  }

  // ── 搜索 ──
  Future<List<MediaItem>> _handleSearch(
    PluginConfig source,
    XiaoshuoBookSource bookSource,
    Map<String, String> vars,
  ) async {
    final keyword = vars['keyword'] ?? vars['key'] ?? vars['title'] ?? '';
    if (keyword.isEmpty) return <MediaItem>[];

    final page = int.tryParse(vars['page'] ?? '1') ?? 1;
    final results = await _webBook.searchBook(
      source: bookSource,
      key: keyword,
      page: page,
    );
    return results.map((sb) => _searchBookToMediaItem(sb, source.id)).toList();
  }

  // ── 发现：按分类 URL 抓取 ──
  Future<List<MediaItem>> _handleExplore(
    PluginConfig source,
    XiaoshuoBookSource bookSource,
    Map<String, String> vars,
  ) async {
    final page = int.tryParse(vars['page'] ?? '1') ?? 1;

    // PTCMS 动态筛选：源在 `filters` 中声明 文库(list)/题材(tags)/进度(finish)/
    // 字数(size)/排序(order) 五个维度。任一被选中即按站点 URL 模板拼装分类页
    // 并抓取；全空则回退到默认发现页（分类 Tab / 全量）。
    //
    // 关键：绝不能给未选维度塞默认值（否则会强制「连载 / 30万字以上 / 最新更新」
    // 等，把用户想看的「全部」也限死）。未选维度直接省略对应路径段，站点即视为
    // 不限定该维度；用户显式选「全部」(value=`all`/空) 也等同省略。
    final list = (vars['list']?.trim()) ?? '';
    final tags = (vars['tags']?.trim()) ?? '';
    final finish = _ptcmsSeg(vars['finish']);
    final size = _ptcmsSeg(vars['size']);
    final order = _ptcmsSeg(vars['order']);
    if (list.isNotEmpty ||
        tags.isNotEmpty ||
        finish != null ||
        size != null ||
        order != null) {
      final buf = StringBuffer(
          '${bookSource.bookSourceUrl}/index.php/book/category');
      if (list.isNotEmpty) buf.write('/list/$list');
      if (tags.isNotEmpty) buf.write('/tags/$tags');
      if (finish != null) buf.write('/finish/$finish');
      if (size != null) buf.write('/size/$size');
      if (order != null) buf.write('/order/$order');
      final books = await _webBook.exploreCategory(
        source: bookSource,
        categoryUrl: buf.toString(),
        page: page,
      );
      return books.map((b) => _xiaoshuoBookToMediaItem(b, source.id)).toList();
    }

    final categoryUrl = vars['category'];

    if (categoryUrl != null && categoryUrl.isNotEmpty) {
      final books = await _webBook.exploreCategory(
        source: bookSource,
        categoryUrl: categoryUrl,
        page: page,
      );
      return books.map((b) => _xiaoshuoBookToMediaItem(b, source.id)).toList();
    }

    // 没指定分类时，走全量发现页
    final books = await _webBook.exploreBook(source: bookSource, page: page);
    return books.map((b) => _xiaoshuoBookToMediaItem(b, source.id)).toList();
  }

  /// PTCMS 筛选段取值：
  /// - 未选（null）/ 选「全部」(`all`/空) → 返回 null，省略该路径段（站点视为
  ///   不限定该维度）；
  /// - 其余 → 原值（如文库 id、题材 id、finish/1|2、size/1..5、order/addtime/shits）。
  static String? _ptcmsSeg(String? raw) {
    if (raw == null) return null;
    final t = raw.trim();
    if (t.isEmpty || t == 'all') return null;
    return t;
  }

  // ── latest：等同 explore（发现页） ──
  Future<List<MediaItem>> _handleLatest(
    PluginConfig source,
    XiaoshuoBookSource bookSource,
    Map<String, String> vars,
  ) async {
    return _handleExplore(source, bookSource, vars);
  }

  // ── 详情 ──
  Future<MediaItem> _handleDetail(
    PluginConfig source,
    XiaoshuoBookSource bookSource,
    Map<String, String> vars,
  ) async {
    final id = vars['id'] ?? vars['detailUrl'] ?? '';
    if (id.isEmpty) {
      throw ArgumentError('detail requires vars["id"]');
    }
    final book = await _webBook.getBookInfo(source: bookSource, bookUrl: id);
    return _xiaoshuoBookToMediaItem(book, source.id);
  }

  // ── 章节列表 ──
  Future<List<Episode>> _handleChapterList(
    PluginConfig source,
    XiaoshuoBookSource bookSource,
    Map<String, String> vars, {
    void Function(List<dynamic>)? onProgress,
  }) async {
    final id = vars['id'] ?? vars['detailUrl'] ?? '';
    if (id.isEmpty) {
      throw ArgumentError('chapters requires vars["id"]');
    }
    // WebBook.getChapterList 需要 XiaoshuoBook 来获取 tocUrl；用 bookUrl=id 构造。
    final book = XiaoshuoBook(bookUrl: id, name: '');
    final chapters = await _webBook.getChapterList(
      source: bookSource,
      book: book,
      // 渐进批次：逐页把章节转为 Episode 后回传上层（首屏快显 + 后台续抓）。
      onBatch: (batch) {
        onProgress?.call(batch
            .map((c) => Episode(
                  id: '${c.index}',
                  title: c.title,
                  url: c.url,
                ))
            .toList());
      },
    );
    return chapters
        .map((c) => Episode(
              id: '${c.index}',
              title: c.title,
              url: c.url,
            ))
        .toList();
  }

  // ── 正文 ──
  Future<List<NovelBlock>> _handleContent(
    PluginConfig source,
    XiaoshuoBookSource bookSource,
    Map<String, String> vars,
  ) async {
    final chapterUrl = vars['url'] ?? vars['chapter'] ?? '';
    if (chapterUrl.isEmpty) {
      throw ArgumentError('content requires vars["url"]');
    }
    final result = await _webBook.getContent(
      source: bookSource,
      chapterUrl: chapterUrl,
    );
    if (result.error != null && result.blocks.isEmpty) {
      throw SourceResolveException(
        sourceId: source.id,
        apiName: 'content',
        message: result.error ?? 'resolve error',
      );
    }
    // 图文块列表（文本段 + 插图），保留解析层给出的原始顺序，
    // 供阅读器图文混排显示。
    return result.blocks;
  }

  // ── 模型转换 ──
  MediaItem _searchBookToMediaItem(SearchBook sb, String sourceId) {
    return MediaItem(
      id: sb.bookUrl,
      title: sb.name,
      coverUrl: sb.coverUrl,
      detailUrl: sb.bookUrl,
      sourceId: sourceId,
      sourceType: SourceType.novelSource,
      author: sb.author.isNotEmpty ? sb.author : null,
      tags: sb.kind
          ?.split(RegExp(r'[,\s]+'))
          .where((s) => s.trim().isNotEmpty)
          .map((s) => s.trim())
          .toList(),
    );
  }

  MediaItem _xiaoshuoBookToMediaItem(XiaoshuoBook book, String sourceId) {
    // 将引擎解析的 updateTime 字符串转为 DateTime。
    DateTime? parsedUpdatedAt;
    if (book.updateTime != null && book.updateTime!.isNotEmpty) {
      parsedUpdatedAt = _parseDateTime(book.updateTime!);
    }

    return MediaItem(
      id: book.bookUrl,
      title: book.name,
      coverUrl: book.coverUrl,
      detailUrl: book.bookUrl,
      sourceId: sourceId,
      sourceType: SourceType.novelSource,
      author: book.author.isNotEmpty ? book.author : null,
      description: book.intro,
      status: book.bookStatus,
      tags: book.kind
          ?.split(RegExp(r'[,\s]+'))
          .where((s) => s.trim().isNotEmpty)
          .map((s) => s.trim())
          .toList(),
      updatedAt: parsedUpdatedAt,
      wordCount: book.wordCount,
    );
  }

  /// 尝试将日期时间字符串解析为 [DateTime]。
  ///
  /// 支持常见中文小说站格式：
  /// - `2022-11-25 16:27:00`
  /// - `2022-11-25 16:27`
  /// - `2022-11-25`
  /// - `2022/11/25 16:27:00`
  static DateTime? _parseDateTime(String value) {
    final trimmed = value.trim();
    // 尝试标准 ISO 格式
    try {
      return DateTime.parse(trimmed);
    } catch (_) {}

    // 尝试常见中文格式：YYYY-MM-DD HH:mm:ss / YYYY/MM/DD HH:mm:ss
    // 注意：不锚定开头/结尾，以容忍 "时间：2026-05-05 16:22" 这类带前缀的文本。
    final isoLike = RegExp(r'(\d{4})[-/](\d{1,2})[-/](\d{1,2})(?:\s+(\d{1,2}):(\d{2})(?::(\d{2}))?)?');
    final m = isoLike.firstMatch(trimmed);
    if (m != null) {
      try {
        return DateTime(
          int.parse(m.group(1)!),
          int.parse(m.group(2)!),
          int.parse(m.group(3)!),
          m.group(4) != null ? int.parse(m.group(4)!) : 0,
          m.group(5) != null ? int.parse(m.group(5)!) : 0,
          m.group(6) != null ? int.parse(m.group(6)!) : 0,
        );
      } catch (_) {}
    }
    return null;
  }
}

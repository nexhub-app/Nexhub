/// 章节正文解析：依据书源 `ruleContent` 解析章节正文，支持规则替换、
/// fallback 选择器探测、广告清理与 HTML 标签剥离。
library;

import 'package:html/parser.dart' as html_parser;

import '../../../core/models/novel_block.dart';
import '../model/book_source.dart';
import '../model/xiaoshuo_book.dart';
import '../model/xiaoshuo_book_chapter.dart';
import '../analyze/analyze_rule.dart';

class BookContent {
  // 预编译正则
  static final _brRegex = RegExp(r'<br\s*/?\s*>', caseSensitive: false);
  static final _pOpenRegex = RegExp(r'<p[^>]*>');
  static final _pCloseRegex = RegExp(r'</p>');
  static final _htmlTagRegex = RegExp(r'<[^>]*>');
  // CSS flex `order` 乱序反爬检测：匹配带 style="...order:N..." 的 <p> 段落。
  static final _cssOrderPRegex = RegExp(
    r'<p[^>]*\bstyle="[^"]*\border:\s*(\d+)[^"]*"[^>]*>([\s\S]*?)</p>',
    caseSensitive: false,
  );
  static final _crlfRegex = RegExp(r'\r\n');
  static final _crRegex = RegExp(r'\r');
  static final _whitespaceRegex = RegExp(r'[ \t]+');

  // 内容选择器列表（静态常量）
  static const _contentSelectors = [
    '#content', '.chapter-content', '.read-content', '#chaptercontent',
    '.novel-content', '.content', '#BookText', '#booktext',
    '.text-content', '#content-body', '.book-content', '.article-content',
    '#chapter-content', '.chapter_text', '#txt', '.readtext',
    '.bookreadercontent', '#BookContent', '.BookContent',
    '.content-body', '#readcontent', '.nr_nr', '#nr1',
    '.readcontent', '#content_1', '#content_2', '#content1',
    '.chaptercontent', '.novelcontent', '#novelcontent',
    '.read_content', '#read_content', '.book_content',
    '#book_content', '.article-content', '#article-content',
    '.article_content', '.chapter_content', '#chapter_content',
    '.chaptertext', '#txtcontent', '.txt-content', '#txt-content',
    '.read-content', '#read-content', '.readcontent',
    '#readcontent', '.text-content', '#text-content',
    '.booktext', '#booktext', '.book-text', '#book-text',
    '.bookreader-content', '#bookreader-content',
    '.article', '#article', '.post-content', '#post-content',
    '.entry-content', '#entry-content', '.story-content',
    '#story-content', '.novel-content', '#novel-content',
    '.chapterbody', '#chapterbody', '.text-body', '#text-body',
    'div[id*="content"]', 'div[class*="content"]',
    'div[id*="Content"]', 'div[class*="Content"]',
    'div[id*="chapter"]', 'div[class*="chapter"]',
    'div[id*="Chapter"]', 'div[class*="Chapter"]',
    'div[id*="text"]', 'div[class*="text"]',
    'div[id*="Text"]', 'div[class*="Text"]',
    'div[id*="read"]', 'div[class*="read"]',
    'div[id*="Read"]', 'div[class*="Read"]',
    'div[id*="novel"]', 'div[class*="novel"]',
    'div[id*="book"]', 'div[class*="book"]',
    'main', 'article', 'section',
    '.main-content', '#main-content',
    '.page-content', '#page-content',
    '.post', '.entry', '.single-post',
  ];

  // 广告清理选择器
  static const _adSelectors = [
    'script', 'style', 'ins', 'iframe',
    '.ad', '.ads', '.adv', '.advert',
    '[id*="ad"]', '[class*="ad"]',
  ];

  // 合并后的广告选择器（预编译，单次 DOM 遍历使用）
  static final _adSelectorCombined = _adSelectors.join(',');

  // 跳过模式（预编译）
  static final _skipPatterns = [
    RegExp(r'^(首页|主页|书库|书架|排行|榜单|分类|搜索|登录|注册)'),
    RegExp(r'^(返回|回到顶部|返回顶部)'),
    RegExp(r'^(广告|推广|点击|注册|下载|APP|微信|QQ)'),
    RegExp(r'^(Copyright|ICP|备案)'),
    RegExp(r'^\d+$'),
    RegExp(r'^(>>|<<|>|<|下一页|上一页|更多)$'),
  ];

  // 广告关键词
  static const _adKeywords = [
    '广告', '推广', '点击', '注册', '登录', '充值',
    '微信', 'QQ', '群', '公众号', '小程序',
    '兴趣部', '全本小说', '免费阅读', '最新章节',
  ];

  // 整行广告关键词（仅用于"短行"匹配，避免误删正文中含常见词如"点击/微信"的段落）。
  static const int _adLineMaxLength = 40;
  static const List<String> _adLineKeywords = <String>[
    '广告', '推广', '充值', '兴趣部', '全本小说',
    '免费阅读', '最新章节', '请收藏', '手机阅读', '下载APP',
    '全文阅读', '笔趣阁', 'app下载', '安卓版',
  ];

  // 内容 fallback 选择器：当书源规则未命中或结果为空时尝试
  static const _fallbackSelectors = [
    '#content',
    '.chapter-content',
    '.read-content',
    '#chaptercontent',
    '.novel-content',
    '.content',
    '#BookText',
    '#booktext',
    '.text-content',
    '#content-body',
    '.book-content',
    '.article-content',
    '#chapter-content',
    '#readcontent',
    '.readcontent',
    '#txt',
    '.txt-content',
    '#txt-content',
    '.post-content',
    '#post-content',
    '.entry-content',
    '#entry-content',
    'article',
    'main',
  ];

  static List<NovelBlock> analyzeContent({
    required XiaoshuoBookSource bookSource,
    required XiaoshuoBook book,
    required XiaoshuoBookChapter bookChapter,
    required String baseUrl,
    required String? redirectUrl,
    required String body,
    String? nextChapterUrl,
  }) {
    final contentRule = bookSource.getContentRule();
    final analyzeRule = AnalyzeRule(book: book, chapter: bookChapter)
      ..setContent(body, redirectUrl ?? baseUrl)
      ..setBaseUrl(baseUrl)
      ..setRedirectUrl(redirectUrl ?? baseUrl);

    String content = '';

    if (contentRule.content != null && contentRule.content!.isNotEmpty) {
      content = _getContent(analyzeRule, contentRule.content!);
    }

    // 如果 primary selector 未命中或结果为空，尝试 fallback selector 列表
    if (content.trim().isEmpty) {
      content = _tryFallbackSelectors(analyzeRule);
    }

    if (content.trim().isEmpty) {
      content = _extractGenericContent(body);
    }

    // 通用反爬：还原 CSS flex `order` 乱序段落（详见 _reorderCssOrderParagraphs）。
    // 必须在 HTML 剥离(_formatContent)之前，此时 content 仍含 <p style="order:N"> 标签。
    content = _reorderCssOrderParagraphs(content);

    // 若抽取结果是 HTML（如 @html），在应用 replaceRegex 前先把 <br>/<p> 边界
    // 规整为换行，使 line-anchored 的 replaceRegex 能按行匹配导航/广告文本，
    // 表现与 @textNodes 抽取后的纯文本一致（笔趣阁多页一致性修复）。
    // 必须在 _reorderCssOrderParagraphs 之后，避免破坏 order 乱序还原所需的 <p> 标签。
    if (content.contains('<')) {
      content = content
          .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
          .replaceAll(RegExp(r'</p>', caseSensitive: false), '\n')
          .replaceAll(RegExp(r'<p[^>]*>', caseSensitive: false), '\n');
    }

    if (contentRule.replaceRegex != null && contentRule.replaceRegex!.isNotEmpty) {
      // 参考 xiaoshuo 原版 BookContent.kt：先 trim 每行，再直接应用正则替换规则
      content = content.split('\n').map((line) => line.trim()).join('\n');
      final replaceRegex = contentRule.replaceRegex!;
      final parts = replaceRegex.split('##');
      final pattern = parts[0];
      final replacement = parts.length >= 2 ? parts.sublist(1).join('##') : '';
      // 防御：空 pattern（如 replaceRegex 误以 '##' 开头 → split 后首段为空）
      // 会让 RegExp('') 在正文每个字符间插入 replacement，把正文撑成乱码。
      // 空 pattern 对任何替换都无意义，直接跳过，避免静默损毁内容。
      if (pattern.isNotEmpty) {
        try {
          // multiLine: true 让 ^...$ 锚点支持每行边界匹配，而非仅整个字符串首尾
          content = content.replaceAll(RegExp(pattern, multiLine: true), replacement);
        } catch (_) {}
      }
    }

    if (contentRule.title != null && contentRule.title!.isNotEmpty) {
      try {
        final title = analyzeRule.getString(contentRule.title!);
        if (title.isNotEmpty) {
          bookChapter.title = title;
        }
      } catch (_) {}
    }

    // 内容清洗：块级剥离 HTML + 按段提取插图 + 按段去除广告行。
    // 此前 _formatContent 会把 <img> 连同所有标签一起删掉，插图永远丢失；
    // 现在 _formatToBlocks 在剥离标签的同时把 <img> 提取为插图块（插在其
    // 相邻文本段之后），使阅读器能图文混排。图片块不参与广告行过滤。
    var blocks = _formatToBlocks(content, baseUrl, redirectUrl ?? baseUrl);
    blocks = _cleanContentAdsBlocks(blocks);

    // 添加段落缩进（仅对声明了 replaceRegex 的源，幂等处理）。
    // 先去掉行首可能存在的全角/半角缩进，再统一加一个全角空格，避免源 HTML
    // 已带首行缩进时与引擎缩进叠加（笔趣阁 #nr1@html 多页一致性修复）。
    if (contentRule.replaceRegex != null &&
        contentRule.replaceRegex!.isNotEmpty &&
        blocks.isNotEmpty) {
      blocks = _applyIndentBlocks(blocks);
    }

    return blocks;
  }

  static String _getContent(AnalyzeRule analyzeRule, String contentRule) {
    try {
      return analyzeRule.getString(contentRule, unescape: false);
    } catch (_) {
      return '';
    }
  }

  /// fallback selector 探测
  static String _tryFallbackSelectors(AnalyzeRule analyzeRule) {
    for (final selector in _fallbackSelectors) {
      try {
        final value = analyzeRule.getString(selector, unescape: false);
        if (value.trim().isNotEmpty) {
          return value;
        }
      } catch (_) {}
    }
    return '';
  }

  /// 内容广告清理（块级）：按文本段匹配广告关键词与跳过模式，删除广告文本块；
  /// 插图块原样保留（插图不是广告行）。
  static List<NovelBlock> _cleanContentAdsBlocks(List<NovelBlock> blocks) {
    final out = <NovelBlock>[];
    for (final b in blocks) {
      if (b is NovelImageBlock) {
        out.add(b);
        continue;
      }
      if (b is! NovelTextBlock) continue;
      final trimmed = b.text.trim();
      if (trimmed.isEmpty) continue;

      // 跳过导航 / 版权等整行模式（始终移除）。
      bool isAd = false;
      for (final pattern in _skipPatterns) {
        if (pattern.hasMatch(trimmed)) {
          isAd = true;
          break;
        }
      }
      if (isAd) continue;

      // 仅对"短行"做广告关键词匹配，避免正文中出现"点击/微信"等常见词被整段误删。
      if (trimmed.length <= _adLineMaxLength) {
        for (final keyword in _adLineKeywords) {
          if (trimmed.contains(keyword)) {
            isAd = true;
            break;
          }
        }
      }
      if (isAd) continue;

      out.add(b);
    }
    return out;
  }

  /// 段落缩进（幂等）：仅作用于文本块，插图块原样保留。
  ///
  /// 先去掉行首已有的全角/半角缩进，再统一加一个全角空格，避免源 HTML
  /// 已带首行缩进时与引擎缩进叠加（笔趣阁 #nr1@html 多页一致性修复）。
  static List<NovelBlock> _applyIndentBlocks(List<NovelBlock> blocks) {
    return [
      for (final b in blocks)
        if (b is NovelImageBlock)
          b
        else if (b is NovelTextBlock)
          NovelTextBlock(_indentParagraph(b.text))
        else
          b,
    ];
  }

  /// 幂等加首行缩进：去掉行首已有缩进后统一加一个全角空格。
  static String _indentParagraph(String text) {
    final stripped = text.replaceFirst(RegExp(r'^[　\s\t]+'), '');
    return '　　$stripped';
  }

  /// 还原 CSS flex `order` 乱序反爬。
  ///
  /// 部分站点（如 PTCMS 系）把正文 `<p>` 在 HTML 源码中打乱顺序，再给每个
  /// 段落设 `style="order:N"`，容器用 `display:flex;flex-direction:column`，
  /// 让浏览器在**视觉上**按 order 升序重排。直接抽取文本会得到乱序正文。
  ///
  /// 本方法是**通用能力**：仅当检测到 3 个以上带 `order:N` 的 `<p>` 段落时
  /// 才触发，按 order 升序重排后重新拼成 `<p>...</p>`，交给 [_formatContent]
  /// 继续剥离标签。对不含该模式的普通站点零副作用（直接原样返回）。
  /// 不依赖任何具体站点/域名，符合"源即插件、引擎只做通用处理"的架构。
  static String _reorderCssOrderParagraphs(String htmlContent) {
    if (htmlContent.isEmpty || !htmlContent.contains('order:')) {
      return htmlContent;
    }
    final matches = _cssOrderPRegex.allMatches(htmlContent).toList();
    if (matches.length < 3) return htmlContent; // 未命中乱序模式，原样返回
    final items = <MapEntry<int, String>>[];
    for (final m in matches) {
      final order = int.tryParse(m.group(1) ?? '');
      if (order == null) continue;
      items.add(MapEntry(order, m.group(2) ?? ''));
    }
    if (items.length < 3) return htmlContent;
    items.sort((a, b) => a.key.compareTo(b.key));
    return items.map((e) => '<p>${e.value}</p>').join('\n');
  }

  /// HTML → 图文块：剥离标签得到文本段，同时把 `<img>` 提取为插图块。
  ///
  /// 逐块（按 <br>/<p> 边界切分）处理：每块先提取内部插图（src / data-src /
  /// data-original 懒加载，拼 baseUrl 绝对化），再文本化（剥离标签 + 解码实体
  /// + 规整空白）。插图块追加在所属文本段之后，保留图文混排位置。
  /// 此前 _formatContent 用 [_htmlTagRegex] 把 <img> 连同所有标签一起删除，插图
  /// 永远丢失 —— 这是"小说阅读器看不到插图"的根因。
  static List<NovelBlock> _formatToBlocks(
    String content,
    String baseUrl,
    String redirectUrl,
  ) {
    if (content.isEmpty) return const [];

    // 先把残留的 <br>/<p> 边界规整成换行（与旧 _formatContent 一致）。
    content = content
        .replaceAll(_brRegex, '\n')
        .replaceAll(_pOpenRegex, '\n')
        .replaceAll(_pCloseRegex, '\n');

    final rawLines = content.split('\n');
    final blocks = <NovelBlock>[];
    for (final rawLine in rawLines) {
      // 1) 提取本块内插图（懒加载属性优先，回退 src）。
      final imgs = _extractImageUrls(rawLine, baseUrl, redirectUrl);
      // 2) 文本化：剥离标签 + 解码实体 + 规整空白。
      var text = rawLine.replaceAll(_htmlTagRegex, '');
      text = _decodeEntities(text);
      text = text
          .replaceAll(_crlfRegex, '\n')
          .replaceAll(_crRegex, '\n')
          .replaceAll(_whitespaceRegex, ' ')
          .trim();
      if (text.isNotEmpty) {
        blocks.add(NovelTextBlock(text));
      }
      for (final img in imgs) {
        blocks.add(NovelImageBlock(img));
      }
    }
    return blocks;
  }

  /// 从一段 HTML 中提取插图绝对 URL（按顺序）。
  ///
  /// 懒加载图常见写法 `<img src="占位.gif" data-src="真图.jpg">`，故优先取
  /// data-original / data-src / data-lazy-src，回退 src。相对路径用最终页 URL
  /// （redirectUrl）解析，避免拼到错误域名。
  static List<String> _extractImageUrls(
    String block,
    String baseUrl,
    String redirectUrl,
  ) {
    final imgTags =
        RegExp(r'<img\b[^>]*>', caseSensitive: false).allMatches(block);
    final urls = <String>[];
    for (final im in imgTags) {
      final tag = im.group(0) ?? '';
      final src = _attr(tag, 'data-original') ??
          _attr(tag, 'data-src') ??
          _attr(tag, 'data-lazy-src') ??
          _attr(tag, 'src');
      if (src == null || src.isEmpty) continue;
      final abs = _toAbsoluteUrl(src, baseUrl, redirectUrl);
      if (_looksLikeImage(abs)) urls.add(abs);
    }
    return urls;
  }

  /// 读取单个 HTML 标签属性值。
  static String? _attr(String tag, String name) {
    final m = RegExp(
      '$name=["\']([^"\']+)["\']',
      caseSensitive: false,
    ).firstMatch(tag);
    return m?.group(1);
  }

  /// 相对路径转绝对 URL：优先用最终页地址（redirectUrl），回退 baseUrl。
  static String _toAbsoluteUrl(String src, String baseUrl, String redirectUrl) {
    if (src.startsWith('http://') ||
        src.startsWith('https://') ||
        src.startsWith('data:image')) {
      return src;
    }
    final base = redirectUrl.isNotEmpty ? redirectUrl : baseUrl;
    if (base.isEmpty) return src;
    try {
      return Uri.parse(base).resolve(src).toString();
    } catch (_) {
      return src;
    }
  }

  /// 过滤明显非插图的占位图（1px 透明图、loading 动画、spacer 等）。
  static bool _looksLikeImage(String url) {
    if (url.startsWith('data:image')) return true;
    final lower = url.toLowerCase();
    if (lower.contains('1x1') ||
        lower.contains('loading') ||
        lower.contains('placeholder') ||
        lower.contains('spacer') ||
        lower.contains('pixel') ||
        lower.contains('blank')) {
      return false;
    }
    return RegExp(
      r'\.(jpe?g|png|gif|webp|avif|bmp|svg)(\?|#|$)',
    ).hasMatch(lower);
  }

  /// 解码常见 HTML 实体（与旧 _formatContent 行为一致）。
  static String _decodeEntities(String text) {
    return text
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&nbsp;', ' ');
  }

  static String _extractGenericContent(String body) {
    final document = html_parser.parse(body);

    // 一次性移除所有广告元素，避免重复操作
    _removeAdsFromDocument(document);

    String bestContent = '';
    double bestScore = 0.0;

    // 优先使用高质量选择器（前 20 个覆盖 90% 的场景）
    final prioritySelectors = _contentSelectors.take(20);

    for (final selector in prioritySelectors) {
      try {
        final el = document.querySelector(selector);
        if (el != null) {
          var text = el.text.trim();
          if (text.isNotEmpty) {
            final score = _calculateContentScoreFast(text);
            if (score > bestScore) {
              bestScore = score;
              bestContent = text;
              // 高质量内容立即返回，不继续遍历剩余 CSS 选择器
              if (bestScore >= 0.7) return bestContent;
            }
          }
        }
      } catch (_) {}
    }

    // 如果最佳内容质量不达标，尝试从 body 直接提取
    if (bestContent.isEmpty || bestScore < 0.2) {
      final bodyEl = document.querySelector('body');
      if (bodyEl != null) {
        var bodyText = _cleanBodyContent(bodyEl.text.trim());
        if (bodyText.length > bestContent.length) {
          bestContent = bodyText;
        }
      }
    }

    return bestContent;
  }

  /// DOM 广告移除
  static void _removeAdsFromDocument(dynamic document) {
    try {
      final ads = document.querySelectorAll(_adSelectorCombined);
      for (final ad in ads) {
        ad.remove();
      }
    } catch (_) {}
  }

  /// 内容评分：综合长度、中文密度、广告关键词命中
  static double _calculateContentScoreFast(String text) {
    if (text.isEmpty) return 0.0;

    final length = text.length;

    // 长度评分（权重更高）
    double lengthScore = 0.0;
    if (length >= 500) {
      lengthScore = 1.0;
    } else if (length >= 300) {
      lengthScore = 0.8;
    } else if (length >= 150) {
      lengthScore = 0.6;
    } else if (length >= 80) {
      lengthScore = 0.4;
    } else {
      lengthScore = 0.1;
    }

    // 简单的文本密度检查（使用字符串操作替代正则）
    int chineseCount = 0;
    for (int i = 0; i < text.length; i++) {
      final code = text.codeUnitAt(i);
      if (code >= 0x4e00 && code <= 0x9fa5) {
        chineseCount++;
      }
    }
    final density = chineseCount / length;
    double densityScore = 0.0;
    if (density >= 0.4) {
      densityScore = 1.0;
    } else if (density >= 0.25) {
      densityScore = 0.7;
    } else if (density >= 0.15) {
      densityScore = 0.4;
    } else {
      densityScore = 0.2;
    }

    // 简化的广告检测（只查前 100 个字符）
    final preview = text.length > 100 ? text.substring(0, 100) : text;
    int adCount = 0;
    for (final keyword in _adKeywords) {
      if (preview.contains(keyword)) {
        adCount++;
      }
    }
    double adScore = 1.0;
    if (adCount > 3) {
      adScore = 0.3;
    } else if (adCount > 1) {
      adScore = 0.7;
    }

    // 综合评分（简化算法）
    return (lengthScore * 0.5 + densityScore * 0.3 + adScore * 0.2).clamp(0.0, 1.0);
  }

  /// body 文本清洗
  static String _cleanBodyContent(String text) {
    final lines = text.split('\n');
    final cleanedLines = <String>[];

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      // 仅按跳过模式过滤；保留短行（如对话"啊。""……"），避免正文残缺。
      bool shouldSkip = false;
      for (final pattern in _skipPatterns) {
        if (pattern.hasMatch(trimmed)) {
          shouldSkip = true;
          break;
        }
      }
      if (!shouldSkip) {
        cleanedLines.add(trimmed);
      }
    }
    return cleanedLines.join('\n');
  }
}

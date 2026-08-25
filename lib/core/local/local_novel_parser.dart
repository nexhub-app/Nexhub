/// 本地小说文件解析：TXT / EPUB → 章节结构。
///
/// 仅依赖 `archive`（ZIP 解压）与 `dart:io` / `dart:convert`，
/// 不引入额外的 epub 专用库，OPF / XHTML 均以正则手动解析。
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'text_encoding.dart' show decodeTextBytes;

/// 下载器在「逐章 TXT」产物内联插图的占位行标记：行首为该标记，其后为插图
/// 的本地绝对路径（或 Android SAF 编码路径）。阅读器解析时识别此行并转为
/// 本地文件渲染。仅为本应用下载落盘约定。
const String kNexhubImgMarker = '@@NEXHUB_IMG@@';

/// 本地小说单章。
class LocalNovelChapter {
  final String title;
  final List<String> content;

  const LocalNovelChapter({required this.title, required this.content});
}

/// 本地小说整书。
class LocalNovelBook {
  final String title;
  final String? author;
  final List<LocalNovelChapter> chapters;
  final String? coverPath;

  const LocalNovelBook({
    required this.title,
    this.author,
    required this.chapters,
    this.coverPath,
  });
}

/// 本地小说解析器（TXT / EPUB）。
class LocalNovelParser {
  LocalNovelParser();

  // 章节标题正则（行首匹配）：中文「第X章/节/回/卷/部/篇/集」「卷X」、
  // 英文「Chapter N」（阿拉伯数字 / 罗马数字 / 英文拼写数字）、序章等固定名。
  // 行长上限与相邻标题间隔校验见 [splitTxtChapters]，用于过滤正文中
  // 「恰好以章节样式开头」的误判行。
  static final RegExp _chapterTitleRegex = RegExp(
    r'^\s*('
    r'第[一二三四五六七八九十百千万零〇两\d]+[章节回卷部篇集]'
    r'|卷[一二三四五六七八九十百千万零〇两\d]+'
    r'|chapter\s+(\d+|[ivxlcdm]+|one|two|three|four|five|six|seven|eight|nine'
    r'|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen'
    r'|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred)'
    r'|prologue|epilogue|preface'
    r'|序章|序言|楔子|引子|尾声|后记|番外|前言|终章|结语'
    r')',
    caseSensitive: false,
  );

  /// 标题行长度上限（字符）：超过视为正文，章节名极少长于此。
  static const int _kMaxHeadingLength = 40;

  /// 相邻章节标题的最小字符间隔：过滤正文中以章节样式开头的误判行
  /// （真章节之间通常有数千字符正文；间隔过小的命中并入前一章）。
  static const int _kMinChapterGapChars = 500;

  /// 开头无标题正文独立成「前言」章的最小长度：过短视为书名/杂项忽略。
  static const int _kPrefaceMinChars = 500;

  /// 全书无任何章节标题命中时的兜底切分块大小（字符），在段落边界切。
  static const int _kHardSplitChars = 10 * 1024;

  /// 单章最大长度（字符）：超过时按段落边界二次切分并加「(N)」序号，
  /// 防止超长章拖垮分页与渲染。
  static const int _kMaxChapterChars = 100 * 1024;

  /// 文件名书名/作者解析的四种常见命名模式（按序尝试，首个命中生效）：
  /// 「前缀《书名》…作者：xxx」「前缀《书名》后缀」「书名 作者：xxx」「书名 by xxx」。
  /// 书名取第 2 捕获组，第 1 + 3 组拼接后作为作者候选清洗。
  static final List<RegExp> _nameAuthorPatterns = <RegExp>[
    RegExp(r'(.*?)《([^《》]+)》.*?作者：(.*)'),
    RegExp(r'(.*?)《([^《》]+)》(.*)'),
    RegExp(r'(^)(.+) 作者：(.+)$'),
    RegExp(r'(^)(.+) by (.+)$'),
  ];

  /// 书名噪声：尾部「作者…」说明与「xx 著」署名。
  static final RegExp _bookNameNoiseRegex = RegExp(r'\s+作\s*者.*|\s+\S+\s+著');

  /// 作者噪声：「作者：」类前缀与「著」署名尾缀。
  static final RegExp _bookAuthorNoiseRegex =
      RegExp(r'^\s*作\s*者[:：\s]+|\s+著');

  /// 「XX 著」署名提取（用于无显式作者标记的《书名》后缀形态）。
  static final RegExp _signatureAuthorRegex =
      RegExp(r'([^\s《》]{1,24})\s*著\s*$');

  static String _formatBookName(String raw) =>
      raw.replaceAll(_bookNameNoiseRegex, '').trim();

  static String _formatBookAuthor(String raw) =>
      raw.replaceAll(_bookAuthorNoiseRegex, '').trim();

  /// 从文件名自动解析书名与作者。
  ///
  /// 先截掉最后一个 `.` 之后的部分（扩展名），再按序尝试
  /// [_nameAuthorPatterns]，命中时书名 = 第 2 捕获组：
  /// - 带显式作者标记的模式（`作者：` / ` by `）：作者取标记后的文本清洗；
  /// - 无标记的《书名》形态：仅当后缀以「XX 著」署名结尾时提取作者；
  /// 全部未命中时书名为整名清洗结果，作者取移除书名后的剩余文本清洗结果
  /// （无剩余则为 null）。返回 `(name:, author:)` 记录，`name` 保证非空、
  /// `author` 可空。
  static ({String name, String? author}) analyzeNameAuthor(String fileName) {
    final dot = fileName.lastIndexOf('.');
    final base = dot > 0 ? fileName.substring(0, dot) : fileName;
    for (var i = 0; i < _nameAuthorPatterns.length; i++) {
      final m = _nameAuthorPatterns[i].firstMatch(base);
      if (m == null) continue;
      final name = (m.group(2) ?? '').trim();
      if (name.isEmpty) continue;
      String? author;
      if (i == 1) {
        // 无标记的《书名》后缀形态：《书名》(标注) 或 《书名》XX著。
        author = _signatureAuthorRegex
            .firstMatch((m.group(3) ?? '').trim())
            ?.group(1);
      } else {
        author = _formatBookAuthor(m.group(3) ?? '');
      }
      return (
        name: name,
        author: (author == null || author.isEmpty) ? null : author,
      );
    }
    final name = _formatBookName(base);
    if (name.isEmpty) return (name: base.trim(), author: null);
    final rest = base.replaceFirst(name, '');
    final author = rest == base ? '' : _formatBookAuthor(rest);
    return (name: name, author: author.isEmpty ? null : author);
  }

  /// 解析 TXT 文件。
  ///
  /// 自动嗅探编码（UTF-8 / GBK / UTF-16）读取；章节切分见
  /// [splitTxtChapters]（逐行扫描，不依赖空行分段）。
  static Future<LocalNovelBook> parseTxt(String filePath) async {
    final file = File(filePath);
    final bytes = await file.readAsBytes();
    var text = decodeTextBytes(bytes);
    // 去除可能的 UTF-8 BOM
    if (text.startsWith('\uFEFF')) text = text.substring(1);
    // 统一换行符为 \n
    text = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

    final parsedName = analyzeNameAuthor(p.basename(filePath));

    return LocalNovelBook(
      title: parsedName.name,
      author: parsedName.author,
      chapters: splitTxtChapters(text, fallbackTitle: parsedName.name),
    );
  }

  /// TXT 章节切分（纯函数，输入须已统一换行符为 `\n`）。
  ///
  /// 逐行扫描而非按空行分段：段落间仅以单个换行分隔的文件（网页抓取
  /// TXT 常见）也能正确分章，不会整本塌成一章。标题行须同时满足：
  /// 非空、长度 ≤ [_kMaxHeadingLength]、命中 [_chapterTitleRegex]、
  /// 与上一个标题间隔 ≥ [_kMinChapterGapChars]。
  ///
  /// - 首个标题前的正文 ≥ [_kPrefaceMinChars] 时独立为「前言」章；
  /// - 全书零标题命中 → 按 [_kHardSplitChars] 在段落边界兜底硬切
  ///   （总量不足两块时保持整本单章，标题用 [fallbackTitle]）；
  /// - 超过 [_kMaxChapterChars] 的章按段落边界二次切分，命名「标题(N)」。
  static List<LocalNovelChapter> splitTxtChapters(
    String text, {
    required String fallbackTitle,
  }) {
    final lines = text.split('\n');

    // 第一遍：收集通过全部校验的标题行（行号 + 字符偏移）。
    final headingLine = <int>[];
    final headingOffset = <int>[];
    var offset = 0;
    for (var i = 0; i < lines.length; i++) {
      final raw = lines[i];
      final t = raw.trim();
      if (t.isNotEmpty &&
          t.length <= _kMaxHeadingLength &&
          _chapterTitleRegex.hasMatch(t) &&
          (headingOffset.isEmpty ||
              offset - headingOffset.last >= _kMinChapterGapChars)) {
        headingLine.add(i);
        headingOffset.add(offset);
      }
      offset += raw.length + 1;
    }

    final chapters = <LocalNovelChapter>[];

    if (headingLine.isEmpty) {
      // 兜底硬切：无任何标题 → 按固定粒度在段落（行）边界切分。
      final paras = _parasInRange(lines, 0, lines.length);
      if (paras.isEmpty) {
        return <LocalNovelChapter>[
          LocalNovelChapter(title: fallbackTitle, content: const <String>['']),
        ];
      }
      if (_totalLen(paras) <= _kHardSplitChars * 2) {
        // 总量过小保持整本单章（与旧行为一致，避免短文被无意义拆碎）。
        return <LocalNovelChapter>[
          LocalNovelChapter(title: fallbackTitle, content: paras),
        ];
      }
      var seq = 0;
      var buf = <String>[];
      var bufLen = 0;
      for (final para in paras) {
        buf.add(para);
        bufLen += para.length;
        if (bufLen >= _kHardSplitChars) {
          seq++;
          chapters.add(LocalNovelChapter(
              title: '第 $seq 部分', content: List<String>.from(buf)));
          buf = <String>[];
          bufLen = 0;
        }
      }
      if (buf.isNotEmpty) {
        seq++;
        chapters.add(LocalNovelChapter(
            title: '第 $seq 部分', content: List<String>.from(buf)));
      }
      return chapters;
    }

    // 第二遍：按标题行切分章节。
    // 首个标题前的开头内容：足够长则独立为「前言」，过短（书名/空行）忽略。
    final lead = _parasInRange(lines, 0, headingLine.first);
    if (_totalLen(lead) >= _kPrefaceMinChars) {
      chapters.add(LocalNovelChapter(title: '前言', content: lead));
    }
    for (var k = 0; k < headingLine.length; k++) {
      final start = headingLine[k] + 1;
      final end = k + 1 < headingLine.length
          ? headingLine[k + 1]
          : lines.length;
      final paras = _parasInRange(lines, start, end);
      chapters.add(LocalNovelChapter(
        title: lines[headingLine[k]].trim(),
        content: paras.isEmpty ? const <String>[''] : paras,
      ));
    }

    // 超长章节二次切分：按段落边界切成 ~[_kMaxChapterChars]/2 块，「标题(N)」。
    final result = <LocalNovelChapter>[];
    for (final ch in chapters) {
      if (_totalLen(ch.content) <= _kMaxChapterChars) {
        result.add(ch);
        continue;
      }
      final target = _kMaxChapterChars ~/ 2;
      var part = 0;
      var buf = <String>[];
      var bufLen = 0;
      for (final para in ch.content) {
        buf.add(para);
        bufLen += para.length;
        if (bufLen >= target) {
          part++;
          result.add(LocalNovelChapter(
              title: '${ch.title}($part)',
              content: List<String>.from(buf)));
          buf = <String>[];
          bufLen = 0;
        }
      }
      if (buf.isNotEmpty) {
        part++;
        result.add(LocalNovelChapter(
            title: '${ch.title}($part)', content: List<String>.from(buf)));
      }
    }
    return result;
  }

  /// 取行区间 [start, end) 内的非空行作为段落（每行一段）。
  static List<String> _parasInRange(List<String> lines, int start, int end) {
    return <String>[
      for (var i = start; i < end; i++)
        if (lines[i].trim().isNotEmpty) lines[i].trim(),
    ];
  }

  static int _totalLen(List<String> paras) =>
      paras.fold<int>(0, (sum, p) => sum + p.length);

  /// 「卷/部」级标题判定（目录智能分卷分组用）：命中的章节标题作为其后
  /// 各章的分节名，直到下一个卷级标题。覆盖中文「第X卷/部」「卷X」与
  /// 英文 Volume/Vol./Part + 数字（罗马/阿拉伯）。
  static final RegExp _volumeTitleRegex = RegExp(
    r'^\s*('
    r'第[一二三四五六七八九十百千万零〇两\d]+[卷部](?![章节回])'
    r'|卷[一二三四五六七八九十百千万零〇两\d]+'
    r'|(volume|vol\.?|part)\s+(\d+|[ivxlcdm]+)'
    r')',
    caseSensitive: false,
  );

  /// 判断章节标题是否为卷级标题（见 [_volumeTitleRegex]）。
  static bool isVolumeTitle(String title) =>
      title.trim().length <= 40 && _volumeTitleRegex.hasMatch(title);

  /// 解析 EPUB 文件。
  ///
  /// 用 archive 解压后：经 META-INF/container.xml 定位 .opf 根文件，
  /// 从中读取 metadata（title/author）与 spine 阅读顺序，
  /// 依次解析每章 XHTML 正文（去标签、解码实体、按段落分割）。
  static Future<LocalNovelBook> parseEpub(String filePath) async {
    final file = File(filePath);
    final bytes = await file.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);

    // 建立文件名索引（仅文件，跳过目录项）
    final fileMap = <String, ArchiveFile>{};
    for (final f in archive) {
      if (f.isFile) fileMap[f.name] = f;
    }

    String readText(String name) {
      final f = fileMap[name];
      if (f == null) return '';
      final data = f.content;
      if (data is! List<int>) return '';
      return utf8.decode(data, allowMalformed: true);
    }

    // 1. 通过 META-INF/container.xml 定位 .opf 根文件
    final containerXml = readText('META-INF/container.xml');
    final opfMatch =
        RegExp(r'full-path="([^"]+\.opf)"').firstMatch(containerXml);
    final opfPath = (opfMatch?.group(1) ?? '').isNotEmpty
        ? opfMatch!.group(1)!
        : 'OEBPS/content.opf'; // 兜底

    final opfXml = readText(opfPath);
    final opfDir = p.dirname(opfPath);

    // 2. 解析 metadata：title / author（元数据缺失时回退文件名自动解析）。
    final fallbackName = analyzeNameAuthor(p.basename(filePath));
    var bookTitle = fallbackName.name;
    String? author = fallbackName.author;
    final titleMatch =
        RegExp(r'<dc:title[^>]*>([^<]*)</dc:title>', caseSensitive: false)
            .firstMatch(opfXml);
    if (titleMatch != null && titleMatch.group(1)!.trim().isNotEmpty) {
      bookTitle = titleMatch.group(1)!.trim();
    }
    final authorMatch =
        RegExp(r'<dc:creator[^>]*>([^<]*)</dc:creator>', caseSensitive: false)
            .firstMatch(opfXml);
    if (authorMatch != null && authorMatch.group(1)!.trim().isNotEmpty) {
      author = authorMatch.group(1)!.trim();
    }

    // 3. 解析 manifest：id → href，并标记导航文档（目录）
    final manifest = <String, String>{};
    final navIds = <String>{};
    // 文件名疑似目录页、需用内容探测二次确认的候选（id → href）
    final navNameCandidates = <String, String>{};
    final itemTagRegex = RegExp(r'<item\b[^>]*/?>');
    for (final m in itemTagRegex.allMatches(opfXml)) {
      final tag = m.group(0)!;
      final idM = RegExp(r'\bid="([^"]+)"').firstMatch(tag);
      final hrefM = RegExp(r'\bhref="([^"]+)"').firstMatch(tag);
      if (idM == null || hrefM == null) continue;
      final id = idM.group(1)!;
      final href = hrefM.group(1)!.split('#').first;
      manifest[id] = href;

      // 导航文档（目录）不计入正文，避免「目录列表」混入阅读内容。识别维度：
      // - EPUB3：manifest 项 `properties="nav"`；
      // - EPUB2：`toc.ncx`（NCX 导航文件，可能被不规范地放进 spine）；
      // - EPUB3：`epub:type` 含 `toc` / `landmarks`（比 properties 更权威的标识）；
      // - 文件名形似 toc/nav/contents 的视觉目录页（Word/Sigil/Calibre 常生成且
      //   未标注 properties="nav"），需用内容探测二次确认，避免误伤正文章节。
      final propsM =
          RegExp(r'\bproperties="([^"]+)"', caseSensitive: false).firstMatch(tag);
      final epubTypeM =
          RegExp(r'\bepub:type="([^"]+)"', caseSensitive: false).firstMatch(tag);
      final epubType = epubTypeM?.group(1)?.toLowerCase() ?? '';
      final lowerHref = href.toLowerCase();

      var isNav = false;
      if (propsM != null && propsM.group(1)!.toLowerCase().contains('nav')) {
        isNav = true;
      }
      if (lowerHref.endsWith('.ncx')) isNav = true;
      if (epubType.contains('toc') || epubType.contains('landmarks')) {
        isNav = true;
      }
      if (RegExp(r'(^|/)(toc|nav|contents|table[-_]?of[-_]?contents)\b',
              caseSensitive: false)
          .hasMatch(lowerHref)) {
        if (isNav) {
          navIds.add(id);
        } else {
          navNameCandidates[id] = href;
        }
      } else if (isNav) {
        navIds.add(id);
      }
    }

    // 内容探测：确认文件名似目录的候选确为链接列表型目录页，才纳入 navIds。
    for (final entry in navNameCandidates.entries) {
      final candidatePath = opfDir.isEmpty || opfDir == '.'
          ? entry.value
          : '$opfDir/${entry.value}';
      final html = readText(candidatePath);
      if (_looksLikeNavDoc(html)) navIds.add(entry.key);
    }

    // 4. 解析 spine 顺序：idref 列表
    final spineOrder = <String>[];
    final itemrefTagRegex = RegExp(r'<itemref\b[^>]*/?>');
    for (final m in itemrefTagRegex.allMatches(opfXml)) {
      final tag = m.group(0)!;
      final idrefM = RegExp(r'\bidref="([^"]+)"').firstMatch(tag);
      if (idrefM != null) spineOrder.add(idrefM.group(1)!);
    }

    // 拼接 opf 所在目录与 href（EPUB 路径统一用 /）
    String resolvePath(String href) {
      if (opfDir.isEmpty || opfDir == '.') return href;
      return '$opfDir/$href';
    }

    final chapters = <LocalNovelChapter>[];

    // 优先用 EPUB 自带目录（nav.xhtml / toc.ncx）驱动章节切分：
    // 标题与顺序更权威，且天然排除目录页本身，避免「目录列表」混入正文。
    // 收集导航文档 href：manifest 声明的优先；未声明则在压缩包内兜底搜寻。
    final navHrefs = <String>[];
    for (final id in navIds) {
      final href = manifest[id];
      if (href != null) navHrefs.add(href);
    }
    if (navHrefs.isEmpty) {
      for (final name in fileMap.keys) {
        final lower = name.toLowerCase();
        final nameMatch = lower.endsWith('.ncx') ||
            RegExp(r'(^|/)(nav|toc|contents|table[-_]?of[-_]?contents)\.x?html?$')
                .hasMatch(lower);
        if (!nameMatch) continue;
        final html = readText(name);
        if (lower.endsWith('.ncx') || _looksLikeNavDoc(html)) {
          navHrefs.add(name);
        }
      }
    }
    final toc = _parseEpubToc(opfDir, navHrefs, readText);

    // 按目标文件分组（忽略 #fragment），供目录标题增强使用。
    final byFile = <String, List<(String, String?)>>{};
    if (toc.isNotEmpty) {
      for (final (title, href) in toc) {
        final hash = href.indexOf('#');
        final file = hash >= 0 ? href.substring(0, hash) : href;
        final frag = hash >= 0 ? href.substring(hash + 1) : '';
        byFile.putIfAbsent(file, () => []).add((title, frag.isEmpty ? null : frag));
      }
    }

    // 导航文档的 href 集合（二次排除，避免「目录列表」混入正文）。
    final navHrefSet = <String>{};
    for (final id in navIds) {
      final href = manifest[id];
      if (href != null) navHrefSet.add(href.split('#').first);
    }

    // 统一切分：以文件内标题(h1-h6 / chapter 类)为主切分依据，
    // 目录条目仅做「标题增强」。即使目录退化（仅 1 条或缺失），也能按正文标题
    // 正常分章，杜绝「整本只有一章」。
    final processed = <String>{};
    void processFile(String file, List<(String, String?)>? entries) {
      if (processed.contains(file)) return;
      processed.add(file);
      if (navHrefSet.contains(file)) return;
      final html = readText(resolvePath(file));
      if (html.isEmpty) return;
      if (_looksLikeNavDoc(html)) return; // 兜底排除视觉目录页
      final fileChapters = _splitContentFile(html, entries);
      if (fileChapters.isEmpty) {
        // 该文件整体无正文/无切分点：若全书尚无章节，给一章占位，避免 0 章。
        if (chapters.isEmpty) {
          final paras = _extractParagraphs(html);
          chapters.add(LocalNovelChapter(
            title: p.basenameWithoutExtension(file),
            content: paras.isEmpty ? const [''] : paras,
          ));
        }
        return;
      }
      chapters.addAll(fileChapters);
    }

    // 先按 spine 顺序（保证阅读顺序），再补上目录引用但不在 spine 的文件。
    for (final idref in spineOrder) {
      if (navIds.contains(idref)) continue;
      final href = manifest[idref];
      if (href == null) continue;
      final file = href.split('#').first;
      processFile(file, byFile[file]);
    }
    for (final file in byFile.keys) {
      processFile(file, byFile[file]);
    }

    return LocalNovelBook(
      title: bookTitle,
      author: author,
      chapters: chapters,
    );
  }

  /// 从 EPUB 压缩包提取封面图（bug 115），返回落盘缓存路径；失败返回 null。
  ///
  /// 优先级：OPF `<meta name="cover" content="ID"/>` 指向的 manifest 图片 →
  /// manifest 中名称含 `cover` 的图片 → 压缩包内第一张图片。
  static Future<String?> extractCover(String filePath) async {
    try {
      final file = File(filePath);
      if (!file.existsSync()) return null;
      final bytes = await file.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      final fileMap = <String, ArchiveFile>{};
      for (final f in archive) {
        if (f.isFile) fileMap[f.name] = f;
      }
      String readText(String name) {
        final f = fileMap[name];
        if (f == null) return '';
        final data = f.content;
        if (data is! List<int>) return '';
        return decodeTextBytes(data);
      }

      final containerXml = readText('META-INF/container.xml');
      final opfMatch =
          RegExp(r'full-path="([^"]+\.opf)"').firstMatch(containerXml);
      final opfPath = (opfMatch?.group(1) ?? '').isNotEmpty
          ? opfMatch!.group(1)!
          : 'OEBPS/content.opf';
      final opfXml = readText(opfPath);
      final opfDir = p.dirname(opfPath);

      String? coverId;
      final metaTag = RegExp(r'<meta\b[^>]*name="cover"[^>]*/?>',
              caseSensitive: false)
          .firstMatch(opfXml);
      if (metaTag != null) {
        final c = RegExp(r'content="([^"]+)"', caseSensitive: false)
            .firstMatch(metaTag.group(0)!);
        if (c != null) coverId = c.group(1);
      }

      final manifest = <String, String>{};
      for (final m in RegExp(r'<item\b[^>]*/?>').allMatches(opfXml)) {
        final tag = m.group(0)!;
        final idM = RegExp(r'\bid="([^"]+)"').firstMatch(tag);
        final hrefM = RegExp(r'\bhref="([^"]+)"').firstMatch(tag);
        if (idM != null && hrefM != null) {
          manifest[idM.group(1)!] = hrefM.group(1)!.split('#').first;
        }
      }

      String? coverHref;
      if (coverId != null && manifest.containsKey(coverId)) {
        coverHref = manifest[coverId];
      } else {
        for (final entry in manifest.entries) {
          final href = entry.value.toLowerCase();
          if (href.contains('cover') &&
              RegExp(r'\.(jpe?g|png|gif|webp|bmp)$').hasMatch(href)) {
            coverHref = entry.value;
            break;
          }
        }
      }
      if (coverHref == null) {
        for (final f in archive.files) {
          if (!f.isFile) continue;
          final lower = f.name.toLowerCase();
          if (RegExp(r'\.(jpe?g|png|gif|webp|bmp)$').hasMatch(lower) &&
              !lower.contains('icon')) {
            coverHref = f.name;
            break;
          }
        }
      }
      if (coverHref == null) return null;

      String resolvePath(String href) {
        if (opfDir.isEmpty || opfDir == '.') return href;
        return '$opfDir/$href';
      }

      final coverFile = fileMap[resolvePath(coverHref)];
      if (coverFile == null || coverFile.content is! List<int>) return null;
      final data = coverFile.content as List<int>;
      final ext = p.extension(coverHref).toLowerCase();
      final tmp = await getTemporaryDirectory();
      final dir = Directory(p.join(tmp.path, 'nexhub_epub_covers'));
      await dir.create(recursive: true);
      final out = File(p.join(dir.path, '${filePath.hashCode}$ext'));
      await out.writeAsBytes(data);
      return out.path;
    } catch (_) {
      return null;
    }
  }

  /// 解析单个内容文件为章节列表（统一切分）。
  ///
  /// 切分依据（并集，保证粒度）：
  ///  - 文件内标题标签（h1-h6）及 class 含 chapter/part 的 p/div；
  ///  - 若 [tocEntries] 非空，额外用目录条目（锚点 / 标题文字定位）增强标题。
  ///
  /// 即使 [tocEntries] 退化（仅 1 条或缺失），只要文件内有标题就能正常分章；
  /// 既无标题也无目录时，整文件作为单章返回（标题取首个目录条目或文件名）。
  static List<LocalNovelChapter> _splitContentFile(
    String html,
    List<(String, String?)>? tocEntries,
  ) {
    final headingCuts = _headingCuts(html); // [(offset, title)] 按偏移升序

    if (headingCuts.isEmpty) {
      // 无正文标题 → 整文件作为单章；标题优先用首个有效目录条目。
      final paras = _extractParagraphs(html);
      var title = '未命名章节';
      if (tocEntries != null && tocEntries.isNotEmpty) {
        final t = tocEntries.first.$1.trim();
        if (t.isNotEmpty && !_isNavLabel(t)) title = t;
      }
      return [LocalNovelChapter(title: title, content: paras)];
    }

    final offsets = headingCuts.map((c) => c.$1).toList();
    final boundaries = <int>[...offsets, html.length];
    final chaptersByIndex =
        List<LocalNovelChapter?>.filled(offsets.length, null);
    for (var i = 0; i < offsets.length; i++) {
      final seg = html.substring(offsets[i], boundaries[i + 1]);
      final paras = _extractParagraphs(seg);
      if (paras.isEmpty) continue;
      // 去除与标题重复的首段（标题标签文本会随正文被一并提出）。
      if (paras.first.trim() == headingCuts[i].$2) paras.removeAt(0);
      if (paras.isEmpty) continue;
      chaptersByIndex[i] =
          LocalNovelChapter(title: headingCuts[i].$2, content: paras);
    }

    // 用目录条目增强标题：把每个条目定位到最近段落，覆盖其标题（更权威）。
    if (tocEntries != null) {
      for (final e in tocEntries) {
        final title = e.$1.trim();
        if (title.isEmpty || _isNavLabel(title)) continue;
        final pos = _locateTocEntry(html, title, e.$2);
        if (pos < 0) continue;
        for (var i = 0; i < offsets.length; i++) {
          if (pos >= offsets[i] && pos < boundaries[i + 1]) {
            final existing = chaptersByIndex[i];
            if (existing != null) {
              chaptersByIndex[i] =
                  LocalNovelChapter(title: title, content: existing.content);
            }
            break;
          }
        }
      }
    }

    return chaptersByIndex.whereType<LocalNovelChapter>().toList();
  }

  /// 返回文件内标题切分点（文档偏移, 标题文本），按偏移升序。
  ///
  /// 覆盖 h1-h6 标题标签，以及 class 含 chapter/part 的 p/div（网络小说 EPUB
  /// 常用 `<p class="chapter">` 等非标题标签承载章节名）。
  static List<(int, String)> _headingCuts(String html) {
    final cuts = <(int, String)>[];
    for (final m in RegExp(r'<h([1-6])[^>]*>([\s\S]*?)</h\1>',
            caseSensitive: false)
        .allMatches(html)) {
      final t = _stripTags(m.group(2)!).trim();
      if (t.isNotEmpty) cuts.add((m.start, t));
    }
    for (final m in RegExp(
      r'<(p|div)\b[^>]*\s+class\s*=\s*["\x27][^>]*?(?:chapter|part)[^>]*?["\x27][^>]*>([\s\S]*?)</\1>',
      caseSensitive: false,
    ).allMatches(html)) {
      final t = _stripTags(m.group(2)!).trim();
      if (t.isNotEmpty) cuts.add((m.start, t));
    }
    // 兜底：普通 `<p>` 章节标题（在线小说 EPUB 常把「第N章 标题」写成无样式的
    // 普通段落）→ 首行命中章节标题正则且较短者作为切分点。
    // 注意：**文件已有 <h1-6> 标题时跳过 <p> 兜底**——我们下载器生成的每章
    // xhtml 是 `<h1>第N章</h1><p>第N章正文。</p>`，`<p>` 首行「第N章正文。」
    // 会被章节标题正则误判成第二个切分点，导致整章被切碎、去重后全空
    // （表现：多章 EPUB 只解析出 1 章占位，章节列表无法显示）。
    if (cuts.isEmpty) {
      for (final m in RegExp(
              r'<p\b[^>]*>([\s\S]*?)</p>', caseSensitive: false)
          .allMatches(html)) {
        final t = _stripTags(m.group(1)!).trim();
        if (t.isEmpty || t.length > 40) continue;
        final firstLine = t.split('\n').first.trim();
        if (_chapterTitleRegex.hasMatch(firstLine)) cuts.add((m.start, t));
      }
    }
    cuts.sort((a, b) => a.$1.compareTo(b.$1));
    return cuts;
  }

  /// 在文件内定位目录条目的偏移：优先锚点(fragment)，其次标题文字位置。
  static int _locateTocEntry(String html, String title, String? frag) {
    if (frag != null && frag.isNotEmpty) {
      final fm = RegExp(r'\b(?:id|name)=["\x27]' +
              RegExp.escape(frag) +
              r'["\x27]',
              caseSensitive: false)
          .firstMatch(html);
      if (fm != null) return fm.start;
    }
    final idx = html.toLowerCase().indexOf(title.toLowerCase());
    return idx;
  }

  /// 判断目录条目标题是否为「目录页本身」的标签（如 目录 / contents）。
  static bool _isNavLabel(String title) {
    final t = title.toLowerCase().trim();
    return t == '目录' ||
        t == 'contents' ||
        t == 'table of contents' ||
        t == '目次';
  }

  /// 将一段正文按空行分段、段内换行合并、去空白。
  static List<String> _splitParas(String body) {
    return body
        .split(RegExp(r'\n\s*\n'))
        .map((s) => s.replaceAll(RegExp(r'[\r\n]+'), '').trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  /// 去除所有 HTML 标签。
  static String _stripTags(String s) =>
      s.replaceAll(RegExp(r'<[^>]+>'), '');

  /// 解码常见 HTML 实体（&amp; 最后处理，避免误解析）。
  static String _decodeEntities(String s) {
    return s
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAllMapped(
            RegExp(r'&#x([0-9a-fA-F]+);'),
            (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)))
        .replaceAllMapped(
            RegExp(r'&#(\d+);'),
            (m) => String.fromCharCode(int.parse(m.group(1)!)))
        .replaceAll('&amp;', '&');
  }

  /// 提取单文件全部正文段落（不按标题切分），供目录驱动的单章/整文件使用。
  static List<String> _extractParagraphs(String html) {
    var body = html;
    body = body.replaceAll(
        RegExp(r'<head\b[\s\S]*?</head>', caseSensitive: false), '');
    body = body.replaceAll(
        RegExp(r'<script\b[\s\S]*?</script>', caseSensitive: false), '');
    body = body.replaceAll(
        RegExp(r'<style\b[\s\S]*?</style>', caseSensitive: false), '');
    body = body.replaceAll(
        RegExp(r'</(p|div|section|article|li|blockquote)\s*>',
            caseSensitive: false),
        '\n\n');
    body = body.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
    body = _decodeEntities(_stripTags(body));
    return _splitParas(body);
  }

  /// 内容探测：判断一个文件是否为「链接列表型目录页」（视觉目录页）。
  ///
  /// 命中条件：含 EPUB3 toc 型 `<nav>`，或正文以大量短链接为主、几乎没有散文。
  /// 用于把文件名疑似目录、但未在 manifest 标注的视觉目录页排除出正文。
  static bool _looksLikeNavDoc(String html) {
    if (html.isEmpty) return false;
    if (RegExp(r'<nav\b[^>]*\bepub:type="[^"]*toc', caseSensitive: false)
        .hasMatch(html)) {
      return true;
    }
    var body = html;
    body = body.replaceAll(
        RegExp(r'<head\b[\s\S]*?</head>', caseSensitive: false), '');
    body = body.replaceAll(
        RegExp(r'<script\b[\s\S]*?</script>', caseSensitive: false), '');
    body = body.replaceAll(
        RegExp(r'<style\b[\s\S]*?</style>', caseSensitive: false), '');
    final text = _stripTags(body);
    if (text.trim().isEmpty) return false;
    final linkCount =
        RegExp(r'<a\b', caseSensitive: false).allMatches(body).length;
    final textLen = text.replaceAll(RegExp(r'\s+'), '').length;
    // 目录页特征：链接很多（≥3）且正文文本很短（基本就是一串章节标题）。
    return linkCount >= 3 && textLen <= 600;
  }

  /// 解析 EPUB 自带目录（EPUB3 nav.xhtml / EPUB2 toc.ncx），返回有序的
  /// (章节标题, 目标 href) 列表。用于按书籍自身章节结构切分；无可用目录时返回空。
  static List<(String, String)> _parseEpubToc(
    String opfDir,
    List<String> navHrefs,
    String Function(String) readText,
  ) {
    String? navHref;
    // 优先 xhtml 型导航文档，其次 .ncx
    for (final href in navHrefs) {
      final lower = href.toLowerCase();
      if (lower.endsWith('.ncx')) {
        navHref ??= href;
        continue;
      }
      if (lower.endsWith('.xhtml') ||
          lower.endsWith('.html') ||
          lower.endsWith('.htm')) {
        navHref = href;
      }
    }
    if (navHref == null) return [];

    // 归一化路径：manifest 中的 href 相对 opfDir，兜底搜寻得到的可能是完整包内
    // 路径（已含 opfDir 前缀），避免重复拼接。
    String clean = navHref;
    if (opfDir.isNotEmpty && opfDir != '.' && clean.startsWith('$opfDir/')) {
      clean = clean.substring(opfDir.length + 1);
    }
    final path = opfDir.isEmpty || opfDir == '.' ? clean : '$opfDir/$clean';
    final html = readText(path);
    if (html.isEmpty) return [];

    final lowerNav = navHref.toLowerCase();
    if (lowerNav.endsWith('.ncx')) return _parseNcxToc(html);
    return _parseNavXhtmlToc(html);
  }

  /// 从 EPUB3 nav.xhtml 提取目录（<nav epub:type="toc"> 内的有序 <a> 链接）。
  static List<(String, String)> _parseNavXhtmlToc(String html) {
    // 优先处理 toc 型 nav 块；若不存在则回退到整篇所有 <a> 链接。
    var scope = html;
    final tocNav = RegExp(
            r'<nav\b[^>]*\bepub:type="[^"]*toc[^"]*"[\s\S]*?</nav>',
            caseSensitive: false)
        .firstMatch(html);
    if (tocNav != null) scope = tocNav.group(0)!;

    final result = <(String, String)>[];
    final linkRe = RegExp(
        r'<a\b[^>]*\bhref="([^"]+)"[^>]*>([\s\S]*?)</a>',
        caseSensitive: false);
    for (final m in linkRe.allMatches(scope)) {
      final href = m.group(1)!;
      final title = _stripTags(m.group(2)!).replaceAll(RegExp(r'\s+'), ' ').trim();
      if (title.isEmpty) continue;
      result.add((title, href));
    }
    return result;
  }

  /// 从 EPUB2 toc.ncx 提取目录（<navPoint> 顺序，含嵌套扁平化）。
  static List<(String, String)> _parseNcxToc(String ncx) {
    final result = <(String, String)>[];
    final pointRe = RegExp(
        r'<navPoint\b[^>]*>(?:\s*<navLabel>\s*<text>([\s\S]*?)</text>\s*</navLabel>)?\s*<content\s+src="([^"]+)"',
        caseSensitive: false);
    for (final m in pointRe.allMatches(ncx)) {
      final title = _stripTags(m.group(1) ?? '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      final src = m.group(2)!;
      if (title.isEmpty) continue;
      result.add((title, src));
    }
    return result;
  }
}

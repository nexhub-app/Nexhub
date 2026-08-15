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

  // 章节标题正则：第X章/节/回/卷、卷X、Chapter N、序章/楔子 等
  static final RegExp _chapterTitleRegex = RegExp(
    r'^\s*('
    r'第[一二三四五六七八九十百千万零〇\d]+[章节回卷部篇集]'
    r'|卷[一二三四五六七八九十百千万零〇\d]+'
    r'|chapter\s+[\divxlcdm]+'
    r'|序章|序言|楔子|引子|尾声|后记|番外'
    r')',
    caseSensitive: false,
  );

  /// 解析 TXT 文件。
  ///
  /// 自动嗅探编码（UTF-8 / GBK / UTF-16）读取，按双换行分段；命中章节标题
  /// 正则的段落开启新章节；若全书无任何章节标题匹配，则整本书作为单章返回。
  static Future<LocalNovelBook> parseTxt(String filePath) async {
    final file = File(filePath);
    final bytes = await file.readAsBytes();
    var text = decodeTextBytes(bytes);
    // 去除可能的 UTF-8 BOM
    if (text.startsWith('\uFEFF')) text = text.substring(1);
    // 统一换行符为 \n
    text = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

    final bookTitle = p.basenameWithoutExtension(filePath);

    // 按双换行（含多个连续空行）分段
    final blocks = text.split(RegExp(r'\n\n+'));

    final chapters = <LocalNovelChapter>[];
    final paras = <String>[];
    var title = '';
    var started = false;

    void flush() {
      if (started) {
        chapters.add(LocalNovelChapter(
          title: title.isEmpty ? '未命名章节' : title,
          content: List<String>.from(paras),
        ));
      }
      paras.clear();
    }

    for (final block in blocks) {
      final trimmed = block.trim();
      if (trimmed.isEmpty) continue;
      final firstLine = trimmed.split('\n').first.trim();
      if (_chapterTitleRegex.hasMatch(firstLine) && firstLine.length <= 40) {
        // 命中章节标题 → 结算上一章并开启新章
        flush();
        started = true;
        title = firstLine;
        // 同段中标题行之后的内容作为首批段落
        final lines = trimmed.split('\n');
        for (var i = 1; i < lines.length; i++) {
          final l = lines[i].trim();
          if (l.isNotEmpty) paras.add(l);
        }
      } else {
        paras.add(trimmed);
      }
    }
    flush();

    // 没有任何章节标题匹配 → 整本书作为单章
    if (chapters.isEmpty) {
      final all = blocks
          .map((b) => b.trim())
          .where((b) => b.isNotEmpty)
          .toList();
      chapters.add(LocalNovelChapter(title: bookTitle, content: all));
    }

    return LocalNovelBook(
      title: bookTitle,
      author: null,
      chapters: chapters,
    );
  }

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

    // 2. 解析 metadata：title / author
    var bookTitle = p.basenameWithoutExtension(filePath);
    String? author;
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

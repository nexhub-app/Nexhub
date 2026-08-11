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
  /// 以 UTF-8 读取，按双换行分段；命中章节标题正则的段落开启新章节；
  /// 若全书无任何章节标题匹配，则整本书作为单章返回。
  static Future<LocalNovelBook> parseTxt(String filePath) async {
    final file = File(filePath);
    final bytes = await file.readAsBytes();
    var text = utf8.decode(bytes, allowMalformed: true);
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

    // 3. 解析 manifest：id → href（属性顺序不固定，整标签内提取）
    final manifest = <String, String>{};
    final navIds = <String>{};
    final itemTagRegex = RegExp(r'<item\b[^>]*/?>');
    for (final m in itemTagRegex.allMatches(opfXml)) {
      final tag = m.group(0)!;
      final idM = RegExp(r'\bid="([^"]+)"').firstMatch(tag);
      final hrefM = RegExp(r'\bhref="([^"]+)"').firstMatch(tag);
      if (idM != null && hrefM != null) {
        final href = hrefM.group(1)!.split('#').first;
        manifest[idM.group(1)!] = href;
        // 导航文档（目录）不计入正文，避免「目录列表」混入阅读内容：
        // - EPUB3：`properties="nav"`；
        // - EPUB2：`toc.ncx`（NCX 导航文件，可能被不规范地放进 spine）。
        final propsM = RegExp(r'\bproperties="([^"]+)"', caseSensitive: false)
            .firstMatch(tag);
        if ((propsM != null &&
                propsM.group(1)!.toLowerCase().contains('nav')) ||
            href.toLowerCase().endsWith('.ncx')) {
          navIds.add(idM.group(1)!);
        }
      }
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

    void loadChapter(String? idref) {
      if (idref == null) return;
      final href = manifest[idref];
      if (href == null) return;
      final html = readText(resolvePath(href));
      if (html.isEmpty) return;
      // 一个 spine 文件可能包含多章，按标题进一步切分；
      // 返回空列表表示该文件无正文（封面 / 导航页），跳过。
      final subs = _parseEpubHtml(html);
      for (final sub in subs) {
        // 标题与正文都空才跳过；有标题的章节即使正文空也保留（见
        // [_parseEpubHtml]：整章空正文仍占一个章节，避免整本 0 章）。
        if (sub.$2.isEmpty && sub.$1.isEmpty) continue;
        chapters.add(LocalNovelChapter(
          title: sub.$1.isEmpty ? '第${chapters.length + 1}章' : sub.$1,
          content: sub.$2,
        ));
      }
    }

    // 按 spine 顺序加载章节（跳过导航文档）
    for (final idref in spineOrder) {
      if (navIds.contains(idref)) continue;
      loadChapter(idref);
    }

    // 兜底：spine 为空时取 manifest 中所有 xhtml/html
    if (chapters.isEmpty) {
      for (final entry in manifest.entries) {
        final href = entry.value.toLowerCase();
        if (!href.endsWith('.xhtml') &&
            !href.endsWith('.html') &&
            !href.endsWith('.htm')) {
          continue;
        }
        loadChapter(entry.key);
      }
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
        return utf8.decode(data, allowMalformed: true);
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

  /// 解析单章 XHTML/HTML：按标题（h1-h6）切分为若干子章节。
  ///
  /// 返回 [(标题, 段落列表)]。标题文本从 `<h1>-<h6>` 提取并作为切分点，
  /// 标题本身不再重复进入正文；无标题则返回单元素（标题为空）。
  /// 正文去标签 / 解码实体 / 按空行分段。
  static List<(String, List<String>)> _parseEpubHtml(String html) {
    // 移除 head / script / style（这些不是正文）。
    var body = html;
    body = body.replaceAll(
        RegExp(r'<head\b[\s\S]*?</head>', caseSensitive: false), '');
    body = body.replaceAll(
        RegExp(r'<script\b[\s\S]*?</script>', caseSensitive: false), '');
    body = body.replaceAll(
        RegExp(r'<style\b[\s\S]*?</style>', caseSensitive: false), '');

    // 将每个标题替换为位置标记并记下标题文本，之后用于切分正文。
    final headingTexts = <String>[];
    body = body.replaceAllMapped(
      RegExp(r'<h([1-6])[^>]*>([\s\S]*?)</h\1>', caseSensitive: false),
      (m) {
        final t = _stripTags(m.group(2)!).trim();
        headingTexts.add(t);
        return '\u0001${headingTexts.length - 1}\u0002';
      },
    );
    // 兜底：识别 class 含 chapter/part 的 <p>/<div> 作为章节标题（网络小说 EPUB
    // 常用 `<p class="chapter_title">` 等非标题标签承载章节名）；空标题不切分。
    body = body.replaceAllMapped(
      RegExp(
        r'<(p|div)\b[^>]*\s+class\s*=\s*[\x22\x27][^>]*?(?:chapter|part)[^>]*?[\x22\x27][^>]*>([\s\S]*?)</\1>',
        caseSensitive: false,
      ),
      (m) {
        final t = _stripTags(m.group(2)!).trim();
        if (t.isEmpty) return m.group(0)!;
        headingTexts.add(t);
        return '\u0001${headingTexts.length - 1}\u0002';
      },
    );

    // 块级闭合标签 → 双换行，<br> → 单换行，便于段落分割。
    body = body.replaceAll(
        RegExp(r'</(p|div|section|article|li|blockquote)\s*>',
            caseSensitive: false),
        '\n\n');
    body = body.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');

    // 去标签 + 解码实体。
    body = _decodeEntities(_stripTags(body));

    final result = <(String, List<String>)>[];
    final marker = RegExp(r'\u0001(\d+)\u0002');
    final parts = body.split(marker);
    for (var i = 0; i < parts.length; i++) {
      final paras = _splitParas(parts[i]);
      if (i == 0) {
        // 首个标题之前的前言段：有内容则作为无标题章节。
        if (paras.isNotEmpty) result.add(('', paras));
      } else {
        final title = headingTexts[i - 1];
        if (paras.isEmpty && title.isEmpty) continue; // 标题与正文都空才跳过
        // 有标题但正文为空（源正文抓取失败/被拦时整章空）也保留章节：
        // 否则整本 0 章 → 阅读器误报「本地文件读取失败」，用户无从排查。
        result.add((title, paras));
      }
    }
    return result;
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
}

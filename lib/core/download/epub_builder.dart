/// EPUB 构建器（文档 §8.4 / §10.1）。
///
/// 构建最小合法 EPUB 2.0 结构：
/// - `mimetype`（不压缩，首条）
/// - `META-INF/container.xml`
/// - `OEBPS/content.opf`（元数据 + manifest + spine）
/// - `OEBPS/toc.ncx`（目录）
/// - `OEBPS/chapter-N.xhtml`（章节正文）
///
/// 使用 `archive` 纯 Dart 包，无平台依赖。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// 字符串 → UTF-8 字节。**严禁用 `s.codeUnits`**：中文 code unit > 255，
/// `Uint8List.fromList` 会截断成低字节 → 整本中文乱码/打不开。
Uint8List _u8(String s) => Uint8List.fromList(utf8.encode(s));

/// EPUB 章节数据。
class EpubChapter {
  final String title;
  final String content; // HTML 片段（段落列表，可含 <img> 引用）

  const EpubChapter({required this.title, required this.content});
}

/// EPUB 内嵌图片资源。
///
/// [href] 为相对 `OEBPS/` 的包内路径（如 `Images/<hash>.jpg`），章节 XHTML
/// 内以同名相对路径 `<img src="...">` 引用；[data] 为图片原始字节。
class EpubImage {
  final String href;
  final Uint8List data;

  const EpubImage({required this.href, required this.data});
}

/// EPUB 元数据。
class EpubMetadata {
  final String title;
  final String? author;
  final String? language;

  const EpubMetadata({
    required this.title,
    this.author,
    this.language = 'zh',
  });
}

/// EPUB 打包器。
class EpubBuilder {
  EpubBuilder();

  /// 构建 EPUB 字节流。
  ///
  /// [images] 为内嵌图片资源（可选）：写入 `OEBPS/<href>` 并注册 manifest，
  /// 供章节 XHTML 内的 `<img>` 引用（图文小说导出不再丢图）。
  ///
  /// F4 自定义模板：
  /// - [css] 非空时写入 `OEBPS/style.css`，所有章节 XHTML `<head>` 注入引用；
  /// - [coverImage] 非空时生成书首封面页 `cover.xhtml`（spine 首项），
  ///   并按 EPUB 2 惯例写入 `<meta name="cover">`；
  /// - [introHtml] 非空时在封面后生成简介页 `intro.xhtml`（占位符已由调用方
  ///   替换、HTML 已转义）。
  static Uint8List build({
    required EpubMetadata metadata,
    required List<EpubChapter> chapters,
    List<EpubImage> images = const <EpubImage>[],
    String? css,
    EpubImage? coverImage,
    String? introHtml,
  }) {
    final archive = Archive();
    final bool hasCss = css != null && css.trim().isNotEmpty;
    final bool hasCover = coverImage != null;
    final bool hasIntro = introHtml != null && introHtml.trim().isNotEmpty;

    // 1. mimetype（不压缩，必须是第一条且无额外字段）
    final mimetypeData = _u8('application/epub+zip');
    final mimetypeFile = ArchiveFile('mimetype', mimetypeData.length, mimetypeData);
    mimetypeFile.compress = false;
    archive.addFile(mimetypeFile);

    // 2. META-INF/container.xml
    final containerData = _u8(_containerXml());
    archive.addFile(ArchiveFile('META-INF/container.xml', containerData.length, containerData));

    // 3. OEBPS/content.opf
    final opfData = _u8(_contentOpf(metadata, chapters, images,
        hasCss: hasCss, coverImage: coverImage, hasIntro: hasIntro));
    archive.addFile(ArchiveFile('OEBPS/content.opf', opfData.length, opfData));

    // 4. OEBPS/toc.ncx
    final ncxData = _u8(_tocNcx(metadata, chapters,
        hasCover: hasCover, hasIntro: hasIntro));
    archive.addFile(ArchiveFile('OEBPS/toc.ncx', ncxData.length, ncxData));

    // 5. 章节正文
    for (var i = 0; i < chapters.length; i++) {
      final ch = chapters[i];
      final chData = _u8(_chapterXhtml(ch, linkCss: hasCss));
      archive.addFile(ArchiveFile('OEBPS/chapter-${i + 1}.xhtml', chData.length, chData));
    }

    // 6. 内嵌图片资源
    for (var i = 0; i < images.length; i++) {
      final img = images[i];
      final path = 'OEBPS/${img.href}';
      if (archive.files.any((f) => f.name == path)) continue; // 同名去重
      archive.addFile(ArchiveFile(path, img.data.length, img.data));
    }

    // 7. F4 模板产物：style.css / cover.xhtml / intro.xhtml / 封面图。
    if (hasCss) {
      final cssData = _u8(css);
      archive.addFile(ArchiveFile('OEBPS/style.css', cssData.length, cssData));
    }
    if (hasCover) {
      final coverPath = 'OEBPS/${coverImage.href}';
      if (!archive.files.any((f) => f.name == coverPath)) {
        archive.addFile(ArchiveFile(
            coverPath, coverImage.data.length, coverImage.data));
      }
      final xhtml = _u8(_staticPageXhtml(
        title: 'Cover',
        linkCss: hasCss,
        body: '<div class="cover" style="text-align:center;margin:0">'
            '<img src="${coverImage.href}" alt="cover"'
            ' style="max-width:100%;max-height:100%"/></div>',
      ));
      archive.addFile(
          ArchiveFile('OEBPS/cover.xhtml', xhtml.length, xhtml));
    }
    if (hasIntro) {
      final xhtml = _u8(_staticPageXhtml(
        title: 'Intro',
        linkCss: hasCss,
        body: introHtml,
      ));
      archive.addFile(
          ArchiveFile('OEBPS/intro.xhtml', xhtml.length, xhtml));
    }

    final encoder = ZipEncoder();
    return encoder.encode(archive) as Uint8List;
  }

  /// 构建 TXT 字节流（简化格式：标题 + 段落）。
  static Uint8List buildTxt({
    required EpubMetadata metadata,
    required List<EpubChapter> chapters,
  }) {
    final buffer = StringBuffer();
    buffer.writeln(metadata.title);
    buffer.writeln('=' * 40);
    if (metadata.author != null && metadata.author!.isNotEmpty) {
      buffer.writeln('Author: ${metadata.author}');
    }
    buffer.writeln();

    for (final ch in chapters) {
      buffer.writeln(ch.title);
      buffer.writeln('-' * 30);
      buffer.writeln(ch.content);
      buffer.writeln();
    }

    return _u8(buffer.toString());
  }

  static String _containerXml() => '''<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''';

  static String _contentOpf(
      EpubMetadata metadata, List<EpubChapter> chapters, List<EpubImage> images,
      {bool hasCss = false, EpubImage? coverImage, bool hasIntro = false}) {
    final bool hasCover = coverImage != null;
    final buf = StringBuffer();
    buf.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    buf.writeln(
        '<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="BookId" version="2.0">');
    buf.writeln('  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"'
        ' xmlns:opf="http://www.idpf.org/2007/opf">');
    buf.writeln('    <dc:title>${_escape(metadata.title)}</dc:title>');
    if (metadata.author != null && metadata.author!.isNotEmpty) {
      buf.writeln(
          '    <dc:creator opf:role="aut">${_escape(metadata.author!)}</dc:creator>');
    }
    buf.writeln(
        '    <dc:language>${metadata.language ?? 'zh'}</dc:language>');
    buf.writeln('    <dc:identifier id="BookId" opf:scheme="UUID">'
        'nexhub-${DateTime.now().millisecondsSinceEpoch}</dc:identifier>');
    // EPUB 2 封面惯例：meta name="cover" 指向 manifest 项。
    if (hasCover) {
      buf.writeln('    <meta name="cover" content="coverImg"/>');
    }
    buf.writeln('  </metadata>');
    buf.writeln('  <manifest>');
    buf.writeln(
        '    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>');
    if (hasCss) {
      buf.writeln(
          '    <item id="css" href="style.css" media-type="text/css"/>');
    }
    if (hasCover) {
      buf.writeln(
          '    <item id="coverPage" href="cover.xhtml" media-type="application/xhtml+xml"/>');
      buf.writeln(
          '    <item id="coverImg" href="${coverImage.href}"'
          ' media-type="${_imageMediaType(coverImage.href)}"/>');
    }
    for (var i = 0; i < chapters.length; i++) {
      buf.writeln(
          '    <item id="ch${i + 1}" href="chapter-${i + 1}.xhtml" media-type="application/xhtml+xml"/>');
    }
    for (var i = 0; i < images.length; i++) {
      buf.writeln(
          '    <item id="img${i + 1}" href="${images[i].href}"'
          ' media-type="${_imageMediaType(images[i].href)}"/>');
    }
    if (hasIntro) {
      buf.writeln(
          '    <item id="introPage" href="intro.xhtml" media-type="application/xhtml+xml"/>');
    }
    buf.writeln('  </manifest>');
    buf.writeln('  <spine toc="ncx">');
    if (hasCover) {
      buf.writeln('    <itemref idref="coverPage"/>');
    }
    if (hasIntro) {
      buf.writeln('    <itemref idref="introPage"/>');
    }
    for (var i = 0; i < chapters.length; i++) {
      buf.writeln('    <itemref idref="ch${i + 1}"/>');
    }
    buf.writeln('  </spine>');
    buf.writeln('</package>');
    return buf.toString();
  }

  /// 按扩展名推断图片 MIME 类型（未知扩展名按 JPEG 兜底）。
  static String _imageMediaType(String href) {
    final ext = href.toLowerCase().split('.').last;
    return switch (ext) {
      'png' => 'image/png',
      'webp' => 'image/webp',
      'gif' => 'image/gif',
      'bmp' => 'image/bmp',
      'svg' => 'image/svg+xml',
      _ => 'image/jpeg',
    };
  }

  static String _tocNcx(EpubMetadata metadata, List<EpubChapter> chapters,
      {bool hasCover = false, bool hasIntro = false}) {
    final buf = StringBuffer();
    buf.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    buf.writeln(
        '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">');
    buf.writeln('  <head>');
    buf.writeln('    <meta name="dtb:uid" content="nexhub"/>');
    buf.writeln('  </head>');
    buf.writeln('  <docTitle><text>${_escape(metadata.title)}</text></docTitle>');
    buf.writeln('  <navMap>');
    var order = 0;
    void navPoint(String id, String title, String src) {
      order += 1;
      buf.writeln(
          '    <navPoint id="$id" playOrder="$order">');
      buf.writeln(
          '      <navLabel><text>${_escape(title)}</text></navLabel>');
      buf.writeln('      <content src="$src"/>');
      buf.writeln('    </navPoint>');
    }

    // F4：封面 / 简介页与 spine 顺序一致地出现在目录最前。
    if (hasCover) navPoint('navCover', 'Cover', 'cover.xhtml');
    if (hasIntro) navPoint('navIntro', 'Intro', 'intro.xhtml');
    for (var i = 0; i < chapters.length; i++) {
      navPoint('nav${i + 1}', chapters[i].title, 'chapter-${i + 1}.xhtml');
    }
    buf.writeln('  </navMap>');
    buf.writeln('</ncx>');
    return buf.toString();
  }

  static String _chapterXhtml(EpubChapter ch, {bool linkCss = false}) {
    final cssLink =
        linkCss ? '<link rel="stylesheet" type="text/css" href="style.css"/>' : '';
    return '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>${_escape(ch.title)}</title>$cssLink</head>
<body>
<h1>${_escape(ch.title)}</h1>
${ch.content}
</body>
</html>''';
  }

  /// F4 静态页（封面 / 简介）共用 XHTML 模板。
  static String _staticPageXhtml({
    required String title,
    required String body,
    bool linkCss = false,
  }) {
    final cssLink =
        linkCss ? '<link rel="stylesheet" type="text/css" href="style.css"/>' : '';
    return '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>${_escape(title)}</title>$cssLink</head>
<body>
$body
</body>
</html>''';
  }

  static String _escape(String s) =>
      s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
}

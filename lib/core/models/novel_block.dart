/// 章节正文块：文本段或插图。
///
/// 解析层（[BookContent]）从章节 HTML 中提取 `<img>` 并转为 [NovelImageBlock]，
/// 与其相邻的文本段一起保留在原有顺序，使阅读器能图文混排显示插图。
///
/// 此前正文被压成 `List<String>` 纯文本、`BookContent` 在清洗阶段直接删除了
/// `<img>` 标签，导致插图永远无法显示。引入块模型后，文本与插图作为一等
/// 公民共存于同一列表，渲染层按类型分别处理。
library;

import 'package:nexhub/core/models/plugin_config.dart';

/// 章节正文的一个块：要么是一段文本，要么是一张插图。
abstract class NovelBlock {
  const NovelBlock();
}

/// 文本段（对应原 `List<String>` 中的一个段落，首行已含 `　　` 缩进）。
class NovelTextBlock extends NovelBlock {
  final String text;

  const NovelTextBlock(this.text);

  @override
  bool operator ==(Object other) =>
      other is NovelTextBlock && other.text == text;

  @override
  int get hashCode => text.hashCode;
}

/// 插图块：章节正文中的一张图片。
///
/// [url] 已是解析层拼好的绝对地址（含 baseUrl 归一化）。
/// [source] 透传给 [SourceImage] 以注入书源防盗链 headers（Referer/Cookie 等）。
class NovelImageBlock extends NovelBlock {
  final String url;
  final PluginConfig? source;

  const NovelImageBlock(this.url, {this.source});

  /// 是否为可显示的图片地址（http/https 或 data:image 内联）。
  bool get isValid =>
      url.startsWith('http://') ||
      url.startsWith('https://') ||
      url.startsWith('data:image');

  @override
  bool operator ==(Object other) =>
      other is NovelImageBlock && other.url == url;

  @override
  int get hashCode => url.hashCode;
}

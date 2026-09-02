/// RSS article detail reader (Browse -> RSS -> feed detail -> article).
///
/// Renders the article HTML body in-app via [flutter_html] instead of stripping
/// tags to plain text. Supports reading settings (font size / line height /
/// night mode) persisted through [ArticleReadingPreferencesNotifier].
library;

import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/article/article_reading_preferences.dart';
import '../../../core/settings/general_settings.dart';
import '../../../core/rss/rss_feed.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/utils/app_haptics.dart';
import '../../../core/widgets/app_empty_state.dart';
import '../../../core/widgets/app_icon_button.dart';
import '../../../core/widgets/source_image.dart';
import '../../../features/rss/presentation/rss_image_gallery.dart';
import '../../../features/rss/presentation/rss_video_player.dart';
import '../../rss/presentation/rss_podcast_player.dart';

/// Single RSS article detail reader page.
class BrowseArticleDetailScreen extends StatelessWidget {
  final RssItem item;
  const BrowseArticleDetailScreen({super.key, required this.item});

  String _formatDate(DateTime? dt) {
    if (dt == null) return '-';
    return GeneralSettingsStore.instance.settings.dateFormat.format(
      dt,
      withTime: true,
    );
  }

  Future<void> _openInBrowser(BuildContext context, AppLocalizations l10n) async {
    try {
      await launchUrl(Uri.parse(item.url), mode: LaunchMode.externalApplication);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.loadFailed)),
        );
      }
    }
  }

  /// 文章内链接点击：仅放行 http/https 外链，拦截 javascript:/data:/tel:/file:
  /// 等危险或不适配的 scheme。
  ///
  /// 此前两类写法会「点了没反应」（旧逻辑只看绝对地址，解析不出 scheme 就静默
  /// return，用户以为应用坏了）：
  /// - 协议相对地址 `//host/path` → 继承文章页协议补全；
  /// - 文档相对地址 `/path`、`./path` → 按文章页地址解析成绝对地址。
  /// 被拦截与打不开都给提示，不再静默吞掉。
  Future<void> _openLinkSafely(BuildContext context, String? url) async {
    if (url == null || url.isEmpty) return;
    final Uri? resolved = _resolveUrl(url);
    final AppLocalizations l10n = AppLocalizations.of(context);
    if (resolved == null) {
      _toast(context, l10n.loadFailed);
      return;
    }
    final String scheme = resolved.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      _toast(context, l10n.rssLinkUnsupported);
      return;
    }
    try {
      await launchUrl(resolved, mode: LaunchMode.externalApplication);
    } on Object {
      _toast(context, l10n.loadFailed);
    }
  }

  /// 把 HTML 里的链接解析为绝对地址（协议相对与文档相对都覆盖）。
  Uri? _resolveUrl(String raw) {
    final String s = raw.trim();
    if (s.isEmpty) return null;
    final Uri? base = Uri.tryParse(item.url);
    // 协议相对：//host/path → 继承文章页协议（缺省 https）。
    if (s.startsWith('//')) {
      return Uri.tryParse('${base?.scheme ?? 'https'}:$s');
    }
    final Uri? parsed = Uri.tryParse(s);
    if (parsed != null && parsed.hasScheme) return parsed;
    // 文档相对：必须参照文章页地址才解析得出绝对地址。
    if (base == null) return null;
    return base.resolve(s);
  }

  void _toast(BuildContext context, String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  void _showReadingSettingsSheet(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (BuildContext ctx) {
        return Consumer<ArticleReadingPreferencesNotifier>(
          builder: (BuildContext ctx, ArticleReadingPreferencesNotifier notifier, _) {
            final prefs = notifier.prefs;
            return ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(ctx).size.height * 0.85,
              ),
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppTokens.spaceLg,
                    AppTokens.spaceSm,
                    AppTokens.spaceLg,
                    AppTokens.spaceLg,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        l10n.articleReadingSettings,
                        style: Theme.of(ctx).textTheme.titleMedium,
                      ),
                      const SizedBox(height: AppTokens.spaceMd),
                      Text(l10n.articleFontSize),
                      Row(
                        children: <Widget>[
                          const Text('A'),
                          Expanded(
                            child: Slider(
                              min: 12,
                              max: 24,
                              divisions: 12,
                              value: prefs.fontSize,
                              label: prefs.fontSize.toStringAsFixed(0),
                              onChangeStart: (_) => AppHaptics.light(),
                              onChanged: notifier.setFontSize,
                            ),
                          ),
                          const Text('A',
                              style: TextStyle(fontSize: 22)),
                        ],
                      ),
                      const SizedBox(height: AppTokens.spaceSm),
                      Text(l10n.articleLineHeight),
                      Slider(
                        min: 1.0,
                        max: 2.5,
                        divisions: 15,
                        value: prefs.lineHeight,
                        label: prefs.lineHeight.toStringAsFixed(1),
                        onChangeStart: (_) => AppHaptics.light(),
                        onChanged: notifier.setLineHeight,
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(l10n.articleNightMode),
                        value: prefs.isNightMode,
                        onChanged: (_) {
                          AppHaptics.selectionClick();
                          notifier.toggleNightMode();
                        },
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// 文章附件区：音频（播客）走播放器，其余（视频/文件）以「打开附件」链接。
  Widget _buildEnclosureWidgets(BuildContext context, AppLocalizations l10n) {
    final audio = item.enclosures
        .where((e) => e.type == null || (e.type?.startsWith('audio') ?? false))
        .toList();
    final video = item.enclosures.where((e) => e.isVideo).toList();
    final others = item.enclosures
        .where((e) =>
            e.type != null &&
            !(e.type?.startsWith('audio') ?? false) &&
            !e.isVideo)
        .toList();

    final children = <Widget>[];
    if (audio.isNotEmpty) {
      children.add(RssPodcastPlayer(enclosures: audio));
    }
    if (video.isNotEmpty) {
      children.add(
        Card(
          margin: const EdgeInsets.only(top: AppTokens.spaceMd),
          child: Padding(
            padding: const EdgeInsets.all(AppTokens.spaceMd),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    const Icon(Icons.play_circle_outline),
                    const SizedBox(width: AppTokens.spaceSm),
                    Text(l10n.rssAttachments,
                        style: Theme.of(context).textTheme.titleSmall),
                  ],
                ),
                const SizedBox(height: AppTokens.spaceSm),
                for (final enc in video)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.play_arrow_outlined),
                    title: Text(enc.title ?? enc.url),
                    subtitle: enc.type != null ? Text(enc.type!) : null,
                    onTap: () => _openVideo(context, enc.url),
                  ),
              ],
            ),
          ),
        ),
      );
    }
    if (others.isNotEmpty) {
      children.add(
        Card(
          margin: const EdgeInsets.only(top: AppTokens.spaceMd),
          child: Padding(
            padding: const EdgeInsets.all(AppTokens.spaceMd),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    const Icon(Icons.attachment_outlined),
                    const SizedBox(width: AppTokens.spaceSm),
                    Text(l10n.rssAttachments,
                        style: Theme.of(context).textTheme.titleSmall),
                  ],
                ),
                const SizedBox(height: AppTokens.spaceSm),
                for (final enc in others)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.open_in_new_outlined),
                    title: Text(enc.title ?? enc.url),
                    subtitle: enc.type != null ? Text(enc.type!) : null,
                    onTap: () => _openAttachment(context, enc.url),
                  ),
              ],
            ),
          ),
        ),
      );
    }
    if (children.isEmpty) return const SizedBox.shrink();
    return Column(children: children);
  }

  Future<void> _openAttachment(BuildContext context, String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    final AppLocalizations? l10n = AppLocalizations.of(context);
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (context.mounted && l10n != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.loadFailed)),
        );
      }
    }
  }

  /// 打开全屏图片画廊（B2 图片查看器）。
  void _openGallery(BuildContext context, List<String> images, int index) {
    if (images.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RssImageGallery(
          images: images,
          initialIndex: index,
          pageUrl: item.url,
        ),
      ),
    );
  }

  /// 打开应用内视频播放器（B4 视频播放：enclosure 视频 / iframe 嵌入视频）。
  void _openVideo(BuildContext context, String url) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RssVideoPlayer(url: url, title: item.title),
      ),
    );
  }

  /// 从正文 HTML 提取所有 `<img>` 的 src，按文章页地址绝对化（用于全屏画廊）。
  List<String> _extractImageUrls(String html) {
    if (html.isEmpty) return const <String>[];
    final Uri? base = Uri.tryParse(item.url);
    final matches = RegExp(
      r'''<img[^>]+src=["']([^"']+)["']''',
      caseSensitive: false,
    ).allMatches(html);
    final List<String> urls = <String>[];
    for (final m in matches) {
      final raw = m.group(1);
      if (raw == null || raw.isEmpty) continue;
      final abs = base != null ? base.resolve(raw).toString() : raw;
      if (!urls.contains(abs)) urls.add(abs);
    }
    return urls;
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final String html = item.content ?? item.description ?? '';
    final List<String> imgUrls = _extractImageUrls(html);

    return Consumer<ArticleReadingPreferencesNotifier>(
      builder: (BuildContext context, ArticleReadingPreferencesNotifier notifier, _) {
        final prefs = notifier.prefs;
        final bool isNight = prefs.isNightMode;
        final Color? bg = isNight ? Colors.grey[900] : null;
        final Color textColor = isNight ? Colors.grey[100]! : Theme.of(context).textTheme.bodyLarge!.color!;
        final Color metaColor = isNight ? Colors.grey[400]! : Theme.of(context).textTheme.bodySmall!.color!;

        final Map<String, Style> htmlStyle = <String, Style>{
          'body': Style(
            fontSize: FontSize(prefs.fontSize),
            lineHeight: LineHeight(prefs.lineHeight),
            color: textColor,
            margin: Margins.zero,
          ),
          'p': Style(
            fontSize: FontSize(prefs.fontSize),
            lineHeight: LineHeight(prefs.lineHeight),
            color: textColor,
          ),
        };

        return Scaffold(
          backgroundColor: bg,
          appBar: AppBar(
            title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            actions: <Widget>[
              AppIconButton(
                icon: Icons.text_fields_outlined,
                tooltip: l10n.articleReadingSettings,
                onPressed: () => _showReadingSettingsSheet(context),
              ),
              AppIconButton(
                icon: Icons.open_in_browser_outlined,
                tooltip: l10n.articleDetailReadFull,
                onPressed: () => _openInBrowser(context, l10n),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _openInBrowser(context, l10n),
            icon: const Icon(Icons.open_in_new_outlined),
            label: Text(l10n.articleDetailReadFull),
          ),
          body: ListView(
            padding: const EdgeInsets.all(AppTokens.spaceLg),
            children: <Widget>[
              if (item.author != null || item.publishedAt != null)
                Row(
                  children: <Widget>[
                    if (item.author != null)
                      Expanded(
                        child: Text('${l10n.articleDetailAuthor}：${item.author}',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: metaColor)),
                      ),
                    if (item.publishedAt != null)
                      AnimatedBuilder(
                        animation: GeneralSettingsStore.instance,
                        builder: (context, _) => Text(
                          '${l10n.articleDetailPublishedAt}：${_formatDate(item.publishedAt)}',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: metaColor),
                        ),
                      ),
                  ],
                ),
              if (item.author != null || item.publishedAt != null)
                const SizedBox(height: AppTokens.spaceMd),
              if (item.coverUrl != null)
                GestureDetector(
                  onTap: () => _openGallery(context, <String>[item.coverUrl!], 0),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(AppTokens.radiusMd),
                    // 封面同样走 SourceImage（带文章页 Referer + 重试）：
                    // AppCoverImage 无源配置时不注入 Referer，防盗链站点拿不到封面。
                    child: SourceImage(
                      url: item.coverUrl,
                      fit: BoxFit.cover,
                      refererOverride: item.url.isNotEmpty ? item.url : null,
                    ),
                  ),
                ),
              if (item.coverUrl != null) const SizedBox(height: AppTokens.spaceMd),
              if (html.isNotEmpty)
                Html(
                  data: html,
                  style: htmlStyle,
                  // 渲染时彻底丢弃危险/追踪标签（B6 HTML 消毒）；
                  // iframe 不在此丢弃——改由下方 Extension 渲染为「播放视频」按钮，
                  // 否则嵌入视频（YouTube/B 站等）会被整段跳过无法播放。
                  doNotRenderTheseTags: const <String>{
                    'script',
                    'object',
                    'embed',
                    'form',
                  },
                  // 自定义标签渲染：正文图片改走 [SourceImage]，默认的
                  // `Image.network` 不带 Referer / UA，防盗链站点一律 403。
                  extensions: <HtmlExtension>[
                    TagExtension(
                      tagsToExtend: <String>{'img'},
                      builder: (ExtensionContext ext) => _HtmlImage(
                        src: ext.attributes['src'] ?? '',
                        pageUrl: item.url,
                        images: imgUrls,
                      ),
                    ),
                    // iframe 嵌入视频：不渲染原始 iframe（XSS/追踪风险），改为
                    // 「播放视频」按钮，点击用应用内 WebView 播放（B4）。
                    TagExtension(
                      tagsToExtend: <String>{'iframe'},
                      builder: (ExtensionContext ext) {
                        final src = ext.attributes['src'] ?? '';
                        if (src.isEmpty) return const SizedBox.shrink();
                        final Uri? base = Uri.tryParse(item.url);
                        final String url =
                            base != null ? base.resolve(src).toString() : src;
                        return Padding(
                          padding: const EdgeInsets.symmetric(
                              vertical: AppTokens.spaceSm),
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.play_circle_outline),
                            label: Text(l10n.rssVideoPlay),
                            onPressed: () => _openVideo(context, url),
                          ),
                        );
                      },
                    ),
                  ],
                  onLinkTap: (String? url, Map<String, String> attributes, _) {
                    _openLinkSafely(context, url);
                  },
                )
              else
                AppEmptyState(icon: Icons.article_outlined, message: l10n.articleDetailEmpty),
              _buildEnclosureWidgets(context, l10n),
            ],
          ),
        );
      },
    );
  }
}

/// 正文内嵌图片。
///
/// 走 [SourceImage] 而非 flutter_html 默认的 `Image.network`：后者既不发
/// Referer 也不发 UA，防盗链站点一律返回 403，用户只看到加载不出来。
/// [SourceImage] 会带上**文章页** Referer（防盗链校验的是「被哪个页面引用」，
/// 用图片自身域名当 Referer 反而无效），并在失败时按指数退避重试三次。
///
/// 另外把相对图片地址按文章页地址解析为绝对地址——feed 正文里
/// `src="/img/a.png"` 这类相对写法相当常见，不解析必然加载不出来。
class _HtmlImage extends StatelessWidget {
  final String src;
  final String pageUrl;
  final List<String> images;

  const _HtmlImage({
    required this.src,
    required this.pageUrl,
    required this.images,
  });

  @override
  Widget build(BuildContext context) {
    if (src.isEmpty) return const SizedBox.shrink();
    final Uri? base = Uri.tryParse(pageUrl);
    final String url = base != null ? base.resolve(src).toString() : src;
    final int index = images.indexOf(url);
    return GestureDetector(
      onTap: () {
        if (images.isEmpty) return;
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => RssImageGallery(
              images: images,
              initialIndex: index < 0 ? 0 : index,
              pageUrl: pageUrl,
            ),
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppTokens.spaceSm),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppTokens.radiusSm),
          child: SourceImage(
            url: url,
            fit: BoxFit.fitWidth,
            refererOverride: pageUrl.isNotEmpty ? pageUrl : null,
          ),
        ),
      ),
    );
  }
}

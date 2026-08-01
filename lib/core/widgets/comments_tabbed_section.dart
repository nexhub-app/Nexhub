/// 详情页「评论」标签页容器。
///
/// 将评论区拆分为两个子页（[SegmentedButton] 切换）：
/// - 「网站评论」：源自定义评论区（[CommentSection]，仅当源声明 comments 段时提供）；
/// - 「Bangumi 吐槽」：Bangumi 官方条目吐槽（[BangumiCommentSection]，按官方文档增加）。
///
/// 源未声明 comments 时仅展示 Bangumi 吐槽子页，默认选中。
library;

import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';

import '../models/plugin_config.dart';
import '../theme/app_tokens.dart';
import 'bangumi_comment_section.dart';
import 'comment_section.dart';

class CommentsTabbedSection extends StatefulWidget {
  final PluginConfig? source;
  final String contentId;
  final String title;
  final SourceType sourceType;

  const CommentsTabbedSection({
    super.key,
    required this.source,
    required this.contentId,
    required this.title,
    required this.sourceType,
  });

  @override
  State<CommentsTabbedSection> createState() => _CommentsTabbedSectionState();
}

class _CommentsTabbedSectionState extends State<CommentsTabbedSection> {
  /// 0 = 网站评论，1 = Bangumi 吐槽。
  late int _tab;

  @override
  void initState() {
    super.initState();
    // 源未声明 comments 段时，不提供网站评论子页，默认展示 Bangumi 吐槽。
    _tab = widget.source?.comments != null ? 0 : 1;
  }

  bool get _hasWebsite => widget.source?.comments != null;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final List<ButtonSegment<int>> segments = <ButtonSegment<int>>[
      if (_hasWebsite)
        ButtonSegment<int>(value: 0, label: Text(l10n.websiteComments)),
      ButtonSegment<int>(value: 1, label: Text(l10n.bangumiComments)),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (segments.length > 1)
          // 两个子页 → 分段按钮切换。
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTokens.spaceLg,
              AppTokens.spaceMd,
              AppTokens.spaceLg,
              0,
            ),
            child: SegmentedButton<int>(
              segments: segments,
              selected: <int>{_tab},
              onSelectionChanged: (Set<int> selected) =>
                  setState(() => _tab = selected.first),
              style: SegmentedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          )
        else
          // 仅一个子页 → 紧凑标签（避免全宽胶囊）。
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTokens.spaceLg,
              AppTokens.spaceSm,
              AppTokens.spaceLg,
              0,
            ),
            child: Text(
              l10n.bangumiComments,
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(color: Theme.of(context).colorScheme.primary),
            ),
          ),
        const SizedBox(height: AppTokens.spaceSm),
        if (_tab == 0 && _hasWebsite)
          CommentSection(
            source: widget.source!,
            contentId: widget.contentId,
          )
        else
          BangumiCommentSection(
            contentId: widget.contentId,
            title: widget.title,
            sourceType: widget.sourceType,
          ),
      ],
    );
  }
}

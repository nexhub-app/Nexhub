/// 全量评论页（源驱动，M-comments）。
///
/// 由 [CommentSection] 的「查看全部」入口 push 进入：`ListView.builder`
/// 懒加载 + 滚动近底部自动拉取下一页（`{page}` 占位符递增，`hasMore` 判停），
/// 底部加载指示器；条目复用 [CommentTile]，入场 [Entrance]（onceKey 防滚动
/// 重播）；已登录且源声明 post 路由时 FAB 写评论。
library;

import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:provider/provider.dart';

import '../auth/source_auth_manager.dart';
import '../comments/comment_api_service.dart';
import '../models/plugin_config.dart';
import '../theme/app_tokens.dart';
import 'app_animations.dart';
import 'comment_section.dart';
import 'source_login_sheet.dart';

class CommentListScreen extends StatefulWidget {
  final PluginConfig source;
  final String contentId;
  final CommentApiService service;

  const CommentListScreen({
    super.key,
    required this.source,
    required this.contentId,
    this.service = const CommentApiService(),
  });

  @override
  State<CommentListScreen> createState() => _CommentListScreenState();
}

class _CommentListScreenState extends State<CommentListScreen> {
  final ScrollController _scroll = ScrollController();
  final List<SourceComment> _comments = <SourceComment>[];
  int _nextPage = 1;
  bool _hasMore = true;
  bool _loading = false;

  /// 首页加载失败（非空时整页显示错误 + 重试）。
  bool _firstPageFailed = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _loadMore();
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scroll.position.extentAfter < 400) _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    setState(() {
      _loading = true;
      _firstPageFailed = false;
    });
    try {
      final page = await widget.service.fetchComments(
        widget.source,
        widget.contentId,
        page: _nextPage,
      );
      if (!mounted) return;
      setState(() {
        _nextPage++;
        _comments.addAll(page.comments);
        _hasMore = page.hasMore && page.comments.isNotEmpty;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (_comments.isEmpty) {
          _firstPageFailed = true;
        } else {
          // 分页失败：停止自动加载，避免滚动触底反复重试。
          _hasMore = false;
        }
      });
    }
  }

  /// 从第一页重载（发布成功后刷新）。
  Future<void> _reload() async {
    setState(() {
      _comments.clear();
      _nextPage = 1;
      _hasMore = true;
    });
    await _loadMore();
  }

  Future<void> _writeComment() async {
    final posted = await showCommentComposerSheet(
      context,
      source: widget.source,
      contentId: widget.contentId,
      service: widget.service,
    );
    if (!mounted) return;
    if (posted == true) {
      _reload();
    } else if (posted == false) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).loginExpired)),
      );
      showSourceLoginSheet(context, source: widget.source);
    }
  }

  Widget _buildBody(AppLocalizations l10n, ThemeData theme) {
    if (_firstPageFailed) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              l10n.commentsLoadFailed,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppTokens.spaceSm),
            OutlinedButton(onPressed: _loadMore, child: Text(l10n.retry)),
          ],
        ),
      );
    }
    if (_comments.isEmpty) {
      if (_loading) {
        return const Center(child: CircularProgressIndicator());
      }
      return Center(
        child: Text(
          l10n.emptyComments,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.all(AppTokens.spaceMd),
      itemCount: _comments.length + (_hasMore || _loading ? 1 : 0),
      itemBuilder: (BuildContext context, int index) {
        if (index >= _comments.length) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: AppTokens.spaceMd),
            child: Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        final comment = _comments[index];
        return Padding(
          padding: const EdgeInsets.only(bottom: AppTokens.spaceSm),
          child: Entrance(
            onceKey: 'comment_${comment.id.isEmpty ? index : comment.id}',
            child: CommentTile(
              source: widget.source,
              comment: comment,
              service: widget.service,
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ThemeData theme = Theme.of(context);
    final bool loggedIn =
        context.watch<SourceAuthManager>().isLoggedIn(widget.source);
    final bool canPost =
        loggedIn && widget.source.comments?.routes['post'] != null;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.allCommentsTitle)),
      body: _buildBody(l10n, theme),
      floatingActionButton: canPost
          ? FloatingActionButton.extended(
              onPressed: _writeComment,
              icon: const Icon(Icons.edit_outlined),
              label: Text(l10n.writeComment),
            )
          : null,
    );
  }
}

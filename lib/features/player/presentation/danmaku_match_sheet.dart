import 'package:flutter/material.dart';
import '../../../core/widgets/app_animations.dart';
import 'package:nexhub/generated/app_localizations.dart';

import '../../../core/danmaku/danmaku_repository.dart';
import '../../../core/danmaku/danmaku_source.dart';
import '../../../core/theme/app_tokens.dart';

/// 手动匹配弹幕面板（底部 Sheet）。
///
/// 流程：输入番剧名搜索 → 选择番剧 → 选择剧集 → 返回该集的 dandanplay episodeId。
/// 用于自动匹配失败时的兜底，或直接为当前集指定弹幕。
class DanmakuMatchSheet extends StatefulWidget {
  const DanmakuMatchSheet({
    super.key,
    required this.repo,
    required this.initialKeyword,
    this.currentEpisodeId,
  });

  final DanmakuRepository repo;
  final String initialKeyword;
  final String? currentEpisodeId;

  /// 以 modal bottom sheet 形式展示，返回选定的 episodeId（取消返回 null）。
  static Future<int?> show(
    BuildContext context, {
    required DanmakuRepository repo,
    required String initialKeyword,
    String? currentEpisodeId,
  }) {
    return showModalBottomSheet<int?>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppTokens.radiusLg),
        ),
      ),
      builder: (BuildContext context) => DanmakuMatchSheet(
        repo: repo,
        initialKeyword: initialKeyword,
        currentEpisodeId: currentEpisodeId,
      ),
    );
  }

  @override
  State<DanmakuMatchSheet> createState() => _DanmakuMatchSheetState();
}

class _DanmakuMatchSheetState extends State<DanmakuMatchSheet> {
  late final TextEditingController _query;
  List<DanmakuSearchResult>? _animes;
  List<DanmakuEpisode>? _episodes;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _query = TextEditingController(text: widget.initialKeyword);
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _doSearch() async {
    final kw = _query.text.trim();
    if (kw.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
      _animes = null;
      _episodes = null;
    });
    try {
      final res = await widget.repo.search(kw);
      setState(() {
        _animes = res;
        _loading = false;
      });
    } on Object catch (e) {
      setState(() {
        _error = 'search_failed: $e';
        _loading = false;
      });
    }
  }

  Future<void> _selectAnime(DanmakuSearchResult anime) async {
    setState(() {
      _loading = true;
      _error = null;
      _episodes = null;
    });
    try {
      // /api/v2/search/episodes 按作品标题搜索，而非 animeId。
      final eps = await widget.repo.getEpisodes(anime.title);
      setState(() {
        _episodes = eps;
        _loading = false;
      });
    } on Object catch (e) {
      setState(() {
        _error = 'episodes_failed: $e';
        _loading = false;
      });
    }
  }

  void _selectEpisode(DanmakuEpisode ep) {
    final id = int.tryParse(ep.episodeId);
    Navigator.of(context).maybePop(id);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return AppSheetBody(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _header(context, l10n, theme),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppTokens.spaceLg,
                vertical: AppTokens.spaceXs,
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: _query,
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: l10n.danmakuSearchHint,
                        border: const OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => _doSearch(),
                    ),
                  ),
                  const SizedBox(width: AppTokens.spaceSm),
                  FilledButton(
                    onPressed: _loading ? null : _doSearch,
                    child: Text(l10n.danmakuSearch),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppTokens.spaceXs),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(AppTokens.spaceLg),
                child: CircularProgressIndicator(),
              )
            else if (_error != null)
              Padding(
                padding: const EdgeInsets.all(AppTokens.spaceLg),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(l10n.danmakuLoadFailed,
                        style: theme.textTheme.bodySmall),
                    const SizedBox(height: AppTokens.spaceXs),
                    Text(
                      _error!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              )
            else if (_episodes != null)
              _episodeList(l10n, theme)
            else if (_animes != null)
              _animeList(l10n, theme)
            else
              Padding(
                padding: const EdgeInsets.all(AppTokens.spaceLg),
                child: Text(l10n.danmakuNoResult,
                    style: theme.textTheme.bodySmall),
              ),
            const SizedBox(height: AppTokens.spaceMd),
          ],
        ),
      ),
    );
  }

  Widget _animeList(AppLocalizations l10n, ThemeData theme) {
    if (_animes!.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(AppTokens.spaceLg),
        child: Text(l10n.danmakuNoResult, style: theme.textTheme.bodySmall),
      );
    }
    return Flexible(
      child: ListView.builder(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(horizontal: AppTokens.spaceLg),
        itemCount: _animes!.length,
        itemBuilder: (context, i) {
          final a = _animes![i];
          return ListTile(
            title: Text(a.title),
            subtitle: a.subtitle != null ? Text(a.subtitle!) : null,
            dense: true,
            onTap: () => _selectAnime(a),
          );
        },
      ),
    );
  }

  Widget _episodeList(AppLocalizations l10n, ThemeData theme) {
    if (_episodes!.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(AppTokens.spaceLg),
        child: Text(l10n.danmakuNoResult, style: theme.textTheme.bodySmall),
      );
    }
    return Flexible(
      child: ListView.builder(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(horizontal: AppTokens.spaceLg),
        itemCount: _episodes!.length,
        itemBuilder: (context, i) {
          final e = _episodes![i];
          return ListTile(
            title: Text(e.title.isEmpty ? 'EP${e.episodeNumber ?? i + 1}' : e.title),
            dense: true,
            onTap: () => _selectEpisode(e),
          );
        },
      ),
    );
  }

  Widget _header(
    BuildContext context,
    AppLocalizations l10n,
    ThemeData theme,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTokens.spaceLg,
        AppTokens.spaceMd,
        AppTokens.spaceSm,
        AppTokens.spaceSm,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              l10n.danmakuMatchEpisode,
              style: theme.textTheme.titleMedium,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: l10n.close,
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }
}

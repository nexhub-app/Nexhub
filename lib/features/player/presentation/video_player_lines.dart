part of 'video_player_screen.dart';

extension _VideoLines on _VideoPlayerScreenState {
 /// 生成线路展示名（线路 1 / 线路 2 …），按 1 起编号。
  String _lineName(int index) {
    final l10n = AppLocalizations.of(context);
    return '${l10n.playerLine} ${index + 1}';
  }

 /// 由解析结果构造播放线路列表。
 ///
 /// 详情页 chips（天堂/精品/暴风/量子 等）选中后，`widget.episodes` 全集
 /// 里同名 [Episode.lineName] 字段反映该选择。本方法从全集按 lineName
 /// 分组，每组取当前 `_episodeIndex` 在该组里的同 position 副本：
 /// - 当前选中 lineName：用 [video] 的已解析 URL 直接 open；
 /// - 其他 lineName：暂用对应 ep.url 占位（剧集页 URL，未解析），
 ///  切到时由 [_changeEpisode] 重新解析（点该线路的某集才解析）；
 ///  不可用则 url 为空，open 时 [PlayerController._openCurrentLine]
 ///  会静默忽略。
 ///
 /// 单 line / 无 lineName 时按旧行为兜底为单条 "线路 1"，保持向后兼容。

 /// 由解析结果构造播放线路列表。
 ///
 /// 详情页 chips（天堂/精品/暴风/量子 等）选中后，`widget.episodes` 全集
 /// 里同名 [Episode.lineName] 字段反映该选择。本方法从全集按 lineName
 /// 分组，每组取当前 `_episodeIndex` 在该组里的同 position 副本：
 /// - 当前选中 lineName：用 [video] 的已解析 URL 直接 open；
 /// - 其他 lineName：暂用对应 ep.url 占位（剧集页 URL，未解析），
 ///  切到时由 [_changeEpisode] 重新解析（点该线路的某集才解析）；
 ///  不可用则 url 为空，open 时 [PlayerController._openCurrentLine]
 ///  会静默忽略。
 ///
 /// 单 line / 无 lineName 时按旧行为兜底为单条 "线路 1"，保持向后兼容。
  List<VideoLine> _buildLines(VideoResult video) {
    final episodes = widget.episodes;
    if (episodes == null || episodes.isEmpty) {
      return <VideoLine>[
        VideoLine(name: _lineName(0), url: video.url, headers: video.headers),
      ];
    }

  // 全集按 lineName 分组（保留原始顺序以便稳定映射 position）。
    final byLine = <String, List<int>>{};
    for (var i = 0; i < episodes.length; i++) {
      final ln = episodes[i].lineName ?? '';
      byLine.putIfAbsent(ln, () => <int>[]).add(i);
    }
    if (byLine.isEmpty) {
      return <VideoLine>[
        VideoLine(name: _lineName(0), url: video.url, headers: video.headers),
      ];
    }

    final String currentLine = _selectedLine ?? widget.episode.lineName ?? '';
    final List<int> currentGroup = byLine[currentLine] ?? <int>[];
    final int currentPos = currentGroup.contains(_episodeIndex)
        ? currentGroup.indexOf(_episodeIndex)
        : 0;

  // 按 lineName 排序保证 UI 顺序稳定。
    final sortedLines = byLine.keys.toList()..sort();
    return <VideoLine>[
      for (final ln in sortedLines)
        if (ln == currentLine)
          VideoLine(
            name: ln.isEmpty ? _lineName(0) : ln,
            url: video.url,
            headers: video.headers,
          )
        else
          VideoLine(
      name: ln.isEmpty ? _lineName(0) : ln, // 空线路名统一走 l10n
            url: _episodeUrlAt(byLine, episodes, ln, currentPos),
            headers: const <String, String>{},
          ),
    ];
  }

 /// 取出指定 lineName 组里第 [pos] 个全集 ep 的剧集页 URL；越界返回空串。
  String _episodeUrlAt(
    Map<String, List<int>> byLine,
    List<Episode> episodes,
    String line,
    int pos,
  ) {
    final group = byLine[line];
    if (group == null || pos < 0 || pos >= group.length) return '';
    return episodes[group[pos]].url;
  }

 // ─────────────────────── 多源自动选源 / 故障回退 ───────────────────────

 /// 在候选线路列表中按线路名找索引（线路名已 canonicalize，与记忆存储的键一致）。

 /// 在候选线路列表中按线路名找索引（线路名已 canonicalize，与记忆存储的键一致）。
  int? _indexOfLineName(String name) {
    for (var i = 0; i < _controller.lines.length; i++) {
      if (_controller.lines[i].name == name) return i;
    }
    return null;
  }

 /// 取指定候选线路的「可直接播放直链」。
 ///
 /// 索引 0 永远是刚解析出的当前线路（已是直链）；其它线路初始只是剧集页地址，
 /// 须重新走解析链路拿真实直链。解析失败（源要求验证等）返回 null，调用方回退。

 /// 取指定候选线路的「可直接播放直链」。
 ///
 /// 索引 0 永远是刚解析出的当前线路（已是直链）；其它线路初始只是剧集页地址，
 /// 须重新走解析链路拿真实直链。解析失败（源要求验证等）返回 null，调用方回退。
  Future<VideoLine?> _resolveLineUrl(int index) async {
    if (index < 0 || index >= _controller.lines.length) return null;
    if (_resolvedLineIndices.contains(index)) {
      return _controller.lines[index];
    }
    final pageUrl = _controller.lines[index].url;
    if (pageUrl.isEmpty) return null;
    try {
      final repo = context.read<SourceRepository>();
      final service = context.read<MediaApiService>();
      final source = repo.getById(widget.sourceId);
      if (source == null) return null;
      final video = await _resolveVideoWithCapture(service, source, pageUrl);
      if (video.url.isEmpty) return null;
      return VideoLine(
        name: _controller.lines[index].name,
        url: video.url,
        headers: video.headers,
      );
    } on Object {
      return null;
    }
  }

 /// 切换到指定候选线路并续播（故障回退 / 用户手动选源共用）。
 ///
 /// 目标线路若尚未解析（仍是剧集页地址）先重新解析拿到直链，再在同一 Player
 /// 实例上重开恢复播放；已解析过的线路直接复用 [PlayerController.selectLine]
 /// （含 位置恢复）。切换成功则记住该线路（按集），供下次进集自动选。
  Future<void> _switchActiveLine(int index,
      {Duration? resumeAt, bool remember = true}) async {
    if (_disposed || index < 0 || index >= _controller.lines.length) return;
    if (index == _controller.currentLineIndex) return;
    _reconnecting = true;
    try {
      final target = await _resolveLineUrl(index);
      if (target == null || target.url.isEmpty) return;
      _controller.lines[index] = target;
      _resolvedLineIndices.add(index);
      _controller.currentLineIndex = index;
      _playUrl = target.url;
      _playHeaders = target.headers;
   // 同一 Player 实例重开并恢复到断流前进度（/ 同款稳健 seek）。
      await _reopenAndResume(target.url, target.headers,
          resumeAt ?? _lastGoodPosition);
      await _controller.play();
   // 仅用户手动选源才记忆；故障自动回退不写死偏好（避免临时死链被永久锁定）。
      if (remember) {
        _rememberLine(target.name);
        if (mounted) {
          _safeSnackBar(
              AppLocalizations.of(context).playerLineSwitched(target.name));
        }
      }
    } on Object {
   // 切换失败静默忽略，stall / 重连逻辑会接管后续恢复。
    } finally {
      _reconnecting = false;
    }
  }

 /// 记住用户手动选中的线路（按「源 + 剧集」）。

 /// 记住用户手动选中的线路（按「源 + 剧集」）。
  Future<void> _rememberLine(String lineName) async {
    try {
      await _lineStore.setSelectedLine(
          widget.sourceId, widget.episode.id, lineName);
    } on Object {
   // 记忆失败不影响播放。
    }
  }

 /// 故障回退：找一个尚未尝试过的候选线路索引（排除当前线路）。
 /// 返回 null 表示所有候选线路都已尝试过，应放弃自动切换。

 /// 故障回退：找一个尚未尝试过的候选线路索引（排除当前线路）。
 /// 返回 null 表示所有候选线路都已尝试过，应放弃自动切换。
  int? _nextUntriedLine() {
    for (var i = 0; i < _controller.lines.length; i++) {
      if (i != _controller.currentLineIndex && !_triedLineIndices.contains(i)) {
        return i;
      }
    }
    return null;
  }

 /// 安全地弹 SnackBar：widget 失活（异步回调滞后）时吞掉异常，避免崩溃。

 /// 弹出选集 + 线路 sheet（FR-3.4）。
 ///
 /// 行为（Bug F 修复）：
 /// - 上半：剧集列表，只显示**当前选中线路**的集。
 /// - 下半：播放线路分组。点击线路**只切换上方要显示的集分组**——
 ///  面板不关闭、也**不立即解析**；只有点完某一集，才由 [_changeEpisode]
 ///  走视频嗅探解析并播放。
 ///
 /// 线路分组键使用全集各 `Episode.lineName` 的**原始值**（而非
 /// [_controller.lines] 里被 canonicalize 过的名字），这样与上方剧集过滤
 /// 用的是同一把钥匙，空串线路名也能正确对上。
 ///
 /// 本地合并多集（[_isDirectMode] 且 [widget.episodes] 非空）也走此面板切换集；
 /// 单集 / 无全集列表时调用方（控件区）已隐藏入口，不会触发。
  void _showLineSheet(AppLocalizations l10n) {
    final allEpisodes = widget.episodes ?? <Episode>[];
  // 全集按 lineName 分组（保留原始值作为分组键）。
    final byLine = <String, List<int>>{};
    for (var i = 0; i < allEpisodes.length; i++) {
      final ln = allEpisodes[i].lineName ?? '';
      byLine.putIfAbsent(ln, () => <int>[]).add(i);
    }
    final distinctLines = byLine.keys.toList()..sort();

  // 当前选中线路（面板内的局部可变状态）：初始为正在播放的那条。
    String selectedLine = _selectedLine ?? widget.episode.lineName ?? '';

  // 选集面板打开期间持有控制栏，禁止自动隐藏。
    _acquirePanelHold();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext ctx) {
        return StatefulBuilder(
          builder: (BuildContext ctx, StateSetter setStateSheet) {
            final filteredIndices = byLine[selectedLine] ?? <int>[];
      // 过滤后当前位置（1 起，仅用于 header 提示）
            final currentPosInLine = filteredIndices.contains(_episodeIndex)
                ? filteredIndices.indexOf(_episodeIndex) + 1
                : 0;
            return SafeArea(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(ctx).size.height * 0.85,
                ),
                child: Column(
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.all(AppTokens.spaceMd),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              l10n.playerEpisodes,
                              style: Theme.of(ctx).textTheme.titleMedium,
                            ),
                          ),
                          if (selectedLine.isNotEmpty &&
                              filteredIndices.isNotEmpty)
                            Text(
                              l10n.playerLineEpisodesProgress(
                                currentPosInLine, filteredIndices.length),
                              style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                                    color: Theme.of(ctx)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                            ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
          // 当前播放线路切换（手动选源，按集记忆）。
          // 仅当候选线路 > 1 时显示；点选即切换正在播放的线路并记住。
                    if (_controller.lines.length > 1)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                            AppTokens.spaceMd,
                            AppTokens.spaceSm,
                            AppTokens.spaceMd,
                            0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              l10n.playerCurrentPlayingLine,
                              style: Theme.of(ctx)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                    color: Theme.of(ctx)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                            ),
                            const SizedBox(height: AppTokens.spaceXs),
                            SizedBox(
                              height: 36,
                              child: ListView.separated(
                                scrollDirection: Axis.horizontal,
                                itemCount: _controller.lines.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(width: AppTokens.spaceSm),
                                itemBuilder: (BuildContext _, int i) {
                                  final line = _controller.lines[i];
                                  final active =
                                      i == _controller.currentLineIndex;
                                  return ChoiceChip(
                                    label: Text(line.name),
                                    selected: active,
                                    onSelected: (bool _) async {
                                      if (i ==
                                          _controller.currentLineIndex) {
                                        return;
                                      }
                   // 关闭面板后切换（与选集同理：点选即生效）。
                                      Navigator.pop(ctx);
                                      await _switchActiveLine(i);
                                    },
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                      )
                    else
                      const SizedBox.shrink(),
                    const Divider(height: 1),
          // 上半：当前线路的剧集列表（仅显示过滤后的集）。
                    Expanded(
                      child: filteredIndices.isEmpty
                          ? _buildLineHint(
                              ctx,
                              icon: Icons.error_outline,
                              text: l10n.playerLineEmpty,
                            )
                          : ListView.builder(
                              itemCount: filteredIndices.length,
                              itemBuilder: (BuildContext _, int j) {
                                final globalIdx = filteredIndices[j];
                                final ep = allEpisodes[globalIdx];
                                final selected = globalIdx == _episodeIndex;
                                final lineLabel = selectedLine.isEmpty
                                    ? _lineName(0)
                                    : selectedLine;
                                return ListTile(
                                  dense: true,
                                  leading: CircleAvatar(
                                    backgroundColor: selected
                                        ? Theme.of(ctx).colorScheme.primary
                                        : null,
                                    child: Text('${j + 1}'),
                                  ),
                                  title: Text(
                                    ep.title,
                                    style: selected
                                        ? TextStyle(
                                            color: Theme.of(ctx)
                                                .colorScheme
                                                .primary,
                                            fontWeight: FontWeight.bold,
                                          )
                                        : null,
                                  ),
                                  subtitle: selectedLine.isNotEmpty
                                      ? Text(
                                          lineLabel,
                                          style: Theme.of(ctx)
                                              .textTheme
                                              .bodySmall
                                              ?.copyWith(
                                                color: Theme.of(ctx)
                                                    .colorScheme
                                                    .onSurfaceVariant,
                                              ),
                                        )
                                      : null,
                                  onTap: () {
                  // 点集才关闭面板并解析播放。
                                    Navigator.pop(ctx);
                                    if (globalIdx != _episodeIndex) {
                                      _changeEpisode(globalIdx);
                                    }
                                  },
                                );
                              },
                            ),
                    ),
                    const Divider(height: 1),
          // 播放线路：横向 Chip 行（节省垂直空间，集数区可显示更多）。
                    if (distinctLines.length > 1)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                            AppTokens.spaceMd,
                            AppTokens.spaceSm,
                            AppTokens.spaceMd,
                            AppTokens.spaceSm),
                        child: SizedBox(
                          height: 40,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: distinctLines.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(width: AppTokens.spaceSm),
                            itemBuilder: (BuildContext _, int i) {
                              final rawLine = distinctLines[i];
                              final displayName = rawLine.isEmpty
                                  ? _lineName(i)
                                  : rawLine;
                              final selected = rawLine == selectedLine;
                              return ChoiceChip(
                                label: Text(displayName),
                                selected: selected,
                                onSelected: (bool selected) {
                                  if (!selected) return;
                                  setStateSheet(() {
                                    selectedLine = rawLine;
                                  });
                                },
                              );
                            },
                          ),
                        ),
                      )
                    else if (distinctLines.length == 1)
           // 单线路时仅显示标签名（不可点击），保持布局一致。
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                            AppTokens.spaceMd,
                            AppTokens.spaceSm,
                            AppTokens.spaceMd,
                            AppTokens.spaceSm),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Icon(Icons.radio_button_checked,
                                  size: 16,
                                  color:
                                      Theme.of(ctx).colorScheme.primary),
                              const SizedBox(width: AppTokens.spaceXs),
                              Text(
                                distinctLines.first.isEmpty
                                    ? _lineName(0)
                                    : distinctLines.first,
                                style: Theme.of(ctx).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    )
    // 面板关闭后释放控制栏租约。
        .whenComplete(_releasePanelHold);
  }

 /// 线路 ≤1 条时的提示占位（图标 + 文案 + 居中）。
 ///
 /// 源共创式架构下，源作者写 `urls` 数组才会出现多线路。`lines.isEmpty`
 /// 多为源未声明/解析失败；`lines.length == 1` 则源只返回了 1 条 URL，
 /// 提示用户可让源作者补 urls 数组。
  Widget _buildLineHint(
    BuildContext ctx, {
    required IconData icon,
    required String text,
  }) {
    final theme = Theme.of(ctx);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTokens.spaceLg,
        vertical: AppTokens.spaceMd,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, color: theme.colorScheme.outline, size: 20),
          const SizedBox(width: AppTokens.spaceSm),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

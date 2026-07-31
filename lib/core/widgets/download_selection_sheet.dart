/// 共享「批量下载选集」弹窗（详情页重构 Phase 2）。
///
/// 重构前影视 / 漫画 / 小说三套详情页各有一份 `_show...SelectionSheet`，
/// 逐字重复约 180 行，仅两处不同：
///
/// 1. 总数：影视按线路去重（多线路镜像会叠加），漫画/小说取列表长度；
/// 2. 副标题：影视显示线路名，其余无。
///
/// 两者都可由 [computeTotalEpisodes] 与 [Episode.lineName] 自动派生，
/// 因此收敛为本文件的单一实现。
///
/// 相比旧实现的改进：
/// * [TextEditingController] 由 [State.dispose] 回收（旧实现每次打开都泄漏两个）；
/// * 内容根部包 [AppSheetBody]，弹出时带回弹放大，与全局动效语言一致；
/// * 顶部补一条拖拽指示条，符合 Material 3 bottom sheet 规范。
library;

import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';

import '../models/episode.dart';
import '../progress/unified_progress_repository.dart';
import '../theme/app_tokens.dart';
import 'app_animations.dart';

/// 弹出批量下载选集弹窗，返回用户勾选的**原始索引**升序列表。
///
/// 取消或未选返回 null / 空列表，调用方需自行判空。
///
/// [progress] 用于「仅未读/未看」预设；为 null 时该预设按「全选」处理
/// （无已读信息即视作全部未读）。
Future<List<int>?> showDownloadSelectionSheet({
  required BuildContext context,
  required List<Episode> chapters,
  required String contentId,
  UnifiedProgressRepository? progress,
}) {
  return showModalBottomSheet<List<int>>(
    context: context,
    isScrollControlled: true,
    builder: (BuildContext sheetCtx) => _DownloadSelectionSheet(
      chapters: chapters,
      contentId: contentId,
      progress: progress,
    ),
  );
}

class _DownloadSelectionSheet extends StatefulWidget {
  const _DownloadSelectionSheet({
    required this.chapters,
    required this.contentId,
    this.progress,
  });

  final List<Episode> chapters;
  final String contentId;
  final UnifiedProgressRepository? progress;

  @override
  State<_DownloadSelectionSheet> createState() =>
      _DownloadSelectionSheetState();
}

class _DownloadSelectionSheetState extends State<_DownloadSelectionSheet> {
  final Set<int> _selected = <int>{};
  final TextEditingController _startCtrl = TextEditingController();
  final TextEditingController _endCtrl = TextEditingController();

  /// 可选总数：影视按线路去重后的最大一组，漫画/小说即列表长度。
  late final int _total = computeTotalEpisodes(widget.chapters);

  /// 所有去重线路名（保留出现顺序）。
  late final List<String> _lines = () {
    final seen = <String>{};
    final result = <String>[];
    for (final ep in widget.chapters) {
      final ln = ep.lineName;
      if (ln != null && ln.isNotEmpty && seen.add(ln)) {
        result.add(ln);
      }
    }
    return result;
  }();

  /// 当前选中的线路索引（_lines 中的位置）；-1 表示「全部」。
  int _lineIndex = -1;

  /// 当前实际展示的集数列表（原始索引），受 _lineIndex 筛选。
  List<int> get _displayIndices {
    if (_lineIndex < 0 || _lines.isEmpty) {
      return List<int>.generate(_total, (i) => i);
    }
    final targetLine = _lines[_lineIndex];
    return <int>[
      for (int i = 0; i < _total; i++)
        if (widget.chapters[i].lineName == targetLine) i,
    ];
  }

  @override
  void dispose() {
    _startCtrl.dispose();
    _endCtrl.dispose();
    super.dispose();
  }

  void _selectAll() => setState(() {
        _selected
          ..clear()
          ..addAll(_displayIndices);
      });

  void _deselectAll() => setState(_selected.clear);

  void _applyRange() {
    final s = int.tryParse(_startCtrl.text);
    final e = int.tryParse(_endCtrl.text);
    if (s == null || e == null || _displayIndices.isEmpty) return;
    final displayTotal = _displayIndices.length;
    final start = s.clamp(1, displayTotal);
    final end = e.clamp(1, displayTotal);
    final lo = start < end ? start : end;
    final hi = start < end ? end : start;
    setState(() {
      _selected
        ..clear()
        ..addAll(List<int>.generate(hi - lo + 1, (i) => _displayIndices[lo - 1 + i]));
    });
  }

  /// 「最新 N 话」：从末尾往前取 N 个（基于当前筛选视图）。
  void _presetLatest(int n) => setState(() {
        final displayTotal = _displayIndices.length;
        _selected
          ..clear()
          ..addAll(List<int>.generate(
            n > displayTotal ? displayTotal : n,
            (i) => _displayIndices[displayTotal - 1 - i],
          ));
      });

  /// 「仅未读/未看」：当前筛选视图内全集减去已读集合。
  void _presetUnread() {
    final read = widget.progress?.readIndices(widget.contentId).toSet() ??
        const <int>{};
    setState(() {
      _selected
        ..clear()
        ..addAll(_displayIndices.where((i) => !read.contains(i)));
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;

    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.7,
        child: AppSheetBody(
          child: Column(
            children: <Widget>[
              // 拖拽指示条。
              Padding(
                padding: const EdgeInsets.only(top: AppTokens.spaceSm),
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(AppTokens.radiusFull),
                  ),
                ),
              ),
              // 标题 + 全选 / 取消全选。
              Padding(
                padding: const EdgeInsets.all(AppTokens.spaceMd),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        l10n.downloadEpisodes,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    TextButton(
                      onPressed: _total > 0 ? _selectAll : null,
                      child: Text(l10n.selectAll),
                    ),
                    TextButton(
                      onPressed: _selected.isEmpty ? null : _deselectAll,
                      child: Text(l10n.deselectAll),
                    ),
                  ],
                ),
              ),
              // 快捷预设。
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: AppTokens.spaceMd),
                child: Wrap(
                  spacing: AppTokens.spaceSm,
                  runSpacing: AppTokens.spaceSm,
                  children: <Widget>[
                    ActionChip(
                      label: Text(l10n.downloadPreset1),
                      onPressed: () => _presetLatest(1),
                    ),
                    ActionChip(
                      label: Text(l10n.downloadPreset5),
                      onPressed: () => _presetLatest(5),
                    ),
                    ActionChip(
                      label: Text(l10n.downloadPreset10),
                      onPressed: () => _presetLatest(10),
                    ),
                    ActionChip(
                      label: Text(l10n.downloadUnread),
                      onPressed: _presetUnread,
                    ),
                  ],
                ),
              ),
              // 区间选择。
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: AppTokens.spaceMd),
                child: Row(
                  children: <Widget>[
                    Text(l10n.episodeRange),
                    const SizedBox(width: AppTokens.spaceSm),
                    SizedBox(
                      width: 56,
                      child: TextField(
                        controller: _startCtrl,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          isDense: true,
                          labelText: l10n.rangeStart,
                        ),
                      ),
                    ),
                    const Text(' - '),
                    SizedBox(
                      width: 56,
                      child: TextField(
                        controller: _endCtrl,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          isDense: true,
                          labelText: l10n.rangeEnd,
                        ),
                      ),
                    ),
                    const SizedBox(width: AppTokens.spaceSm),
                    TextButton(
                      onPressed: _applyRange,
                      child: Text(l10n.applyRange),
                    ),
                  ],
                ),
              ),
              const Divider(),
              // ── 线路筛选（多线路时显示）──
              if (_lines.length > 1) ...<Widget>[
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppTokens.spaceMd,
                    vertical: AppTokens.spaceXs,
                  ),
                  child: Row(
                    children: <Widget>[
                      Text(
                        l10n.videoSourceLine,
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                      const SizedBox(width: AppTokens.spaceSm),
                      Expanded(
                        child: SizedBox(
                          height: 36,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: _lines.length + 1, // +「全部」
                            separatorBuilder: (_, __) =>
                                const SizedBox(width: AppTokens.spaceXs),
                            itemBuilder: (BuildContext _, int li) {
                              final label = li == 0 ? l10n.selectAll : _lines[li - 1];
                              final selected = _lineIndex == li - 1;
                              return FilterChip(
                                label: Text(label),
                                selected: selected,
                                onSelected: (bool v) => setState(() {
                                  _lineIndex = v ? li - 1 : -1;
                                  _selected.clear(); // 切换线路时清空选择
                                }),
                                visualDensity: VisualDensity.compact,
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(),
              ],
              Expanded(
                child: ListView.builder(
                  itemCount: _displayIndices.length,
                  itemBuilder: (BuildContext _, int pos) {
                    final i = _displayIndices[pos];
                    final ep = widget.chapters[i];
                    final line = ep.lineName;
                    return CheckboxListTile(
                      value: _selected.contains(i),
                      onChanged: (bool? v) => setState(() {
                        if (v == true) {
                          _selected.add(i);
                        } else {
                          _selected.remove(i);
                        }
                      }),
                      title: Text(ep.title),
                      subtitle:
                          (line != null && line.isNotEmpty) ? Text(line) : null,
                    );
                  },
                ),
              ),
              const Divider(),
              // 底部计数 + 确认。
              Padding(
                padding: const EdgeInsets.all(AppTokens.spaceMd),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(l10n.selectedCount(
                        _selected.length,
                        _displayIndices.length,
                      )),
                    ),
                    FilledButton(
                      onPressed: _selected.isEmpty
                          ? null
                          : () => Navigator.of(context)
                              .pop(_selected.toList()..sort()),
                      child: Text(l10n.addToDownload),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

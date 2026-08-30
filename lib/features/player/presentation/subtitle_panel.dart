import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../../../core/ai/translation_exception.dart';
import '../../../core/utils/app_log.dart';
import '../../../core/ai/vision_translation_client.dart';
import '../../../core/player/player_controller.dart';
import '../../../core/player/subtitle_offline_pipeline.dart';
import '../../../core/player/subtitle_translation_controller.dart';
import '../../../core/settings/player_settings.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/utils/app_haptics.dart';
import '../../../core/widgets/app_alert_dialog.dart';
import '../../novel/domain/novel_summary_settings.dart';

/// 字幕面板（底部抽屉）。
///
/// 展示可用字幕轨道列表、字幕偏移滑块（-5s~+5s）与显示开关，
/// 通过 [PlayerController] 实时切换 / 调整字幕，变更立即生效。
/// 另含「实时翻译」区块（[SubtitleTranslationController]，可选注入）：
/// 开关 / 显示原文 / 无字幕时画面 OCR 兜底；「整片翻译（离线）」区块
/// （[SubtitleOfflinePipeline]，注入 videoPath 时显示）：外挂字幕文件
/// 整片批量翻译 + 双语 SRT/ASS 导出。
class SubtitlePanel extends StatefulWidget {
  const SubtitlePanel({
    super.key,
    required this.controller,
    this.defaults,
    this.translator,
    this.videoPath,
  });

  final PlayerController controller;

 /// 全局播放器默认设置：面板样式项的初始值来源（打通设置页默认值）。
  final PlayerSettings? defaults;

  /// 视频实时翻译控制器；null 时不显示翻译区块（如测试环境）。
  final SubtitleTranslationController? translator;

  /// 当前播放媒体路径（F6 离线整片翻译的任务标识；空时不显示该区块）。
  final String? videoPath;

 /// 以 modal bottom sheet 形式展示字幕面板。
  static Future<void> show(
    BuildContext context, {
    required PlayerController controller,
    PlayerSettings? defaults,
    SubtitleTranslationController? translator,
    String? videoPath,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppTokens.radiusLg),
        ),
      ),
      builder: (BuildContext context) => SubtitlePanel(
        controller: controller,
        defaults: defaults,
        translator: translator,
        videoPath: videoPath,
      ),
    );
  }

  @override
  State<SubtitlePanel> createState() => _SubtitlePanelState();
}

class _SubtitlePanelState extends State<SubtitlePanel> {
 /// 当前可用字幕轨道（过滤掉 'auto' / 'no' 占位项，仅展示真实轨道）。
  List<SubtitleTrack> _tracks = const <SubtitleTrack>[];

  StreamSubscription<Tracks>? _tracksSub;

  // ── F6 离线整片翻译 ──
  final SubtitleOfflinePipeline _offlinePipeline = SubtitleOfflinePipeline();
  String? _offlineJobId;
  bool _offlineStarting = false;

 // ── 字幕样式状态（本地 UI 状态，onChangeEnd 时写入 mpv） ──
 // 初始值取自全局播放器默认设置（widget.defaults），与设置页打通。
  late double _subFontSize;
  late double _subScale;
  late double _subBorderSize;
  late double _subShadowOffset;
  late String _subColor;
  late String _subBorderColor;
  late String _subShadowColor;
  late String _subPosition;
  late String _subAssMode;

  @override
  void initState() {
    super.initState();
  // 样式初值取自控制器（已恢复的 记忆或默认回落值），与记忆打通。
    final c = widget.controller;
    _subFontSize = c.subFontSize;
    _subScale = c.subScale;
    _subBorderSize = c.subBorderSize;
    _subShadowOffset = c.subShadowOffset;
    _subColor = c.subColor;
    _subBorderColor = c.subBorderColor;
    _subShadowColor = c.subShadowColor;
    _subPosition = c.subPosition;
    _subAssMode = c.subAssMode;
    unawaited(_refreshJobs());
    _refreshTracks(widget.controller.subtitleTracks);
    _tracksSub = widget.controller.tracksStream.listen((Tracks t) {
      _refreshTracks(t.subtitle);
    });
  }

  @override
  void dispose() {
    _tracksSub?.cancel();
    super.dispose();
  }

 /// 更新可用字幕轨道列表（过滤占位项），并同步当前选中轨道的显示状态。
  void _refreshTracks(List<SubtitleTrack> tracks) {
    final real = tracks
        .where((SubtitleTrack t) => t.id != 'auto' && t.id != 'no')
        .toList(growable: false);
    if (mounted) setState(() => _tracks = real);
  }

 /// 生成轨道展示标签：优先 title，其次 language，最后回退到「轨道 N」。
  String _trackLabel(SubtitleTrack track, AppLocalizations l10n) {
    if (track.title != null && track.title!.trim().isNotEmpty) {
      return track.title!.trim();
    }
    if (track.language != null && track.language!.trim().isNotEmpty) {
      return track.language!.trim();
    }
    return l10n.subtitleTrackN(track.id);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.85,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _header(context, l10n, theme),
          Flexible(
            child: AnimatedBuilder(
              animation: widget.controller,
              builder: (BuildContext context, _) {
                return ListView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppTokens.spaceLg,
                    vertical: AppTokens.spaceSm,
                  ),
                  children: <Widget>[
                    _trackSection(l10n, theme),
                    const Divider(height: 1),
                    _styleSection(l10n, theme),
                    const SizedBox(height: AppTokens.spaceMd),
                    _offsetSection(l10n, theme),
                    const SizedBox(height: AppTokens.spaceXs),
                    _visibleSection(l10n, theme),
                    if (widget.translator != null) ...<Widget>[
                      const SizedBox(height: AppTokens.spaceXs),
                      const Divider(height: 1),
                      _translationSection(l10n, theme),
                    ],
                    if ((widget.videoPath ?? '').isNotEmpty) ...<Widget>[
                      const SizedBox(height: AppTokens.spaceXs),
                      const Divider(height: 1),
                      _offlineSection(l10n, theme),
                    ],
                    const SizedBox(height: AppTokens.spaceLg),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, AppLocalizations l10n, ThemeData theme) {
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
              l10n.subtitleTitle,
              style: theme.textTheme.titleMedium,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).maybePop(),
            tooltip: l10n.close,
          ),
        ],
      ),
    );
  }

  Widget _trackSection(AppLocalizations l10n, ThemeData theme) {
    final current = widget.controller.currentSubtitleTrack;
    final visible = widget.controller.subtitleVisible;
  // 当前生效的轨道：显示开关关闭时视为未选中。
    final selected = visible ? current : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
    // #5 A4-#5: 加载外部字幕文件
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.file_open_outlined, color: theme.colorScheme.primary),
          title: Text(l10n.loadExternalSubtitle),
          onTap: () => _pickExternalSubtitle(l10n),
        ),
        const Divider(height: 1),
        for (final SubtitleTrack track in _tracks)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(_trackLabel(track, l10n)),
            trailing: selected?.id == track.id
                ? Icon(Icons.check, color: theme.colorScheme.primary)
                : null,
            onTap: () {
              widget.controller.setSubtitleTrack(track);
              unawaited(widget.controller.saveSubtitleState());
            },
          ),
    // 关闭字幕
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.subtitleNone),
          trailing: selected == null
              ? Icon(Icons.check, color: theme.colorScheme.primary)
              : null,
          onTap: () {
            widget.controller.setSubtitleTrack(null);
            unawaited(widget.controller.saveSubtitleState());
          },
        ),
        if (_tracks.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppTokens.spaceSm),
            child: Text(
              l10n.subtitleNoTracks,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }

 /// #5 A4-#5: 通过 file_picker 选择本地 .srt/.vtt/.ass 字幕文件，
 /// 使用 SubtitleTrack.uri 加载到播放器。
  Future<void> _pickExternalSubtitle(AppLocalizations l10n) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const <String>['srt', 'vtt', 'ass', 'ssa'],
      );
      if (result == null || result.files.isEmpty) return;
      final path = result.files.first.path;
      if (path == null || path.isEmpty) return;
      final track = SubtitleTrack.uri(path);
      await widget.controller.setSubtitleTrack(track);
      await widget.controller.setSubtitleVisible(true);
      await widget.controller.saveSubtitleState();
      messenger.showSnackBar(
        SnackBar(content: Text(track.title ?? path)),
      );
    } on Object {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.loadExternalSubtitleFailed)),
      );
    }
  }

 /// 字幕样式设置：字号 / 颜色 / 边框 / 阴影 / 缩放 / 位置 / ASS覆盖。
  Widget _styleSection(AppLocalizations l10n, ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
    // 标题
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AppTokens.spaceXs),
          child: Text(
            l10n.subtitleStyleTitle,
            style: theme.textTheme.titleSmall,
          ),
        ),
    // 字号滑块
        Row(
          children: <Widget>[
            Expanded(child: Text(l10n.subtitleFontSize, style: theme.textTheme.bodyMedium)),
            Text('${_subFontSize.toInt()}', style: theme.textTheme.bodySmall),
          ],
        ),
        Slider(
          value: _subFontSize,
          min: 14,
          max: 60,
          divisions: 46,
          onChangeStart: (_) => AppHaptics.light(),
          onChanged: (v) => setState(() => _subFontSize = v),
          onChangeEnd: (v) {
            widget.controller.setSubtitleFontSize(v);
            unawaited(widget.controller.saveSubtitleState());
          },
        ),
    // 缩放
        Row(
          children: <Widget>[
            Expanded(child: Text(l10n.subtitleScale, style: theme.textTheme.bodyMedium)),
            Text(_subScale.toStringAsFixed(2), style: theme.textTheme.bodySmall),
          ],
        ),
        Slider(
          value: _subScale,
          min: 0.5,
          max: 3.0,
          divisions: 50,
          onChangeStart: (_) => AppHaptics.light(),
          onChanged: (v) => setState(() => _subScale = v),
          onChangeEnd: (v) {
            widget.controller.setSubtitleScale(v);
            unawaited(widget.controller.saveSubtitleState());
          },
        ),
    // 边框宽度
        Row(
          children: <Widget>[
            Expanded(child: Text(l10n.subtitleBorderSize, style: theme.textTheme.bodyMedium)),
            Text('${_subBorderSize.toStringAsFixed(1)}px', style: theme.textTheme.bodySmall),
          ],
        ),
        Slider(
          value: _subBorderSize,
          min: 0,
          max: 6,
          divisions: 12,
          onChangeStart: (_) => AppHaptics.light(),
          onChanged: (v) => setState(() => _subBorderSize = v),
          onChangeEnd: (v) {
            widget.controller.setSubtitleBorderSize(v);
            unawaited(widget.controller.saveSubtitleState());
          },
        ),
    // 阴影偏移
        Row(
          children: <Widget>[
            Expanded(child: Text(l10n.subtitleShadowOffset, style: theme.textTheme.bodyMedium)),
            Text('${_subShadowOffset.toStringAsFixed(1)}px', style: theme.textTheme.bodySmall),
          ],
        ),
        Slider(
          value: _subShadowOffset,
          min: 0,
          max: 12,
          divisions: 24,
          onChangeStart: (_) => AppHaptics.light(),
          onChanged: (v) => setState(() => _subShadowOffset = v),
          onChangeEnd: (v) {
            widget.controller.setSubtitleShadowOffset(v);
            unawaited(widget.controller.saveSubtitleState());
          },
        ),

        const SizedBox(height: AppTokens.spaceXs),

    // 颜色选择行（文字颜色 + 边框颜色 + 阴影颜色）
        Wrap(
          spacing: AppTokens.spaceSm,
          runSpacing: AppTokens.spaceXs,
          children: <Widget>[
            ActionChip(
              avatar: CircleAvatar(backgroundColor: _bgrToColor(_subColor), radius: 8),
              label: Text(l10n.subtitleTextColor),
              onPressed: () => _pickColor(l10n, isText: true),
            ),
            ActionChip(
              avatar: CircleAvatar(backgroundColor: _bgrToColor(_subBorderColor), radius: 8),
              label: Text(l10n.subtitleBorderColorLabel),
              onPressed: () => _pickColor(l10n, isBorder: true),
            ),
            ActionChip(
              avatar: CircleAvatar(backgroundColor: _bgrToColor(_subShadowColor), radius: 8),
              label: Text(l10n.subtitleShadowColorLabel),
              onPressed: () => _pickColor(l10n, isShadow: true),
            ),
          ],
        ),

        const SizedBox(height: AppTokens.spaceSm),

    // 位置选择
        Row(
          children: <Widget>[
            Expanded(child: Text(l10n.subtitlePosition, style: theme.textTheme.bodyMedium)),
          ],
        ),
        SegmentedButton<String>(
          segments: const <ButtonSegment<String>>[
            ButtonSegment(value: 'top', label: Text('顶部'), icon: Icon(Icons.vertical_align_top, size: 16)),
            ButtonSegment(value: 'center', label: Text('居中'), icon: Icon(Icons.vertical_align_center, size: 16)),
            ButtonSegment(value: 'bottom', label: Text('底部'), icon: Icon(Icons.vertical_align_bottom, size: 16)),
          ],
          selected: {_subPosition},
          onSelectionChanged: (Set<String> s) {
            final pos = s.first;
            setState(() => _subPosition = pos);
            widget.controller.setSubtitlePosition(pos);
            unawaited(widget.controller.saveSubtitleState());
          },
          showSelectedIcon: false,
          style: ButtonStyle(
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            padding: WidgetStateProperty.all(const EdgeInsets.symmetric(horizontal: AppTokens.spaceSm)),
            visualDensity: VisualDensity.compact,
          ),
        ),

        const SizedBox(height: AppTokens.spaceSm),

    // ASS/SSA 覆盖模式
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Text(l10n.subtitleAssOverride, style: theme.textTheme.bodyMedium),
            DropdownButton<String>(
              value: _subAssMode,
              items: const <DropdownMenuItem<String>>[
                DropdownMenuItem(value: 'yes', child: Text('是')),
                DropdownMenuItem(value: 'no', child: Text('否')),
                DropdownMenuItem(value: 'strip', child: Text('剥离')),
                DropdownMenuItem(value: 'force', child: Text('强制')),
              ],
              onChanged: (v) {
                if (v != null) {
                  setState(() => _subAssMode = v);
                  widget.controller.setSubtitleAssOverride(v);
                  unawaited(widget.controller.saveSubtitleState());
                }
              },
              underline: Container(),
              iconSize: 18,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ],
    );
  }

 /// 颜色选择器（弹出预设颜色网格）。
  Future<void> _pickColor(AppLocalizations l10n, {bool isText = false, bool isBorder = false, bool isShadow = false}) async {
    final colors = <String>[
   'FFFFFF', // 白
   'FFFF00', // 黄
   '00FF00', // 绿
   '00FFFF', // 青
   'FF0000', // 红
   'FF00FF', // 品红
   '0000FF', // 蓝
   '000000', // 黑
    ];
    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) => AppAlertDialog(
        title: Text(isText ? l10n.subtitleTextColor : isBorder ? l10n.subtitleBorderColorLabel : l10n.subtitleShadowColorLabel),
        content: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: colors.map((c) {
            final color = _bgrToColor(c);
            return GestureDetector(
              onTap: () => Navigator.pop(ctx, c),
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.white24),
                ),
              ),
            );
          }).toList(),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l10n.cancel)),
        ],
      ),
    );
    if (selected == null) return;
    if (isText) {
      setState(() => _subColor = selected);
      widget.controller.setSubtitleColor(selected);
      unawaited(widget.controller.saveSubtitleState());
    } else if (isBorder) {
      setState(() => _subBorderColor = selected);
      widget.controller.setSubtitleBorderColor(selected);
      unawaited(widget.controller.saveSubtitleState());
    } else {
      setState(() => _subShadowColor = selected);
      widget.controller.setSubtitleShadowColor(selected);
      unawaited(widget.controller.saveSubtitleState());
    }
  }

 /// BGR 十六进制字符串转 Color（mpv 使用 BGR 格式）。
  static Color _bgrToColor(String hex) {
    final val = int.tryParse(hex, radix: 16) ?? 0xFFFFFFFF;
  // mpv sub-color 是 BGR(AABBGGRR)，Flutter Color 是 ARGB(0xAARRGGBB)
    final r = (val >> 16) & 0xFF;
    final g = (val >> 8) & 0xFF;
    final b = val & 0xFF;
    return Color.fromARGB(255, r, g, b);
  }

  Widget _offsetSection(AppLocalizations l10n, ThemeData theme) {
    final delay = widget.controller.subtitleDelay;
    final seconds = delay.inMilliseconds / 1000.0;
    final sign = seconds >= 0 ? '+' : '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Text(l10n.subtitleOffset, style: theme.textTheme.bodyMedium),
            Text(
              '$sign${seconds.toStringAsFixed(1)}s',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.primary),
            ),
          ],
        ),
        Slider(
          value: seconds.clamp(-5.0, 5.0),
          min: -5,
          max: 5,
          divisions: 100,
          onChangeStart: (_) => AppHaptics.light(),
          onChanged: (double v) {
            widget.controller.setSubtitleDelay(Duration(milliseconds: (v * 1000).round()));
            unawaited(widget.controller.saveSubtitleState());
          },
        ),
      ],
    );
  }

  Widget _visibleSection(AppLocalizations l10n, ThemeData theme) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(l10n.subtitleShow),
      value: widget.controller.subtitleVisible,
      onChanged: (bool v) {
        AppHaptics.selectionClick();
        widget.controller.setSubtitleVisible(v);
        unawaited(widget.controller.saveSubtitleState());
      },
    );
  }

  /// 实时翻译区块（视频实时翻译功能）：开关 + 显示原文 + 画面 OCR 兜底。
  /// 译文渲染在播放画面覆盖层（TranslatedSubtitleOverlay），不在本面板内。
  /// 包 [ListenableBuilder]：开关切换后区块即时刷新（面板外层仅监听
  /// PlayerController，不覆盖翻译控制器的变更）。
  Widget _translationSection(AppLocalizations l10n, ThemeData theme) {
    final SubtitleTranslationController t = widget.translator!;
    return ListenableBuilder(
      listenable: t,
      builder: (BuildContext context, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppTokens.spaceXs),
              child: Text(
                l10n.subTransSectionTitle,
                style: theme.textTheme.titleSmall,
              ),
            ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.subTransToggle),
              subtitle: Text(l10n.subTransToggleDesc,
                  style: theme.textTheme.bodySmall),
              value: t.enabled,
              onChanged: (bool v) {
                AppHaptics.selectionClick();
                unawaited(t.setEnabled(v));
              },
            ),
            if (t.enabled) ...<Widget>[
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.subTransShowOriginal),
                value: t.showOriginal,
                onChanged: (bool v) {
                  AppHaptics.selectionClick();
                  unawaited(t.setShowOriginal(v));
                },
              ),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.subTransOcrFallback),
                subtitle: Text(l10n.subTransOcrFallbackDesc,
                    style: theme.textTheme.bodySmall),
                value: t.ocrFallback,
                onChanged: (bool v) {
                  AppHaptics.selectionClick();
                  unawaited(t.setOcrFallback(v));
                },
              ),
            ],
          ],
        );
      },
    );
  }

  /// F6 整片翻译（离线）：选外挂字幕文件 → 整片批量翻译（断点续跑）→
  /// 双语 SRT/ASS 导出（系统分享）与 WebDAV 上传。
  Widget _offlineSection(AppLocalizations l10n, ThemeData theme) {
    return ListenableBuilder(
      listenable: _offlinePipeline,
      builder: (BuildContext context, _) {
        final job =
            _offlineJobId == null ? null : _jobsById[_offlineJobId!];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppTokens.spaceXs),
              child: Text(l10n.offlineTranslateTitle,
                  style: theme.textTheme.titleSmall),
            ),
            if (job == null)
              Padding(
                padding: const EdgeInsets.only(bottom: AppTokens.spaceXs),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(l10n.offlineHint,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.outline)),
                    const SizedBox(height: AppTokens.spaceSm),
                    _offlineStarting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : OutlinedButton.icon(
                            onPressed: _pickSubtitleAndStart,
                            icon: const Icon(Icons.movie_filter_outlined,
                                size: 18),
                            label: Text(l10n.offlinePickSubtitle),
                          ),
                  ],
                ),
              )
            else ...<Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      job.status == SubtitleJobStatus.done
                          ? l10n.offlineJobDone
                          : l10n.offlineJobProgress(
                              job.translatedCount, job.cueCount),
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  if (job.status == SubtitleJobStatus.running)
                    IconButton(
                      tooltip: l10n.offlineCancel,
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () =>
                          _offlinePipeline.cancel(job.id),
                    ),
                ],
              ),
              if (job.status == SubtitleJobStatus.running)
                LinearProgressIndicator(
                  value: job.cueCount == 0
                      ? null
                      : job.translatedCount / job.cueCount,
                ),
              if (job.status == SubtitleJobStatus.failed) ...<Widget>[
                Text(job.error ?? l10n.offlineJobFailed,
                    style: TextStyle(
                        fontSize: 12, color: theme.colorScheme.error)),
                TextButton.icon(
                  onPressed: () => unawaited(_resumeOfflineJob(job)),
                  icon: const Icon(Icons.refresh, size: 16),
                  label: Text(l10n.offlineResume),
                ),
              ],
              if (job.status == SubtitleJobStatus.done) ...<Widget>[
                Wrap(
                  spacing: AppTokens.spaceSm,
                  runSpacing: AppTokens.spaceXs,
                  children: <Widget>[
                    OutlinedButton.icon(
                      onPressed: () =>
                          unawaited(_exportOffline(job, ass: false)),
                      icon: const Icon(Icons.file_download_outlined,
                          size: 16),
                      label: Text(l10n.offlineExportSrt),
                    ),
                    OutlinedButton.icon(
                      onPressed: () =>
                          unawaited(_exportOffline(job, ass: true)),
                      icon: const Icon(Icons.file_download_outlined,
                          size: 16),
                      label: Text(l10n.offlineExportAss),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => unawaited(_uploadOffline(job)),
                      icon: const Icon(Icons.cloud_upload_outlined,
                          size: 16),
                      label: Text(l10n.offlineUpload),
                    ),
                  ],
                ),
                OutlinedButton.icon(
                  onPressed: () => unawaited(_resumeOfflineJob(job)),
                  icon: const Icon(Icons.translate, size: 16),
                  label: Text(l10n.offlineRetranslate),
                ),
                // F10：批量导出全部已完成任务的双语 SRT。
                TextButton.icon(
                  onPressed: _doneJobCount > 1
                      ? () => unawaited(_exportAllOffline())
                      : null,
                  icon: const Icon(Icons.file_copy_outlined, size: 16),
                  label: Text(l10n.offlineExportAll,
                      style: const TextStyle(fontSize: 12)),
                ),
              ],
            ],
          ],
        );
      },
    );
  }

  /// 任务列表缓存（面板打开期间增量维护，进度经 pipeline 监听刷新）。
  final Map<String, SubtitleOfflineJob> _jobsById =
      <String, SubtitleOfflineJob>{};

  /// 已完成任务数（≥2 时显示批量导出入口，F10）。
  int get _doneJobCount => _jobsById.values
      .where((j) => j.status == SubtitleJobStatus.done)
      .length;

  /// F10：批量导出全部已完成任务的双语 SRT（系统分享多选文件）。
  Future<void> _exportAllOffline() async {
    final done = _jobsById.values
        .where((j) => j.status == SubtitleJobStatus.done)
        .toList(growable: false);
    final paths = <XFile>[];
    for (final job in done) {
      try {
        final path = await _offlinePipeline.export(job: job, ass: false);
        paths.add(XFile(path));
      } on Object catch (e) {
        AppLog.instance.w('[字幕离线] 批量导出单任务失败: $e');
      }
    }
    if (paths.isEmpty || !mounted) return;
    await Share.shareXFiles(paths);
  }

  Future<void> _refreshJobs() async {
    try {
      final jobs = await _offlinePipeline.listJobs();
      if (!mounted) return;
      setState(() {
        for (final j in jobs) {
          _jobsById[j.id] = j;
        }
      });
    } on Object {
      // Hive 不可用时隐藏离线区块状态。
    }
  }

  /// 选择字幕文件并创建/续跑任务。
  Future<void> _pickSubtitleAndStart() async {
    final l10n = AppLocalizations.of(context);
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['srt', 'ass', 'ssa', 'vtt'],
    );
    final path = result?.files.single.path;
    if (path == null || path.isEmpty || !mounted) return;
    await _startOfflineJob(path, l10n);
  }

  Future<void> _startOfflineJob(String subtitlePath, AppLocalizations l10n) async {
    setState(() => _offlineStarting = true);
    try {
      final settings = NovelSummarySettings.instance;
      final cfg = await settings.getMediaTranslationConfig();
      if (cfg.baseUrl.trim().isEmpty) {
        throw const TranslationException('未配置 AI 接口：请先在 设置 → AI 配置 中填写'
            '通用接口或视频翻译专用接口');
      }
      final lang = await settings.getMediaTranslationTargetLanguage();
      final id = await _offlinePipeline.start(
        videoPath: widget.videoPath!,
        videoTitle: p.basename(widget.videoPath!),
        subtitlePath: subtitlePath,
        lang: lang,
        config: AiEndpointConfig(
          baseUrl: cfg.baseUrl,
          apiKey: cfg.apiKey,
          model: cfg.model,
        ),
      );
      if (!mounted) return;
      setState(() => _offlineJobId = id);
      await _refreshJobs();
    } on Object catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    } finally {
      if (mounted) setState(() => _offlineStarting = false);
    }
  }

  /// 续跑既有任务（失败重试 / 补译）。
  Future<void> _resumeOfflineJob(SubtitleOfflineJob job) async {
    final l10n = AppLocalizations.of(context);
    await _startOfflineJob(job.subtitlePath, l10n);
  }

  /// 导出双语字幕并调起系统分享。
  Future<void> _exportOffline(SubtitleOfflineJob job, {required bool ass}) async {
    try {
      final path = await _offlinePipeline.export(job: job, ass: ass);
      if (!mounted) return;
      await Share.shareXFiles(<XFile>[XFile(path)]);
    } on Object catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    }
  }

  /// 上传双语字幕（默认 SRT）到 WebDAV。
  Future<void> _uploadOffline(SubtitleOfflineJob job) async {
    final l10n = AppLocalizations.of(context);
    try {
      final path = await _offlinePipeline.export(job: job, ass: false);
      final url = await _offlinePipeline.uploadToWebDav(path);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.offlineUploaded(url))),
      );
    } on Object catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    }
  }
}

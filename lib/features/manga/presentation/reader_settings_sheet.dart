import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';

import '../../../core/comic/models/reader_preferences.dart';
import '../../../core/theme/app_tokens.dart';
import 'reader_image_filter.dart';
import 'reader_tap_zones.dart';

/// 以 ModalBottomSheet 弹出漫画阅读设置（模态变体）。
///
/// 注意：漫画阅读器的「实时」设置入口是阅读器内的**内联面板**（桌面端右侧、
/// 移动端底部，与小说阅读器行为一致），由 [buildComicSettingsSheet] 承载内容、
/// 阅读器自行定位。本函数仅作为「模态底部弹窗」备用入口保留。
Future<void> showReaderSettings(
  BuildContext context,
  ReaderPreferences current, {
  void Function(ReaderPreferences)? onChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _FlatSettingsSheet(initial: current, onChanged: onChanged),
  );
}

/// 漫画设置面板内容（[ReaderPreferences] 驱动），供阅读器以「内联面板」形式
/// 直接嵌入阅读界面（桌面端右侧 / 移动端底部），或用于 [showReaderSettings] 模态弹窗。
///
/// [onClose] 非空时，关闭图标调用它（内联场景用它关闭面板）；为 null 时走
/// `Navigator.pop`（模态场景）。
Widget buildComicSettingsSheet({
  required ReaderPreferences initial,
  void Function(ReaderPreferences)? onChanged,
  VoidCallback? onClose,
}) =>
    _FlatSettingsSheet(initial: initial, onChanged: onChanged, onClose: onClose);

class _FlatSettingsSheet extends StatefulWidget {
  final ReaderPreferences initial;
  final void Function(ReaderPreferences)? onChanged;
  final VoidCallback? onClose;
  const _FlatSettingsSheet({
    required this.initial,
    required this.onChanged,
    this.onClose,
  });

  @override
  State<_FlatSettingsSheet> createState() => _FlatSettingsSheetState();
}

class _FlatSettingsSheetState extends State<_FlatSettingsSheet> {
  late ReaderPreferences _draft;

  @override
  void initState() {
    super.initState();
    _draft = widget.initial;
  }

  void _update(ReaderPreferences next) {
    setState(() => _draft = next);
    widget.onChanged?.call(next);
  }

  // ──────────────────── 构建辅助 ────────────────────

  /// 带标题的设置段（标题 + 子控件）。
  Widget _section(BuildContext context, String label, Widget child) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTokens.spaceMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AppTokens.spaceSm),
          child,
        ],
      ),
    );
  }

  /// 分组之间的次级标题（淡色，比主标题小），可选 [description] 在标题下方渲染说明。
  Widget _groupHeading(BuildContext context, String label, {String? description}) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: AppTokens.spaceMd, bottom: AppTokens.spaceXs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: textTheme.titleSmall?.copyWith(
              color: scheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (description != null && description.isNotEmpty) ...<Widget>[
            const SizedBox(height: AppTokens.spaceXs),
            Text(
              description,
              style: textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _switchTile(String label, bool value, ValueChanged<bool> onChanged) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      value: value,
      onChanged: onChanged,
    );
  }

  String _l(String key) {
    final l10n = AppLocalizations.of(context);
    switch (key) {
      // readingMode
      case 'readerModeSingleLTR':
        return l10n.readerModeSingleLTR;
      case 'readerModeSingleRTL':
        return l10n.readerModeSingleRTL;
      case 'readerModeSingleVertical':
        return l10n.readerModeSingleVertical;
      case 'readerModeWebtoon':
        return l10n.readerModeWebtoon;
      case 'readerModeWebtoonWithGap':
        return l10n.readerModeWebtoonWithGap;
      // orientation
      case 'readerOrientationDefault':
        return l10n.readerOrientationDefault;
      case 'readerOrientationSystem':
        return l10n.readerOrientationSystem;
      case 'readerOrientationPortrait':
        return l10n.readerOrientationPortrait;
      case 'readerOrientationLandscape':
        return l10n.readerOrientationLandscape;
      case 'readerOrientationLockPortrait':
        return l10n.readerOrientationLockPortrait;
      case 'readerOrientationLockLandscape':
        return l10n.readerOrientationLockLandscape;
      case 'readerOrientationReversePortrait':
        return l10n.readerOrientationReversePortrait;
      // background
      case 'readerBgBlack':
        return l10n.readerBgBlack;
      case 'readerBgGray':
        return l10n.readerBgGray;
      case 'readerBgWhite':
        return l10n.readerBgWhite;
      case 'readerBgAuto':
        return l10n.readerBgAuto;
      // tap zone
      case 'readerTapLShape':
        return l10n.readerTapLShape;
      case 'readerTapLeftRight':
        return l10n.readerTapLeftRight;
      case 'readerTapKindle':
        return l10n.readerTapKindle;
      case 'readerTapBothSides':
        return l10n.readerTapBothSides;
      case 'readerTapOff':
        return l10n.readerTapOff;
      // tap invert
      case 'readerTapInvertNone':
        return l10n.readerTapInvertNone;
      case 'readerTapInvertLeftRight':
        return l10n.readerTapInvertLeftRight;
      case 'readerTapInvertUpDown':
        return l10n.readerTapInvertUpDown;
      case 'readerTapInvertAll':
        return l10n.readerTapInvertAll;
      // flash color
      case 'readerFlashBlack':
        return l10n.readerFlashBlack;
      case 'readerFlashWhite':
        return l10n.readerFlashWhite;
      case 'readerFlashBlackWhite':
        return l10n.readerFlashBlackWhite;
      // initial zoom
      case 'readerZoomFitWidth':
        return l10n.readerZoomFitWidth;
      case 'readerZoomFitHeight':
        return l10n.readerZoomFitHeight;
      case 'readerZoomOriginal':
        return l10n.readerZoomOriginal;
      default:
        return key;
    }
  }

  // ──────────────────── 各设置的子控件 ────────────────────

  Widget _buildReadingMode() {
    return Wrap(
      spacing: AppTokens.spaceSm,
      runSpacing: AppTokens.spaceSm,
      children: ReadingMode.values.map((m) {
        return ChoiceChip(
          label: Text(_l(m.l10nKey())),
          selected: _draft.readingMode == m,
          onSelected: (_) {
            // 切到竖排 / 长条时双页拆分不再生效，自动关闭。
            final bool compatible =
                m == ReadingMode.singleLTR || m == ReadingMode.singleRTL;
            _update(_draft.copyWith(
              readingMode: m,
              splitDoublePage: compatible ? _draft.splitDoublePage : false,
            ));
          },
        );
      }).toList(),
    );
  }

  Widget _buildBackground() {
    return Wrap(
      spacing: AppTokens.spaceSm,
      runSpacing: AppTokens.spaceSm,
      children: ReaderBackgroundColor.values.map((b) {
        return ChoiceChip(
          label: Text(_l(b.l10nKey())),
          selected: _draft.background == b,
          onSelected: (_) => _update(_draft.copyWith(background: b)),
        );
      }).toList(),
    );
  }

  Widget _buildOrientation() {
    return Wrap(
      spacing: AppTokens.spaceSm,
      runSpacing: AppTokens.spaceSm,
      children: ScreenOrientation.values.map((o) {
        return ChoiceChip(
          label: Text(_l(o.l10nKey())),
          selected: _draft.orientation == o,
          onSelected: (_) => _update(_draft.copyWith(orientation: o)),
        );
      }).toList(),
    );
  }

  Widget _buildTapZone() {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Wrap(
          spacing: AppTokens.spaceSm,
          runSpacing: AppTokens.spaceSm,
          children: <ReaderTapZoneLayout>[
            ReaderTapZoneLayout.lShape,
            ReaderTapZoneLayout.leftRight,
            ReaderTapZoneLayout.kindle,
            ReaderTapZoneLayout.bothSides,
            ReaderTapZoneLayout.off,
          ].map((t) {
            return ChoiceChip(
              label: Text(_l(t.l10nKey())),
              selected: _draft.tapZoneLayout == t,
              onSelected: (_) => _update(_draft.copyWith(tapZoneLayout: t)),
            );
          }).toList(),
        ),
        const SizedBox(height: AppTokens.spaceSm),
        Text(l10n.readerTapPreviewHint,
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: AppTokens.spaceXs),
        SizedBox(
          height: 140,
          child: ReaderTapZones(
            showPreview: true,
            layout: _draft.tapZoneLayout,
            tapZoneInvert: _draft.tapZoneInvert,
            isVertical: false,
            previewLabels: <String, String>{
              'prev': l10n.tapPreviewPrev,
              'next': l10n.tapPreviewNext,
              'toggle': l10n.tapPreviewToggle,
            },
            onPrev: () {},
            onNext: () {},
            onToggleUi: () {},
          ),
        ),
      ],
    );
  }

  Widget _buildTapInvert() {
    return Wrap(
      spacing: AppTokens.spaceSm,
      runSpacing: AppTokens.spaceSm,
      children: TapZoneInvert.values.map((t) {
        return ChoiceChip(
          label: Text(_l(t.l10nKey())),
          selected: _draft.tapZoneInvert == t,
          onSelected: (_) => _update(_draft.copyWith(tapZoneInvert: t)),
        );
      }).toList(),
    );
  }

  Widget _buildInitialZoom() {
    return Wrap(
      spacing: AppTokens.spaceSm,
      runSpacing: AppTokens.spaceSm,
      children: ReaderInitialZoom.values.map((z) {
        return ChoiceChip(
          label: Text(_l(z.l10nKey())),
          selected: _draft.initialZoom == z,
          onSelected: (_) => _update(_draft.copyWith(initialZoom: z)),
        );
      }).toList(),
    );
  }

  Widget _buildFlashColor() {
    return Wrap(
      spacing: AppTokens.spaceSm,
      runSpacing: AppTokens.spaceSm,
      children: ReaderFlashColor.values.map((c) {
        return ChoiceChip(
          label: Text(_l(c.l10nKey())),
          selected: _draft.flashColor == c,
          onSelected: (_) => _update(_draft.copyWith(flashColor: c)),
        );
      }).toList(),
    );
  }

  Widget _buildImageFilter() {
    return ReaderImageFilterPanel(
      brightness: _draft.filterBrightness,
      contrast: _draft.filterContrast,
      colorTemp: _draft.filterColorTemp,
      saturation: _draft.filterSaturation,
      hue: _draft.filterHue,
      inverted: _draft.filterInverted,
      grayscale: _draft.filterGrayscale,
      onChanged: (b, c, t, s, h) => _update(_draft.copyWith(
        filterBrightness: b,
        filterContrast: c,
        filterColorTemp: t,
        filterSaturation: s,
        filterHue: h,
      )),
      onInvertedChanged: (v) => _update(_draft.copyWith(filterInverted: v)),
      onGrayscaleChanged: (v) => _update(_draft.copyWith(filterGrayscale: v)),
    );
  }

  // ──────────────────── 顶层构建 ────────────────────

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Container(
      constraints: BoxConstraints(
        maxHeight:
            MediaQuery.of(context).size.height * AppTokens.readerSettingsMaxHeightFactor,
      ),
      padding: const EdgeInsets.fromLTRB(
        AppTokens.spaceLg,
        AppTokens.spaceMd,
        AppTokens.spaceLg,
        AppTokens.spaceMd,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // 标题 + 关闭
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Text(l10n.readerSettings,
                  style: Theme.of(context).textTheme.titleLarge),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: widget.onClose ?? () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const Divider(height: 1),
          // 内容区（可滚动）
          Flexible(
            child: SingleChildScrollView(
              padding: EdgeInsets.zero,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  // ── 翻页与点击 ────────────────────────────────
                  _groupHeading(context, l10n.readerGroupPageTap,
                      description: l10n.readerGroupPageTapDesc),
                  _section(context, l10n.readerMode, _buildReadingMode()),
                  _section(context, l10n.readerBackground, _buildBackground()),
                  _section(context, l10n.readerOrientation, _buildOrientation()),
                  _section(context, l10n.readerTapZone, _buildTapZone()),
                  _section(context, l10n.readerTapInvert, _buildTapInvert()),
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppTokens.spaceMd),
                    child: _SliderRow(
                      label: l10n.readerSideMargin,
                      value: _draft.sideMargin,
                      min: 0.0,
                      max: 0.5,
                      divisions: 50,
                      displayValue: '${(_draft.sideMargin * 100).round()}%',
                      onChanged: (v) => _update(_draft.copyWith(sideMargin: v)),
                    ),
                  ),
                  _switchTile(l10n.readerZoom, _draft.doubleTapZoom,
                      (v) => _update(_draft.copyWith(doubleTapZoom: v))),
                  _section(context, l10n.readerInitialZoom, _buildInitialZoom()),

                  // ── 画面与滤镜 ────────────────────────────────
                  _groupHeading(context, l10n.readerGroupViewFilter,
                      description: l10n.readerGroupViewFilterDesc),
                  _buildImageFilter(),

                  // ── 进度与显示 ────────────────────────────────
                  _groupHeading(context, l10n.readerGroupProgress,
                      description: l10n.readerGroupProgressDesc),
                  _switchTile(l10n.readerCropEdge, _draft.cropEdge,
                      (v) => _update(_draft.copyWith(cropEdge: v))),
                  _switchTile(l10n.readerShowPageNumber, _draft.showPageNumber,
                      (v) => _update(_draft.copyWith(showPageNumber: v))),
                  _switchTile(l10n.readerProgressBarOnRight,
                      _draft.progressBarOnRight,
                      (v) => _update(_draft.copyWith(progressBarOnRight: v))),
                  _switchTile(l10n.readerKeepScreenOn, _draft.keepScreenOn,
                      (v) => _update(_draft.copyWith(keepScreenOn: v))),
                  _switchTile(l10n.readerRotatePage, _draft.rotateLandscape,
                      (v) => _update(_draft.copyWith(rotateLandscape: v))),
                  _switchTile(
                      l10n.readerSplitDoublePage, _draft.splitDoublePage, (v) {
                    ReaderPreferences next = _draft.copyWith(splitDoublePage: v);
                    if (v &&
                        _draft.readingMode != ReadingMode.singleLTR &&
                        _draft.readingMode != ReadingMode.singleRTL) {
                      next = next.copyWith(readingMode: ReadingMode.singleLTR);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(l10n.readerSplitDoublePageHint),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    }
                    _update(next);
                  }),
                  _switchTile(l10n.readerFullscreen, _draft.fullscreen,
                      (v) => _update(_draft.copyWith(fullscreen: v))),
                  _switchTile(l10n.readerLongPressMenu, _draft.showLongPressMenu,
                      (v) => _update(_draft.copyWith(showLongPressMenu: v))),
                  _switchTile(l10n.readerPreventShrink, _draft.preventShrink,
                      (v) => _update(_draft.copyWith(preventShrink: v))),
                  _switchTile(l10n.readerChapterTransition,
                      _draft.showChapterTransition,
                      (v) => _update(_draft.copyWith(showChapterTransition: v))),

                  // ── 翻页闪光 ────────────────────────────────
                  _groupHeading(context, l10n.readerGroupFlash,
                      description: l10n.readerGroupFlashDesc),
                  _switchTile(l10n.readerFlashEnabled, _draft.flashEnabled,
                      (v) => _update(_draft.copyWith(flashEnabled: v))),
                  if (_draft.flashEnabled) ...<Widget>[
                    Padding(
                      padding: const EdgeInsets.only(top: AppTokens.spaceXs),
                      child: _SliderRow(
                        label: l10n.readerFlashTime,
                        value: _draft.flashTime.toDouble(),
                        min: 50,
                        max: 600,
                        divisions: 55,
                        displayValue: '${_draft.flashTime} ms',
                        onChanged: (v) =>
                            _update(_draft.copyWith(flashTime: v.round())),
                      ),
                    ),
                    _SliderRow(
                      label: l10n.readerFlashInterval,
                      value: _draft.flashInterval.toDouble(),
                      min: 0,
                      max: 600,
                      divisions: 60,
                      displayValue: '${_draft.flashInterval} ms',
                      onChanged: (v) =>
                          _update(_draft.copyWith(flashInterval: v.round())),
                    ),
                  ],
                  _section(context, l10n.readerFlashColor, _buildFlashColor()),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 通用滑块行（标签 + 滑块 + 数值）。
class _SliderRow extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String displayValue;
  final ValueChanged<double> onChanged;

  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.displayValue,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppTokens.spaceXs),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 96,
            child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
          ),
          Expanded(
            child: Slider(
              value: value,
              min: min,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 64,
            child: Text(
              displayValue,
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }
}

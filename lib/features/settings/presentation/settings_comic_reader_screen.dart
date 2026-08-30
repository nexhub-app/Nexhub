/// 漫画阅读器设置子页 —— 漫画阅读默认（全局默认值，打开漫画时兜底生效）。
///
/// 持久化到 SharedPreferences（key: `reader_default_settings_v1`）。
library;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';

import '../../../core/comic/models/reader_preferences.dart';
import '../../../core/settings/reader_default_settings.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/utils/app_haptics.dart';
import '../../../core/widgets/app_alert_dialog.dart';
import '../../manga/presentation/reader_image_filter.dart';
import '../../manga/presentation/reader_tap_zones.dart';
import 'widgets/settings_widgets.dart';
import 'widgets/settings_search_target.dart';

/// 漫画阅读器默认设置页面。
class SettingsComicReaderScreen extends StatefulWidget {
  const SettingsComicReaderScreen({super.key});

  @override
  State<SettingsComicReaderScreen> createState() =>
      _SettingsComicReaderScreenState();
}

class _SettingsComicReaderScreenState extends State<SettingsComicReaderScreen> {
  final ReaderDefaultSettingsStore _store = ReaderDefaultSettingsStore();
  late ReaderDefaultSettings _settings;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _settings = const ReaderDefaultSettings();
    _store.load().then((s) {
      if (mounted) {
        setState(() {
          _settings = s;
          _loaded = true;
        });
      }
    });
  }

  void _update(ReaderDefaultSettings next) {
    setState(() => _settings = next);
    _store.save(next);
  }

  // ── 枚举标签方法（使用新枚举，与内联面板对齐）──

  String _readingModeLabel(AppLocalizations l10n, ReadingMode m) {
    return switch (m) {
      ReadingMode.singleLTR => l10n.readerModeSingleLTR,
      ReadingMode.singleRTL => l10n.readerModeSingleRTL,
      ReadingMode.singleVertical => l10n.readerModeSingleVertical,
      ReadingMode.webtoon => l10n.readerModeWebtoon,
      ReadingMode.webtoonWithGap => l10n.readerModeWebtoonWithGap,
    };
  }

  String _backgroundLabel(AppLocalizations l10n, ReaderBackgroundColor b) {
    return switch (b) {
      ReaderBackgroundColor.black => l10n.readerBgBlack,
      ReaderBackgroundColor.gray => l10n.readerBgGray,
      ReaderBackgroundColor.white => l10n.readerBgWhite,
      ReaderBackgroundColor.auto => l10n.readerBgAuto,
    };
  }

  String _orientationLabel(AppLocalizations l10n, ScreenOrientation o) {
    return switch (o) {
      ScreenOrientation.defaultMode => l10n.readerOrientationDefault,
      ScreenOrientation.followSystem => l10n.readerOrientationSystem,
      ScreenOrientation.portrait => l10n.readerOrientationPortrait,
      ScreenOrientation.landscape => l10n.readerOrientationLandscape,
      ScreenOrientation.lockPortrait => l10n.readerOrientationLockPortrait,
      ScreenOrientation.lockLandscape => l10n.readerOrientationLockLandscape,
      ScreenOrientation.reversePortrait => l10n.readerOrientationReversePortrait,
    };
  }

  String _tapZoneLayoutLabel(AppLocalizations l10n, ReaderTapZoneLayout t) {
    return switch (t) {
      ReaderTapZoneLayout.lShape => l10n.readerTapLShape,
      ReaderTapZoneLayout.leftRight => l10n.readerTapLeftRight,
      ReaderTapZoneLayout.kindle => l10n.readerTapKindle,
      ReaderTapZoneLayout.bothSides => l10n.readerTapBothSides,
      ReaderTapZoneLayout.off => l10n.readerTapOff,
    };
  }

  String _tapZoneInvertLabel(AppLocalizations l10n, TapZoneInvert inv) {
    return switch (inv) {
      TapZoneInvert.none => l10n.readerTapInvertNone,
      TapZoneInvert.leftRight => l10n.readerTapInvertLeftRight,
      TapZoneInvert.upDown => l10n.readerTapInvertUpDown,
      TapZoneInvert.all => l10n.readerTapInvertAll,
    };
  }

  String _initialZoomLabel(AppLocalizations l10n, ComicInitialZoom z) {
    return switch (z) {
      ComicInitialZoom.fitWidth => l10n.readerZoomFitWidth,
      ComicInitialZoom.fitHeight => l10n.readerZoomFitHeight,
      ComicInitialZoom.original => l10n.readerZoomOriginal,
    };
  }

  String _flashColorLabel(AppLocalizations l10n, ReaderFlashColor c) {
    return switch (c) {
      ReaderFlashColor.black => l10n.readerFlashBlack,
      ReaderFlashColor.white => l10n.readerFlashWhite,
      ReaderFlashColor.blackWhite => l10n.readerFlashBlackWhite,
    };
  }

  String _mouseWheelActionLabel(AppLocalizations l10n, MouseWheelAction a) {
    return switch (a) {
      MouseWheelAction.zoom => l10n.readerWheelZoom,
      MouseWheelAction.page => l10n.readerWheelPage,
    };
  }

  String _colorProfileLabel(AppLocalizations l10n, ReaderColorProfile c) {
    return switch (c) {
      ReaderColorProfile.none => l10n.readerColorProfileNone,
      ReaderColorProfile.srgb => l10n.readerColorProfileSrgb,
      ReaderColorProfile.warm => l10n.readerColorProfileWarm,
      ReaderColorProfile.cool => l10n.readerColorProfileCool,
      ReaderColorProfile.manga => l10n.readerColorProfileManga,
      ReaderColorProfile.paper => l10n.readerColorProfilePaper,
    };
  }

  String _einkStyleLabel(AppLocalizations l10n, ReaderEInkRefreshStyle s) {
    return switch (s) {
      ReaderEInkRefreshStyle.white => l10n.readerEInkRefreshWhite,
      ReaderEInkRefreshStyle.black => l10n.readerEInkRefreshBlack,
    };
  }

  String _zoomStartLabel(AppLocalizations l10n, ZoomStart z) {
    return switch (z) {
      ZoomStart.left => l10n.readerZoomStartLeft,
      ZoomStart.center => l10n.readerZoomStartCenter,
      ZoomStart.right => l10n.readerZoomStartRight,
    };
  }

  String _longPressZoomPositionLabel(
      AppLocalizations l10n, LongPressZoomPosition p) {
    return switch (p) {
      LongPressZoomPosition.press => l10n.readerLongPressAtPress,
      LongPressZoomPosition.center => l10n.readerLongPressAtCenter,
    };
  }

  String _pageAnimationLabel(AppLocalizations l10n, ReaderPageAnimation a) {
    return switch (a) {
      ReaderPageAnimation.none => l10n.readerPageAnimNone,
      ReaderPageAnimation.slide => l10n.readerPageAnimSlide,
      ReaderPageAnimation.fade => l10n.readerPageAnimFade,
    };
  }

  /// 是否显示「音量键翻页」设置：仅 Android。
  bool get _showVolumeKey {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android;
  }

  /// 阅读模式切换联动：切到竖排 / 长条时双页拆分不再生效，自动关闭。
  /// （与阅读器内联面板行为一致）
  void _updateReadingMode(ReadingMode m) {
    final bool compatible =
        m == ReadingMode.singleLTR || m == ReadingMode.singleRTL;
    _update(_settings.copyWith(
      readingMode: m,
      comicSplitDoublePage: compatible ? _settings.comicSplitDoublePage : false,
    ));
  }

  /// 是否显示「鼠标滚轮」设置分组：仅桌面平台。
  bool get _showMouseWheel {
    final TargetPlatform p = defaultTargetPlatform;
    return p == TargetPlatform.windows ||
        p == TargetPlatform.macOS ||
        p == TargetPlatform.linux ||
        p == TargetPlatform.fuchsia;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.comicReaderSettingsTitle),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.restore),
            tooltip: l10n.restoreDefault,
            onPressed: _confirmReset,
          ),
        ],
      ),
      body: _loaded
          ? SettingsAutoScroll(
              child: ListView(
              padding: const EdgeInsets.all(AppTokens.spaceLg),
              children: <Widget>[
                // ── 常用设置（置顶快捷项，与阅读器内联面板对齐）──
                SettingsCard(
                  key: const ValueKey<String>('comic.common'),
                  title: l10n.readerCommonSettings,
                  index: 0,
                  expandable: false,
                  backgroundColor:
                      Theme.of(context).colorScheme.primaryContainer
                          .withValues(alpha: 0.22),
                  children: <Widget>[
                    // 阅读模式（5 选项 ChoiceChip）
                    _chipSection(
                      context,
                      l10n.readerMode,
                      ReadingMode.values.map((m) {
                        return ChoiceChip(
                          label: Text(_readingModeLabel(l10n, m)),
                          selected: _settings.readingMode == m,
                          onSelected: (_) {
                            AppHaptics.selectionClick();
                            _updateReadingMode(m);
                          },
                        );
                      }).toList(),
                    ),
                    // 背景颜色（4 选项 ChoiceChip）
                    _chipSection(
                      context,
                      l10n.readerBackground,
                      ReaderBackgroundColor.values.map((b) {
                        return ChoiceChip(
                          label: Text(_backgroundLabel(l10n, b)),
                          selected: _settings.comicBackground == b,
                          onSelected: (_) {
                            AppHaptics.selectionClick();
                            _update(_settings.copyWith(comicBackground: b));
                          },
                        );
                      }).toList(),
                    ),
                    // 屏幕方向（7 选项 ChoiceChip）
                    _chipSection(
                      context,
                      l10n.readerOrientation,
                      ScreenOrientation.values.map((o) {
                        return ChoiceChip(
                          label: Text(_orientationLabel(l10n, o)),
                          selected: _settings.comicOrientation == o,
                          onSelected: (_) {
                            AppHaptics.selectionClick();
                            _update(_settings.copyWith(comicOrientation: o));
                          },
                        );
                      }).toList(),
                    ),
                    // 侧边距
                    SettingsSliderTile(
                      label: l10n.readerSideMargin,
                      value: _settings.comicSideMargin,
                      min: 0.0,
                      max: 0.5,
                      divisions: 50,
                      display: '${(_settings.comicSideMargin * 100).round()}%',
                      onChanged: (v) =>
                          _update(_settings.copyWith(comicSideMargin: v)),
                    ),
                    // 双击缩放
                    SettingsSwitchTile(
                      title: l10n.readerZoom,
                      value: _settings.doubleTapZoom,
                      onChanged: (v) =>
                          _update(_settings.copyWith(doubleTapZoom: v)),
                    ),
                    // 全屏
                    SettingsSwitchTile(
                      title: l10n.readerFullscreen,
                      value: _settings.comicFullscreen,
                      onChanged: (v) =>
                          _update(_settings.copyWith(comicFullscreen: v)),
                    ),
                    // 屏幕常亮
                    SettingsSwitchTile(
                      title: l10n.readerKeepScreenOn,
                      value: _settings.comicKeepScreenOn,
                      onChanged: (v) =>
                          _update(_settings.copyWith(comicKeepScreenOn: v)),
                    ),
                    // 进度条在右
                    SettingsSwitchTile(
                      title: l10n.readerProgressBarOnRight,
                      value: _settings.comicProgressBarOnRight,
                      onChanged: (v) => _update(
                          _settings.copyWith(comicProgressBarOnRight: v)),
                    ),
                  ],
                ),

                // ── 翻页与点击 ──
                SettingsCard(
                  key: const ValueKey<String>('comic.tapPage'),
                  title: l10n.comicSectionTapPage,
                  description: l10n.readerGroupPageTapDesc,
                  index: 1,
                  children: <Widget>[
                    // 阅读模式（5 选项 ChoiceChip）
                    _chipSection(
                      context,
                      l10n.readerMode,
                      ReadingMode.values.map((m) {
                        return ChoiceChip(
                          label: Text(_readingModeLabel(l10n, m)),
                          selected: _settings.readingMode == m,
                          onSelected: (_) {
                            AppHaptics.selectionClick();
                            _updateReadingMode(m);
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: AppTokens.spaceMd),

                    // 背景颜色（4 选项 ChoiceChip）
                    _chipSection(
                      context,
                      l10n.readerBackground,
                      ReaderBackgroundColor.values.map((b) {
                        return ChoiceChip(
                          label: Text(_backgroundLabel(l10n, b)),
                          selected: _settings.comicBackground == b,
                          onSelected: (_) {
                            AppHaptics.selectionClick();
                            _update(_settings.copyWith(comicBackground: b));
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: AppTokens.spaceMd),

                    // 屏幕方向（7 选项 ChoiceChip）
                    _chipSection(
                      context,
                      l10n.readerOrientation,
                      ScreenOrientation.values.map((o) {
                        return ChoiceChip(
                          label: Text(_orientationLabel(l10n, o)),
                          selected: _settings.comicOrientation == o,
                          onSelected: (_) {
                            AppHaptics.selectionClick();
                            _update(_settings.copyWith(comicOrientation: o));
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: AppTokens.spaceMd),

                    // 点击区域布局 + 实时预览
                    Text(l10n.readerTapZone,
                        style: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w500)),
                    const SizedBox(height: AppTokens.spaceSm),
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
                          label: Text(_tapZoneLayoutLabel(l10n, t)),
                          selected: _settings.comicTapZoneLayout == t,
                          onSelected: (_) {
                            AppHaptics.selectionClick();
                            _update(_settings.copyWith(comicTapZoneLayout: t));
                          },
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
                        layout: _settings.comicTapZoneLayout,
                        tapZoneInvert: _settings.comicTapZoneInvert,
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
                    const SizedBox(height: AppTokens.spaceMd),

                    // 点击翻转
                    _chipSection(
                      context,
                      l10n.readerTapInvert,
                      TapZoneInvert.values.map((inv) {
                        return ChoiceChip(
                          label: Text(_tapZoneInvertLabel(l10n, inv)),
                          selected: _settings.comicTapZoneInvert == inv,
                          onSelected: (_) {
                            AppHaptics.selectionClick();
                            _update( _settings.copyWith(comicTapZoneInvert: inv));
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: AppTokens.spaceMd),

                    // 侧边距
                    SettingsSliderTile(
                      label: l10n.readerSideMargin,
                      value: _settings.comicSideMargin,
                      min: 0.0,
                      max: 0.5,
                      divisions: 50,
                      display: '${(_settings.comicSideMargin * 100).round()}%',
                      onChanged: (v) =>
                          _update(_settings.copyWith(comicSideMargin: v)),
                    ),

                    // 双击缩放
                    SettingsSwitchTile(
                      title: l10n.readerZoom,
                      value: _settings.doubleTapZoom,
                      onChanged: (v) =>
                          _update(_settings.copyWith(doubleTapZoom: v)),
                    ),

                    // 初始缩放
                    _chipSection(
                      context,
                      l10n.readerInitialZoom,
                      ComicInitialZoom.values.map((z) {
                        return ChoiceChip(
                          label: Text(_initialZoomLabel(l10n, z)),
                          selected: _settings.comicInitialZoom == z,
                          onSelected: (_) {
                            AppHaptics.selectionClick();
                            _update(_settings.copyWith(comicInitialZoom: z));
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: AppTokens.spaceMd),

                    // 缩放锚点（REQ-B11）
                    _chipSection(
                      context,
                      l10n.readerZoomStart,
                      ZoomStart.values.map((z) {
                        return ChoiceChip(
                          label: Text(_zoomStartLabel(l10n, z)),
                          selected: _settings.comicZoomStart == z,
                          onSelected: (_) {
                            AppHaptics.selectionClick();
                            _update(_settings.copyWith(comicZoomStart: z));
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: AppTokens.spaceMd),

                    // 长按缩放（REQ-B2）：开启时显示锚点选择
                    SettingsSwitchTile(
                      key: const ValueKey<String>('comic.longPressZoom'),
                      title: l10n.readerLongPressZoom,
                      subtitle: l10n.readerLongPressZoomDesc,
                      value: _settings.comicEnableLongPressToZoom,
                      onChanged: (v) => _update(
                          _settings.copyWith(comicEnableLongPressToZoom: v)),
                    ),
                    SettingsExpand(
                      visible: _settings.comicEnableLongPressToZoom,
                      padding: EdgeInsets.zero,
                      child: _chipSection(
                        context,
                        l10n.readerLongPressZoomPosition,
                        LongPressZoomPosition.values.map((p) {
                          return ChoiceChip(
                            label: Text(_longPressZoomPositionLabel(l10n, p)),
                            selected: _settings.comicLongPressZoomPosition == p,
                            onSelected: (_) {
                              AppHaptics.selectionClick();
                              _update( _settings.copyWith(comicLongPressZoomPosition: p));
                            },
                          );
                        }).toList(),
                      ),
                    ),
                    const SizedBox(height: AppTokens.spaceMd),

                    // 翻页过渡动画（REQ-B7）
                    _chipSection(
                      context,
                      l10n.readerPageAnimation,
                      ReaderPageAnimation.values.map((a) {
                        return ChoiceChip(
                          label: Text(_pageAnimationLabel(l10n, a)),
                          selected: _settings.comicPageAnimation == a,
                          onSelected: (_) {
                            AppHaptics.selectionClick();
                            _update(_settings.copyWith(comicPageAnimation: a));
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: AppTokens.spaceMd),

                    // 双击缩放动画时长（REQ-B7）
                    SettingsSliderTile(
                      key: const ValueKey<String>('comic.doubleTapSpeed'),
                      label: l10n.readerDoubleTapAnimSpeed,
                      value: _settings.comicDoubleTapAnimSpeed.toDouble(),
                      min: 100,
                      max: 1500,
                      divisions: 14,
                      display: '${_settings.comicDoubleTapAnimSpeed}ms',
                      onChanged: (v) => _update(_settings.copyWith(
                          comicDoubleTapAnimSpeed: v.round())),
                    ),
                    const SizedBox(height: AppTokens.spaceMd),

                    // 自动翻页（REQ-B9，paged 模式）
                    SettingsSwitchTile(
                      key: const ValueKey<String>('comic.autoPageTurning'),
                      title: l10n.readerAutoPageTurning,
                      subtitle: l10n.readerAutoPageTurningDesc,
                      value: _settings.comicAutoPageTurningEnabled,
                      onChanged: (v) {
                        // 关闭只切开关、保留间隔；重新开启恢复上次间隔，
                        // 从未设置过才兜底 5。
                        final int cur =
                            _settings.comicAutoPageTurningInterval;
                        _update(_settings.copyWith(
                          comicAutoPageTurningEnabled: v,
                          comicAutoPageTurningInterval: v && cur <= 0 ? 5 : cur,
                        ));
                      },
                    ),
                    SettingsExpand(
                      visible: _settings.comicAutoPageTurningEnabled,
                      padding: EdgeInsets.zero,
                      child: SettingsSliderTile(
                        key: const ValueKey<String>('comic.autoPageInterval'),
                        label: l10n.readerAutoPageInterval,
                        value: _settings.comicAutoPageTurningInterval
                            .clamp(1, 20)
                            .toDouble(),
                        min: 1,
                        max: 20,
                        divisions: 19,
                        display:
                            '${_settings.comicAutoPageTurningInterval.clamp(1, 20)}s',
                        onChanged: (v) => _update(_settings.copyWith(
                            comicAutoPageTurningInterval: v.round())),
                      ),
                    ),

                    // 音量键翻页（REQ-B8，仅 Android）
                    if (_showVolumeKey) ...<Widget>[
                      const SizedBox(height: AppTokens.spaceMd),
                      SettingsSwitchTile(
                        key: const ValueKey<String>('comic.volumePageTurn'),
                        title: l10n.readerVolumeKeyPageTurn,
                        subtitle: l10n.readerVolumeKeyPageTurnDesc,
                        value: _settings.comicVolumeKeyPageTurn,
                        onChanged: (v) => _update(
                            _settings.copyWith(comicVolumeKeyPageTurn: v)),
                      ),
                      SettingsExpand(
                        visible: _settings.comicVolumeKeyPageTurn,
                        padding: EdgeInsets.zero,
                        child: SettingsSliderTile(
                          key: const ValueKey<String>('comic.volumeDistance'),
                          label: l10n.readerVolumeKeyDistance,
                          value: _settings
                              .comicVolumeKeyPageTurnDistancePercent
                              .toDouble(),
                          min: 10,
                          max: 100,
                          divisions: 18,
                          display:
                              '${_settings.comicVolumeKeyPageTurnDistancePercent}%',
                          onChanged: (v) => _update(_settings.copyWith(
                              comicVolumeKeyPageTurnDistancePercent: v.round())),
                        ),
                      ),
                    ],
                  ],
                ),

                // ── 画面与滤镜（复用 ReaderImageFilterPanel）──
                SettingsCard(
                  key: const ValueKey<String>('comic.visualFilter'),
                  title: l10n.comicSectionVisualFilter,
                  description: l10n.readerGroupViewFilterDesc,
                  index: 2,
                  children: <Widget>[
                    ReaderImageFilterPanel(
                      brightness: _settings.comicFilterBrightness,
                      contrast: _settings.comicFilterContrast,
                      colorTemp: _settings.comicFilterColorTemp,
                      saturation: _settings.comicFilterSaturation,
                      hue: _settings.comicFilterHue,
                      inverted: _settings.comicFilterInverted,
                      grayscale: _settings.comicGrayscale,
                      onChanged: (b, c, t, s, h) => _update(
                        _settings.copyWith(
                          comicFilterBrightness: b,
                          comicFilterContrast: c,
                          comicFilterColorTemp: t,
                          comicFilterSaturation: s,
                          comicFilterHue: h,
                        ),
                      ),
                      onInvertedChanged: (v) =>
                          _update(_settings.copyWith(comicFilterInverted: v)),
                      onGrayscaleChanged: (v) =>
                          _update(_settings.copyWith(comicGrayscale: v)),
                    ),
                    // 阅读亮度（REQ-C3）：正值写系统、负值叠加遮罩。
                    SettingsSliderTile(
                      key: const ValueKey<String>('comic.brightness'),
                      label: l10n.readerBrightness,
                      value: _settings.comicReaderBrightness,
                      min: -1.0,
                      max: 1.0,
                      divisions: 40,
                      display:
                          _settings.comicReaderBrightness.toStringAsFixed(2),
                      onChanged: (v) =>
                          _update(_settings.copyWith(comicReaderBrightness: v)),
                    ),
                    // 夜览暖色盖层（REQ-C3 亮度双轨扩展）：独立于阅读亮度。
                    SettingsSwitchTile(
                      key: const ValueKey<String>('comic.nightLight'),
                      title: l10n.readerNightLight,
                      subtitle: l10n.readerNightLightDesc,
                      value: _settings.comicNightLightEnabled,
                      onChanged: (v) => _update(
                          _settings.copyWith(comicNightLightEnabled: v)),
                    ),
                    if (_settings.comicNightLightEnabled)
                      SettingsSliderTile(
                        key: const ValueKey<String>('comic.nightLightOpacity'),
                        label: l10n.readerNightLightOpacity,
                        value: _settings.comicNightLightOpacity,
                        min: 0.1,
                        max: 0.85,
                        divisions: 15,
                        display: _settings.comicNightLightOpacity
                            .toStringAsFixed(2),
                      onChanged: (v) => _update(
                          _settings.copyWith(comicNightLightOpacity: v)),
                      ),
                    // 色彩配置（ICC 校色近似）：矩阵预设
                    _chipSection(
                      context,
                      l10n.readerColorProfile,
                      ReaderColorProfile.values.map((c) {
                        return ChoiceChip(
                          label: Text(_colorProfileLabel(l10n, c)),
                          selected: _settings.comicColorProfile == c,
                          onSelected: (_) {
                            AppHaptics.selectionClick();
                            _update( _settings.copyWith(comicColorProfile: c));
                          },
                        );
                      }).toList(),
                    ),
                  ],
                ),

                // ── E-Ink 刷新（墨水屏防残影）──
                SettingsCard(
                  key: const ValueKey<String>('comic.einkRefresh'),
                  title: l10n.readerGroupEInk,
                  description: l10n.readerGroupEInkDesc,
                  index: 9,
                  children: <Widget>[
                    SettingsSwitchTile(
                      key: const ValueKey<String>('comic.einkToggle'),
                      title: l10n.readerEInkRefresh,
                      subtitle: l10n.readerEInkRefreshDesc,
                      value: _settings.comicEinkRefreshEnabled,
                      onChanged: (v) => _update(
                          _settings.copyWith(comicEinkRefreshEnabled: v)),
                    ),
                    if (_settings.comicEinkRefreshEnabled) ...<Widget>[
                      SettingsSliderTile(
                        key: const ValueKey<String>('comic.einkInterval'),
                        label: l10n.readerEInkRefreshInterval,
                        value: _settings.comicEinkRefreshInterval.toDouble(),
                        min: 1,
                        max: 50,
                        divisions: 49,
                        display: '${_settings.comicEinkRefreshInterval}',
                        onChanged: (v) => _update(_settings.copyWith(
                            comicEinkRefreshInterval: v.round())),
                      ),
                      SettingsSliderTile(
                        key: const ValueKey<String>('comic.einkDuration'),
                        label: l10n.readerEInkRefreshDuration,
                        value: _settings.comicEinkRefreshDuration.toDouble(),
                        min: 50,
                        max: 1000,
                        divisions: 95,
                        display: '${_settings.comicEinkRefreshDuration} ms',
                        onChanged: (v) => _update(_settings.copyWith(
                            comicEinkRefreshDuration: v.round())),
                      ),
                      _chipSection(
                        context,
                        l10n.readerEInkRefreshStyle,
                        ReaderEInkRefreshStyle.values.map((s) {
                          return ChoiceChip(
                            label: Text(_einkStyleLabel(l10n, s)),
                            selected: _settings.comicEinkRefreshStyle == s,
                            onSelected: (_) {
                              AppHaptics.selectionClick();
                              _update(_settings.copyWith( comicEinkRefreshStyle: s));
                            },
                          );
                        }).toList(),
                      ),
                    ],
                  ],
                ),

                // ── 进度与显示 ──
                SettingsCard(
                  title: l10n.comicSectionProgress,
                  description: l10n.readerGroupProgressDesc,
                  index: 3,
                  children: <Widget>[
                    SettingsSwitchTile(
                      title: l10n.readerCropEdge,
                      value: _settings.comicCropEdge,
                      onChanged: (v) =>
                          _update(_settings.copyWith(comicCropEdge: v)),
                    ),
                    SettingsSwitchTile(
                      title: l10n.readerShowPageNumber,
                      value: _settings.comicShowPageNumber,
                      onChanged: (v) =>
                          _update(_settings.copyWith(comicShowPageNumber: v)),
                    ),
                    SettingsSwitchTile(
                      title: l10n.readerProgressBarOnRight,
                      value: _settings.comicProgressBarOnRight,
                      onChanged: (v) => _update(
                          _settings.copyWith(comicProgressBarOnRight: v)),
                    ),
                    SettingsSwitchTile(
                      key: const ValueKey<String>('comic.chapterSlider'),
                      title: l10n.readerShowChapterSlider,
                      value: _settings.comicShowChapterSlider,
                      onChanged: (v) => _update(
                          _settings.copyWith(comicShowChapterSlider: v)),
                    ),
                    SettingsSwitchTile(
                      title: l10n.readerKeepScreenOn,
                      value: _settings.comicKeepScreenOn,
                      onChanged: (v) =>
                          _update(_settings.copyWith(comicKeepScreenOn: v)),
                    ),
                    SettingsSwitchTile(
                      title: l10n.readerRotatePage,
                      value: _settings.comicRotateLandscape,
                      onChanged: (v) =>
                          _update(_settings.copyWith(comicRotateLandscape: v)),
                    ),
                    SettingsSwitchTile(
                      title: l10n.readerSplitDoublePage,
                      value: _settings.comicSplitDoublePage,
                      onChanged: (v) {
                        var next =
                            _settings.copyWith(comicSplitDoublePage: v);
                        if (v &&
                            _settings.readingMode != ReadingMode.singleLTR &&
                            _settings.readingMode != ReadingMode.singleRTL) {
                          next = next.copyWith(readingMode: ReadingMode.singleLTR);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(l10n.readerSplitDoublePageHint),
                              duration: const Duration(seconds: 2),
                            ),
                          );
                        }
                        _update(next);
                      },
                    ),
                    SettingsSwitchTile(
                      title: l10n.readerFullscreen,
                      value: _settings.comicFullscreen,
                      onChanged: (v) =>
                          _update(_settings.copyWith(comicFullscreen: v)),
                    ),
                    SettingsSwitchTile(
                      title: l10n.readerLongPressMenu,
                      value: _settings.comicShowLongPressMenu,
                      onChanged: (v) => _update(
                          _settings.copyWith(comicShowLongPressMenu: v)),
                    ),
                    SettingsSwitchTile(
                      title: l10n.readerPreventShrink,
                      value: _settings.comicPreventShrink,
                      onChanged: (v) =>
                          _update(_settings.copyWith(comicPreventShrink: v)),
                    ),
                    SettingsSwitchTile(
                      title: l10n.readerChapterTransition,
                      value: _settings.comicChapterTransition,
                      onChanged: (v) =>
                          _update(_settings.copyWith(comicChapterTransition: v)),
                    ),
                    SettingsSliderTile(
                      key: const ValueKey<String>('comic.preload'),
                      label: l10n.readerPreloadCount,
                      value: _settings.comicPreloadImageCount.toDouble(),
                      min: 1,
                      max: 16,
                      divisions: 15,
                      display: '${_settings.comicPreloadImageCount}',
                      onChanged: (v) => _update(
                          _settings.copyWith(comicPreloadImageCount: v.round())),
                    ),
                    SettingsSwitchTile(
                      key: const ValueKey<String>('comic.seamless'),
                      title: l10n.readerSeamlessReading,
                      subtitle: l10n.readerSeamlessReadingDesc,
                      value: _settings.comicSeamlessReading,
                      onChanged: (v) => _update(
                          _settings.copyWith(comicSeamlessReading: v)),
                    ),
                    SettingsSwitchTile(
                      key: const ValueKey<String>('comic.chapterSeparator'),
                      title: l10n.readerChapterSeparator,
                      subtitle: l10n.readerChapterSeparatorDesc,
                      value: _settings.comicShowChapterSeparator,
                      onChanged: (v) => _update(
                          _settings.copyWith(comicShowChapterSeparator: v)),
                    ),
                    // 条漫解码限幅（P3 资源/内存）：连续模式解码位图下采样，
                    // 限制长条漫原图的全尺寸解码内存。
                    SettingsSwitchTile(
                      key: const ValueKey<String>('comic.webtoonLimit'),
                      title: l10n.readerWebtoonDecodeLimit,
                      value: _settings.comicWebtoonLimitDecodeSize,
                      onChanged: (v) => _update(
                          _settings.copyWith(comicWebtoonLimitDecodeSize: v)),
                    ),
                    // 自动滚动（REQ-B10，条漫）：开关 + 滚动速度。
                    SettingsSwitchTile(
                      key: const ValueKey<String>('comic.autoScroll'),
                      title: l10n.readerAutoScroll,
                      subtitle: l10n.readerAutoScrollDesc,
                      value: _settings.comicAutoScroll,
                      onChanged: (v) =>
                          _update(_settings.copyWith(comicAutoScroll: v)),
                    ),
                    SettingsSliderTile(
                      key: const ValueKey<String>('comic.scrollSpeed'),
                      label: l10n.readerScrollSpeed,
                      value: _settings.comicReaderScrollSpeed,
                      min: 0.5,
                      max: 3.0,
                      divisions: 25,
                      display:
                          '${_settings.comicReaderScrollSpeed.toStringAsFixed(1)}x',
                      onChanged: (v) =>
                          _update(_settings.copyWith(comicReaderScrollSpeed: v)),
                    ),
                  ],
                ),

                // ── 闪屏效果 ──
                SettingsCard(
                  key: const ValueKey<String>('comic.flash'),
                  title: l10n.comicSectionFlash,
                  description: l10n.readerGroupFlashDesc,
                  index: 4,
                  children: <Widget>[
                    SettingsSwitchTile(
                      title: l10n.readerFlashEnabled,
                      value: _settings.comicFlashEnabled,
                      onChanged: (v) =>
                          _update(_settings.copyWith(comicFlashEnabled: v)),
                    ),
                    SettingsExpand(
                      visible: _settings.comicFlashEnabled,
                      padding: EdgeInsets.zero,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          SettingsSliderTile(
                            label: l10n.readerFlashTime,
                            value: _settings.comicFlashTime.toDouble(),
                            min: 50,
                            max: 600,
                            divisions: 55,
                            display: '${_settings.comicFlashTime} ms',
                            onChanged: (v) => _update(
                                _settings.copyWith(comicFlashTime: v.round())),
                          ),
                          SettingsSliderTile(
                            label: l10n.readerFlashInterval,
                            value: _settings.comicFlashInterval.toDouble(),
                            min: 0,
                            max: 600,
                            divisions: 60,
                            display: '${_settings.comicFlashInterval} ms',
                            onChanged: (v) => _update(
                                _settings.copyWith(comicFlashInterval: v.round())),
                          ),
                        ],
                      ),
                    ),
                    SettingsChoiceChips<ReaderFlashColor>(
                      title: l10n.readerFlashColor,
                      selected: _settings.comicFlashColor,
                      onSelected: (c) =>
                          _update(_settings.copyWith(comicFlashColor: c)),
                      options: ReaderFlashColor.values
                          .map((c) => SettingsChoiceChipData<ReaderFlashColor>(
                                value: c,
                                label: _flashColorLabel(l10n, c),
                              ))
                          .toList(),
                    ),
                  ],
                ),

                // ── 鼠标滚轮（仅桌面平台）──
                if (_showMouseWheel)
                  SettingsCard(
                    key: const ValueKey<String>('comic.mouseWheel'),
                    title: l10n.comicSectionMouseWheel,
                    description: l10n.readerGroupMouseWheelDesc,
                    index: 5,
                    children: <Widget>[
                      // 滚轮作用：条漫（连续滚动）模式下按上下文自动分派，
                      // 「缩放/翻页」二选一无意义，仅在翻页模式显示。
                      if (!_settings.readingMode.isWebtoon) ...<Widget>[
                        _chipSection(
                          context,
                          l10n.readerWheelAction,
                          MouseWheelAction.values.map((a) {
                            return ChoiceChip(
                              label: Text(_mouseWheelActionLabel(l10n, a)),
                              selected: _settings.comicMouseWheelAction == a,
                              onSelected: (_) {
                                AppHaptics.selectionClick();
                                _update(_settings.copyWith( comicMouseWheelAction: a));
                              },
                            );
                          }).toList(),
                        ),
                        const SizedBox(height: AppTokens.spaceMd),
                      ],
                      // 滚轮方向（自然/反向）：条漫模式下仍控制放大时的方向。
                      _chipSection(
                        context,
                        l10n.comicDefaultScrollWheel,
                        <Widget>[
                          ChoiceChip(
                            label: Text(l10n.comicWheelNatural),
                            selected: _settings.comicScrollWheel ==
                                ComicScrollWheel.natural,
                            onSelected: (_) {
                              AppHaptics.selectionClick();
                              _update( _settings.copyWith( comicScrollWheel: ComicScrollWheel.natural));
                            },
                          ),
                          ChoiceChip(
                            label: Text(l10n.comicWheelInverted),
                            selected: _settings.comicScrollWheel ==
                                ComicScrollWheel.inverted,
                            onSelected: (_) {
                              AppHaptics.selectionClick();
                              _update( _settings.copyWith( comicScrollWheel: ComicScrollWheel.inverted));
                            },
                          ),
                        ],
                      ),
                    ],
                  ),

                // ── 自动（下载 / 跳章过滤）──
                SettingsCard(
                  key: const ValueKey<String>('comic.auto'),
                  title: l10n.comicReaderAutoSection,
                  index: 6,
                  children: <Widget>[
                    SettingsSwitchTile(
                      key: const ValueKey<String>('comic.autoFavorite'),
                      title: l10n.readerAutoFavorite,
                      subtitle: l10n.readerAutoFavoriteDesc,
                      value: _settings.comicIsAutoFavorite,
                      onChanged: (v) => _update(
                          _settings.copyWith(comicIsAutoFavorite: v)),
                    ),
                    SettingsSwitchTile(
                      key: const ValueKey<String>('comic.autoDownload'),
                      title: l10n.readerAutoDownload,
                      subtitle: l10n.readerAutoDownloadDesc,
                      value: _settings.comicAutoDownloadChapters,
                      onChanged: (v) => _update(
                          _settings.copyWith(comicAutoDownloadChapters: v)),
                    ),
                    SettingsSwitchTile(
                      key: const ValueKey<String>('comic.skipRead'),
                      title: l10n.readerSkipReadChapters,
                      subtitle: l10n.readerSkipReadChaptersDesc,
                      value: _settings.comicSkipReadChapters,
                      onChanged: (v) =>
                          _update(_settings.copyWith(comicSkipReadChapters: v)),
                    ),
                    SettingsSwitchTile(
                      key: const ValueKey<String>('comic.skipFiltered'),
                      title: l10n.readerSkipFilteredChapters,
                      subtitle: l10n.readerSkipFilteredChaptersDesc,
                      value: _settings.comicSkipFilteredChapters,
                      onChanged: (v) => _update(
                          _settings.copyWith(comicSkipFilteredChapters: v)),
                    ),
                    SettingsSwitchTile(
                      key: const ValueKey<String>('comic.skipDuplicate'),
                      title: l10n.readerSkipDuplicateChapters,
                      subtitle: l10n.readerSkipDuplicateChaptersDesc,
                      value: _settings.comicSkipDuplicateChapters,
                      onChanged: (v) => _update(
                          _settings.copyWith(comicSkipDuplicateChapters: v)),
                    ),
                  ],
                ),

                // ── 浮层（时间 / 电量）──
                SettingsCard(
                  key: const ValueKey<String>('comic.overlay'),
                  title: l10n.comicReaderOverlaySection,
                  index: 7,
                  children: <Widget>[
                    SettingsSwitchTile(
                      key: const ValueKey<String>('comic.clockBattery'),
                      title: l10n.readerClockBattery,
                      subtitle: l10n.readerClockBatteryDesc,
                      value: _settings.comicShowClockBattery,
                      onChanged: (v) =>
                          _update(_settings.copyWith(comicShowClockBattery: v)),
                    ),
                    SettingsExpand(
                      visible: _settings.comicShowClockBattery,
                      padding: EdgeInsets.zero,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          _chipSection(
                            context,
                            l10n.readerClockPosition,
                            <Widget>[
                              ChoiceChip(
                                label: Text(l10n.readerClockPosTopLeft),
                                selected:
                                    _settings.comicClockBatteryPosition ==
                                        ClockBatteryPosition.topLeft,
                                onSelected: (_) {
                                  AppHaptics.selectionClick();
                                  _update(_settings.copyWith( comicClockBatteryPosition: ClockBatteryPosition.topLeft));
                                },
                              ),
                              ChoiceChip(
                                label: Text(l10n.readerClockPosTopRight),
                                selected:
                                    _settings.comicClockBatteryPosition ==
                                        ClockBatteryPosition.topRight,
                                onSelected: (_) {
                                  AppHaptics.selectionClick();
                                  _update(_settings.copyWith( comicClockBatteryPosition: ClockBatteryPosition.topRight));
                                },
                              ),
                              ChoiceChip(
                                label: Text(l10n.readerClockPosBottomLeft),
                                selected:
                                    _settings.comicClockBatteryPosition ==
                                        ClockBatteryPosition.bottomLeft,
                                onSelected: (_) {
                                  AppHaptics.selectionClick();
                                  _update(_settings.copyWith( comicClockBatteryPosition: ClockBatteryPosition.bottomLeft));
                                },
                              ),
                              ChoiceChip(
                                label: Text(l10n.readerClockPosBottomRight),
                                selected:
                                    _settings.comicClockBatteryPosition ==
                                        ClockBatteryPosition.bottomRight,
                                onSelected: (_) {
                                  AppHaptics.selectionClick();
                                  _update(_settings.copyWith( comicClockBatteryPosition: ClockBatteryPosition.bottomRight));
                                },
                              ),
                            ],
                          ),
                          SettingsSliderTile(
                            key: const ValueKey<String>('comic.clockMargin'),
                            label: l10n.readerClockMargin,
                            value: _settings.comicClockBatteryMargin,
                            min: 0,
                            max: 40,
                            divisions: 40,
                            display:
                                '${_settings.comicClockBatteryMargin.round()}',
                            onChanged: (v) => _update(
                                _settings.copyWith(comicClockBatteryMargin: v)),
                          ),
                          SettingsSliderTile(
                            key: const ValueKey<String>('comic.clockOpacity'),
                            label: l10n.readerClockOpacity,
                            value: _settings.comicClockBatteryOpacity,
                            min: 0.1,
                            max: 1.0,
                            divisions: 9,
                            display:
                                _settings.comicClockBatteryOpacity
                                    .toStringAsFixed(2),
                            onChanged: (v) => _update(_settings.copyWith(
                                comicClockBatteryOpacity: v)),
                          ),
                          SettingsSliderTile(
                            key: const ValueKey<String>('comic.clockFontSize'),
                            label: l10n.readerClockFontSize,
                            value: _settings.comicClockBatteryFontSize,
                            min: 10,
                            max: 24,
                            divisions: 14,
                            display:
                                '${_settings.comicClockBatteryFontSize.round()}',
                            onChanged: (v) => _update(_settings.copyWith(
                                comicClockBatteryFontSize: v)),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

                // ── 多图 / 间距 ──
                SettingsCard(
                  key: const ValueKey<String>('comic.multiImage'),
                  title: l10n.comicReaderMultiImageSection,
                  index: 8,
                  children: <Widget>[
                    SettingsSliderTile(
                      key: const ValueKey<String>('comic.pageSpacing'),
                      label: l10n.readerPageSpacing,
                      value: _settings.comicReaderPageSpacing.toDouble(),
                      min: 0,
                      max: 50,
                      divisions: 50,
                      display: '${_settings.comicReaderPageSpacing}',
                      onChanged: (v) => _update(
                          _settings.copyWith(comicReaderPageSpacing: v.round())),
                    ),
                    SettingsSwitchTile(
                      key: const ValueKey<String>('comic.singleFirst'),
                      title: l10n.readerShowSingleImageOnFirstPage,
                      subtitle: l10n.readerShowSingleImageOnFirstPageDesc,
                      value: _settings.comicShowSingleImageOnFirstPage,
                      onChanged: (v) => _update(_settings.copyWith(
                          comicShowSingleImageOnFirstPage: v)),
                    ),
                    SettingsSliderTile(
                      key: const ValueKey<String>('comic.screenCountPortrait'),
                      label: l10n.readerScreenPicNumberPortrait,
                      value: _settings.comicReaderScreenPicNumberForPortrait
                          .toDouble(),
                      min: 1,
                      max: 5,
                      divisions: 4,
                      display:
                          '${_settings.comicReaderScreenPicNumberForPortrait}',
                      onChanged: (v) => _update(_settings.copyWith(
                          comicReaderScreenPicNumberForPortrait: v.round())),
                    ),
                    SettingsSliderTile(
                      key: const ValueKey<String>('comic.screenCountLandscape'),
                      label: l10n.readerScreenPicNumberLandscape,
                      value: _settings.comicReaderScreenPicNumberForLandscape
                          .toDouble(),
                      min: 1,
                      max: 5,
                      divisions: 4,
                      display:
                          '${_settings.comicReaderScreenPicNumberForLandscape}',
                      onChanged: (v) => _update(_settings.copyWith(
                          comicReaderScreenPicNumberForLandscape: v.round())),
                    ),
                  ],
                ),
              ],
              ),
            )
          : const Center(child: CircularProgressIndicator()),
    );
  }

  /// 带标题的 ChoiceChip 组。
  Widget _chipSection(BuildContext context, String label, List<Widget> chips) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(fontWeight: FontWeight.w500)),
        const SizedBox(height: AppTokens.spaceSm),
        Wrap(
          spacing: AppTokens.spaceSm,
          runSpacing: AppTokens.spaceSm,
          children: chips,
        ),
      ],
    );
  }

  void _confirmReset() {
    final l10n = AppLocalizations.of(context);
    showDialog<void>(
      context: context,
      builder: (ctx) => AppAlertDialog(
        title: Text(l10n.restoreDefault),
        content: Text(l10n.comicResetConfirm),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _update(const ReaderDefaultSettings());
            },
            child: Text(l10n.restoreDefault),
          ),
        ],
      ),
    );
  }
}
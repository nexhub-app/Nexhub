import 'package:flutter/material.dart';
import '../../../core/widgets/app_animations.dart';
import 'package:nexhub/generated/app_localizations.dart';

import '../../../core/danmaku/danmaku_settings.dart';
import '../../../core/theme/app_tokens.dart';
import '../../settings/presentation/widgets/settings_widgets.dart';

/// 弹幕设置面板（底部弹出 Sheet）。
class DanmakuSettingsSheet extends StatefulWidget {
  const DanmakuSettingsSheet({
    super.key,
    required this.settings,
    required this.onChanged,
    this.onMatch,
  });

  final DanmakuSettings settings;
  final ValueChanged<DanmakuSettings> onChanged;

  /// 手动匹配弹幕回调（打开搜索/选集面板）。为 null 时不显示该入口。
  final VoidCallback? onMatch;

  /// 以 modal bottom sheet 形式展示。
  static Future<void> show(
    BuildContext context, {
    required DanmakuSettings settings,
    required ValueChanged<DanmakuSettings> onChanged,
    VoidCallback? onMatch,
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
      builder: (BuildContext context) => DanmakuSettingsSheet(
        settings: settings,
        onChanged: onChanged,
        onMatch: onMatch,
      ),
    );
  }

  @override
  State<DanmakuSettingsSheet> createState() => _DanmakuSettingsSheetState();
}

class _DanmakuSettingsSheetState extends State<DanmakuSettingsSheet> {
  late final TextEditingController _keywordController;
  late DanmakuSettings _settings;

  @override
  void initState() {
    super.initState();
    _settings = widget.settings;
    _keywordController = TextEditingController();
  }

  @override
  void dispose() {
    _keywordController.dispose();
    super.dispose();
  }

  void _update(DanmakuSettings next) {
    setState(() => _settings = next);
    widget.onChanged(next);
  }

  void _addKeyword() {
    final text = _keywordController.text.trim();
    if (text.isEmpty) return;
    if (_settings.filterKeywords.contains(text)) {
      _keywordController.clear();
      return;
    }
    _update(_settings.copyWith(
      filterKeywords: <String>[..._settings.filterKeywords, text],
    ));
    _keywordController.clear();
  }

  void _removeKeyword(String keyword) {
    _update(_settings.copyWith(
      filterKeywords:
          _settings.filterKeywords.where((k) => k != keyword).toList(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return AppSheetBody(
      child: Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _header(context, l10n, theme),
            Flexible(
              child: ListView(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppTokens.spaceLg,
                  vertical: AppTokens.spaceSm,
                ),
                children: <Widget>[
                  if (widget.onMatch != null)
                    ListTile(
                      leading: const Icon(Icons.sync_alt_outlined),
                      title: Text(l10n.danmakuMatchEpisode),
                      subtitle: Text(l10n.danmakuSearchHint),
                      onTap: () {
                        Navigator.of(context).maybePop();
                        widget.onMatch?.call();
                      },
                    ),
                  _keywordSection(l10n, theme),
                  // 以下滑块 / 开关复用设置页统一组件（灵动脉冲 + 统一手感）。
                  SettingsSliderTile(
                    label: l10n.danmakuTimeOffset,
                    value: _settings.timeOffset,
                    min: -10,
                    max: 10,
                    divisions: 20,
                    display: _settings.timeOffset.toStringAsFixed(1),
                    onChanged: (v) =>
                        _update(_settings.copyWith(timeOffset: v)),
                  ),
                  SettingsSliderTile(
                    label: l10n.danmakuArea,
                    value: _settings.area,
                    min: 0.1,
                    max: 1.0,
                    divisions: 9,
                    display: _settings.area.toStringAsFixed(1),
                    onChanged: (v) => _update(_settings.copyWith(area: v)),
                  ),
                  SettingsSliderTile(
                    label: l10n.danmakuDuration,
                    value: _settings.duration,
                    min: 3,
                    max: 15,
                    divisions: 12,
                    display: _settings.duration.toStringAsFixed(0),
                    onChanged: (v) => _update(_settings.copyWith(duration: v)),
                  ),
                  SettingsSliderTile(
                    label: l10n.danmakuLineHeight,
                    value: _settings.lineHeight,
                    min: 1.0,
                    max: 2.0,
                    divisions: 10,
                    display: _settings.lineHeight.toStringAsFixed(1),
                    onChanged: (v) => _update(_settings.copyWith(lineHeight: v)),
                  ),
                  SettingsSliderTile(
                    label: l10n.danmakuFontSize,
                    value: _settings.fontSize,
                    min: 12,
                    max: 28,
                    divisions: 16,
                    display: _settings.fontSize.toStringAsFixed(0),
                    onChanged: (v) =>
                        _update(_settings.copyWith(fontSize: v)),
                  ),
                  SettingsSliderTile(
                    label: l10n.danmakuOpacity,
                    value: _settings.opacity,
                    min: 0.1,
                    max: 1.0,
                    divisions: 9,
                    display: '${(_settings.opacity * 100).round()}%',
                    onChanged: (v) =>
                        _update(_settings.copyWith(opacity: v)),
                  ),
                  SettingsSwitchTile(
                    title: l10n.danmakuHideTop,
                    value: _settings.hideTop,
                    onChanged: (v) =>
                        _update(_settings.copyWith(hideTop: v)),
                  ),
                  SettingsSwitchTile(
                    title: l10n.danmakuHideBottom,
                    value: _settings.hideBottom,
                    onChanged: (v) =>
                        _update(_settings.copyWith(hideBottom: v)),
                  ),
                  SettingsSwitchTile(
                    title: l10n.danmakuHideScroll,
                    value: _settings.hideScroll,
                    onChanged: (v) =>
                        _update(_settings.copyWith(hideScroll: v)),
                  ),
                  SettingsSwitchTile(
                    title: l10n.danmakuFollowSpeed,
                    value: _settings.followPlaybackSpeed,
                    onChanged: (v) => _update(
                        _settings.copyWith(followPlaybackSpeed: v)),
                  ),
                  const SizedBox(height: AppTokens.spaceLg),
                ],
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }

  Widget _header(
      BuildContext context, AppLocalizations l10n, ThemeData theme) {
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
              l10n.danmaku,
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

  Widget _keywordSection(AppLocalizations l10n, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppTokens.spaceSm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(l10n.danmakuFilterKeywords,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: AppTokens.spaceSm),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _keywordController,
                  decoration: InputDecoration(
                    hintText: l10n.danmakuKeywordHint,
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _addKeyword(),
                ),
              ),
              const SizedBox(width: AppTokens.spaceSm),
              IconButton.filled(
                icon: const Icon(Icons.add),
                onPressed: _addKeyword,
                tooltip: l10n.danmakuAddKeyword,
              ),
            ],
          ),
          if (_settings.filterKeywords.isNotEmpty) ...<Widget>[
            const SizedBox(height: AppTokens.spaceSm),
            Wrap(
              spacing: AppTokens.spaceXs,
              runSpacing: AppTokens.spaceXs,
              children: <Widget>[
                for (final keyword in _settings.filterKeywords)
                  Chip(
                    label: Text(keyword),
                    onDeleted: () => _removeKeyword(keyword),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

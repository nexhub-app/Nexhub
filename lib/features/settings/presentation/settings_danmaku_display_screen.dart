/// 弹幕显示设置子页 —— 与播放器内设置面板**共用同一份数据**
/// （[DanmakuDisplaySettingsStore]，key: `danmaku_display_settings_v1`）。
///
/// 在本页修改的任何弹幕显示参数（区域/行高/字号/不透明度/时长/显隐开关等）
/// 都会立即写回该存储；进入播放器时播放器读取的也是同一份，因此两处始终一致。
///
/// 注：早期版本曾包含「显示区域 / 字体大小」的分段按钮并存与各自独立的
/// 滑块、「同屏上限」「滚动速度」分段按钮，但分段选择从未被 canvas_danmaku
/// 渲染层读取（`DanmakuSettings` 中对应 enum 字段仍保留以做向后兼容）。
library;

import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';

import '../../../core/danmaku/danmaku_settings.dart';
import '../../../core/danmaku/danmaku_settings_store.dart';
import '../../../core/theme/app_tokens.dart';
import 'widgets/settings_widgets.dart';

/// 弹幕显示设置页面（Scaffold 全页）。
class SettingsDanmakuDisplayScreen extends StatefulWidget {
  const SettingsDanmakuDisplayScreen({super.key});

  @override
  State<SettingsDanmakuDisplayScreen> createState() =>
      _SettingsDanmakuDisplayScreenState();
}

class _SettingsDanmakuDisplayScreenState
    extends State<SettingsDanmakuDisplayScreen> {
  final TextEditingController _keywordController = TextEditingController();
  final DanmakuDisplaySettingsStore _store = DanmakuDisplaySettingsStore();
  late DanmakuSettings _settings;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _settings = const DanmakuSettings();
    _store.load().then((s) {
      if (mounted) {
        setState(() {
          _settings = s;
          _loaded = true;
        });
      }
    });
  }

  @override
  void dispose() {
    _keywordController.dispose();
    super.dispose();
  }

  void _update(DanmakuSettings next) {
    setState(() => _settings = next);
    _store.save(next);
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

    return Scaffold(
      appBar: AppBar(title: Text(l10n.danmakuDisplaySettingsTitle)),
      body: _loaded
          ? ListView(
              padding: const EdgeInsets.symmetric(
                horizontal: AppTokens.spaceLg,
                vertical: AppTokens.spaceSm,
              ),
              children: <Widget>[
                // ── 过滤与屏蔽 ──
                SettingsCard(
                  index: 0,
                  title: l10n.danmakuDisplayGroupFilter,
                  children: <Widget>[
                    _keywordSection(l10n),
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
                  ],
                ),

                // ── 外观 ──
                // 注：「字体大小」原为分段按钮（小/中/大 → `fontSizePreset`），
                // canvas_danmaku 渲染层只读取 `fontSize`（double），分段选择从未生效。
                // 现统一使用下方 12-28 滑块（更细自定义）。
                // 模型与 enum `DanmakuFontSize` 字段保留，旧 JSON 仍可被 fromJson 解析。
                SettingsCard(
                  index: 1,
                  title: l10n.danmakuDisplayGroupAppearance,
                  children: <Widget>[
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
                  ],
                ),

                // ── 显示 ──
                // 注：本组曾有三个分段按钮与一个滑块并存，其中：
                //   - 显示区域（1/4 半屏 全屏 → `displayArea`）从未被渲染层读取；
                //   - 同屏上限（10/20/50/100 → `maxOnScreen`）未被引擎支持（无此字段）；
                //   - 滚动速度（慢/中/快 → `scrollSpeed`）未被引擎读取。
                // 现移除以上 3 个分段按钮，仅保留生效滑块。
                // 模型与对应 enum 字段保留，旧 JSON 仍可被 fromJson 解析（向后兼容）。
                SettingsCard(
                  index: 2,
                  title: l10n.danmakuDisplayGroupDisplay,
                  children: <Widget>[
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
                    SettingsSwitchTile(
                      title: l10n.danmakuFollowSpeed,
                      value: _settings.followPlaybackSpeed,
                      onChanged: (v) => _update(
                          _settings.copyWith(followPlaybackSpeed: v)),
                    ),
                  ],
                ),
              ],
            )
          : const Center(child: CircularProgressIndicator()),
    );
  }

  Widget _keywordSection(AppLocalizations l10n) {
    final theme = Theme.of(context);
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
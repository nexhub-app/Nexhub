/// 页面动态效果设置子页 —— 漫画阅读默认（comic_motion 引擎投影）。
///
/// 完整调节项由共享组件 [MotionEffectsAdjustments] 渲染（与漫画阅读设置页
/// 的「动态效果」卡片、阅读器内联面板分组同源）；本页只承载仓库加载 / 保存
/// 与恢复默认。持久化到 SharedPreferences（key: `reader_default_settings_v1`，
/// 与漫画阅读设置页共用同一仓库，仅写 `comicMotionEffects` 字段）。
library;

import 'package:material_ui/material_ui.dart';
import 'package:nexhub/generated/app_localizations.dart';

import '../../../core/comic/models/motion_effect_settings.dart';
import '../../../core/settings/reader_default_settings.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_loading_indicator.dart';
import '../../../core/widgets/app_glass_bar.dart';
import 'widgets/motion_effects_adjustments.dart';
import 'widgets/settings_widgets.dart';

/// 页面动态效果设置页面。
class SettingsMotionEffectsScreen extends StatefulWidget {
  const SettingsMotionEffectsScreen({super.key});

  @override
  State<SettingsMotionEffectsScreen> createState() =>
      _SettingsMotionEffectsScreenState();
}

class _SettingsMotionEffectsScreenState
    extends State<SettingsMotionEffectsScreen> {
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.motionEffectTitle),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.restore_rounded),
            tooltip: l10n.restoreDefault,
            onPressed: () => _update(_settings.copyWith(
                comicMotionEffects: const MotionEffectSettings())),
          ),
        ],
      ),
      body: !_loaded
          ? const Center(child: AppLoadingIndicator())
          : ListView(
              padding: context.pageInset(AppTokens.spaceLg),
              children: <Widget>[
                SettingsCard(
                  key: const ValueKey<String>('motion.master'),
                  title: l10n.motionEffectTitle,
                  description: l10n.motionEffectDesc,
                  index: 0,
                  children: <Widget>[
                    MotionEffectsAdjustments(
                      settings: _settings.comicMotionEffects,
                      onChanged: (next) =>
                          _update(_settings.copyWith(comicMotionEffects: next)),
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}

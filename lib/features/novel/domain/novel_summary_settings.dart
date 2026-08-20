import 'package:shared_preferences/shared_preferences.dart';

import 'novel_summary_service.dart';

/// 阅读速览（章节内容总结）的本地设置：总结方式（离线/云端）与云端 API 配置。
/// 底层走 SharedPreferences（与现有弹幕凭据一致；API 密钥明文存本机，不外发）。
class NovelSummarySettings {
  static final NovelSummarySettings instance = NovelSummarySettings._();
  NovelSummarySettings._();

  static const String _kMode = 'novel_overview_mode_v1';
  static const String _kBase = 'novel_overview_api_base_v1';
  static const String _kKey = 'novel_overview_api_key_v1';
  static const String _kModel = 'novel_overview_api_model_v1';

  Future<NovelOverviewMode> getMode() async {
    final p = await SharedPreferences.getInstance();
    final v = p.getString(_kMode);
    return v == 'api' ? NovelOverviewMode.api : NovelOverviewMode.local;
  }

  Future<void> setMode(NovelOverviewMode mode) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kMode, mode == NovelOverviewMode.api ? 'api' : 'local');
  }

  Future<NovelSummaryConfig> getConfig() async {
    final p = await SharedPreferences.getInstance();
    return NovelSummaryConfig(
      baseUrl: p.getString(_kBase) ?? '',
      apiKey: p.getString(_kKey) ?? '',
      model: p.getString(_kModel) ?? '',
    );
  }

  Future<void> saveConfig(NovelSummaryConfig cfg) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kBase, cfg.baseUrl);
    await p.setString(_kKey, cfg.apiKey);
    await p.setString(_kModel, cfg.model);
  }
}

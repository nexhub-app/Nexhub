/// 源公告横幅：当某源声明了 `announcement` 时，在该源相关页面顶部展示。
///
/// 横幅含源名 + 公告标题 + 正文（可选）+ 「查看详情」外链（可选）+ 关闭按钮。
/// 公告内容完全由源 JSON 声明，app 不写死任何站点文案（契合「源即插件」理念）。
library;

import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/plugin_config.dart';
import '../theme/app_tokens.dart';

class SourceAnnouncementBanner extends StatelessWidget {
  final PluginConfig source;
  final VoidCallback? onDismiss;

  const SourceAnnouncementBanner({
    super.key,
    required this.source,
    this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final announcement = source.announcement;
    if (announcement == null) return const SizedBox.shrink();

    final AppLocalizations l10n = AppLocalizations.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final a = announcement;

    return Container(
      margin: const EdgeInsets.only(bottom: AppTokens.spaceMd),
      padding: const EdgeInsets.all(AppTokens.spaceMd),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              Icons.campaign_outlined,
              size: 20,
              color: scheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(width: AppTokens.spaceSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '${source.name} · ${a.title}',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: scheme.onPrimaryContainer,
                      ),
                ),
                if (a.body != null && a.body!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: AppTokens.spaceXs),
                    child: Text(
                      a.body!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onPrimaryContainer,
                          ),
                    ),
                  ),
                if (a.url != null && a.url!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: AppTokens.spaceXs),
                    child: InkWell(
                      onTap: () => _openUrl(a.url!),
                      child: Text(
                        l10n.sourceAnnouncementView,
                        style: TextStyle(
                          color: scheme.primary,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (onDismiss != null)
            IconButton(
              icon: Icon(Icons.close, size: 18, color: scheme.onPrimaryContainer),
              onPressed: onDismiss,
              tooltip: l10n.close,
            ),
        ],
      ),
    );
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (_) {
      // 外链打开失败静默忽略，不阻断 UI。
    }
  }
}

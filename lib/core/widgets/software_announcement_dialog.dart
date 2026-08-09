/// 软件公告启动弹窗（项 8）：列出本次启动尚未读过的公告。
///
/// 与源级横幅 [SourceAnnouncementBanner] 解耦——这是「软件级」公告，
/// 内容来自打包资源 `assets/announcements.json`，而非某个源 JSON。
library;

import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/software_announcement_service.dart';
import '../theme/app_tokens.dart';

/// 展示未读软件公告。用户点「知道了」后全部标记为已读。
/// 无未读时直接返回，不弹窗。
Future<void> showSoftwareAnnouncements(
  BuildContext context,
  List<SoftwareAnnouncement> announcements,
) async {
  if (announcements.isEmpty || !context.mounted) return;
  final l10n = AppLocalizations.of(context);
  final bool isZh = Localizations.localeOf(context).languageCode == 'zh';

  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      return AlertDialog(
        insetPadding: const EdgeInsets.all(AppTokens.spaceMd),
        title: Row(
          children: <Widget>[
            Icon(Icons.campaign_outlined,
                color: Theme.of(dialogContext).colorScheme.primary),
            const SizedBox(width: AppTokens.spaceSm),
            Expanded(child: Text(l10n.appAnnouncement)),
          ],
        ),
        content: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(dialogContext).size.height * 0.6,
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (final a in announcements) ...<Widget>[
                  if (a.date.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppTokens.spaceXxs),
                      child: Text(
                        a.date,
                        style:
                            Theme.of(dialogContext).textTheme.labelSmall?.copyWith(
                                  color: Theme.of(dialogContext)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                      ),
                    ),
                  Text(
                    isZh ? a.title : a.titleEn,
                    style: Theme.of(dialogContext)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: AppTokens.spaceXxs),
                  Text(
                    isZh ? a.body : a.bodyEn,
                    style: Theme.of(dialogContext).textTheme.bodySmall,
                  ),
                  if (a.url.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: AppTokens.spaceXs),
                      child: InkWell(
                        onTap: () => _openUrl(a.url),
                        child: Text(
                          isZh ? a.urlText : a.urlTextEn,
                          style: TextStyle(
                            color: Theme.of(dialogContext).colorScheme.primary,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: AppTokens.spaceMd),
                  const Divider(height: 1),
                  const SizedBox(height: AppTokens.spaceMd),
                ],
              ],
            ),
          ),
        ),
        actions: <Widget>[
          FilledButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              SoftwareAnnouncementService.instance
                  .markSeen(announcements.map((a) => a.id).toList());
            },
            child: Text(l10n.appAnnouncementGotIt),
          ),
        ],
      );
    },
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
    // 外链打开失败静默忽略。
  }
}

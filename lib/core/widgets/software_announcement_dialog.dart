/// 软件公告启动弹窗（项 8）：列出本次启动尚未读过的公告。
///
/// 与源级横幅 [SourceAnnouncementBanner] 解耦——这是「软件级」公告，
/// 内容来自远程多源 JSON（见 [SoftwareAnnouncementService]），而非某个源 JSON。
library;

import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/software_announcement_service.dart';
import '../theme/app_tokens.dart';

/// 展示未读软件公告。用户点「知道了」后全部标记为已读。
/// 无未读时直接返回，不弹窗。
///
/// 使用底部上滑弹层（isScrollControlled + 最大 85% 屏高 + 滚动容器），
/// 公告较多时可滑动查看，不会被截断。
Future<void> showSoftwareAnnouncements(
  BuildContext context,
  List<SoftwareAnnouncement> announcements,
) async {
  if (announcements.isEmpty || !context.mounted) return;
  final l10n = AppLocalizations.of(context);
  final bool isZh = Localizations.localeOf(context).languageCode == 'zh';

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius:
          BorderRadius.vertical(top: Radius.circular(AppTokens.radiusLg)),
    ),
    builder: (sheetContext) {
      final scheme = Theme.of(sheetContext).colorScheme;
      return ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(sheetContext).size.height * 0.85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // 顶部拖拽指示（仅装饰，enableDrag=false 不响应拖拽关闭）。
            Padding(
              padding: const EdgeInsets.only(top: AppTokens.spaceSm),
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: scheme.onSurfaceVariant.withOpacity(0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppTokens.spaceMd,
                AppTokens.spaceMd,
                AppTokens.spaceMd,
                AppTokens.spaceSm,
              ),
              child: Row(
                children: <Widget>[
                  Icon(Icons.campaign_outlined, color: scheme.primary),
                  const SizedBox(width: AppTokens.spaceSm),
                  Expanded(
                    child: Text(
                      l10n.appAnnouncement,
                      style: Theme.of(sheetContext).textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // 可滚动内容：公告多时滑动查看。
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(AppTokens.spaceMd),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    for (final a in announcements) ...<Widget>[
                      if (a.date.isNotEmpty)
                        Padding(
                          padding:
                              const EdgeInsets.only(bottom: AppTokens.spaceXxs),
                          child: Text(
                            a.date,
                            style: Theme.of(sheetContext)
                                .textTheme
                                .labelSmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ),
                      Text(
                        isZh ? a.title : a.titleEn,
                        style: Theme.of(sheetContext)
                            .textTheme
                            .titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: AppTokens.spaceXxs),
                      Text(
                        isZh ? a.body : a.bodyEn,
                        style: Theme.of(sheetContext).textTheme.bodySmall,
                      ),
                      if (a.url.isNotEmpty)
                        Padding(
                          padding:
                              const EdgeInsets.only(top: AppTokens.spaceXs),
                          child: InkWell(
                            onTap: () => _openUrl(a.url),
                            child: Text(
                              isZh ? a.urlText : a.urlTextEn,
                              style: TextStyle(
                                color: scheme.primary,
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
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(AppTokens.spaceMd),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () {
                    Navigator.of(sheetContext).pop();
                    SoftwareAnnouncementService.instance
                        .markSeen(announcements.map((a) => a.id).toList());
                  },
                  child: Text(l10n.appAnnouncementGotIt),
                ),
              ),
            ),
          ],
        ),
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

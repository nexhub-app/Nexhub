/// About screen —— application info, licenses, repository and update entry.
library;

import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:dio/dio.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_list_tile.dart';
import './widgets/settings_widgets.dart';
import 'package:nexhub/core/widgets/app_alert_dialog.dart';

/// 致谢条目数据模型（文件作用域）。
class _AcknowledgementCredit {
  final String name;
  final String desc;
  final String url;
  const _AcknowledgementCredit({
    required this.name,
    required this.desc,
    required this.url,
  });
}

/// 致谢弹窗中的单条署名卡片。
class _AcknowledgementCard extends StatelessWidget {
  final _AcknowledgementCredit credit;
  final AppLocalizations l10n;
  const _AcknowledgementCard({
    required this.credit,
    required this.l10n,
  });

  Future<void> _open() async {
    final Uri uri = Uri.parse(credit.url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTokens.spaceMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            credit.name,
            style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: AppTokens.spaceXs),
          Text(credit.desc, style: textTheme.bodySmall),
          const SizedBox(height: AppTokens.spaceXs),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _open,
              child: Text(l10n.acknowledgementsViewProject),
            ),
          ),
        ],
      ),
    );
  }
}

/// Project repository URL opened via url_launcher.
const String _kProjectRepositoryUrl = 'https://github.com/nexhub-app/nexhub';

class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  PackageInfo? _packageInfo;

  @override
  void initState() {
    super.initState();
    _loadPackageInfo();
  }

  Future<void> _loadPackageInfo() async {
    final PackageInfo info = await PackageInfo.fromPlatform();
    if (mounted) {
      setState(() => _packageInfo = info);
    }
  }

  Future<void> _openRepository() async {
    final Uri url = Uri.parse(_kProjectRepositoryUrl);
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }
  }

  /// 检查 GitHub 最新发布版本，与当前版本比较。
  Future<void> _checkForUpdate(AppLocalizations l10n) async {
    if (_packageInfo == null) await _loadPackageInfo();
    final String current = _packageInfo?.version ?? '0.0.0';

    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AppAlertDialog(
        content: Row(
          children: <Widget>[
            const CircularProgressIndicator(),
            const SizedBox(width: AppTokens.spaceMd),
            Text(l10n.updateChecking),
          ],
        ),
      ),
    );

    String? latestTag;
    try {
      latestTag = await _fetchLatestReleaseTag();
    } on Object {
      latestTag = null;
    }

    if (!mounted) return;
    Navigator.of(context).pop(); // 关闭加载框

    if (latestTag == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.updateCheckFailed)),
      );
      return;
    }

    final bool newer = _isNewer(
      _normalizeVersion(latestTag),
      _normalizeVersion(current),
    );

    if (!mounted) return;
    if (newer) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AppAlertDialog(
          title: Text(l10n.updateAvailable(latestTag!)),
          content: Text(l10n.updateAvailableHint),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                _openRepository();
              },
              child: Text(l10n.updateGoToDownload),
            ),
          ],
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.updateLatest)),
      );
    }
  }

  /// 从 GitHub Releases API 获取最新发布标签（tag_name）。
  Future<String?> _fetchLatestReleaseTag() async {
    final Dio dio = Dio();
    final Response<List<dynamic>> resp =
        await dio.get<List<dynamic>>(
      'https://api.github.com/repos/nexhub-app/nexhub/releases',
      options: Options(
        headers: <String, String>{
          'Accept': 'application/vnd.github+json',
        },
        receiveTimeout: const Duration(seconds: 10),
        sendTimeout: const Duration(seconds: 10),
      ),
    );
    final List<dynamic>? list = resp.data;
    if (list == null || list.isEmpty) return null;
    final Map<String, dynamic> first = list.first as Map<String, dynamic>;
    return first['tag_name'] as String?;
  }

  /// 将版本字符串规范为数字段列表（去掉前缀 v 与预发布后缀）。
  List<int> _normalizeVersion(String v) {
    final String cleaned =
        v.replaceAll(RegExp(r'^[vV]'), '').split('-').first;
    return cleaned.split('.').map((e) => int.tryParse(e) ?? 0).toList();
  }

  /// 判断 [a] 是否比 [b] 版本更新（按数字段逐位比较）。
  bool _isNewer(List<int> a, List<int> b) {
    final int n = a.length > b.length ? a.length : b.length;
    for (int i = 0; i < n; i++) {
      final int x = i < a.length ? a[i] : 0;
      final int y = i < b.length ? b[i] : 0;
      if (x > y) return true;
      if (x < y) return false;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final TextTheme textTheme = Theme.of(context).textTheme;
    final String versionText = _packageInfo == null
        ? ''
        : '${_packageInfo!.version}+${_packageInfo!.buildNumber}';

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.aboutAppTitle),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.maybePop(context),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppTokens.spaceLg),
        children: <Widget>[
          // ── App identity block ──
          Center(
            child: Column(
              children: <Widget>[
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppTokens.radiusLg),
                  child: Image.asset(
                    'assets/icon/icon.png',
                    width: 80,
                    height: 80,
                    fit: BoxFit.cover,
                  ),
                ),
                const SizedBox(height: AppTokens.spaceMd),
                Text(
                  'NexHub',
                  style: textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: AppTokens.spaceXs),
                if (versionText.isNotEmpty)
                  Text(
                    versionText,
                    style: textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),

          const SizedBox(height: AppTokens.spaceXl),

          // ── Description ──
          AppListTile(
            leading: const SettingsLeadingIcon(icon:Icons.info_outline),
            title: Text(l10n.aboutApp),
            subtitle: Text(l10n.aboutDescription),
          ),

          const SizedBox(height: AppTokens.spaceLg),

          // ── Licenses / libraries ──
          AppListTile(
            leading: const SettingsLeadingIcon(icon:Icons.description_outlined),
            title: Text(l10n.openSourceLicenses),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'NexHub',
              applicationVersion: versionText,
              applicationIcon: const SizedBox(
                width: 48,
                height: 48,
                child: Image(
                  image: AssetImage('assets/icon/icon.png'),
                  fit: BoxFit.cover,
                ),
              ),
            ),
          ),
          AppListTile(
            leading: const SettingsLeadingIcon(icon:Icons.inventory_2_outlined),
            title: Text(l10n.thirdPartyLibraries),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'NexHub',
              applicationVersion: versionText,
            ),
          ),

        AppListTile(
          leading: const SettingsLeadingIcon(icon:Icons.favorite_outline),
          title: Text(l10n.acknowledgements),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _showAcknowledgements(l10n),
        ),

        const SizedBox(height: AppTokens.spaceLg),

        // ── Repository / update ──
          AppListTile(
            leading: const SettingsLeadingIcon(icon:Icons.code),
            title: Text(l10n.projectRepository),
            trailing: const Icon(Icons.chevron_right),
            onTap: _openRepository,
          ),
          AppListTile(
            leading: const SettingsLeadingIcon(icon:Icons.system_update_alt),
            title: Text(l10n.checkUpdate),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _checkForUpdate(l10n),
          ),
        ],
      ),
    );
  }

  Future<void> _showAcknowledgements(AppLocalizations l10n) async {
    final List<_AcknowledgementCredit> credits = <_AcknowledgementCredit>[
      _AcknowledgementCredit(
        name: 'Legado',
        desc: l10n.acknowledgementsLegado,
        url: 'https://github.com/gedoor/legado',
      ),
      _AcknowledgementCredit(
        name: 'Mihon',
        desc: l10n.acknowledgementsMihon,
        url: 'https://github.com/mihonapp/mihon',
      ),
      _AcknowledgementCredit(
        name: 'RSSHub',
        desc: l10n.acknowledgementsRssHub,
        url: 'https://github.com/DIYgod/RSSHub',
      ),
    ];
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(l10n.acknowledgements),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              ...credits.map(
                (c) => _AcknowledgementCard(credit: c, l10n: l10n),
              ),
              const SizedBox(height: AppTokens.spaceMd),
              Text(
                l10n.acknowledgementsMoreLibs,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.cancel),
          ),
        ],
      ),
    );
  }
}

/// About screen —— application info, licenses, repository and update entry.
library;

import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/update/update_manager.dart';
import '../../../core/update/update_settings.dart';
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
  bool _downloadCompleteNotified = false;
  bool _updateDialogVisible = false;

  @override
  void initState() {
    super.initState();
    _loadPackageInfo();
    // 更新对话框已关闭时，后台下载完成/失败经此回调弹提示（保证静默/关框下载可感知）。
    UpdateManager.instance.addListener(_onUpdateManagerChanged);
  }

  @override
  void dispose() {
    UpdateManager.instance.removeListener(_onUpdateManagerChanged);
    super.dispose();
  }

  void _onUpdateManagerChanged() {
    final m = UpdateManager.instance;
    if (!mounted || _updateDialogVisible) return;
    if (m.status == UpdateStatus.done && !_downloadCompleteNotified) {
      _downloadCompleteNotified = true;
      final String name = m.progress.fileName;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$name 下载完成')),
      );
    } else if (m.status == UpdateStatus.failed && !_downloadCompleteNotified) {
      _downloadCompleteNotified = true;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(m.lastError ?? '下载失败')),
      );
    }
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

  /// 检查最新版本并下载安装。
  Future<void> _checkForUpdate(AppLocalizations l10n) async {
    if (_packageInfo == null) await _loadPackageInfo();
    final String current = _packageInfo?.version ?? '0.0.0';
    final manager = UpdateManager.instance;
    _downloadCompleteNotified = false;

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

    final UpdateReleaseInfo? release = await manager.checkForUpdate();
    if (!mounted) return;
    Navigator.of(context).pop(); // 关闭加载框

    if (release == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.updateCheckFailed)),
      );
      return;
    }

    final bool newer = manager.isNewer(
      release.tagName,
      current,
    );

    if (!mounted) return;
    if (newer) {
      _updateDialogVisible = true;
      await showDialog<void>(
        context: context,
        builder: (ctx) => _UpdateDialog(
          release: release,
          currentVersion: current,
        ),
      );
      _updateDialogVisible = false;
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.updateLatest)),
      );
    }
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
            leading: const SettingsLeadingIcon(icon:Icons.settings_input_antenna),
            title: Text(l10n.updateMirrorSettings),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _openMirrorSettings(l10n),
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
      _AcknowledgementCredit(
        name: 'Anime4K',
        desc: l10n.acknowledgementsAnime4K,
        url: 'https://github.com/bloc97/Anime4K',
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

  /// 打开镜像设置页。
  void _openMirrorSettings(AppLocalizations l10n) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => UpdateMirrorSettingsScreen(l10n: l10n),
      ),
    );
  }
}

/// 更新可用对话框：展示版本信息、下载进度、静默下载开关与安装操作。
class _UpdateDialog extends StatefulWidget {
  final UpdateReleaseInfo release;
  final String currentVersion;

  const _UpdateDialog({
    required this.release,
    required this.currentVersion,
  });

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  final UpdateManager _manager = UpdateManager.instance;
  bool _silent = false;
  bool _downloading = false;
  bool _downloaded = false;
  double _progress = 0.0;

  @override
  void initState() {
    super.initState();
    _manager.addListener(_onManagerUpdate);
  }

  @override
  void dispose() {
    _manager.removeListener(_onManagerUpdate);
    super.dispose();
  }

  void _onManagerUpdate() {
    if (!mounted) return;
    final p = _manager.progress.progress;
    setState(() {
      if (_manager.status == UpdateStatus.downloading) {
        _downloading = true;
        _progress = p;
      } else if (_manager.status == UpdateStatus.done) {
        _downloading = false;
        _downloaded = true;
      } else if (_manager.status == UpdateStatus.failed) {
        _downloading = false;
      }
    });
  }

  Future<void> _startDownload() async {
    setState(() => _downloading = true);
    final String? path = await _manager.downloadInstaller(
      widget.release,
      silent: _silent,
    );
    if (mounted && path != null) {
      setState(() {
        _downloading = false;
        _downloaded = true;
      });
    } else if (mounted) {
      setState(() => _downloading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _manager.lastError ?? 'Download failed',
          ),
        ),
      );
    }
  }

  Future<void> _install() async {
    final bool ok = await _manager.installDownloaded();
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_manager.lastError ?? 'Install failed')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final TextTheme textTheme = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String mirrorName = _manager.currentMirrorName;
    final int percent = (_progress * 100).round();

    return AlertDialog(
      title: Text(l10n.updateAvailable(widget.release.tagName)),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                widget.release.body.isEmpty
                    ? l10n.updateAvailableHint
                    : widget.release.body,
                style: textTheme.bodyMedium,
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: AppTokens.spaceMd),
              // 镜像信息
              Row(
                children: <Widget>[
                  Icon(Icons.cloud_download_outlined,
                      size: 18, color: scheme.onSurfaceVariant),
                  const SizedBox(width: AppTokens.spaceXs),
                  Text(
                    '${l10n.updateMirror}: $mirrorName',
                    style: textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
              const SizedBox(height: AppTokens.spaceSm),
              // 下载进度
              if (_downloading) ...<Widget>[
                LinearProgressIndicator(value: _progress),
                const SizedBox(height: AppTokens.spaceXs),
                Text(
                  '$percent%',
                  style: textTheme.bodySmall
                      ?.copyWith(color: scheme.primary),
                  textAlign: TextAlign.right,
                ),
                const SizedBox(height: AppTokens.spaceSm),
              ],
              if (_downloaded) ...<Widget>[
                Row(
                  children: <Widget>[
                    Icon(Icons.check_circle_outline,
                        color: scheme.primary, size: 20),
                    const SizedBox(width: AppTokens.spaceXs),
                    Text(
                      l10n.updateDownloaded,
                      style: textTheme.bodyMedium,
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        if (!_downloading && !_downloaded) ...<Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
          // 静默下载开关
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                l10n.updateSilentDownload,
                style: textTheme.bodySmall,
              ),
              const SizedBox(width: AppTokens.spaceXs),
              Switch(
                value: _silent,
                onChanged: (v) => setState(() => _silent = v),
                materialTapTargetSize:
                    MaterialTapTargetSize.shrinkWrap,
              ),
            ],
          ),
          FilledButton(
            onPressed: _startDownload,
            child: Text(l10n.updateDownloadAndInstall),
          ),
        ] else if (_downloading) ...<Widget>[
          TextButton(
            onPressed: () {
              // 关闭对话框，下载在后台继续（静默下载）。
              // 完成后 About 页监听 UpdateManager 弹出提示。
              Navigator.pop(context);
            },
            child: Text(l10n.cancel),
          ),
        ] else if (_downloaded) ...<Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: _install,
            child: Text(l10n.updateInstallNow),
          ),
        ],
      ],
    );
  }
}

/// 镜像设置页：自动切换开关、镜像选择、自定义镜像增删。
class UpdateMirrorSettingsScreen extends StatefulWidget {
  final AppLocalizations l10n;

  const UpdateMirrorSettingsScreen({super.key, required this.l10n});

  @override
  State<UpdateMirrorSettingsScreen> createState() =>
      _UpdateMirrorSettingsScreenState();
}

class _UpdateMirrorSettingsScreenState
    extends State<UpdateMirrorSettingsScreen> {
  final UpdateManager _manager = UpdateManager.instance;
  UpdateSettings _settings = const UpdateSettings.defaults();
  bool _loaded = false;
  final Map<String, int> _latencyResults = <String, int>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await _manager.reloadSettings();
    if (!mounted) return;
    setState(() {
      _settings = _manager.settings;
      _loaded = true;
    });
    // 页面加载后自动测速所有镜像
    _probeAllMirrors();
  }

  Future<void> _save(UpdateSettings s) async {
    setState(() => _settings = s);
    await _manager.saveSettings(s);
  }

  void _addCustomMirror() {
    final TextEditingController nameCtrl = TextEditingController();
    final TextEditingController urlCtrl = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(widget.l10n.updateAddMirror),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: nameCtrl,
              decoration: InputDecoration(
                labelText: widget.l10n.updateMirrorName,
              ),
            ),
            const SizedBox(height: AppTokens.spaceMd),
            TextField(
              controller: urlCtrl,
              decoration: InputDecoration(
                labelText: widget.l10n.updateMirrorUrl,
                hintText: 'https://ghproxy.com/',
              ),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(widget.l10n.cancel),
          ),
          FilledButton(
            onPressed: () {
              final String name = nameCtrl.text.trim();
              final String url = urlCtrl.text.trim();
              if (name.isEmpty || url.isEmpty) return;
              Navigator.pop(ctx);
              _save(_settings.copyWith(
                customMirrors: <UpdateMirror>[
                  ..._settings.customMirrors,
                  UpdateMirror(name: name, baseUrl: url),
                ],
              ));
            },
            child: Text(widget.l10n.confirm),
          ),
        ],
      ),
    );
  }

  void _removeCustomMirror(int index) {
    final List<UpdateMirror> mirrors = List<UpdateMirror>.of(
      _settings.customMirrors,
    )..removeAt(index);
    _save(_settings.copyWith(customMirrors: mirrors));
  }

  Future<void> _probeAllMirrors() async {
    setState(() {
      _latencyResults.clear();
    });
    // 组装所有镜像列表（默认镜像 + 自定义镜像）
    final List<({String name, String prefix})> mirrors =
        List<({String name, String prefix})>.of(
            UpdateManager.defaultMirrors);
    for (final m in _settings.customMirrors) {
      mirrors.add((name: m.name, prefix: m.baseUrl));
    }
    // 并发探测所有镜像，每个结果到达后立即更新 UI
    final List<Future<void>> probes = <Future<void>>[
      for (final m in mirrors)
        _manager.probeMirror(m.prefix).then((int ms) {
          if (mounted) {
            setState(() => _latencyResults[m.name] = ms);
          }
        }).catchError((_) {
          if (mounted) {
            setState(() => _latencyResults[m.name] = -1);
          }
        }),
    ];
    await Future.wait(probes);
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = widget.l10n;
    final TextTheme textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.updateMirrorSettings),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.maybePop(context),
        ),
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(AppTokens.spaceLg),
              children: <Widget>[
                // 自动切换镜像开关
                AppListTile(
                  leading: const Icon(Icons.bolt),
                  title: Text(l10n.updateAutoSwitchMirror),
                  subtitle: Text(l10n.updateAutoSwitchMirrorDesc),
                  trailing: Switch(
                    value: _settings.autoSwitchMirror,
                    onChanged: (v) =>
                        _save(_settings.copyWith(autoSwitchMirror: v)),
                  ),
                ),
                const SizedBox(height: AppTokens.spaceMd),
                // 当前镜像选择
                Text(
                  l10n.updateMirrorSelection,
                  style: textTheme.titleSmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: AppTokens.spaceSm),
                ..._buildMirrorTiles(l10n),
                const SizedBox(height: AppTokens.spaceLg),
                // 自定义镜像
                Text(
                  l10n.updateCustomMirrors,
                  style: textTheme.titleSmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: AppTokens.spaceSm),
                if (_settings.customMirrors.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        vertical: AppTokens.spaceSm),
                    child: Text(
                      l10n.updateNoCustomMirrors,
                      style: textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                else
                  ..._settings.customMirrors.asMap().entries.map((e) {
                    final int idx = e.key;
                    final UpdateMirror m = e.value;
                    return ListTile(
                      leading: const Icon(Icons.dns_outlined),
                      title: Text(m.name),
                      subtitle: Text(
                        m.baseUrl,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: l10n.delete,
                        onPressed: () => _removeCustomMirror(idx),
                      ),
                    );
                  }),
                const SizedBox(height: AppTokens.spaceSm),
                OutlinedButton.icon(
                  onPressed: _addCustomMirror,
                  icon: const Icon(Icons.add),
                  label: Text(l10n.updateAddMirror),
                ),
              ],
            ),
    );
  }

  List<Widget> _buildMirrorTiles(AppLocalizations l10n) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final List<({String name, String prefix})> mirrors =
        List<({String name, String prefix})>.of(
            UpdateManager.defaultMirrors);
    for (final m in _settings.customMirrors) {
      mirrors.add((name: m.name, prefix: m.baseUrl));
    }

    final List<Widget> tiles = <Widget>[];
    for (int i = 0; i < mirrors.length; i++) {
      final int idx = i;
      final String label = mirrors[i].name;
      final bool selected = _settings.mirrorIndex == idx;
      // 该镜像的测速延迟（-1 = 超时，null = 未测）
      final int? latency = _latencyResults[label];
      tiles.add(
        RadioListTile<int>(
          value: idx,
          groupValue: _settings.mirrorIndex,
          onChanged: (v) => _save(_settings.copyWith(mirrorIndex: v ?? 0)),
          title: Text(label),
          subtitle: latency != null
              ? Text(
                  latency < 0
                      ? l10n.updateMirrorTimeout
                      : '${latency}ms',
                  style: TextStyle(
                    color: latency < 0
                        ? scheme.error
                        : latency < 1000
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                )
              : null,
          secondary: selected
              ? const Icon(Icons.check_circle, color: null)
              : null,
        ),
      );
      if (i < mirrors.length - 1) {
        tiles.add(const Divider(height: 1));
      }
    }
    return tiles;
  }
}

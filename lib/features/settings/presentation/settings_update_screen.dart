/// 更新设置页 —— 升级通道、自动检查/下载、应用内下载与下载镜像的统一入口。
///
/// 对应需求：
/// - 升级通道（稳定版 / 测试版）：按 [UpdateChannel] 过滤 GitHub release；
/// - 自动检查更新 / 自动下载更新（仅 WiFi）；
/// - 应用内下载开关（关闭后跳浏览器）；
/// - 下载镜像：自动切换、镜像选择、自定义镜像与测速。
///
/// 本页同时是设置搜索的可滚动目标（见 `settings_search_target.dart`），
/// 每个设置项都带 `ValueKey<String>` 供搜索直达。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../core/theme/app_tokens.dart';
import '../../../core/update/update_manager.dart';
import '../../../core/update/update_settings.dart';
import '../../../core/utils/app_haptics.dart';
import '../../../core/widgets/app_alert_dialog.dart';
import '../../../core/widgets/app_list_tile.dart';
import './widgets/settings_search_target.dart';
import './widgets/settings_widgets.dart';

/// 自定义镜像地址归一化：补末尾斜杠（漏写会拼接出非法下载 URL）。
String _normalizeMirrorBaseUrl(String url) {
  final String base = url.trim();
  return base.endsWith('/') ? base : '$base/';
}

class SettingsUpdateScreen extends StatefulWidget {
  const SettingsUpdateScreen({super.key});

  @override
  State<SettingsUpdateScreen> createState() => _SettingsUpdateScreenState();
}

class _SettingsUpdateScreenState extends State<SettingsUpdateScreen> {
  final UpdateManager _manager = UpdateManager.instance;
  UpdateSettings _settings = const UpdateSettings.defaults();
  bool _loaded = false;
  String _currentVersion = '';
  bool _updateDialogVisible = false;
  bool _downloadCompleteNotified = false;
  final Map<String, int> _latencyResults = <String, int>{};

  /// 社区镜像列表是否展开（默认折叠，仅显示最快的 5 个：官方 + 前 4）。
  bool _mirrorExpanded = false;
  bool _mirrorExpansionInitialized = false;

  /// 可见的社区镜像数量（展开前=4，展开后=全部）。
  int get _visibleCommunityCount => _mirrorExpanded ? _communityCount : 4;

  /// 社区镜像总数（默认镜像去掉 GitHub 官方）。
  int get _communityCount => UpdateManager.defaultMirrors.length - 1;

  @override
  void initState() {
    super.initState();
    _load();
    _loadVersion();
    // 更新对话框已关闭时，后台下载完成/失败经此回调弹提示。
    _manager.addListener(_onUpdateManagerChanged);
  }

  @override
  void dispose() {
    _manager.removeListener(_onUpdateManagerChanged);
    super.dispose();
  }

  void _onUpdateManagerChanged() {
    final m = UpdateManager.instance;
    if (!mounted || _updateDialogVisible) return;
    if (m.status == UpdateStatus.done && !_downloadCompleteNotified) {
      _downloadCompleteNotified = true;
      final String name = m.progress.fileName;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$name ${_l10n().updateDownloaded}')),
      );
    } else if (m.status == UpdateStatus.failed && !_downloadCompleteNotified) {
      final String? err = m.lastError;
      if (err == 'opened-in-browser') {
        _downloadCompleteNotified = true;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_l10n().updateOpenedBrowser)),
        );
      } else if (err != null) {
        _downloadCompleteNotified = true;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(err)),
        );
      }
    }
  }

  AppLocalizations _l10n() => AppLocalizations.of(context);

  Future<void> _loadVersion() async {
    try {
      final PackageInfo info = await PackageInfo.fromPlatform();
      if (mounted) setState(() => _currentVersion = info.version);
    } on Object {
      // 忽略，版本号非关键。
    }
  }

  Future<void> _load() async {
    await _manager.reloadSettings();
    if (!mounted) return;
    setState(() {
      _settings = _manager.settings;
      _loaded = true;
    });
    _ensureMirrorExpansionValid();
    // 进入页面即用真实安装包文件自动测速（用户需求：打开即可看到各镜像
    // 对下载文件的实测延迟；全部失败时给出统一提示）。
    _probeAllMirrors();
  }

  /// 若当前选中的镜像位于折叠区，自动展开，避免选中项「消失」。
  void _ensureMirrorExpansionValid() {
    if (_mirrorExpansionInitialized) return;
    _mirrorExpansionInitialized = true;
    final int idx = _settings.mirrorIndex;
    final bool isCommunity = idx >= 1 && idx <= _communityCount;
    if (isCommunity && idx > _visibleCommunityCount) {
      _mirrorExpanded = true;
    }
  }

  /// 测速是否已全部完成（每个镜像都有结果键）。
  bool get _probeFinished {
    final List<({String name, String prefix})> all =
        List<({String name, String prefix})>.of(UpdateManager.defaultMirrors);
    for (final m in _settings.customMirrors) {
      all.add((name: m.name, prefix: _normalizeMirrorBaseUrl(m.baseUrl)));
    }
    return all.every((m) => _latencyResults.containsKey(m.name));
  }

  /// 组装镜像显示顺序：GitHub 官方固定首位，其余（社区 + 自定义）在
  /// 测速**全部完成**后按实测延迟升序排列；测速中或无结果时保持默认顺序，
  /// 避免列表随每批结果刷新而跳动。
  List<({String name, String prefix})> _sortedMirrors() {
    final List<({String name, String prefix})> all =
        List<({String name, String prefix})>.of(UpdateManager.defaultMirrors);
    for (final m in _settings.customMirrors) {
      all.add((name: m.name, prefix: _normalizeMirrorBaseUrl(m.baseUrl)));
    }
    if (_latencyResults.isEmpty || !_probeFinished) return all;
    final List<({String name, String prefix})> head = all.take(1).toList();
    final List<({String name, String prefix})> tail = all.skip(1).toList();
    tail.sort((a, b) {
      final int? la = _latencyResults[a.name];
      final int? lb = _latencyResults[b.name];
      if (la == null && lb == null) return 0;
      if (la == null) return 1; // 未测的排后
      if (lb == null) return -1;
      if (la < 0 && lb < 0) return a.name.compareTo(b.name);
      if (la < 0) return 1; // 不可达排最后（稳定）
      if (lb < 0) return -1;
      return la.compareTo(lb);
    });
    return <({String name, String prefix})>[...head, ...tail];
  }

  /// 测速完成后：按排序后的列表重映射当前选中镜像索引（仍保持选中同一镜像）。
  void _remapMirrorIndexAfterSort() {
    if (_latencyResults.isEmpty) return;
    final List<({String name, String prefix})> old =
        List<({String name, String prefix})>.of(UpdateManager.defaultMirrors);
    for (final m in _settings.customMirrors) {
      old.add((name: m.name, prefix: _normalizeMirrorBaseUrl(m.baseUrl)));
    }
    if (old.length <= _settings.mirrorIndex) return;
    final String selectedName = old[_settings.mirrorIndex].name;
    final List<({String name, String prefix})> sorted = _sortedMirrors();
    final int newIdx = sorted.indexWhere((m) => m.name == selectedName);
    if (newIdx >= 0 && newIdx != _settings.mirrorIndex) {
      _settings = _settings.copyWith(mirrorIndex: newIdx);
      unawaited(_manager.saveSettings(_settings));
    }
  }

  Future<void> _save(UpdateSettings s) async {
    AppHaptics.selectionClick();
    setState(() => _settings = s);
    await _manager.saveSettings(s);
  }

  void _addCustomMirror() {
    final TextEditingController nameCtrl = TextEditingController();
    final TextEditingController urlCtrl = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_l10n().updateAddMirror),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: nameCtrl,
              decoration: InputDecoration(
                labelText: _l10n().updateMirrorName,
              ),
            ),
            const SizedBox(height: AppTokens.spaceMd),
            TextField(
              controller: urlCtrl,
              decoration: InputDecoration(
                labelText: _l10n().updateMirrorUrl,
                hintText: 'https://ghproxy.com/',
              ),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(_l10n().cancel),
          ),
          FilledButton(
            onPressed: () {
              final String name = nameCtrl.text.trim();
              final String rawUrl = urlCtrl.text.trim();
              // 校验：仅接受合法的 http/https 地址（避免存入无法请求的坏 URL）。
              final Uri? uri = Uri.tryParse(rawUrl);
              final bool valid = name.isNotEmpty &&
                  uri != null &&
                  (uri.scheme == 'https' || uri.scheme == 'http') &&
                  uri.host.isNotEmpty;
              if (!valid) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(_l10n().updateMirrorUrlInvalid)),
                );
                return;
              }
              Navigator.pop(ctx);
              _save(_settings.copyWith(
                customMirrors: <UpdateMirror>[
                  ..._settings.customMirrors,
                  UpdateMirror(
                    name: name,
                    baseUrl: _normalizeMirrorBaseUrl(rawUrl),
                  ),
                ],
              ));
            },
            child: Text(_l10n().confirm),
          ),
        ],
      ),
    );
  }

  void _removeCustomMirror(int index) {
    AppHaptics.medium();
    final List<UpdateMirror> mirrors = List<UpdateMirror>.of(
      _settings.customMirrors,
    )..removeAt(index);
    final UpdateSettings next = _settings.copyWith(customMirrors: mirrors);
    setState(() => _settings = next);
    unawaited(_manager.saveSettings(next));
  }

  Future<void> _probeAllMirrors() async {
    setState(() {
      _latencyResults.clear();
    });
    final List<({String name, String prefix})> mirrors =
        List<({String name, String prefix})>.of(UpdateManager.defaultMirrors);
    for (final m in _settings.customMirrors) {
      mirrors.add((name: m.name, prefix: _normalizeMirrorBaseUrl(m.baseUrl)));
    }
    // 用真实下载文件（当前平台安装包）测速，而不是 release 页面：
    // 用户关心的是「安装包能不能加速下载」，发布页可达不代表文件可达。
    final String probeUrl = _manager.defaultProbeUrl();
    // 分批并发（每批 8 个）：一次性并发 40+ 请求易触发连接数/系统资源限制，
    // 导致本可用的镜像被误判为超时，分批后逐个收结果即时刷新 UI。
    const int batchSize = 8;
    for (int start = 0; start < mirrors.length; start += batchSize) {
      final int end = (start + batchSize).clamp(0, mirrors.length);
      final List<({String name, String prefix})> batch =
          mirrors.sublist(start, end);
      await Future.wait(<Future<void>>[
        for (final m in batch)
          _manager.probeMirror(m.prefix, testUrl: probeUrl).then((int ms) {
            if (mounted) {
              setState(() => _latencyResults[m.name] = ms);
            }
          }).catchError((_) {
            if (mounted) {
              setState(() => _latencyResults[m.name] = -1);
            }
          }),
      ]);
      if (!mounted) return;
    }
    if (!mounted) return;
    // 全部测速完成：社区镜像按实测延迟升序重排，并重映射当前选中镜像索引。
    _remapMirrorIndexAfterSort();
    if (!mounted) return;
    setState(() {});
    // 下载将回退 GitHub 官方直连。
    final bool anyReachable = _latencyResults.values.any((int v) => v >= 0);
    if (!anyReachable) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_l10n().updateMirrorAllUnreachable)),
      );
    }
  }

  /// 检查最新版本并进入更新对话框。
  Future<void> _checkForUpdate() async {
    AppHaptics.medium();
    final l10n = _l10n();
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

    final UpdateReleaseInfo? release = await _manager.checkForUpdate();
    if (!mounted) return;
    Navigator.of(context).pop(); // 关闭加载框

    if (release == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.updateCheckFailed)),
      );
      return;
    }

    final bool newer = _manager.isNewer(release.tagName, _currentVersion);
    if (!mounted) return;
    if (newer) {
      _updateDialogVisible = true;
      await showDialog<void>(
        context: context,
        builder: (ctx) => _UpdateDialog(
          release: release,
          currentVersion: _currentVersion,
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
    final l10n = _l10n();
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.updateSettings),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.maybePop(context),
        ),
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : SettingsAutoScroll(
              child: ListView(
                // 底部留出系统手势条/导航条空间，避免「检查更新」按钮被遮挡。
                padding: EdgeInsets.fromLTRB(
                  AppTokens.spaceLg,
                  AppTokens.spaceLg,
                  AppTokens.spaceLg,
                  MediaQuery.of(context).padding.bottom + AppTokens.spaceXl,
                ),
                children: <Widget>[
                  // ── 升级通道 ──
                  SettingsCard(
                    title: l10n.updateChannelSection,
                    children: <Widget>[
                      SegmentedButton<UpdateChannel>(
                        key: const ValueKey<String>('update.channel'),
                        selected: <UpdateChannel>{_settings.updateChannel},
                        onSelectionChanged: (Set<UpdateChannel> set) {
                          if (set.isEmpty) return;
                          _save(_settings.copyWith(updateChannel: set.first));
                        },
                        segments: <ButtonSegment<UpdateChannel>>[
                          ButtonSegment<UpdateChannel>(
                            value: UpdateChannel.stable,
                            label: Text(l10n.updateChannelStable),
                            icon: const Icon(Icons.shield_outlined),
                          ),
                          ButtonSegment<UpdateChannel>(
                            value: UpdateChannel.beta,
                            label: Text(l10n.updateChannelBeta),
                            icon: const Icon(Icons.science_outlined),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppTokens.spaceXs),
                      Text(
                        _settings.updateChannel == UpdateChannel.beta
                            ? l10n.updateChannelBetaDesc
                            : l10n.updateChannelStableDesc,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppTokens.spaceXs),

                  // ── 自动检查更新 ──
                  AppListTile(
                    key: const ValueKey<String>('update.autoCheck'),
                    leading: const SettingsLeadingIcon(
                      icon: Icons.notifications_active_outlined,
                    ),
                    title: Text(l10n.updateAutoCheck),
                    subtitle: Text(l10n.updateAutoCheckDesc),
                    trailing: Switch(
                      value: _settings.autoCheck,
                      onChanged: (v) => _save(_settings.copyWith(autoCheck: v)),
                    ),
                  ),

                  // ── 自动下载更新 ──
                  AppListTile(
                    key: const ValueKey<String>('update.autoDownload'),
                    leading: const SettingsLeadingIcon(
                      icon: Icons.download_for_offline_outlined,
                    ),
                    title: Text(l10n.updateAutoDownload),
                    subtitle: Text(l10n.updateAutoDownloadDesc),
                    trailing: Switch(
                      value: _settings.autoDownload,
                      onChanged: (v) =>
                          _save(_settings.copyWith(autoDownload: v)),
                    ),
                  ),
                  if (_settings.autoDownload)
                    AppListTile(
                      key: const ValueKey<String>('update.wifiOnly'),
                      leading: const SettingsLeadingIcon(
                        icon: Icons.wifi,
                      ),
                      title: Text(l10n.updateWifiOnlyAutoDownload),
                      subtitle: Text(l10n.updateWifiOnlyAutoDownloadDesc),
                      trailing: Switch(
                        value: _settings.wifiOnlyAutoDownload,
                        onChanged: (v) => _save(
                          _settings.copyWith(wifiOnlyAutoDownload: v),
                        ),
                      ),
                    ),

                  // ── 应用内下载 ──
                  AppListTile(
                    key: const ValueKey<String>('update.inAppDownload'),
                    leading: const SettingsLeadingIcon(
                      icon: Icons.storage_outlined,
                    ),
                    title: Text(l10n.updateInAppDownload),
                    subtitle: Text(l10n.updateInAppDownloadDesc),
                    trailing: Switch(
                      value: _settings.inAppDownload,
                      onChanged: (v) =>
                          _save(_settings.copyWith(inAppDownload: v)),
                    ),
                  ),

                  const SizedBox(height: AppTokens.spaceLg),

                  // ── 镜像设置 ──
                  Text(
                    l10n.updateMirrorSection,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  const SizedBox(height: AppTokens.spaceXs),
                  // 社区镜像致谢（折叠区也始终展示）。
                  Text(
                    l10n.updateMirrorCommunityThanks,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                  const SizedBox(height: AppTokens.spaceSm),
                  AppListTile(
                    key: const ValueKey<String>('update.mirrorAutoSwitch'),
                    leading: const Icon(Icons.bolt),
                    title: Text(l10n.updateAutoSwitchMirror),
                    subtitle: Text(l10n.updateAutoSwitchMirrorDesc),
                    trailing: Switch(
                      value: _settings.autoSwitchMirror,
                      onChanged: (v) =>
                          _save(_settings.copyWith(autoSwitchMirror: v)),
                    ),
                  ),
                  const SizedBox(height: AppTokens.spaceSm),
                  _buildMirrorTiles(l10n),
                  const SizedBox(height: AppTokens.spaceMd),
                  // 自定义镜像
                  Text(
                    l10n.updateCustomMirrors,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
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
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
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
                  const SizedBox(height: AppTokens.spaceMd),
                  OutlinedButton.icon(
                    onPressed: _probeAllMirrors,
                    icon: const Icon(Icons.speed),
                    label: Text(l10n.updateTestMirrors),
                  ),

                  const SizedBox(height: AppTokens.spaceXl),

                  // ── 检查更新 ──
                  FilledButton.icon(
                    key: const ValueKey<String>('update.check'),
                    onPressed: _checkForUpdate,
                    icon: const Icon(Icons.system_update_alt),
                    label: Text(l10n.checkUpdate),
                  ),
                  const SizedBox(height: AppTokens.spaceSm),
                  if (_currentVersion.isNotEmpty)
                    Center(
                      child: Text(
                        'v$_currentVersion',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                      ),
                    ),
                ],
              ),
            ),
    );
  }

  Widget _buildMirrorTiles(AppLocalizations l10n) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final ThemeData theme = Theme.of(context);
    final List<({String name, String prefix})> mirrors = _sortedMirrors();
    final int customStart = UpdateManager.defaultMirrors.length;

    final List<Widget> tiles = <Widget>[];
    for (int i = 0; i < mirrors.length; i++) {
      final int idx = i;
      final bool isCommunity = idx >= 1 && idx < customStart;
      // 折叠态下跳过折叠区的社区镜像（保留 GitHub 官方 + 前 4 个社区）。
      if (isCommunity && !_mirrorExpanded && idx > _visibleCommunityCount) {
        continue;
      }
      final String label = mirrors[i].name;
      final bool selected = _settings.mirrorIndex == idx;
      final int? latency = _latencyResults[label];
      tiles.add(
        RadioListTile<int>(
          key: idx == 0 ? const ValueKey<String>('update.mirror') : null,
          value: idx,
          title: Text(label),
          subtitle: latency != null
              ? Text(
                  latency < 0 ? l10n.updateMirrorTimeout : '${latency}ms',
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
          secondary: selected ? const Icon(Icons.check_circle) : null,
        ),
      );
      if (i < mirrors.length - 1) {
        tiles.add(const Divider(height: 1));
      }
    }

    final Widget group = RadioGroup<int>(
      groupValue: _settings.mirrorIndex,
      onChanged: (v) {
        if (v != null && v != _settings.mirrorIndex) {
          AppHaptics.selectionClick();
          _save(_settings.copyWith(mirrorIndex: v));
        }
      },
      child: Column(children: tiles),
    );

    // 折叠中的社区镜像数（>0 时显示「展开全部」，展开后显示「收起」）。
    final int hidden = _mirrorExpanded
        ? 0
        : (_communityCount - _visibleCommunityCount).clamp(0, _communityCount);
    if (hidden <= 0 && !_mirrorExpanded) return group;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        group,
        const SizedBox(height: AppTokens.spaceXs),
        TextButton.icon(
          key: const ValueKey<String>('update.mirrorToggle'),
          onPressed: () {
            AppHaptics.selectionClick();
            setState(() => _mirrorExpanded = !_mirrorExpanded);
          },
          icon: Icon(
            _mirrorExpanded ? Icons.expand_less : Icons.expand_more,
            size: 20,
          ),
          label: Text(
            _mirrorExpanded
                ? l10n.updateMirrorCollapse
                : l10n.updateMirrorShowAll(hidden),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.primary,
            ),
          ),
        ),
      ],
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
    AppHaptics.medium();
    setState(() => _downloading = true);
    final String? path = await _manager.downloadInstaller(
      widget.release,
      silent: _silent,
    );
    if (!mounted) return;
    if (path != null) {
      setState(() {
        _downloading = false;
        _downloaded = true;
      });
    } else {
      setState(() => _downloading = false);
      final String? err = _manager.lastError;
      if (err == 'opened-in-browser') {
        // 应用内下载关闭：已打开浏览器，关闭对话框并提示。
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(AppLocalizations.of(context).updateOpenedBrowser)),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(err ?? 'Download failed')),
        );
      }
    }
  }

  Future<void> _install() async {
    AppHaptics.medium();
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
              if (_downloading) ...<Widget>[
                LinearProgressIndicator(value: _progress),
                const SizedBox(height: AppTokens.spaceXs),
                Text(
                  '$percent%',
                  style: textTheme.bodySmall?.copyWith(color: scheme.primary),
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
                onChanged: (v) {
                  AppHaptics.selectionClick();
                  setState(() => _silent = v);
                },
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
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

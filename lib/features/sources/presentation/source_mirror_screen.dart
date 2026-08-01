library;

import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';

import '../../../core/models/plugin_config.dart';
import '../../../core/navigation/app_page_route.dart';
import '../../../core/scraper/http_fetcher.dart';
import '../../../core/scraper/publish_page_mirror_extractor.dart';
import '../../../core/services/config_loader.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_alert_dialog.dart';
import '../../../core/widgets/app_empty_state.dart';
import '../../../core/widgets/app_form_field.dart';
import '../../../core/widgets/app_icon_button.dart';
import '../../../core/widgets/app_list_tile.dart';
import 'source_login_screen.dart';

/// 镜像管理页：列出源的可用镜像，支持测速与切换。
///
/// 合并展示两类镜像：
/// - 声明镜像（[SiteConfig.mirrors]，不可删除）
/// - 自定义镜像（[ConfigLoader.getCustomMirrors]，可删除，带「自定义」标记）
///
/// 支持手动添加自定义镜像、以及从发布页（[SiteConfig.publishPageUrl]）提取镜像。
class SourceMirrorScreen extends StatefulWidget {
  final PluginConfig source;
  const SourceMirrorScreen({super.key, required this.source});

  @override
  State<SourceMirrorScreen> createState() => _SourceMirrorScreenState();
}

class _SourceMirrorScreenState extends State<SourceMirrorScreen> {
  late String _activeBaseUrl;
  final Map<String, int> _speeds = <String, int>{};
  final Set<String> _testing = <String>{};
  final Set<String> _failed = <String>{};

  @override
  void initState() {
    super.initState();
    _activeBaseUrl = ConfigLoader.instance.getActiveMirror(widget.source);
  }

  Future<void> _testSpeed(String baseUrl) async {
    if (_testing.contains(baseUrl)) return;
    setState(() {
      _testing.add(baseUrl);
      _failed.remove(baseUrl);
    });
    final stopwatch = Stopwatch()..start();
    try {
      await HttpFetcher.instance.getHtml(baseUrl);
      if (mounted) setState(() => _speeds[baseUrl] = stopwatch.elapsedMilliseconds);
    } catch (_) {
      if (mounted) setState(() => _failed.add(baseUrl));
    } finally {
      stopwatch.stop();
      if (mounted) setState(() => _testing.remove(baseUrl));
    }
  }

  void _select(String baseUrl) {
    ConfigLoader.instance.setActiveMirror(widget.source.id, baseUrl);
    setState(() => _activeBaseUrl = baseUrl);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context).mirrorSwitched)),
    );
  }

  Future<void> _showAddCustomMirrorDialog() async {
    final l10n = AppLocalizations.of(context);
    final nameCtl = TextEditingController();
    final domainCtl = TextEditingController();
    final baseUrlCtl = TextEditingController();

    final added = await showDialog<bool>(
      context: context,
      builder: (ctx) => AppAlertDialog(
        title: Text(l10n.mirrorAddCustom),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              AppFormField(
                label: l10n.mirrorName,
                controller: nameCtl,
                hint: 'mirror1.example.com',
              ),
              const SizedBox(height: AppTokens.spaceMd),
              AppFormField(
                label: l10n.mirrorDomain,
                controller: domainCtl,
                hint: 'mirror1.example.com',
              ),
              const SizedBox(height: AppTokens.spaceMd),
              AppFormField(
                label: l10n.mirrorBaseUrl,
                controller: baseUrlCtl,
                hint: 'https://mirror1.example.com',
                keyboardType: TextInputType.url,
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.confirm),
          ),
        ],
      ),
    );

    nameCtl.dispose();
    domainCtl.dispose();
    final baseUrlValue = baseUrlCtl.text.trim();
    baseUrlCtl.dispose();

    if (added != true) return;
    if (!mounted) return;

    if (!baseUrlValue.startsWith('http://') &&
        !baseUrlValue.startsWith('https://')) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.mirrorAddInvalid)),
      );
      return;
    }

    // 域名/名称缺省时从 baseUrl 自动推导，避免强制用户填全三栏。
    final uri = Uri.tryParse(baseUrlValue);
    final host = uri?.host ?? '';
    final domain = domainCtl.text.trim().isEmpty ? host : domainCtl.text.trim();
    final name = nameCtl.text.trim().isEmpty ? host : nameCtl.text.trim();

    await ConfigLoader.instance.addCustomMirror(
      widget.source.id,
      MirrorConfig(
        name: name,
        domain: domain,
        baseUrl: baseUrlValue,
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _deleteCustomMirror(String baseUrl) async {
    await ConfigLoader.instance.removeCustomMirror(widget.source.id, baseUrl);
    if (mounted) setState(() {});
  }

  Future<void> _extractFromPublish() async {
    final l10n = AppLocalizations.of(context);
    final publishPageUrl = widget.source.site.publishPageUrl;
    if (publishPageUrl == null || publishPageUrl.trim().isEmpty) return;

    // 展示加载态。
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AppAlertDialog(
        content: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const CircularProgressIndicator(),
            const SizedBox(width: AppTokens.spaceMd),
            Text(l10n.mirrorExtracting),
          ],
        ),
      ),
    );

    List<MirrorConfig> candidates;
    try {
      candidates = await PublishPageMirrorExtractor().extract(
        publishPageUrl,
        selector: widget.source.site.publishMirrorSelector,
      );
    } catch (_) {
      candidates = const <MirrorConfig>[];
    }

    if (!mounted) return;
    Navigator.of(context).pop(); // 关闭加载态

    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.mirrorNoMirrorsExtracted)),
      );
      return;
    }

    // 去重：剔除已存在的声明镜像与自定义镜像（按 baseUrl）。
    final existing = <String>{};
    existing.addAll(widget.source.site.mirrors.map((m) => m.baseUrl));
    existing.addAll(
        ConfigLoader.instance.getCustomMirrors(widget.source.id).map((m) => m.baseUrl));
    final selectable =
        candidates.where((m) => !existing.contains(m.baseUrl)).toList();
    if (selectable.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.mirrorNoMirrorsExtracted)),
      );
      return;
    }

    await _showExtractMultiSelect(selectable);
  }

  Future<void> _showExtractMultiSelect(List<MirrorConfig> candidates) async {
    final l10n = AppLocalizations.of(context);
    final selected = <String>{
      ...candidates.map((m) => m.baseUrl),
    };

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AppAlertDialog(
          title: Text(l10n.mirrorExtractFromPublish),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: candidates.length,
              itemBuilder: (ctx, i) {
                final m = candidates[i];
                final checked = selected.contains(m.baseUrl);
                return CheckboxListTile(
                  value: checked,
                  title: Text(m.name),
                  subtitle: Text(m.baseUrl),
                  onChanged: (v) {
                    setDialogState(() {
                      if (v == true) {
                        selected.add(m.baseUrl);
                      } else {
                        selected.remove(m.baseUrl);
                      }
                    });
                  },
                );
              },
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: selected.isEmpty
                  ? null
                  : () => Navigator.of(ctx).pop(true),
              child: Text(l10n.mirrorImportSelected),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true) return;
    if (!mounted) return;

    for (final m in candidates) {
      if (selected.contains(m.baseUrl)) {
        await ConfigLoader.instance.addCustomMirror(widget.source.id, m);
      }
    }
    if (mounted) setState(() {});
  }

  Widget _buildTile(MirrorConfig m, {required bool isCustom}) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final speed = _speeds[m.baseUrl];
    final testing = _testing.contains(m.baseUrl);
    final failed = _failed.contains(m.baseUrl);
    return AppListTile(
      leading: CircleAvatar(
        backgroundColor: scheme.primaryContainer,
        child: Text(
          m.name.isNotEmpty ? m.name[0].toUpperCase() : '?',
          style: TextStyle(color: scheme.onPrimaryContainer),
        ),
      ),
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Flexible(child: Text(m.name)),
          if (isCustom) ...<Widget>[
            const SizedBox(width: AppTokens.spaceSm),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppTokens.spaceXs + 2,
                vertical: AppTokens.spaceXs,
              ),
              decoration: BoxDecoration(
                color: scheme.tertiaryContainer,
                borderRadius: BorderRadius.circular(AppTokens.radiusSm),
              ),
              child: Text(
                l10n.mirrorCustom,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.onTertiaryContainer,
                    ),
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(
        m.domain,
        style: TextStyle(color: scheme.onSurfaceVariant),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (testing)
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: scheme.primary,
              ),
            )
          else if (failed)
            Icon(Icons.error_outline, color: scheme.error, size: 16)
          else if (speed != null)
            Text(
              l10n.mirrorTestResultMs(speed),
              style: Theme.of(context).textTheme.bodySmall,
            )
          else
            const SizedBox.shrink(),
          AppIconButton(
            icon: Icons.speed,
            tooltip: l10n.mirrorTest,
            onPressed: () => _testSpeed(m.baseUrl),
          ),
          if (isCustom)
            AppIconButton(
              icon: Icons.delete_outline,
              tooltip: l10n.mirrorDelete,
              onPressed: () => _deleteCustomMirror(m.baseUrl),
            ),
          Radio<String>(
            value: m.baseUrl,
            groupValue: _activeBaseUrl,
            onChanged: (_) => _select(m.baseUrl),
          ),
        ],
      ),
      onTap: () => _select(m.baseUrl),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final declared = widget.source.site.mirrors;
    final custom = ConfigLoader.instance.getCustomMirrors(widget.source.id);
    final hasPublishPage =
        widget.source.site.publishPageUrl?.trim().isNotEmpty ?? false;

    final entries = <Widget>[
      ...declared.map((m) => _buildTile(m, isCustom: false)),
      if (declared.isNotEmpty && custom.isNotEmpty)
        const Divider(height: 1),
      ...custom.map((m) => _buildTile(m, isCustom: true)),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.source.name),
        actions: <Widget>[
          if (widget.source.comments?.supportsLogin == true)
            AppIconButton(
              icon: Icons.login_outlined,
              tooltip: l10n.sourceLogin,
              onPressed: () => Navigator.of(context).push(
                AppPageRoute<void>(
                  builder: (_) => SourceLoginScreen(source: widget.source),
                ),
              ),
            ),
          if (hasPublishPage)
            AppIconButton(
              icon: Icons.cloud_download_outlined,
              tooltip: l10n.mirrorExtractFromPublish,
              onPressed: _extractFromPublish,
            ),
          AppIconButton(
            icon: Icons.add,
            tooltip: l10n.mirrorAddCustom,
            onPressed: _showAddCustomMirrorDialog,
          ),
        ],
      ),
      body: entries.isEmpty
          ? AppEmptyState(icon: Icons.dns, message: l10n.mirrorNoMirrors)
          : ListView(
              padding: const EdgeInsets.all(AppTokens.spaceLg),
              children: <Widget>[
                ...entries,
                const SizedBox(height: AppTokens.spaceLg),
                Container(
                  padding: const EdgeInsets.all(AppTokens.spaceMd),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(AppTokens.radiusMd),
                  ),
                  child: Row(
                    children: <Widget>[
                      Icon(Icons.lock,
                          size: 16, color: scheme.onSurfaceVariant),
                      const SizedBox(width: AppTokens.spaceSm),
                      Expanded(
                        child: Text(
                          l10n.mirrorStealthLocked,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

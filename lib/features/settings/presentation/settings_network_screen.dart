/// 全局网络配置页：代理 / DNS / DoH / DoT / SNI / ECH / Hosts 七模块。
///
/// 表单风格对齐 [SettingsCloudSyncScreen]（OutlineInputBorder + prefixIcon +
/// FilledButton.icon + 转圈态 + SnackBar）；复用 [settings_widgets.dart] 的
/// SettingsCard / SettingsSwitchTile / SettingsSegmentedTile。
///
/// 生效边界（UI 显式告知）：全局配置经 HttpOverrides 覆盖所有 dart:io
/// HttpClient 派生流量；ECH 与自定义 SNI 值受 Dart TLS 栈限制，标注「实验性」。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/network/model/network_config.dart';
import '../../../core/network/model/network_validators.dart';
import '../../../core/network/network_config_service.dart';
import '../../../core/network/runtime/dns_resolver.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_alert_dialog.dart';
import 'widgets/settings_widgets.dart';

/// DoH 预设端点。
const Map<String, String> _dohPresets = <String, String>{
  'Cloudflare': 'https://cloudflare-dns.com/dns-query',
  'Google': 'https://dns.google/dns-query',
  'Quad9': 'https://dns.quad9.net/dns-query',
};

class SettingsNetworkScreen extends StatefulWidget {
  const SettingsNetworkScreen({super.key});

  @override
  State<SettingsNetworkScreen> createState() => _SettingsNetworkScreenState();
}

class _SettingsNetworkScreenState extends State<SettingsNetworkScreen> {
  // 工作副本：编辑期不直接改服务层，保存时统一提交。
  late NetworkConfig _draft;

  final _proxyHostCtrl = TextEditingController();
  final _proxyPortCtrl = TextEditingController();
  final _proxyUserCtrl = TextEditingController();
  final _proxyPassCtrl = TextEditingController();
  final _dohUrlCtrl = TextEditingController();
  final _dotHostCtrl = TextEditingController();
  final _dotPortCtrl = TextEditingController();
  final _sniDefaultCtrl = TextEditingController();
  final _echCtrl = TextEditingController();
  final _dnsTestHostCtrl = TextEditingController(text: 'www.google.com');

  bool _testingProxy = false;
  bool _testingDns = false;
  bool _testingDoh = false;
  bool _saving = false;
  bool _passwordDirty = false;

  @override
  void initState() {
    super.initState();
    final service = NetworkConfigService.instance;
    _draft = service.config;
    _proxyHostCtrl.text = _draft.proxy.host;
    _proxyPortCtrl.text = _draft.proxy.port > 0 ? '${_draft.proxy.port}' : '';
    _proxyUserCtrl.text = _draft.proxy.username;
    _dohUrlCtrl.text = _draft.dns.dohUrl;
    _dotHostCtrl.text = _draft.dns.dotHost;
    _dotPortCtrl.text = '${_draft.dns.dotPort}';
    _sniDefaultCtrl.text = _draft.sni.defaultSni ?? '';
    _echCtrl.text = _draft.ech.echConfigList;
  }

  @override
  void dispose() {
    _proxyHostCtrl.dispose();
    _proxyPortCtrl.dispose();
    _proxyUserCtrl.dispose();
    _proxyPassCtrl.dispose();
    _dohUrlCtrl.dispose();
    _dotHostCtrl.dispose();
    _dotPortCtrl.dispose();
    _sniDefaultCtrl.dispose();
    _echCtrl.dispose();
    _dnsTestHostCtrl.dispose();
    super.dispose();
  }

  /// 延迟档位色。仅用于 SnackBar（反色表面），故取 onInverseSurface 档。
  Color _latencyColor(ColorScheme scheme, int ms) {
    if (ms < 300) return AppStatusColors.ok(scheme, onInverseSurface: true);
    if (ms < 800) return AppStatusColors.warn(scheme, onInverseSurface: true);
    return AppStatusColors.fail(scheme, onInverseSurface: true);
  }

  /// 把校验器返回的 key 映射为本地化文案。
  String _errText(AppLocalizations l10n, String key) => switch (key) {
        'networkErrorInvalidHost' => l10n.networkErrorInvalidHost,
        'networkErrorInvalidPort' => l10n.networkErrorInvalidPort,
        'networkErrorInvalidIp' => l10n.networkErrorInvalidIp,
        'networkErrorInvalidDomain' => l10n.networkErrorInvalidDomain,
        'networkErrorInvalidDohUrl' => l10n.networkErrorInvalidDohUrl,
        _ => key,
      };

  /// 从控件与工作副本组装最终配置。
  NetworkConfig _collect() {
    return _draft.copyWith(
      proxy: _draft.proxy.copyWith(
        host: _proxyHostCtrl.text.trim(),
        port: int.tryParse(_proxyPortCtrl.text.trim()) ?? 0,
        username: _proxyUserCtrl.text.trim(),
      ),
      dns: _draft.dns.copyWith(
        dohUrl: _dohUrlCtrl.text.trim(),
        dotHost: _dotHostCtrl.text.trim(),
        dotPort: int.tryParse(_dotPortCtrl.text.trim()) ?? 853,
      ),
      sni: _draft.sni.copyWith(
        defaultSni: _sniDefaultCtrl.text.trim().isEmpty
            ? null
            : _sniDefaultCtrl.text.trim(),
      ),
      ech: _draft.ech.copyWith(echConfigList: _echCtrl.text.trim()),
    );
  }

  /// 保存前统一校验：返回第一个错误文案，null 表示通过。
  String? _validate(AppLocalizations l10n, NetworkConfig cfg) {
    final proxyErr = NetworkValidators.validateProxy(
      mode: cfg.proxy.mode.name,
      host: cfg.proxy.host,
      portText: '${cfg.proxy.port}',
    );
    if (proxyErr.isNotEmpty) return _errText(l10n, proxyErr.first);
    if (cfg.dns.mode == DnsMode.doh) {
      final e = NetworkValidators.validateDohUrl(cfg.dns.dohUrl);
      if (e.isNotEmpty) return _errText(l10n, e.first);
    }
    if (cfg.dns.mode == DnsMode.dot) {
      final e = NetworkValidators.validateDot(
        host: cfg.dns.dotHost,
        portText: '${cfg.dns.dotPort}',
      );
      if (e.isNotEmpty) return _errText(l10n, e.first);
    }
    return null;
  }

  Future<void> _save(AppLocalizations l10n) async {
    final cfg = _collect();
    final err = _validate(l10n, cfg);
    if (err != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    setState(() => _saving = true);
    await NetworkConfigService.instance.update(
      cfg,
      password: _passwordDirty ? _proxyPassCtrl.text : null,
    );
    if (!mounted) return;
    setState(() {
      _saving = false;
      _draft = cfg;
      _passwordDirty = false;
    });
    _proxyPassCtrl.clear();
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(l10n.networkSaved)));
  }

  Future<void> _reset(AppLocalizations l10n) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AppAlertDialog(
        title: Text(l10n.networkResetTitle),
        content: Text(l10n.networkResetConfirm),
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
    if (ok != true) return;
    await NetworkConfigService.instance.resetToDefaults();
    if (!mounted) return;
    setState(() {
      _draft = NetworkConfig.defaults;
      _proxyHostCtrl.text = '';
      _proxyPortCtrl.text = '';
      _proxyUserCtrl.text = '';
      _proxyPassCtrl.clear();
      _passwordDirty = false;
      _dohUrlCtrl.text = '';
      _dotHostCtrl.text = '';
      _dotPortCtrl.text = '853';
      _sniDefaultCtrl.text = '';
      _echCtrl.text = '';
    });
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(l10n.networkResetDone)));
  }

  Future<void> _testProxy(AppLocalizations l10n) async {
    setState(() => _testingProxy = true);
    final cfg = _collect();
    final (ok, ms) = await NetworkConfigService.instance.testProxy(
      cfg,
      password: _passwordDirty ? _proxyPassCtrl.text : null,
    );
    if (!mounted) return;
    setState(() => _testingProxy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok ? l10n.networkTestSuccess(ms) : l10n.networkTestFailed,
          style: ok
              ? TextStyle(
                  color: _latencyColor(Theme.of(context).colorScheme, ms))
              : null,
        ),
      ),
    );
  }

  Future<void> _testDns(AppLocalizations l10n) async {
    final host = _dnsTestHostCtrl.text.trim();
    if (host.isEmpty) return;
    setState(() => _testingDns = true);
    final cfg = _collect();
    final (ips, ms) = await NetworkConfigService.instance
        .testDns(host, cfg.dns, cfg.hosts);
    if (!mounted) return;
    setState(() => _testingDns = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ips.isEmpty
              ? l10n.networkTestFailed
              : l10n.networkDnsTestResult(ips.join(', '), ms),
          style: ips.isEmpty
              ? null
              : TextStyle(
                  color: _latencyColor(Theme.of(context).colorScheme, ms)),
        ),
      ),
    );
  }

  Future<void> _testDoh(AppLocalizations l10n) async {
    final url = _dohUrlCtrl.text.trim();
    if (NetworkValidators.validateDohUrl(url).isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.networkErrorInvalidDohUrl)),
      );
      return;
    }
    setState(() => _testingDoh = true);
    final (ok, ms) = await NetworkConfigService.instance.testDoh(url);
    if (!mounted) return;
    setState(() => _testingDoh = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok ? l10n.networkTestSuccess(ms) : l10n.networkTestFailed,
          style: ok
              ? TextStyle(
                  color: _latencyColor(Theme.of(context).colorScheme, ms))
              : null,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.networkSettingsTitle)),
      body: ListView(
        padding: const EdgeInsets.all(AppTokens.spaceLg),
        children: <Widget>[
          _buildInfoCard(l10n),
          _buildProxyCard(l10n),
          _buildDnsCard(l10n),
          if (_draft.dns.mode == DnsMode.doh) _buildDohCard(l10n),
          if (_draft.dns.mode == DnsMode.dot) _buildDotCard(l10n),
          _buildHostsCard(l10n),
          _buildSniCard(l10n),
          _buildEchCard(l10n),
          const SizedBox(height: AppTokens.spaceMd),
          FilledButton.icon(
            onPressed: _saving ? null : () => _save(l10n),
            icon: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save),
            label: Text(l10n.save),
          ),
          const SizedBox(height: AppTokens.spaceMd),
          OutlinedButton.icon(
            onPressed: () => _reset(l10n),
            icon: const Icon(Icons.restore),
            label: Text(l10n.networkReset),
          ),
          const SizedBox(height: AppTokens.spaceXl),
        ],
      ),
    );
  }

  Widget _buildInfoCard(AppLocalizations l10n) {
    final theme = Theme.of(context);
    return SettingsCard(
      title: l10n.networkInfoTitle,
      children: <Widget>[
        Text(
          l10n.networkInfoBody,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => launchUrl(
              Uri.parse('https://nexhub-app.github.io/website/docs.html'),
              mode: LaunchMode.externalApplication,
            ),
            icon: const Icon(Icons.help_outline, size: 18),
            label: Text(l10n.networkHelpDoc),
          ),
        ),
      ],
    );
  }

  Widget _buildProxyCard(AppLocalizations l10n) {
    return SettingsCard(
      title: l10n.networkProxyTitle,
      children: <Widget>[
        SegmentedButton<ProxyMode>(
          selected: <ProxyMode>{_draft.proxy.mode},
          onSelectionChanged: (s) => setState(() {
            _draft = _draft.copyWith(
                proxy: _draft.proxy.copyWith(mode: s.first));
          }),
          segments: <ButtonSegment<ProxyMode>>[
            ButtonSegment(
                value: ProxyMode.direct,
                label: Text(l10n.networkProxyModeDirect)),
            ButtonSegment(
                value: ProxyMode.system,
                label: Text(l10n.networkProxyModeSystem)),
            ButtonSegment(
                value: ProxyMode.manual,
                label: Text(l10n.networkProxyModeManual)),
          ],
        ),
        if (_draft.proxy.mode == ProxyMode.manual) ...<Widget>[
          SegmentedButton<ProxyProtocol>(
            selected: <ProxyProtocol>{_draft.proxy.protocol},
            onSelectionChanged: (s) => setState(() {
              _draft = _draft.copyWith(
                  proxy: _draft.proxy.copyWith(protocol: s.first));
            }),
            segments: <ButtonSegment<ProxyProtocol>>[
              ButtonSegment(
                  value: ProxyProtocol.http,
                  label: Text(l10n.networkProxyProtocolHttp)),
              ButtonSegment(
                  value: ProxyProtocol.socks5,
                  label: Text(l10n.networkProxyProtocolSocks5)),
            ],
          ),
          _field(_proxyHostCtrl, l10n.networkProxyHost, Icons.dns_outlined),
          _field(_proxyPortCtrl, l10n.networkProxyPort, Icons.numbers,
              number: true),
          _field(_proxyUserCtrl, l10n.networkProxyUsername,
              Icons.person_outline),
          _field(_proxyPassCtrl, l10n.networkProxyPassword, Icons.lock_outline,
              obscure: true, onChanged: (_) => _passwordDirty = true),
          _testButton(l10n.networkTestProxy, _testingProxy,
              () => _testProxy(l10n)),
        ],
      ],
    );
  }

  Widget _buildDnsCard(AppLocalizations l10n) {
    return SettingsCard(
      title: l10n.networkDnsTitle,
      children: <Widget>[
        SegmentedButton<DnsMode>(
          selected: <DnsMode>{_draft.dns.mode},
          onSelectionChanged: (s) => setState(() {
            _draft = _draft.copyWith(dns: _draft.dns.copyWith(mode: s.first));
          }),
          segments: <ButtonSegment<DnsMode>>[
            ButtonSegment(
                value: DnsMode.system,
                label: Text(l10n.networkDnsModeSystem)),
            ButtonSegment(
                value: DnsMode.custom,
                label: Text(l10n.networkDnsModeCustom)),
            ButtonSegment(
                value: DnsMode.doh, label: Text(l10n.networkDnsModeDoh)),
            ButtonSegment(
                value: DnsMode.dot, label: Text(l10n.networkDnsModeDot)),
          ],
        ),
        if (_draft.dns.mode == DnsMode.custom)
          _stringListEditor(
            l10n,
            title: l10n.networkDnsServers,
            emptyHint: l10n.networkDnsServersEmpty,
            values: _draft.dns.servers,
            addLabel: l10n.networkAddServer,
            inputLabel: l10n.networkProxyHost,
            validate: (v) => NetworkValidators.validateDnsServer(v),
            onChanged: (list) => setState(() {
              _draft = _draft.copyWith(dns: _draft.dns.copyWith(servers: list));
            }),
          ),
        SettingsSwitchTile(
          title: l10n.networkDnsCacheEnabled,
          subtitle: l10n.networkDnsCacheStatus(DnsResolver.instance.cacheSize),
          value: _draft.dns.cacheEnabled,
          onChanged: (v) => setState(() {
            _draft =
                _draft.copyWith(dns: _draft.dns.copyWith(cacheEnabled: v));
          }),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: () {
              DnsResolver.instance.clearCache();
              setState(() {});
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(l10n.networkCacheCleared)),
              );
            },
            icon: const Icon(Icons.cleaning_services_outlined, size: 18),
            label: Text(l10n.networkClearCache),
          ),
        ),
        _field(_dnsTestHostCtrl, l10n.networkDnsTestHost, Icons.travel_explore),
        _testButton(l10n.networkTestDns, _testingDns, () => _testDns(l10n)),
      ],
    );
  }

  Widget _buildDohCard(AppLocalizations l10n) {
    final presetKey = _dohPresets.entries
        .firstWhere((e) => e.value == _dohUrlCtrl.text.trim(),
            orElse: () => const MapEntry('', ''))
        .key;
    return SettingsCard(
      title: l10n.networkDohTitle,
      children: <Widget>[
        DropdownButtonFormField<String>(
          value: presetKey.isEmpty ? null : presetKey,
          decoration: InputDecoration(
            labelText: l10n.networkDohPreset,
            border: const OutlineInputBorder(),
            prefixIcon: const Icon(Icons.public),
          ),
          items: <DropdownMenuItem<String>>[
            for (final e in _dohPresets.entries)
              DropdownMenuItem(value: e.key, child: Text(e.key)),
          ],
          onChanged: (key) {
            if (key == null) return;
            setState(() => _dohUrlCtrl.text = _dohPresets[key] ?? '');
          },
        ),
        _field(_dohUrlCtrl, l10n.networkDohUrl, Icons.link),
        _testButton(l10n.networkTestDoh, _testingDoh, () => _testDoh(l10n)),
      ],
    );
  }

  Widget _buildDotCard(AppLocalizations l10n) {
    return SettingsCard(
      title: l10n.networkDotTitle,
      children: <Widget>[
        _field(_dotHostCtrl, l10n.networkDotHost, Icons.dns_outlined),
        _field(_dotPortCtrl, l10n.networkDotPort, Icons.numbers, number: true),
        _testButton(l10n.networkTestDns, _testingDns, () => _testDns(l10n)),
      ],
    );
  }

  Widget _buildHostsCard(AppLocalizations l10n) {
    return SettingsCard(
      title: l10n.networkHostsTitle,
      children: <Widget>[
        if (_draft.hosts.isEmpty)
          Text(l10n.networkHostsEmpty,
              style: Theme.of(context).textTheme.bodySmall)
        else
          for (var i = 0; i < _draft.hosts.length; i++)
            _hostRow(l10n, i, _draft.hosts[i]),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: () => _addHost(l10n),
            icon: const Icon(Icons.add, size: 18),
            label: Text(l10n.networkAddHost),
          ),
        ),
      ],
    );
  }

  Widget _hostRow(AppLocalizations l10n, int index, HostsEntry entry) {
    return Row(
      children: <Widget>[
        Checkbox(
          value: entry.enabled,
          onChanged: (v) => setState(() {
            final list = List<HostsEntry>.of(_draft.hosts);
            list[index] = entry.copyWith(enabled: v ?? true);
            _draft = _draft.copyWith(hosts: list);
          }),
        ),
        Expanded(child: Text('${entry.ip}  →  ${entry.host}')),
        IconButton(
          icon: const Icon(Icons.delete_outline),
          onPressed: () => setState(() {
            final list = List<HostsEntry>.of(_draft.hosts)..removeAt(index);
            _draft = _draft.copyWith(hosts: list);
          }),
        ),
      ],
    );
  }

  Future<void> _addHost(AppLocalizations l10n) async {
    final ipCtrl = TextEditingController();
    final hostCtrl = TextEditingController();
    final entry = await showDialog<HostsEntry>(
      context: context,
      builder: (ctx) => AppAlertDialog(
        title: Text(l10n.networkAddHost),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: ipCtrl,
              decoration: InputDecoration(
                labelText: l10n.networkHostsIp,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppTokens.spaceMd),
            TextField(
              controller: hostCtrl,
              decoration: InputDecoration(
                labelText: l10n.networkHostsHost,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () {
              final errs = NetworkValidators.validateHostsEntry(
                ip: ipCtrl.text.trim(),
                host: hostCtrl.text.trim(),
              );
              if (errs.isNotEmpty) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  SnackBar(content: Text(_errText(l10n, errs.first))),
                );
                return;
              }
              Navigator.of(ctx).pop(HostsEntry(
                ip: ipCtrl.text.trim(),
                host: hostCtrl.text.trim(),
              ));
            },
            child: Text(l10n.add),
          ),
        ],
      ),
    );
    ipCtrl.dispose();
    hostCtrl.dispose();
    if (entry != null) {
      setState(() {
        _draft = _draft.copyWith(hosts: <HostsEntry>[..._draft.hosts, entry]);
      });
    }
  }

  Widget _buildSniCard(AppLocalizations l10n) {
    final theme = Theme.of(context);
    return SettingsCard(
      title: l10n.networkSniTitle,
      children: <Widget>[
        Text(l10n.networkExperimentalNote,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.error)),
        SettingsSwitchTile(
          title: l10n.networkSniEnabled,
          value: _draft.sni.enabled,
          onChanged: (v) => setState(() {
            _draft = _draft.copyWith(sni: _draft.sni.copyWith(enabled: v));
          }),
        ),
        if (_draft.sni.enabled)
          _field(_sniDefaultCtrl, l10n.networkSniDefault, Icons.vpn_lock),
      ],
    );
  }

  Widget _buildEchCard(AppLocalizations l10n) {
    final theme = Theme.of(context);
    return SettingsCard(
      title: l10n.networkEchTitle,
      children: <Widget>[
        Text(l10n.networkExperimentalNote,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.error)),
        SettingsSwitchTile(
          title: l10n.networkEchEnabled,
          value: _draft.ech.enabled,
          onChanged: (v) => setState(() {
            _draft = _draft.copyWith(ech: _draft.ech.copyWith(enabled: v));
          }),
        ),
        if (_draft.ech.enabled)
          _field(_echCtrl, l10n.networkEchConfigList, Icons.enhanced_encryption),
      ],
    );
  }

  // ---- 通用小组件 ----

  Widget _field(
    TextEditingController ctrl,
    String label,
    IconData icon, {
    bool obscure = false,
    bool number = false,
    ValueChanged<String>? onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: AppTokens.spaceSm),
      child: TextField(
        controller: ctrl,
        obscureText: obscure,
        onChanged: onChanged,
        keyboardType:
            number ? TextInputType.number : TextInputType.text,
        inputFormatters:
            number ? <TextInputFormatter>[FilteringTextInputFormatter.digitsOnly] : null,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          prefixIcon: Icon(icon),
          isDense: true,
        ),
      ),
    );
  }

  Widget _testButton(String label, bool busy, VoidCallback onPressed) {
    return Align(
      alignment: Alignment.centerLeft,
      child: OutlinedButton.icon(
        onPressed: busy ? null : onPressed,
        icon: busy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.network_check, size: 18),
        label: Text(label),
      ),
    );
  }

  Widget _stringListEditor(
    AppLocalizations l10n, {
    required String title,
    required String emptyHint,
    required List<String> values,
    required String addLabel,
    required String inputLabel,
    required List<String> Function(String) validate,
    required ValueChanged<List<String>> onChanged,
  }) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(title,
            style: theme.textTheme.bodyMedium
                ?.copyWith(fontWeight: FontWeight.w600)),
        if (values.isEmpty)
          Text(emptyHint, style: theme.textTheme.bodySmall)
        else
          for (var i = 0; i < values.length; i++)
            Row(
              children: <Widget>[
                Expanded(child: Text(values[i])),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () =>
                      onChanged(List<String>.of(values)..removeAt(i)),
                ),
              ],
            ),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: () async {
              final ctrl = TextEditingController();
              final added = await showDialog<String>(
                context: context,
                builder: (ctx) => AppAlertDialog(
                  title: Text(addLabel),
                  content: TextField(
                    controller: ctrl,
                    decoration: InputDecoration(
                      labelText: inputLabel,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  actions: <Widget>[
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: Text(l10n.cancel),
                    ),
                    FilledButton(
                      onPressed: () {
                        final errs = validate(ctrl.text.trim());
                        if (errs.isNotEmpty) {
                          ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                              content: Text(_errText(l10n, errs.first))));
                          return;
                        }
                        Navigator.of(ctx).pop(ctrl.text.trim());
                      },
                      child: Text(l10n.add),
                    ),
                  ],
                ),
              );
              ctrl.dispose();
              if (added != null && added.isNotEmpty) {
                onChanged(<String>[...values, added]);
              }
            },
            icon: const Icon(Icons.add, size: 18),
            label: Text(addLabel),
          ),
        ),
      ],
    );
  }
}

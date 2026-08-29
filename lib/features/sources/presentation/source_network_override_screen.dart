/// 源级网络覆盖页：为单个源覆盖全局网络配置（逐方面「继承全局 / 覆盖」）。
///
/// 每个方面（代理 / DNS / SNI / ECH / Hosts）含一个「覆盖全局」开关：
/// - 关：继承全局（该方面不写入 [SourceNetworkConfig]）；
/// - 开：展开与全局页同款表单，整方面覆盖全局。
///
/// 生效边界：仅作用于经 HttpFetcher 的该源抓取；封面图/原生组件不受源级覆盖影响。
/// SNI 覆盖对 https 直连生效（值 `-` 免 SNI）；ECH 运行时未接通，卡片内说明替代路径。
/// 读写 [SourceNetworkOverrideStore]，保存后经
/// [NetworkConfigService.onSourceOverrideChanged] 即时生效。
///
/// 打开页面时工作副本逐方面取「用户覆盖 ?? 源文件 network 块」，与
/// [NetworkConfigService.effectiveFor] 的合并语义一致：导入自带 network
/// 块的源后直接沿用源自带配置，用户无需重新配置；保存后固化为用户覆盖。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nexhub/generated/app_localizations.dart';

import '../../../core/models/plugin_config.dart';
import '../../../core/network/model/network_config.dart';
import '../../../core/network/model/network_validators.dart';
import '../../../core/network/model/source_network_config.dart';
import '../../../core/network/network_config_service.dart';
import '../../../core/network/source_network_override_store.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_alert_dialog.dart';
import '../../settings/presentation/widgets/settings_widgets.dart';

/// DoH 预设端点（与全局页保持一致）。
const Map<String, String> _dohPresets = <String, String>{
  'Cloudflare': 'https://cloudflare-dns.com/dns-query',
  'Google': 'https://dns.google/dns-query',
  'Quad9': 'https://dns.quad9.net/dns-query',
};

class SourceNetworkOverrideScreen extends StatefulWidget {
  const SourceNetworkOverrideScreen({super.key, required this.source});

  final PluginConfig source;

  @override
  State<SourceNetworkOverrideScreen> createState() =>
      _SourceNetworkOverrideScreenState();
}

class _SourceNetworkOverrideScreenState
    extends State<SourceNetworkOverrideScreen> {
  // 各方面工作副本：null = 继承全局（不覆盖）。
  ProxyConfig? _proxy;
  DnsConfig? _dns;
  SniConfig? _sni;
  EchConfig? _ech;
  List<HostsEntry>? _hosts;

  final _proxyHostCtrl = TextEditingController();
  final _proxyPortCtrl = TextEditingController();
  final _proxyUserCtrl = TextEditingController();
  final _dohUrlCtrl = TextEditingController();
  final _dotHostCtrl = TextEditingController();
  final _dotPortCtrl = TextEditingController();
  final _sniDefaultCtrl = TextEditingController();
  final _echCtrl = TextEditingController();
  final _sniTestHostCtrl = TextEditingController(text: 'www.cloudflare.com');

  bool _saving = false;
  bool _testingSni = false;

  /// 源文件自带的 network 块（源作者随源下发，可能为 null 或空）。
  bool get _hasFileNetwork {
    final f = widget.source.network;
    return f != null && !f.isEmpty;
  }

  @override
  void initState() {
    super.initState();
    // 工作副本逐方面 = 用户覆盖 ?? 源文件 network 块，与运行时
    // NetworkConfigService.effectiveFor 的合并语义一致：导入自带
    // network 块的源后，此页直接沿用源自带配置，无需重新手配。
    final ov = SourceNetworkOverrideStore.instance.get(widget.source.id);
    final file = widget.source.network;
    _proxy = ov?.proxy ?? file?.proxy;
    _dns = ov?.dns ?? file?.dns;
    _sni = ov?.sni ?? file?.sni;
    _ech = ov?.ech ?? file?.ech;
    _hosts = ov?.hosts ?? file?.hosts;
    _proxyHostCtrl.text = _proxy?.host ?? '';
    _proxyPortCtrl.text =
        (_proxy != null && _proxy!.port > 0) ? '${_proxy!.port}' : '';
    _proxyUserCtrl.text = _proxy?.username ?? '';
    _dohUrlCtrl.text = _dns?.dohUrl ?? '';
    _dotHostCtrl.text = _dns?.dotHost ?? '';
    _dotPortCtrl.text = '${_dns?.dotPort ?? 853}';
    _sniDefaultCtrl.text = _sni?.defaultSni ?? '';
    _echCtrl.text = _ech?.echConfigList ?? '';
  }

  @override
  void dispose() {
    _proxyHostCtrl.dispose();
    _proxyPortCtrl.dispose();
    _proxyUserCtrl.dispose();
    _dohUrlCtrl.dispose();
    _dotHostCtrl.dispose();
    _dotPortCtrl.dispose();
    _sniDefaultCtrl.dispose();
    _echCtrl.dispose();
    _sniTestHostCtrl.dispose();
    super.dispose();
  }

  String _errText(AppLocalizations l10n, String key) => switch (key) {
        'networkErrorInvalidHost' => l10n.networkErrorInvalidHost,
        'networkErrorInvalidPort' => l10n.networkErrorInvalidPort,
        'networkErrorInvalidIp' => l10n.networkErrorInvalidIp,
        'networkErrorInvalidDomain' => l10n.networkErrorInvalidDomain,
        'networkErrorInvalidDohUrl' => l10n.networkErrorInvalidDohUrl,
        _ => key,
      };

  /// 从控件与工作副本组装最终覆盖（仅包含已启用方面）。
  SourceNetworkConfig _collect() {
    return SourceNetworkConfig(
      proxy: _proxy?.copyWith(
        host: _proxyHostCtrl.text.trim(),
        port: int.tryParse(_proxyPortCtrl.text.trim()) ?? 0,
        username: _proxyUserCtrl.text.trim(),
      ),
      dns: _dns?.copyWith(
        dohUrl: _dohUrlCtrl.text.trim(),
        dotHost: _dotHostCtrl.text.trim(),
        dotPort: int.tryParse(_dotPortCtrl.text.trim()) ?? 853,
      ),
      sni: _sni?.copyWith(
        defaultSni: _sniDefaultCtrl.text.trim().isEmpty
            ? null
            : _sniDefaultCtrl.text.trim(),
      ),
      ech: _ech?.copyWith(echConfigList: _echCtrl.text.trim()),
      hosts: _hosts,
    );
  }

  Future<void> _save(AppLocalizations l10n) async {
    final cfg = _collect();
    final errs = cfg.validate();
    if (errs.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_errText(l10n, errs.first))),
      );
      return;
    }
    setState(() => _saving = true);
    await SourceNetworkOverrideStore.instance
        .set(widget.source.id, cfg.isEmpty ? null : cfg);
    NetworkConfigService.instance.onSourceOverrideChanged();
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(l10n.sourceNetworkSaved)));
  }

  Future<void> _clear(AppLocalizations l10n) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AppAlertDialog(
        title: Text(l10n.sourceNetworkClear),
        // 源自带 network 块时，清除的是「自定义覆盖」，回落到源自带配置
        // （运行时仍会生效该配置），而非继承全局。
        content: Text(_hasFileNetwork
            ? l10n.sourceNetworkClearConfirmFromSource
            : l10n.sourceNetworkClearConfirm),
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
    await SourceNetworkOverrideStore.instance.remove(widget.source.id);
    NetworkConfigService.instance.onSourceOverrideChanged();
    if (!mounted) return;
    final file = widget.source.network;
    setState(() {
      _proxy = file?.proxy;
      _dns = file?.dns;
      _sni = file?.sni;
      _ech = file?.ech;
      _hosts = file?.hosts;
      _proxyHostCtrl.text = _proxy?.host ?? '';
      _proxyPortCtrl.text =
          (_proxy != null && _proxy!.port > 0) ? '${_proxy!.port}' : '';
      _proxyUserCtrl.text = _proxy?.username ?? '';
      _dohUrlCtrl.text = _dns?.dohUrl ?? '';
      _dotHostCtrl.text = _dns?.dotHost ?? '';
      _dotPortCtrl.text = '${_dns?.dotPort ?? 853}';
      _sniDefaultCtrl.text = _sni?.defaultSni ?? '';
      _echCtrl.text = _ech?.echConfigList ?? '';
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(_hasFileNetwork
          ? l10n.sourceNetworkClearedToSource
          : l10n.sourceNetworkCleared),
    ));
  }

  /// 源级 SNI 握手测试：以「全局配置 + 本页工作副本覆盖」构建档案，
  /// 与运行时合并语义一致。
  Future<void> _testSni(AppLocalizations l10n) async {
    final host = _sniTestHostCtrl.text.trim();
    if (host.isEmpty) return;
    final cfg = _collect();
    final sni = cfg.sni;
    if (sni != null) {
      final err =
          NetworkValidators.validateSniValue(sni.defaultSni ?? '');
      if (err.isNotEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_errText(l10n, err.first))));
        return;
      }
    }
    setState(() => _testingSni = true);
    final (ok, ms, name) = await NetworkConfigService.instance.testSni(
      host,
      NetworkConfigService.instance.config,
      override: cfg,
    );
    if (!mounted) return;
    setState(() => _testingSni = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok ? l10n.networkSniTestResult(name, ms) : l10n.networkTestFailed,
          style: ok
              ? TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                )
              : null,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.sourceNetworkOverride)),
      body: ListView(
        padding: const EdgeInsets.all(AppTokens.spaceLg),
        children: <Widget>[
          _buildInfoCard(l10n),
          _buildProxyCard(l10n),
          _buildDnsCard(l10n),
          _buildSniCard(l10n),
          _buildEchCard(l10n),
          _buildHostsCard(l10n),
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
            onPressed: () => _clear(l10n),
            icon: const Icon(Icons.restore),
            label: Text(l10n.sourceNetworkClear),
          ),
          const SizedBox(height: AppTokens.spaceXl),
        ],
      ),
    );
  }

  Widget _buildInfoCard(AppLocalizations l10n) {
    final theme = Theme.of(context);
    return SettingsCard(
      title: widget.source.name,
      children: <Widget>[
        Text(
          l10n.sourceNetworkScopeNote,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        // 源自带 network 块：明确告知已自动沿用，避免误以为需要重新配置。
        if (_hasFileNetwork) ...<Widget>[
          const SizedBox(height: AppTokens.spaceSm),
          Text(
            l10n.sourceNetworkFromSourceNote,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.primary),
          ),
        ],
      ],
    );
  }

  /// 每方面卡片头部：「覆盖全局」开关。
  Widget _overrideToggle(
    AppLocalizations l10n, {
    required bool enabled,
    required ValueChanged<bool> onChanged,
  }) {
    return SettingsSwitchTile(
      title: l10n.networkOverrideEnable,
      subtitle: enabled ? null : l10n.networkInheritGlobal,
      value: enabled,
      onChanged: onChanged,
    );
  }

  Widget _buildProxyCard(AppLocalizations l10n) {
    final p = _proxy;
    return SettingsCard(
      title: l10n.networkProxyTitle,
      children: <Widget>[
        _overrideToggle(
          l10n,
          enabled: p != null,
          onChanged: (v) => setState(
              () => _proxy = v ? ProxyConfig.defaults : null),
        ),
        if (p != null) ...<Widget>[
          SegmentedButton<ProxyMode>(
            selected: <ProxyMode>{p.mode},
            onSelectionChanged: (s) =>
                setState(() => _proxy = p.copyWith(mode: s.first)),
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
          if (p.mode == ProxyMode.manual) ...<Widget>[
            SegmentedButton<ProxyProtocol>(
              selected: <ProxyProtocol>{p.protocol},
              onSelectionChanged: (s) =>
                  setState(() => _proxy = p.copyWith(protocol: s.first)),
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
          ],
        ],
      ],
    );
  }

  Widget _buildDnsCard(AppLocalizations l10n) {
    final d = _dns;
    return SettingsCard(
      title: l10n.networkDnsTitle,
      children: <Widget>[
        _overrideToggle(
          l10n,
          enabled: d != null,
          onChanged: (v) =>
              setState(() => _dns = v ? DnsConfig.defaults : null),
        ),
        if (d != null) ...<Widget>[
          SegmentedButton<DnsMode>(
            selected: <DnsMode>{d.mode},
            onSelectionChanged: (s) =>
                setState(() => _dns = d.copyWith(mode: s.first)),
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
          if (d.mode == DnsMode.custom)
            _stringListEditor(
              l10n,
              title: l10n.networkDnsServers,
              emptyHint: l10n.networkDnsServersEmpty,
              values: d.servers,
              addLabel: l10n.networkAddServer,
              inputLabel: l10n.networkProxyHost,
              validate: NetworkValidators.validateDnsServer,
              onChanged: (list) =>
                  setState(() => _dns = d.copyWith(servers: list)),
            ),
          if (d.mode == DnsMode.doh) ...<Widget>[
            DropdownButtonFormField<String>(
              value: _dohPresets.entries
                      .any((e) => e.value == _dohUrlCtrl.text.trim())
                  ? _dohPresets.entries
                      .firstWhere((e) => e.value == _dohUrlCtrl.text.trim())
                      .key
                  : null,
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
          ],
          if (d.mode == DnsMode.dot) ...<Widget>[
            _field(_dotHostCtrl, l10n.networkDotHost, Icons.dns_outlined),
            _field(_dotPortCtrl, l10n.networkDotPort, Icons.numbers,
                number: true),
          ],
        ],
      ],
    );
  }

  Widget _buildSniCard(AppLocalizations l10n) {
    final theme = Theme.of(context);
    final s = _sni;
    return SettingsCard(
      title: l10n.networkSniTitle,
      children: <Widget>[
        Text(
          l10n.networkSniRuntimeNote,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        _overrideToggle(
          l10n,
          enabled: s != null,
          onChanged: (v) => setState(
              () => _sni = v ? const SniConfig(enabled: true) : null),
        ),
        if (s != null) ...<Widget>[
          _field(_sniDefaultCtrl, l10n.networkSniDefault, Icons.vpn_lock),
          _domainSniEditor(l10n),
          _field(_sniTestHostCtrl, l10n.networkSniTestHost,
              Icons.travel_explore),
          _testButton(l10n.networkTestSni, _testingSni, () => _testSni(l10n)),
        ],
      ],
    );
  }

  Widget _buildEchCard(AppLocalizations l10n) {
    final theme = Theme.of(context);
    final e = _ech;
    return SettingsCard(
      title: l10n.networkEchTitle,
      children: <Widget>[
        Text(
          l10n.networkEchRuntimeNote,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        _overrideToggle(
          l10n,
          enabled: e != null,
          onChanged: (v) => setState(
              () => _ech = v ? const EchConfig(enabled: true) : null),
        ),
        if (e != null)
          _field(_echCtrl, l10n.networkEchConfigList,
              Icons.enhanced_encryption),
      ],
    );
  }

  /// 域名 → SNI 映射编辑器（与全局页同语义：`.` 前缀后缀通配、`-` 免 SNI）。
  Widget _domainSniEditor(AppLocalizations l10n) {
    final theme = Theme.of(context);
    final s = _sni;
    final entries = s?.domainSni.entries.toList() ?? const <MapEntry<String, String>>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(l10n.networkSniDomainTitle,
            style: theme.textTheme.bodyMedium
                ?.copyWith(fontWeight: FontWeight.w600)),
        if (entries.isEmpty)
          Text(l10n.networkSniDomainEmpty, style: theme.textTheme.bodySmall)
        else
          for (final entry in entries)
            Row(
              children: <Widget>[
                Expanded(child: Text('${entry.key}  →  ${entry.value}')),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => setState(() {
                    final next = Map<String, String>.of(s!.domainSni)
                      ..remove(entry.key);
                    _sni = s.copyWith(domainSni: next);
                  }),
                ),
              ],
            ),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: () => _addSniMapping(l10n),
            icon: const Icon(Icons.add, size: 18),
            label: Text(l10n.networkSniAddDomain),
          ),
        ),
      ],
    );
  }

  Future<void> _addSniMapping(AppLocalizations l10n) async {
    final hostCtrl = TextEditingController();
    final valueCtrl = TextEditingController();
    final added = await showDialog<MapEntry<String, String>>(
      context: context,
      builder: (ctx) => AppAlertDialog(
        title: Text(l10n.networkSniAddDomain),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: hostCtrl,
              decoration: InputDecoration(
                labelText: l10n.networkSniDomainHost,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppTokens.spaceMd),
            TextField(
              controller: valueCtrl,
              decoration: InputDecoration(
                labelText: l10n.networkSniDomainValue,
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
              final errs = NetworkValidators.validateSniEntry(
                host: hostCtrl.text.trim(),
                value: valueCtrl.text.trim(),
              );
              if (errs.isNotEmpty) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  SnackBar(content: Text(_errText(l10n, errs.first))),
                );
                return;
              }
              Navigator.of(ctx).pop(MapEntry(
                hostCtrl.text.trim(),
                valueCtrl.text.trim(),
              ));
            },
            child: Text(l10n.add),
          ),
        ],
      ),
    );
    hostCtrl.dispose();
    valueCtrl.dispose();
    if (added != null) {
      setState(() {
        final next = Map<String, String>.of(_sni?.domainSni ?? const {});
        next[added.key] = added.value;
        _sni = (_sni ?? const SniConfig(enabled: true))
            .copyWith(domainSni: next);
      });
    }
  }

  Widget _buildHostsCard(AppLocalizations l10n) {
    final h = _hosts;
    return SettingsCard(
      title: l10n.networkHostsTitle,
      children: <Widget>[
        _overrideToggle(
          l10n,
          enabled: h != null,
          onChanged: (v) =>
              setState(() => _hosts = v ? <HostsEntry>[] : null),
        ),
        if (h != null) ...<Widget>[
          if (h.isEmpty)
            Text(l10n.networkHostsEmpty,
                style: Theme.of(context).textTheme.bodySmall)
          else
            for (var i = 0; i < h.length; i++) _hostRow(l10n, h, i),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: () => _addHost(l10n),
              icon: const Icon(Icons.add, size: 18),
              label: Text(l10n.networkAddHost),
            ),
          ),
        ],
      ],
    );
  }

  Widget _hostRow(AppLocalizations l10n, List<HostsEntry> list, int index) {
    final entry = list[index];
    return Row(
      children: <Widget>[
        Checkbox(
          value: entry.enabled,
          onChanged: (v) => setState(() {
            final next = List<HostsEntry>.of(list);
            next[index] = entry.copyWith(enabled: v ?? true);
            _hosts = next;
          }),
        ),
        Expanded(child: Text('${entry.ip}  →  ${entry.host}')),
        IconButton(
          icon: const Icon(Icons.delete_outline),
          onPressed: () => setState(() {
            _hosts = List<HostsEntry>.of(list)..removeAt(index);
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
        _hosts = <HostsEntry>[...?_hosts, entry];
      });
    }
  }

  // ---- 通用小组件 ----

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

  Widget _field(
    TextEditingController ctrl,
    String label,
    IconData icon, {
    bool number = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: AppTokens.spaceSm),
      child: TextField(
        controller: ctrl,
        keyboardType: number ? TextInputType.number : TextInputType.text,
        inputFormatters: number
            ? <TextInputFormatter>[FilteringTextInputFormatter.digitsOnly]
            : null,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          prefixIcon: Icon(icon),
          isDense: true,
        ),
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

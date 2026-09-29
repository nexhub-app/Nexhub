/// 添加 / 重新登录媒体服务器向导：地址 → 探测（可手选类型）→ 登录。
///
/// - 新增模式：输入地址后可先「探测」预览服务器名与类型（识别失败可手选），
///   登录提交时自动完成 `addServer` + `login` 两步；
/// - 重新登录模式：从管理页带入已有服务器档案，仅补账号密码（401 引导回此页）。
library;

import 'package:material_ui/material_ui.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:provider/provider.dart';

import '../../../core/services/media_server/media_server_auth.dart';
import '../../../core/services/media_server/media_server_models.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_glass_bar.dart';

class MediaServerAddScreen extends StatefulWidget {
  const MediaServerAddScreen({super.key, this.existing});

  /// 非空 = 重新登录模式（地址与类型来自既有档案，不可改）。
  final MediaServerInfo? existing;

  @override
  State<MediaServerAddScreen> createState() => _MediaServerAddScreenState();
}

class _MediaServerAddScreenState extends State<MediaServerAddScreen> {
  late final MediaServerInfo? _existing = widget.existing;
  late final bool _relogin = _existing != null;

  final TextEditingController _address = TextEditingController();
  final TextEditingController _username = TextEditingController();
  final TextEditingController _password = TextEditingController();

  ServerType _type = ServerType.jellyfin;
  String? _detectedName;
  bool _probing = false;
  bool _submitting = false;

  @override
  void dispose() {
    _address.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _relogin
              ? l10n.mediaServerReloginTitle(_existing!.name)
              : l10n.mediaServerAddServer,
        ),
      ),
      body: ListView(
        padding: context.pageInset(AppTokens.spaceLg),
        children: <Widget>[
          if (_relogin) ...<Widget>[
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(AppTokens.spaceMd),
                child: Row(
                  children: <Widget>[
                    Icon(
                      Icons.dns_rounded,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: AppTokens.spaceMd),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            _existing!.name,
                            style: theme.textTheme.titleSmall,
                          ),
                          Text(
                            '${_existing.baseUrl} · ${_existing.type.name}',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppTokens.spaceLg),
          ] else ...<Widget>[
            TextField(
              controller: _address,
              keyboardType: TextInputType.url,
              enabled: !_submitting,
              decoration: InputDecoration(
                labelText: l10n.mediaServerAddressLabel,
                hintText: l10n.mediaServerAddressHint,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.dns_rounded),
              ),
            ),
            const SizedBox(height: AppTokens.spaceMd),
            Text(l10n.mediaServerTypeLabel, style: theme.textTheme.labelLarge),
            const SizedBox(height: AppTokens.spaceXs),
            SegmentedButton<ServerType>(
              segments: const <ButtonSegment<ServerType>>[
                ButtonSegment<ServerType>(
                  value: ServerType.jellyfin,
                  label: Text('Jellyfin'),
                  icon: Icon(Icons.movie_rounded),
                ),
                ButtonSegment<ServerType>(
                  value: ServerType.emby,
                  label: Text('Emby'),
                  icon: Icon(Icons.live_tv_rounded),
                ),
              ],
              selected: <ServerType>{_type},
              onSelectionChanged: _submitting
                  ? null
                  : (s) => setState(() => _type = s.first),
            ),
            const SizedBox(height: AppTokens.spaceMd),
            OutlinedButton.icon(
              onPressed: _probing ? null : _detect,
              icon: _probing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.search_rounded),
              label: Text(
                _probing ? l10n.mediaServerDetecting : l10n.mediaServerDetect,
              ),
            ),
            if (_detectedName != null) ...<Widget>[
              const SizedBox(height: AppTokens.spaceSm),
              Text(
                l10n.mediaServerDetectedAs(_detectedName!),
                style: theme.textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: AppTokens.spaceSm),
            Text(
              l10n.mediaServerManualTypeHint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppTokens.spaceLg),
          ],
          TextField(
            controller: _username,
            enabled: !_submitting,
            decoration: InputDecoration(
              labelText: l10n.mediaServerUsernameLabel,
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.person_rounded),
            ),
          ),
          const SizedBox(height: AppTokens.spaceMd),
          TextField(
            controller: _password,
            obscureText: true,
            enabled: !_submitting,
            decoration: InputDecoration(
              labelText: l10n.mediaServerPasswordLabel,
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.key_rounded),
            ),
          ),
          const SizedBox(height: AppTokens.spaceLg),
          FilledButton.icon(
            onPressed: _submitting ? null : _submit,
            icon: _submitting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.login_rounded),
            label: Text(
              _submitting ? l10n.mediaServerLoggingIn : l10n.mediaServerLogin,
            ),
          ),
        ],
      ),
    );
  }

  /// 探测预览：识别类型与服务器名（识别失败仅提示，可手选后直接登录）。
  Future<void> _detect() async {
    final l10n = AppLocalizations.of(context);
    if (_address.text.trim().isEmpty) {
      _showError(l10n.mediaServerAddressRequired);
      return;
    }
    setState(() => _probing = true);
    try {
      final r = await context.read<MediaServerAuth>().probeAddress(
            _address.text,
          );
      if (!mounted) return;
      setState(() {
        _type = r.type;
        _detectedName = r.serverName;
      });
    } on Object catch (e) {
      if (mounted) _showError(e);
    } finally {
      if (mounted) setState(() => _probing = false);
    }
  }

  /// 登录提交：新增模式先 `addServer`（内含探测 / 手选类型）再 `login`。
  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context);
    final auth = context.read<MediaServerAuth>();
    final user = _username.text.trim();
    final pass = _password.text;
    if (user.isEmpty || pass.isEmpty) {
      _showError(l10n.mediaServerCredentialsRequired);
      return;
    }
    if (!_relogin && _address.text.trim().isEmpty) {
      _showError(l10n.mediaServerAddressRequired);
      return;
    }
    setState(() => _submitting = true);
    try {
      if (_relogin) {
        await auth.login(_existing!.id, user, pass);
      } else {
        final info = await auth.addServer(_address.text, typeOverride: _type);
        await auth.login(info.id, user, pass);
      }
      if (!mounted) return;
      Navigator.of(context).pop();
    } on Object catch (e) {
      if (mounted) _showError(e);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _showError(Object message) {
    final l10n = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.mediaServerOperationFailed('$message'))),
    );
  }
}

/// 弹弹play 账号登录页（重构：账号体系从弹幕显示设置迁出至此）。
///
/// - 用户级账号登录：用户名 + 密码 → [DandanplayAuth.login]
///   （POST /api/v2/login，需应用级 AppId/AppSecret 已配置，否则给出友好提示）；
/// - 登录态展示与登出；
/// - 应用级凭据（AppId/AppSecret）维持编译期注入，本页不提供编辑入口。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';

import '../../../core/danmaku/dandanplay_auth.dart';
import '../../../core/settings/danmaku_config.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_animations.dart';
import '../../../core/widgets/app_list_tile.dart';
import './widgets/settings_widgets.dart';

class SettingsDandanplayAccountScreen extends StatefulWidget {
  const SettingsDandanplayAccountScreen({super.key});

  @override
  State<SettingsDandanplayAccountScreen> createState() =>
      _SettingsDandanplayAccountScreenState();
}

class _SettingsDandanplayAccountScreenState
    extends State<SettingsDandanplayAccountScreen> {
  final TextEditingController _userCtrl = TextEditingController();
  final TextEditingController _passCtrl = TextEditingController();
  final TextEditingController _emailCtrl = TextEditingController();
  final TextEditingController _screenCtrl = TextEditingController();
  bool _busy = false;
  String? _error;
  bool _appConfigured = true;
  bool _isRegister = false;

  @override
  void initState() {
    super.initState();
    unawaited(DandanplayAuth.instance.init());
    _checkAppConfigured();
  }

  Future<void> _checkAppConfigured() async {
    final cfg = await DanmakuConfigStore().load();
    if (mounted) setState(() => _appConfigured = cfg.isConfigured);
  }

  @override
  void dispose() {
    _userCtrl.dispose();
    _passCtrl.dispose();
    _emailCtrl.dispose();
    _screenCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit(AppLocalizations l10n) async {
    if (_isRegister) {
      await _register(l10n);
    } else {
      await _login(l10n);
    }
  }

  Future<void> _login(AppLocalizations l10n) async {
    final userName = _userCtrl.text.trim();
    final password = _passCtrl.text;
    if (userName.isEmpty || password.isEmpty) {
      setState(() => _error = l10n.danmakuLoginEmptyFields);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await DandanplayAuth.instance.login(userName, password);
      if (!mounted) return;
      _userCtrl.clear();
      _passCtrl.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.loginSuccess)),
      );
    } on StateError catch (e) {
      if (!mounted) return;
      final msg = e.message.contains('credentials not configured')
          ? l10n.dandanplayAppNotConfigured
          : e.message;
      setState(() => _error = msg);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _register(AppLocalizations l10n) async {
    final userName = _userCtrl.text.trim();
    final password = _passCtrl.text;
    final email = _emailCtrl.text.trim();
    final screenName = _screenCtrl.text.trim();
    if (userName.isEmpty || password.isEmpty || email.isEmpty) {
      setState(() => _error = l10n.dandanplayRegisterEmptyFields);
      return;
    }
    if (!_isValidEmail(email)) {
      setState(() => _error = l10n.dandanplayRegisterEmailInvalid);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await DandanplayAuth.instance.register(
        userName: userName,
        password: password,
        email: email,
        screenName: screenName.isNotEmpty ? screenName : userName,
      );
      if (!mounted) return;
      _userCtrl.clear();
      _passCtrl.clear();
      _emailCtrl.clear();
      _screenCtrl.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.dandanplayRegisterSuccess)),
      );
    } on StateError catch (e) {
      if (!mounted) return;
      final msg = e.message.contains('credentials not configured')
          ? l10n.dandanplayAppNotConfigured
          : e.message;
      setState(() => _error = msg);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _isValidEmail(String value) =>
      RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(value);

  Future<void> _logout(AppLocalizations l10n) async {
    await DandanplayAuth.instance.logout();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.dandanplayLoggedOut)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return AppShrinkTitleScaffold(
      title: Text(l10n.danmakuAccountSection),
      body: Entrance(
        offset: 10,
        fromScale: 0.985,
        duration: AppTokens.durBase,
        child: AnimatedBuilder(
          animation: DandanplayAuth.instance,
          builder: (BuildContext ctx, _) {
            final auth = DandanplayAuth.instance;
            final loggedIn = auth.isLoggedIn;
            return ListView(
              padding: const EdgeInsets.all(AppTokens.spaceLg),
              children: <Widget>[
                AppListTile(
                  leading: const SettingsLeadingIcon(
                    icon: Icons.chat_bubble_outline,
                  ),
                  title: Text(l10n.danmakuAccountSection),
                  subtitle: Text(loggedIn
                      ? l10n.danmakuAccountLoggedInAs(auth.displayName ?? '')
                      : l10n.loginStatusLoggedOut),
                ),
                const SizedBox(height: AppTokens.spaceMd),
                if (!_appConfigured)
                  Container(
                    margin: const EdgeInsets.only(bottom: AppTokens.spaceMd),
                    padding: const EdgeInsets.all(AppTokens.spaceMd),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.errorContainer
                          .withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(AppTokens.radiusMd),
                    ),
                    child: Text(
                      l10n.dandanplayAppNotConfigured,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                if (loggedIn)
                  FilledButton.tonal(
                    onPressed: () => _logout(l10n),
                    child: Text(l10n.logoutAction),
                  )
                else ...<Widget>[
                  SegmentedButton<bool>(
                    selected: <bool>{_isRegister},
                    onSelectionChanged: (set) {
                      if (_busy) return;
                      setState(() => _isRegister = set.first);
                    },
                    segments: <ButtonSegment<bool>>[
                      ButtonSegment<bool>(
                        value: false,
                        label: Text(l10n.dandanplayLoginTab),
                      ),
                      ButtonSegment<bool>(
                        value: true,
                        label: Text(l10n.dandanplayRegisterTab),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppTokens.spaceMd),
                  TextField(
                    controller: _userCtrl,
                    autofocus: true,
                    enabled: !_busy,
                    decoration:
                        InputDecoration(labelText: l10n.danmakuUsername),
                  ),
                  const SizedBox(height: AppTokens.spaceSm),
                  TextField(
                    controller: _passCtrl,
                    obscureText: true,
                    enabled: !_busy,
                    decoration:
                        InputDecoration(labelText: l10n.danmakuPassword),
                    onSubmitted: (_) {
                      if (!_busy) _submit(l10n);
                    },
                  ),
                  if (_isRegister) ...<Widget>[
                    const SizedBox(height: AppTokens.spaceSm),
                    TextField(
                      controller: _emailCtrl,
                      enabled: !_busy,
                      keyboardType: TextInputType.emailAddress,
                      decoration:
                          InputDecoration(labelText: l10n.dandanplayEmail),
                    ),
                    const SizedBox(height: AppTokens.spaceSm),
                    TextField(
                      controller: _screenCtrl,
                      enabled: !_busy,
                      decoration:
                          InputDecoration(labelText: l10n.dandanplayNickname),
                    ),
                  ],
                  if (_error != null) ...<Widget>[
                    const SizedBox(height: AppTokens.spaceSm),
                    Text(
                      _error!,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.error),
                    ),
                  ],
                  const SizedBox(height: AppTokens.spaceMd),
                  FilledButton(
                    onPressed: _busy ? null : () => _submit(l10n),
                    child: Text(_isRegister
                        ? l10n.dandanplayRegisterAction
                        : l10n.danmakuLoginAction),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Bangumi 账户与收藏浏览设置页。
///
/// - 账户登录：个人 Access Token 输入与验证（token 存 secure storage）、
///   登录状态展示与登出；
/// - 浏览 Bangumi 收藏：登录后按五状态（想看 / 在看 / 看过 / 搁置 / 抛弃）
///   筛选查看远端收藏条目信息（[BangumiCollectionBrowser]）。
/// 单条同步与绑定 / 评分入口下沉到详情页 Bangumi 卡片与书架长按菜单。
library;

import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/services/bangumi/bangumi_oauth_config.dart';
import '../../../core/services/bangumi/bangumi_sync_service.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/bangumi_collection_browser.dart';

class SettingsBangumiScreen extends StatefulWidget {
  const SettingsBangumiScreen({super.key});

  @override
  State<SettingsBangumiScreen> createState() => _SettingsBangumiScreenState();
}

class _SettingsBangumiScreenState extends State<SettingsBangumiScreen> {
  final TextEditingController _tokenController = TextEditingController();
  bool _verifying = false;
  bool _oauthing = false;

  @override
  void dispose() {
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _verifyToken(AppLocalizations l10n) async {
    final service = context.read<BangumiSyncService>();
    final token = _tokenController.text.trim();
    if (token.isEmpty) return;
    setState(() => _verifying = true);
    try {
      await service.auth.saveToken(token);
      _tokenController.clear();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.bangumiTokenSaved)),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.bangumiTokenInvalid)),
      );
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  /// OAuth 2.0 授权码登录：打开浏览器 → 深链回调 → 保存 token。
  Future<void> _loginWithOAuth(AppLocalizations l10n) async {
    setState(() => _oauthing = true);
    try {
      final service = context.read<BangumiSyncService>();
      await service.auth.loginWithOAuth();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.loginSuccess)),
      );
    } on StateError catch (e) {
      if (!mounted) return;
      final msg = e.message == 'bangumi oauth not configured'
          ? l10n.bangumiOauthNotConfigured
          : l10n.bangumiOauthFailed;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg)),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.bangumiOauthFailed)),
      );
    } finally {
      if (mounted) setState(() => _oauthing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final service = context.watch<BangumiSyncService>();
    final auth = service.auth;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.bangumiSettings)),
      body: ListView(
        padding: const EdgeInsets.all(AppTokens.spaceLg),
        children: <Widget>[
          // ───── 账号区 ─────
          Text(l10n.bangumiAccount, style: theme.textTheme.titleMedium),
          const SizedBox(height: AppTokens.spaceMd),
          if (auth.isLoggedIn) ...<Widget>[
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.account_circle),
              title: Text(l10n.bangumiLoggedInAs(auth.displayName ?? '')),
              subtitle: (auth.username != null && auth.username!.isNotEmpty)
                  ? Text('@${auth.username}')
                  : null,
              trailing: TextButton(
                onPressed: () => auth.logout(),
                child: Text(l10n.logoutAction),
              ),
            ),
          ] else ...<Widget>[
            // ── OAuth 2.0 授权登录（推荐）──
            FilledButton.icon(
              onPressed: _oauthing ? null : () => _loginWithOAuth(l10n),
              icon: _oauthing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.login),
              label: Text(l10n.bangumiLoginWithOAuth),
            ),
            const SizedBox(height: AppTokens.spaceSm),
            Text(
              BangumiOAuthConfig.configured
                  ? l10n.bangumiOauthHint
                  : l10n.bangumiOauthNotConfigured,
              style: theme.textTheme.bodySmall?.copyWith(
                color: BangumiOAuthConfig.configured
                    ? null
                    : theme.colorScheme.error,
              ),
            ),
            const SizedBox(height: AppTokens.spaceLg),
            const Divider(),
            const SizedBox(height: AppTokens.spaceMd),
            TextField(
              controller: _tokenController,
              decoration: InputDecoration(
                labelText: l10n.bangumiTokenHint,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.key),
              ),
              obscureText: true,
            ),
            const SizedBox(height: AppTokens.spaceMd),
            FilledButton.icon(
              onPressed: _verifying ? null : () => _verifyToken(l10n),
              icon: _verifying
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.verified_user),
              label: Text(l10n.bangumiTokenVerify),
            ),
            const SizedBox(height: AppTokens.spaceSm),
            TextButton.icon(
              onPressed: () => launchUrl(
                Uri.parse('https://next.bgm.tv/demo/access-token'),
                mode: LaunchMode.externalApplication,
              ),
              icon: const Icon(Icons.open_in_new, size: 16),
              label: Text(l10n.bangumiGetToken),
            ),
          ],
          // ───── 浏览 Bangumi 收藏（登录后可用）─────
          if (auth.isLoggedIn) ...<Widget>[
            const SizedBox(height: AppTokens.spaceXl),
            const Divider(),
            const SizedBox(height: AppTokens.spaceMd),
            Text(l10n.bangumiBrowseCollection,
                style: theme.textTheme.titleMedium),
            const SizedBox(height: AppTokens.spaceMd),
            const BangumiCollectionBrowser(),
          ],
        ],
      ),
    );
  }
}

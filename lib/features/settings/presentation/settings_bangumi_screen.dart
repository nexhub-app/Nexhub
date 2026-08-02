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

import '../../../core/services/bangumi/bangumi_auth.dart';
import '../../../core/services/bangumi/bangumi_oauth_config.dart';
import '../../../core/services/bangumi/bangumi_proxy_config.dart';
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

  // ── 代理 / 镜像配置 ──
  final TextEditingController _mainSiteController = TextEditingController();
  final TextEditingController _apiController = TextEditingController();
  final TextEditingController _imageController = TextEditingController();
  BangumiProxyMode _proxyMode = BangumiProxyMode.direct;

  @override
  void initState() {
    super.initState();
    final cfg = BangumiProxyConfig.instance;
    _proxyMode = cfg.mode;
    _mainSiteController.text = cfg.mainSite;
    _apiController.text = cfg.api;
    _imageController.text = cfg.image;
  }

  @override
  void dispose() {
    _tokenController.dispose();
    _mainSiteController.dispose();
    _apiController.dispose();
    _imageController.dispose();
    super.dispose();
  }

  /// 保存代理 / 镜像设置到本地存储并同步全局实例。
  Future<void> _saveProxy(AppLocalizations l10n) async {
    final cfg = BangumiProxyConfig(
      mode: _proxyMode,
      mainSite: _mainSiteController.text.trim(),
      api: _apiController.text.trim(),
      image: _imageController.text.trim(),
    );
    await cfg.save();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.bangumiProxySaved)),
    );
  }

  Future<void> _verifyToken(AppLocalizations l10n) async {
    final auth = context.read<BangumiAuth>();
    final token = _tokenController.text.trim();
    if (token.isEmpty) return;
    setState(() => _verifying = true);
    try {
      await auth.saveToken(token);
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
      final auth = context.read<BangumiAuth>();
      await auth.loginWithOAuth();
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
    // 订阅 BangumiAuth 直接响应 login/logout（之前订阅 SyncService 取 auth
    // 字段是不会重建的，导致 logout 后 UI 不刷新）。SyncService 仅在「同步中」
    // 状态需要，用 read 拿即可。
    final auth = context.watch<BangumiAuth>();

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
          // ───── 代理 / 镜像设置 ─────
          const SizedBox(height: AppTokens.spaceXl),
          const Divider(),
          const SizedBox(height: AppTokens.spaceMd),
          Text(l10n.bangumiProxyTitle, style: theme.textTheme.titleMedium),
          const SizedBox(height: AppTokens.spaceMd),
          SegmentedButton<BangumiProxyMode>(
            segments: <ButtonSegment<BangumiProxyMode>>[
              ButtonSegment<BangumiProxyMode>(
                value: BangumiProxyMode.direct,
                label: Text(l10n.bangumiProxyDirect),
                icon: const Icon(Icons.lan),
              ),
              ButtonSegment<BangumiProxyMode>(
                value: BangumiProxyMode.mirror,
                label: Text(l10n.bangumiProxyMirror),
                icon: const Icon(Icons.dns),
              ),
            ],
            selected: <BangumiProxyMode>{_proxyMode},
            onSelectionChanged: (s) => setState(() => _proxyMode = s.first),
          ),
          if (_proxyMode == BangumiProxyMode.mirror) ...<Widget>[
            const SizedBox(height: AppTokens.spaceMd),
            Text(l10n.bangumiProxyHint, style: theme.textTheme.bodySmall),
            const SizedBox(height: AppTokens.spaceMd),
            TextField(
              controller: _mainSiteController,
              decoration: InputDecoration(
                labelText: l10n.bangumiProxyMainSite,
                hintText: 'next.bgm.tv',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.home_outlined),
              ),
            ),
            const SizedBox(height: AppTokens.spaceMd),
            TextField(
              controller: _apiController,
              decoration: InputDecoration(
                labelText: l10n.bangumiProxyApi,
                hintText: 'api.bgm.tv',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.cloud_outlined),
              ),
            ),
            const SizedBox(height: AppTokens.spaceMd),
            TextField(
              controller: _imageController,
              decoration: InputDecoration(
                labelText: l10n.bangumiProxyImage,
                hintText: 'lain.bgm.tv',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.image_outlined),
              ),
            ),
          ],
          const SizedBox(height: AppTokens.spaceMd),
          FilledButton.icon(
            onPressed: () => _saveProxy(l10n),
            icon: const Icon(Icons.save),
            label: Text(l10n.save),
          ),
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

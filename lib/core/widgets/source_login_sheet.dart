/// 源登录方式选择底部面板。
///
/// 由评论区「登录后评论」等入口唤起，提供两种登录方式：
/// - 「网页登录」：push [WebViewLoginScreen]，在站点页面完成登录后自动
///   捕获会话 Cookie（桌面端不支持内嵌 WebView 时提示改用粘贴方式）。
/// - 「粘贴 Cookie」：[AppAlertDialog] + 多行输入框，确认后对源相关 host
///   调 [HttpFetcher.syncCookies] 手动回灌。
///
/// 已登录时顶部显示登录状态与「退出登录」（经 [SourceAuthManager.logout]
/// 清除该源相关 host 的 Cookie）。
library;

import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:provider/provider.dart';

import '../../features/verification/presentation/webview_login_screen.dart';
import '../auth/source_auth_manager.dart';
import '../models/plugin_config.dart';
import '../navigation/app_page_route.dart';
import '../platform/platform_service.dart';
import '../scraper/http_fetcher.dart';
import '../theme/app_tokens.dart';
import 'app_alert_dialog.dart';
import 'app_animations.dart';
import 'app_card.dart';

/// 唤起源登录面板。返回后调用方可经 SourceAuthManager 读取最新登录态。
Future<void> showSourceLoginSheet(
  BuildContext context, {
  required PluginConfig source,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(AppTokens.radiusLg),
      ),
    ),
    builder: (BuildContext ctx) => _SourceLoginSheet(source: source),
  );
}

class _SourceLoginSheet extends StatelessWidget {
  final PluginConfig source;

  const _SourceLoginSheet({required this.source});

  /// 该源涉及的 host：登录页 url 与站点 baseUrl（去重）。
  List<String> _hosts() {
    final hosts = <String>{};
    void add(String? url) {
      final host = Uri.tryParse(url ?? '')?.host;
      if (host != null && host.isNotEmpty) hosts.add(host);
    }

    add(source.comments?.login?.url);
    add(source.site.baseUrl);
    return hosts.toList();
  }

  /// 网页登录：push WebView 登录页，返回 true 后重新评估登录态。
  Future<void> _webLogin(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final supported =
        PlatformService.instance.isAndroid || PlatformService.instance.isIOS;
    if (!supported) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.webviewLoginUnsupported)),
      );
      return;
    }
    final auth = context.read<SourceAuthManager>();
    final navigator = Navigator.of(context);
    final ok = await navigator.push<bool>(
      AppPageRoute<bool>(
        builder: (_) => WebViewLoginScreen(source: source),
      ),
    );
    if (ok == true) {
      await auth.refreshLoginState(source);
    }
    if (context.mounted) navigator.pop();
  }

  /// 粘贴 Cookie：多行输入对话框，确认后对源相关 host 手动回灌。
  Future<void> _pasteCookie(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final auth = context.read<SourceAuthManager>();
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AppAlertDialog(
        title: Text(l10n.pasteCookie),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 4,
          decoration: InputDecoration(
            hintText: l10n.cookieHint,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppTokens.radiusMd),
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: Text(l10n.confirm),
          ),
        ],
      ),
    );
    controller.dispose();
    if (text == null || text.isEmpty) return;
    for (final host in _hosts()) {
      HttpFetcher.instance.syncCookies(host, text);
    }
    await auth.refreshLoginState(source);
    messenger.showSnackBar(SnackBar(content: Text(l10n.loginSuccess)));
    if (context.mounted) navigator.pop();
  }

  /// 退出登录：清除该源相关 host 的 Cookie 并关闭面板。
  Future<void> _logout(BuildContext context) async {
    final auth = context.read<SourceAuthManager>();
    final navigator = Navigator.of(context);
    await auth.logout(source);
    if (context.mounted) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ThemeData theme = Theme.of(context);
    final bool loggedIn = context.watch<SourceAuthManager>().isLoggedIn(source);
    // WebView 仅在移动端可用；桌面/Web 直接隐藏「网页登录」入口。
    final bool webLoginSupported = PlatformService.instance.isAndroid ||
        PlatformService.instance.isIOS;

    return AppSheetBody(
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppTokens.spaceMd,
            AppTokens.spaceSm,
            AppTokens.spaceMd,
            AppTokens.spaceMd,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: AppTokens.spaceXs),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onSurfaceVariant
                        .withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: AppTokens.spaceSm),
              Text(l10n.sourceLogin, style: theme.textTheme.titleMedium),
              const SizedBox(height: AppTokens.spaceMd),
              if (loggedIn) ...<Widget>[
                Row(
                  children: <Widget>[
                    Icon(
                      Icons.check_circle,
                      size: 20,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: AppTokens.spaceSm),
                    Expanded(
                      child: Text(
                        l10n.loggedInState,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    TextButton(
                      onPressed: () => _logout(context),
                      child: Text(l10n.logoutAction),
                    ),
                  ],
                ),
                const SizedBox(height: AppTokens.spaceSm),
              ],
              if (webLoginSupported) ...<Widget>[
                _LoginOptionCard(
                  icon: Icons.public,
                  title: l10n.webLogin,
                  subtitle: l10n.webLoginDesc,
                  onTap: () => _webLogin(context),
                ),
                const SizedBox(height: AppTokens.spaceSm),
              ],
              _LoginOptionCard(
                icon: Icons.cookie_outlined,
                title: l10n.pasteCookie,
                subtitle: l10n.pasteCookieDesc,
                onTap: () => _pasteCookie(context),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 登录方式选项卡片（图标 + 标题 + 说明）。
class _LoginOptionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _LoginOptionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return AppCard(
      onTap: onTap,
      child: Row(
        children: <Widget>[
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(AppTokens.radiusSm),
            ),
            child: Icon(
              icon,
              size: 22,
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(width: AppTokens.spaceMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title, style: theme.textTheme.labelLarge),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Icon(
            Icons.chevron_right,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ],
      ),
    );
  }
}

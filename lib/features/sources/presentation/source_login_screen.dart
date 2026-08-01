/// 源登录全屏页（与 [showSourceLoginSheet] 同款逻辑，面向源管理/镜像页入口）。
///
/// 复用 [SourceAuthManager] 的登录态判定与 [WebViewLoginScreen] 的网页登录，
/// 提供三种操作：
/// - 「网页登录」：push [WebViewLoginScreen]，完成后刷新登录态；
/// - 「粘贴 Cookie」：[AppAlertDialog] + 多行输入，确认后对源相关 host
///   调 [HttpFetcher.syncCookies] 手动回灌；
/// - 「退出登录」：已登录时可见，经 [SourceAuthManager.logout] 清除 Cookie。
///
/// 桌面端（WebView 不可用）「网页登录」仅提示，需改用「粘贴 Cookie」。
library;

import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:provider/provider.dart';

import '../../../core/auth/source_auth_manager.dart';
import '../../../core/models/plugin_config.dart';
import '../../../core/navigation/app_page_route.dart';
import '../../../core/platform/platform_service.dart';
import '../../../core/scraper/http_fetcher.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_alert_dialog.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_form_field.dart';
import '../../verification/presentation/webview_login_screen.dart';

/// 源登录全屏页。接收一个 [PluginConfig source]，展示登录态与登录操作。
class SourceLoginScreen extends StatefulWidget {
  final PluginConfig source;

  const SourceLoginScreen({super.key, required this.source});

  @override
  State<SourceLoginScreen> createState() => _SourceLoginScreenState();
}

class _SourceLoginScreenState extends State<SourceLoginScreen> {
  @override
  void initState() {
    super.initState();
    // 进入页面即刷新登录态（声明 checkUrl 时异步探测二次确认）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<SourceAuthManager>().refreshLoginState(widget.source);
    });
  }

  /// 该源涉及的 host：登录页 url 与站点 baseUrl（去重）。
  /// 与 [SourceLoginSheet] 同款取值，保证 Cookie 回灌/清除覆盖同一组 host。
  List<String> _hosts() {
    final hosts = <String>{};
    void add(String? url) {
      final host = Uri.tryParse(url ?? '')?.host;
      if (host != null && host.isNotEmpty) hosts.add(host);
    }

    add(widget.source.comments?.login?.url);
    add(widget.source.site.baseUrl);
    return hosts.toList();
  }

  /// 网页登录：push WebView 登录页，返回后重新评估登录态。
  Future<void> _webLogin() async {
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
    final ok = await Navigator.of(context).push<bool>(
      AppPageRoute<bool>(
        builder: (_) => WebViewLoginScreen(source: widget.source),
      ),
    );
    if (ok == true) {
      await auth.refreshLoginState(widget.source);
    }
  }

  /// 粘贴 Cookie：多行输入对话框，确认后对源相关 host 手动回灌。
  Future<void> _pasteCookie() async {
    final l10n = AppLocalizations.of(context);
    final auth = context.read<SourceAuthManager>();
    final messenger = ScaffoldMessenger.of(context);
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AppAlertDialog(
        title: Text(l10n.pasteCookie),
        content: AppFormField(
          label: l10n.cookieInputHint,
          hint: l10n.cookieHint,
          controller: controller,
          maxLines: 4,
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
    await auth.refreshLoginState(widget.source);
    messenger.showSnackBar(SnackBar(content: Text(l10n.loginSuccess)));
  }

  /// 退出登录：清除该源相关 host 的 Cookie。
  Future<void> _logout() async {
    final auth = context.read<SourceAuthManager>();
    await auth.logout(widget.source);
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool loggedIn =
        context.watch<SourceAuthManager>().isLoggedIn(widget.source);

    return Scaffold(
      appBar: AppBar(title: Text(widget.source.name)),
      body: ListView(
        padding: const EdgeInsets.all(AppTokens.spaceLg),
        children: <Widget>[
          // 登录状态卡片
          AppCard(
            child: Row(
              children: <Widget>[
                Icon(
                  loggedIn ? Icons.check_circle : Icons.lock_outline,
                  size: 22,
                  color: loggedIn ? scheme.primary : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: AppTokens.spaceSm),
                Expanded(
                  child: Text(
                    loggedIn
                        ? l10n.loginStatusLoggedIn
                        : l10n.loginStatusLoggedOut,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                if (loggedIn)
                  TextButton(
                    onPressed: _logout,
                    child: Text(l10n.logoutAction),
                  ),
              ],
            ),
          ),
          const SizedBox(height: AppTokens.spaceMd),
          _LoginOptionCard(
            icon: Icons.public,
            title: l10n.webLogin,
            subtitle: l10n.webLoginDesc,
            onTap: _webLogin,
          ),
          const SizedBox(height: AppTokens.spaceSm),
          _LoginOptionCard(
            icon: Icons.cookie_outlined,
            title: l10n.pasteCookie,
            subtitle: l10n.pasteCookieDesc,
            onTap: _pasteCookie,
          ),
        ],
      ),
    );
  }
}

/// 登录方式选项卡片（图标 + 标题 + 说明 + 右侧箭头）。
/// 与 [SourceLoginSheet] 内的同款卡片保持一致样式。
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

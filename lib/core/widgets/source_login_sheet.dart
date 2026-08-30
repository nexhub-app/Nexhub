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
import 'source_login_widgets.dart';

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
    for (final d in source.network?.cookieDomains ?? const <String>[]) {
      final h = d.startsWith('.') ? d.substring(1) : d;
      if (h.isNotEmpty) hosts.add(h);
    }
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
    final auth = context.read<SourceAuthManager>();
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final successMsg = AppLocalizations.of(context).loginSuccess;
    final text = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => const _PasteCookieDialog(),
    );
    if (text == null || text.isEmpty) return;
    for (final host in _hosts()) {
      HttpFetcher.instance.syncCookies(host, text);
    }
    await auth.refreshLoginState(source);
    messenger.showSnackBar(SnackBar(content: Text(successMsg)));
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
    // 是否提供网页登录入口：源声明了 login.url（登录页地址）即视为支持网页
    // 登录。「网页登录」与「粘贴 Cookie」在 login.url 存在时显示，与是否走
    // API Key（sendTokenAs:"key"）无关——两者可并存。完全由源配置驱动，
    // 不写死站点。
    final bool hasWebLogin = source.comments?.login?.url != null;

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
              // 手动 API Key 模式（sendTokenAs:"key"）：受保护请求（收藏/个人页）
              // 需要用户在源站账户设置页获取的 API Key，粘贴后持久化，并即时校验。
              if (source.comments?.login?.sendTokenAs == 'key') ...<Widget>[
                ApiKeyTile(source: source),
                const SizedBox(height: AppTokens.spaceMd),
              ],
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
              if (hasWebLogin && webLoginSupported) ...<Widget>[
                LoginOptionCard(
                  icon: Icons.public,
                  title: l10n.webLogin,
                  subtitle: l10n.webLoginDesc,
                  onTap: () => _webLogin(context),
                ),
                const SizedBox(height: AppTokens.spaceSm),
              ],
              if (hasWebLogin) LoginOptionCard(
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

/// 手动 API Key 输入卡片与登录方式卡片已抽到 [source_login_widgets.dart]，
/// 本文件仅保留底部面板的布局与登录动作（网页登录 / 粘贴 Cookie / 退出）。
/// 两处共用 [ApiKeyTile] 与 [LoginOptionCard]，保证行为一致、避免重复维护。

/// 粘贴 Cookie 输入对话框。
///
/// 控制器由本 State 持有：待对话框（含退场动画）完全卸载后才释放，避免在
/// 退场动画期间释放仍被 [EditableText] 使用的控制器，触发「used after being
/// disposed」并连锁引发 build scope 崩溃。
class _PasteCookieDialog extends StatefulWidget {
  const _PasteCookieDialog();

  @override
  State<_PasteCookieDialog> createState() => _PasteCookieDialogState();
}

class _PasteCookieDialogState extends State<_PasteCookieDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    return AppAlertDialog(
      title: Text(l10n.pasteCookie),
      content: TextField(
        controller: _controller,
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
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: Text(l10n.confirm),
        ),
      ],
    );
  }
}

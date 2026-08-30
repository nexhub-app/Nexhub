/// 源登录全屏页（与 [showSourceLoginSheet] 同款逻辑，面向源管理/镜像页入口）。
///
/// 复用 [SourceAuthManager] 的登录态判定与 [WebViewLoginScreen] 的网页登录，
/// 提供三种操作：
/// - 「网页登录」：仅移动端可见，push [WebViewLoginScreen]，完成后刷新登录态；
/// - 「粘贴 Cookie」：自定义 [Dialog] + 紧凑 [Column]，确认后对源相关 host
///   调 [HttpFetcher.syncCookies] 手动回灌；
/// - 「退出登录」：已登录时可见，经 [SourceAuthManager.logout] 清除 Cookie。
///
/// 桌面端（WebView 不可用）直接隐藏「网页登录」入口，无需改用其他方式。
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
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/source_login_widgets.dart';
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
    // 注意：不在此自动打开 WebView 登录——用户主动点击「网页登录」才拉起，
    // 避免打开源登录界面时意外弹出内置浏览器（产品明确要求不自动打开）。
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
    for (final d in widget.source.network?.cookieDomains ?? const <String>[]) {
      final h = d.startsWith('.') ? d.substring(1) : d;
      if (h.isNotEmpty) hosts.add(h);
    }
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
  ///
  /// 桌面/Web 端布局说明：自定义 [Dialog] + 紧凑 [Column]，避免 [AppAlertDialog]
  /// 在大屏上默认拉伸到 ~80% 屏高的"上下贴边、留白巨大"问题。
  Future<void> _pasteCookie() async {
    final l10n = AppLocalizations.of(context);
    final auth = context.read<SourceAuthManager>();
    final messenger = ScaffoldMessenger.of(context);
    final successMsg = l10n.loginSuccess;
    final text = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => const _PasteCookieDialog(),
    );
    if (text == null || text.isEmpty) return;
    for (final host in _hosts()) {
      HttpFetcher.instance.syncCookies(host, text);
    }
    await auth.refreshLoginState(widget.source);
    messenger.showSnackBar(SnackBar(content: Text(successMsg)));
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
    // WebView 仅在移动端可用；桌面/Web 直接隐藏「网页登录」入口，
    // 避免用户点了再弹"不支持"，体验上更明确。
    final bool webLoginSupported =
        PlatformService.instance.isAndroid || PlatformService.instance.isIOS;
    // 是否提供网页登录入口：源声明了 login.url（登录页地址）即视为支持网页登录。
    // 与底部面板 [showSourceLoginSheet] 同一套判定，完全由源配置驱动，不写死站点。
    final bool hasWebLogin = widget.source.comments?.login?.url != null;
    // 手动 API Key 模式（sendTokenAs:"key"）：纯 API Key 源不声明
    // login.url / checkCookie，因此不显示「网页登录」「粘贴 Cookie」，只显示 API Key 框。
    final bool isApiKey = widget.source.comments?.login?.sendTokenAs == 'key';

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
          // 手动 API Key 模式（sendTokenAs:"key"）：受保护请求（收藏/个人页）需要
          // 用户在源站账户设置页获取的 API Key，粘贴后持久化并即时校验。
          if (isApiKey) ...<Widget>[
            ApiKeyTile(source: widget.source),
            const SizedBox(height: AppTokens.spaceMd),
          ],
          if (hasWebLogin && webLoginSupported) ...<Widget>[
            LoginOptionCard(
              icon: Icons.public,
              title: l10n.webLogin,
              subtitle: l10n.webLoginDesc,
              onTap: _webLogin,
            ),
            const SizedBox(height: AppTokens.spaceSm),
          ],
          if (hasWebLogin) LoginOptionCard(
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

/// 登录方式选项卡片已抽到 [source_login_widgets.dart] 的 [LoginOptionCard]，
/// 本页直接复用，不再重复定义。

/// 粘贴 Cookie 输入对话框（本页专用，保留桌面端紧凑布局）。
///
/// 控制器由本 State 持有：待对话框（含退场动画）完全卸载后才释放，避免在
/// 退场动画期间释放仍被 [EditableText] 使用的控制器，触发「used after
/// being disposed」并连锁引发 build scope 崩溃。
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
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(
        horizontal: AppTokens.spaceLg,
        vertical: AppTokens.spaceXl,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(AppTokens.spaceLg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                l10n.pasteCookie,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: AppTokens.spaceMd),
              TextField(
                controller: _controller,
                autofocus: true,
                minLines: 3,
                maxLines: 4,
                decoration: InputDecoration(
                  labelText: l10n.cookieInputHint,
                  hintText: l10n.cookieHint,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppTokens.radiusMd),
                  ),
                ),
              ),
              const SizedBox(height: AppTokens.spaceLg),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(l10n.cancel),
                  ),
                  const SizedBox(width: AppTokens.spaceSm),
                  FilledButton(
                    onPressed: () =>
                        Navigator.of(context).pop(_controller.text.trim()),
                    child: Text(l10n.confirm),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

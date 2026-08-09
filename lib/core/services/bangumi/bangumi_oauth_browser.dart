/// 内置 WebView（InAppWebView）完成 Bangumi OAuth 授权。
///
/// 用 [InAppWebView] 嵌在 Dialog 中打开授权页，经 [shouldOverrideUrlLoading]
/// 与 [onLoadStart] 截获 `nexhub://oauth/callback?code=...` 自定义协议回跳。
///
/// 相比原先的 [InAppBrowser] 独立浏览器窗口，嵌入式 Dialog 由应用完全掌控生命周期，
/// 不会因系统/浏览器窗口的返回手势导致回调丢失、[loginWithOAuth] 的 Future 一直
/// 挂起（界面一直转圈）。截获到 code 即关闭对话框并回传；用户主动关闭则返回 null。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:nexhub/generated/app_localizations.dart';

/// 打开嵌入式 WebView 完成 Bangumi OAuth 授权，返回授权码；用户主动关闭则返回 null。
///
/// [context] 用于弹出承载 WebView 的 Dialog；[authorizeUrl] 为完整授权页地址；
/// [redirectScheme] 为回跳协议头（如 `nexhub://oauth/callback`），命中即视为授权完成。
Future<String?> openBangumiOAuthBrowser({
  required BuildContext context,
  required String authorizeUrl,
  required String redirectScheme,
}) async {
  final completer = Completer<String?>();

  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      var handled = false; // 是否已截获 code（防重复处理）
      var closed = false; // 对话框是否已关闭（防重复 pop）

      void completeCode(String? code) {
        if (!handled) {
          handled = true;
          if (!completer.isCompleted) completer.complete(code);
        }
      }

      void closeDialog() {
        if (!closed) {
          closed = true;
          Navigator.of(dialogContext).pop();
        }
      }

      void handleUrl(String? url) {
        if (url == null || handled) return;
        if (!url.startsWith(redirectScheme)) return;
        final uri = Uri.tryParse(url);
        if (uri == null) return;
        if (uri.scheme == 'nexhub' &&
            uri.host == 'oauth' &&
            uri.path == '/callback') {
          final code = uri.queryParameters['code'];
          if (code != null && code.isNotEmpty) {
            completeCode(code);
            closeDialog();
          }
        }
      }

      final l10n = AppLocalizations.of(dialogContext);

      return PopScope(
        // canPop=true：允许系统返回 / 关闭按钮关闭对话框（视为取消授权）；
        // 截获 code 后的程序化 pop 也会触发 onPopInvoked，但因 handled 已置位，
        // completeCode(null) 被守卫忽略，不会覆盖已完成的 code。
        canPop: true,
        onPopInvoked: (bool didPop) {
          if (didPop) completeCode(null);
        },
        child: Dialog(
          insetPadding: const EdgeInsets.all(16),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 600,
              maxHeight: MediaQuery.of(dialogContext).size.height * 0.9,
            ),
            child: Column(
              children: <Widget>[
                _OAuthDialogBar(onClose: closeDialog, closeTooltip: l10n.cancel),
                Expanded(
                  child: InAppWebView(
                    initialUrlRequest: URLRequest(url: WebUri(authorizeUrl)),
                    initialSettings: InAppWebViewSettings(
                      javaScriptEnabled: true,
                      useShouldOverrideUrlLoading: true,
                    ),
                    shouldOverrideUrlLoading:
                        (controller, navigationAction) async {
                      handleUrl(navigationAction.request.url?.toString());
                      if (handled) return NavigationActionPolicy.CANCEL;
                      return NavigationActionPolicy.ALLOW;
                    },
                    onLoadStart: (controller, url) {
                      // shouldOverrideUrlLoading 不触发时的兜底（部分 WebView 版本
                      // 对自定义协议 302 重定向不回调 shouldOverrideUrlLoading）。
                      handleUrl(url?.toString());
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );

  // 10 分钟无操作兜底超时（理论上关闭对话框必然先完成 completer）。
  try {
    return await completer.future.timeout(const Duration(minutes: 10));
  } on TimeoutException {
    return null;
  }
}

/// OAuth Dialog 顶部条：关闭按钮 + 标题。
class _OAuthDialogBar extends StatelessWidget {
  const _OAuthDialogBar({required this.onClose, required this.closeTooltip});

  final VoidCallback onClose;
  final String closeTooltip;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Row(
        children: <Widget>[
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: closeTooltip,
            onPressed: onClose,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Bangumi',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        ],
      ),
    );
  }
}

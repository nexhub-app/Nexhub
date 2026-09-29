/// 内嵌 WebView（InAppWebView）完成 OneDrive OAuth 授权。
///
/// 与 Bangumi 同一范式：用 [InAppWebView] 嵌在 Dialog 中打开
/// `login.microsoftonline.com` 授权页，经 [shouldOverrideUrlLoading] 与
/// [onLoadStart] 截获回跳 `http://localhost?code=...`（回跳不会真正发起
/// 请求，截获后立即取消导航）。用户主动关闭对话框则返回 null。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:nexhub/generated/app_localizations.dart';

/// 打开嵌入式 WebView 完成 OneDrive OAuth 授权，返回授权码；用户关闭则返回 null。
///
/// [redirectPrefix] 为回跳前缀（`http://localhost`），命中即视为授权完成。
Future<String?> openOneDriveOAuthBrowser({
  required BuildContext context,
  required String authorizeUrl,
  required String redirectPrefix,
}) async {
  final completer = Completer<String?>();

  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      var handled = false; // 是否已截获 code（防重复处理）
      var closed = false; // 对话框是否已关闭（防重复 pop）
      var progress = 0.0;
      var loading = true;

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
        if (!url.startsWith(redirectPrefix)) return;
        final uri = Uri.tryParse(url);
        if (uri == null) return;
        // 错误回跳（用户拒绝授权等）同样按取消处理。
        final error = uri.queryParameters['error'];
        if (error != null && error.isNotEmpty) {
          completeCode(null);
          closeDialog();
          return;
        }
        final code = uri.queryParameters['code'];
        if (code != null && code.isNotEmpty) {
          completeCode(code);
          closeDialog();
        }
      }

      final l10n = AppLocalizations.of(dialogContext);

      return PopScope(
        canPop: true,
        onPopInvokedWithResult: (bool didPop, Object? result) {
          if (didPop) completeCode(null);
        },
        child: Dialog(
          insetPadding: const EdgeInsets.all(16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 600,
              maxHeight: MediaQuery.of(dialogContext).size.height * 0.9,
            ),
            child: Column(
              children: <Widget>[
                _OAuthDialogBar(
                    onClose: closeDialog, title: l10n.onedriveLoginTitle),
                StatefulBuilder(
                  builder: (ctx, setInner) {
                    return Expanded(
                      child: Column(
                        children: <Widget>[
                          if (loading)
                            LinearProgressIndicator(
                              value: progress > 0 ? progress : null,
                            ),
                          Expanded(
                            child: InAppWebView(
                              initialUrlRequest:
                                  URLRequest(url: WebUri(authorizeUrl)),
                              initialSettings: InAppWebViewSettings(
                                javaScriptEnabled: true,
                                useShouldOverrideUrlLoading: true,
                              ),
                              onProgressChanged: (controller, p) async {
                                setInner(() {
                                  progress = p / 100;
                                  loading = p < 100;
                                });
                              },
                              shouldOverrideUrlLoading:
                                  (controller, navigationAction) async {
                                handleUrl(
                                    navigationAction.request.url?.toString());
                                if (handled) {
                                  return NavigationActionPolicy.CANCEL;
                                }
                                return NavigationActionPolicy.ALLOW;
                              },
                              onLoadStart: (controller, url) {
                                // shouldOverrideUrlLoading 不触发时的兜底（部分 WebView
                                // 版本对 302 重定向不回调 shouldOverrideUrlLoading）。
                                handleUrl(url?.toString());
                              },
                              onLoadStop: (controller, url) async {
                                setInner(() => loading = false);
                                handleUrl(url?.toString());
                              },
                            ),
                          ),
                        ],
                      ),
                    );
                  },
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

/// OAuth Dialog 顶部条：关闭按钮 + 品牌标题，使用主题色，带圆角与阴影。
class _OAuthDialogBar extends StatelessWidget {
  const _OAuthDialogBar({required this.onClose, required this.title});

  final VoidCallback onClose;
  final String title;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: scheme.shadow.withValues(alpha: 0.15),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: <Widget>[
          Icon(Icons.cloud_rounded, color: scheme.onPrimaryContainer, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: scheme.onPrimaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded),
            color: scheme.onPrimaryContainer,
            style: IconButton.styleFrom(
              backgroundColor:
                  scheme.onPrimaryContainer.withValues(alpha: 0.12),
            ),
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

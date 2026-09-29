/// OneDrive 设备码登录对话框 —— 无 WebView 平台（Linux）的兜底登录 UI。
///
/// 展示 user_code 与验证网址（可复制 / 可直接打开系统浏览器），后台等待
/// [waitFlow]（由 [OneDriveAuthService] 轮询 token 端点）完成：成功返回
/// true；失败在框内展示错误并允许关闭；用户关闭对话框返回 false
/// （后台轮询不中断，此后完成授权仍会自动登录）。
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../theme/app_tokens.dart';

/// 弹出设备码登录对话框。返回是否在对话框内完成了授权。
Future<bool> showOneDriveDeviceCodeDialog({
  required BuildContext context,
  required String userCode,
  required String verificationUri,
  required Future<void> Function() waitFlow,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _DeviceCodeDialog(
      userCode: userCode,
      verificationUri: verificationUri,
      waitFlow: waitFlow,
    ),
  );
  return result ?? false;
}

class _DeviceCodeDialog extends StatefulWidget {
  const _DeviceCodeDialog({
    required this.userCode,
    required this.verificationUri,
    required this.waitFlow,
  });

  final String userCode;
  final String verificationUri;
  final Future<void> Function() waitFlow;

  @override
  State<_DeviceCodeDialog> createState() => _DeviceCodeDialogState();
}

class _DeviceCodeDialogState extends State<_DeviceCodeDialog> {
  bool _waiting = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _waitFlow();
  }

  Future<void> _waitFlow() async {
    try {
      await widget.waitFlow();
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _waiting = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _openPage() async {
    final uri = Uri.tryParse(widget.verificationUri);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on Object {
      // 无法拉起浏览器：用户可手动复制网址
    }
  }

  void _copyCode() {
    Clipboard.setData(ClipboardData(text: widget.userCode));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context).onedriveCopied)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(l10n.onedriveDeviceCodeTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(l10n.onedriveDeviceCodeIntro(widget.verificationUri)),
          const SizedBox(height: AppTokens.spaceMd),
          Container(
            padding: const EdgeInsets.all(AppTokens.spaceMd),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(AppTokens.radiusMd),
            ),
            child: Center(
              child: SelectableText(
                widget.userCode,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 2,
                ),
              ),
            ),
          ),
          const SizedBox(height: AppTokens.spaceMd),
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _openPage,
                  icon: const Icon(Icons.open_in_new_rounded, size: 18),
                  label: Text(l10n.onedriveOpenPage),
                ),
              ),
              const SizedBox(width: AppTokens.spaceSm),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _copyCode,
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  label: Text(l10n.onedriveCopy),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppTokens.spaceMd),
          if (_waiting)
            Row(
              children: <Widget>[
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: AppTokens.spaceSm),
                Expanded(child: Text(l10n.onedriveWaitingAuth)),
              ],
            )
          else ...<Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.error_rounded,
                    size: 18, color: theme.colorScheme.error),
                const SizedBox(width: AppTokens.spaceSm),
                Expanded(
                  child: Text(
                    _error ?? l10n.onedriveAuthFailed,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.error),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppTokens.spaceSm),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(l10n.cancel),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

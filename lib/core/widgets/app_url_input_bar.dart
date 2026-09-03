import 'package:flutter/material.dart';
import '../theme/app_tokens.dart';

/// 统一 URL 输入条：文本框 + 提交按钮 + loading 态。
///
/// 供 browse_network / browse_web_scrape / source_import / collect_api_import 复用，
/// 避免各 feature 重复实现「输入 URL → 提交」这一高频交互。
class AppUrlInputBar extends StatelessWidget {
  final TextEditingController? controller;
  final String hintText;
  final String? labelText;
  final ValueChanged<String> onSubmit;
  final bool isLoading;
  final String submitLabel;
  final TextInputAction textInputAction;

  const AppUrlInputBar({
    super.key,
    this.controller,
    required this.hintText,
    this.labelText,
    required this.onSubmit,
    this.isLoading = false,
    required this.submitLabel,
    this.textInputAction = TextInputAction.go,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: TextField(
            controller: controller,
            decoration: InputDecoration(
              hintText: hintText,
              labelText: labelText,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: AppTokens.spaceMd,
                vertical: AppTokens.spaceSm,
              ),
              prefixIcon: const Icon(Icons.link),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppTokens.radiusMd),
              ),
            ),
            keyboardType: TextInputType.url,
            textInputAction: textInputAction,
            onSubmitted: isLoading ? null : (v) => onSubmit(v.trim()),
          ),
        ),
        const SizedBox(width: AppTokens.spaceSm),
        SizedBox(
          width: 100,
          child: FilledButton(
            style: FilledButton.styleFrom(
              minimumSize: const Size(100, 44),
              padding:
                  const EdgeInsets.symmetric(horizontal: AppTokens.spaceSm),
            ),
            onPressed: isLoading
                ? null
                : () => onSubmit(controller?.text.trim() ?? ''),
            child: isLoading
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(submitLabel),
          ),
        ),
      ],
    );
  }
}

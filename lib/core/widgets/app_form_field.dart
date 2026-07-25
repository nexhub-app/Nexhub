import 'package:flutter/material.dart';
import '../theme/app_tokens.dart';

/// 统一表单字段：标签 + 输入框。聚焦时边框变主色加粗、底色轻微上染、标签变主色，
/// 平滑过渡，与 [AppSearchField] 手感一致。
///
/// 供 browse_add_article_feed / collect_api_import / source_import 复用，
/// 统一标签样式（textTheme.labelMedium + onSurfaceVariant），禁止各 feature 内联重复。
class AppFormField extends StatefulWidget {
  final String label;
  final String? hint;
  final TextEditingController? controller;
  final TextInputType? keyboardType;
  final int maxLines;
  final Widget? prefixIcon;
  final Widget? suffixIcon;
  final ValueChanged<String>? onChanged;

  const AppFormField({
    super.key,
    required this.label,
    this.hint,
    this.controller,
    this.keyboardType,
    this.maxLines = 1,
    this.prefixIcon,
    this.suffixIcon,
    this.onChanged,
  });

  @override
  State<AppFormField> createState() => _AppFormFieldState();
}

class _AppFormFieldState extends State<AppFormField> {
  final FocusNode _focus = FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focused = _focus.hasFocus;
    _focus.addListener(_onFocusChanged);
  }

  void _onFocusChanged() {
    if (mounted) setState(() => _focused = _focus.hasFocus);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChanged);
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color borderColor = _focused ? scheme.primary : scheme.outline;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        AnimatedDefaultTextStyle(
          duration: AppTokens.durFast,
          curve: Curves.easeOutCubic,
          style: Theme.of(context)
                  .textTheme
                  .labelMedium
                  ?.copyWith(
                    color:
                        _focused ? scheme.primary : scheme.onSurfaceVariant,
                  ) ??
              const TextStyle(),
          child: Text(widget.label),
        ),
        const SizedBox(height: AppTokens.spaceSm),
        AnimatedContainer(
          duration: AppTokens.durFast,
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppTokens.radiusMd),
            border: Border.all(
              color: borderColor,
              width: _focused ? 2 : 1,
            ),
            color: _focused
                ? scheme.primary.withValues(alpha: 0.06)
                : null,
          ),
          child: TextField(
            controller: widget.controller,
            focusNode: _focus,
            keyboardType: widget.keyboardType,
            maxLines: widget.maxLines,
            onChanged: widget.onChanged,
            decoration: InputDecoration(
              hintText: widget.hint,
              prefixIcon: widget.prefixIcon,
              suffixIcon: widget.suffixIcon,
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: AppTokens.spaceSm,
                vertical: AppTokens.spaceXs + 4,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

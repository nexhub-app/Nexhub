/// 源编辑全字段页（独立页面）。
///
/// 以 JSON 形式展示该源的全部配置（site / parser / routes / selectors /
/// category / homeSections / filters / antiHotlinking / webviewConfig /
/// comments / network / announcement …），用户可在此修改**所有模块的所有字段**，
/// 保存即整体覆盖原源。id 被锁定，避免误改 id 产生重复源。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:provider/provider.dart';

import '../../../core/models/plugin_config.dart';
import '../../../core/services/source_repository.dart';
import '../../../core/theme/app_tokens.dart';

/// 源编辑页：接收 [PluginConfig source]，以可编辑 JSON 呈现全部字段。
class SourceEditScreen extends StatefulWidget {
  final PluginConfig source;

  const SourceEditScreen({super.key, required this.source});

  @override
  State<SourceEditScreen> createState() => _SourceEditScreenState();
}

class _SourceEditScreenState extends State<SourceEditScreen> {
  late final TextEditingController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    // 美化输出：2 空格缩进，便于阅读与编辑。
    _controller = TextEditingController(
      text: const JsonEncoder.withIndent('  ').convert(widget.source.toJson()),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 保存：解析 JSON → 校验 → 整体替换源。
  Future<void> _save() async {
    final l10n = AppLocalizations.of(context);
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    try {
      final map = jsonDecode(text) as Map<String, dynamic>;
      // 锁定 id，避免误改 id 产生重复源或丢失原源。
      map['id'] = widget.source.id;
      final config = PluginConfig.fromJson(map);
      final errors = config.validate();
      if (errors.isNotEmpty) {
        if (mounted) {
          setState(() => _error = '${l10n.sourceEditInvalidJson}\n'
              '${errors.join('\n')}');
        }
        return;
      }
      context.read<SourceRepository>().replaceSource(config);
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.sourceEditSaved)),
        );
      }
    } on Object catch (e) {
      if (mounted) {
        setState(() => _error = '${l10n.sourceEditInvalidJson}\n$e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.sourceEdit),
        actions: <Widget>[
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save_outlined),
            label: Text(l10n.save),
          ),
          const SizedBox(width: AppTokens.spaceSm),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(AppTokens.spaceMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              l10n.sourceEditJsonHint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppTokens.spaceSm),
            Expanded(
              child: TextField(
                controller: _controller,
                maxLines: null,
                expands: true,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.all(12),
                ),
              ),
            ),
            if (_error != null) ...<Widget>[
              const SizedBox(height: AppTokens.spaceSm),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(AppTokens.radiusSm),
                ),
                child: Text(
                  _error!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

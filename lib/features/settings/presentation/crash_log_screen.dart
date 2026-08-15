/// 崩溃日志查看页（D 阶段）。
///
/// 展示 [CrashLog] 落盘的运行期异常记录（Flutter 错误 + 未捕获异常），
/// 支持刷新 / 复制全部 / 清空。空态提示用户先复现问题。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nexhub/generated/app_localizations.dart';

import '../../../core/debug/crash_log.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_animations.dart';
import '../../../core/widgets/app_empty_state.dart';

class CrashLogScreen extends StatefulWidget {
  const CrashLogScreen({super.key});

  @override
  State<CrashLogScreen> createState() => _CrashLogScreenState();
}

class _CrashLogScreenState extends State<CrashLogScreen> {
  String _log = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final text = await CrashLog.read();
    if (mounted) {
      setState(() {
        _log = text;
        _loading = false;
      });
    }
  }

  Future<void> _copyAll(AppLocalizations l10n) async {
    if (_log.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _log));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.crashLogCopied)),
      );
    }
  }

  Future<void> _clearAll(AppLocalizations l10n) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.crashLogClear),
        content: Text(l10n.confirmActionHint),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.confirm),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await CrashLog.clear();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.crashLogCleared)),
      );
      await _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.crashLogTitle),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: l10n.refresh,
            onPressed: _reload,
          ),
          IconButton(
            icon: const Icon(Icons.copy_all_outlined),
            tooltip: l10n.crashLogCopyAll,
            onPressed: _log.isEmpty ? null : () => _copyAll(l10n),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: l10n.crashLogClear,
            onPressed: _log.isEmpty ? null : () => _clearAll(l10n),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _log.isEmpty
              ? AppEmptyState(
                  icon: Icons.check_circle_outline,
                  message: l10n.crashLogEmpty,
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(AppTokens.spaceMd),
                  child: AppSheetBody(
                    child: SelectableText(
                      _log,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        height: 1.5,
                      ),
                    ),
                  ),
                ),
    );
  }
}

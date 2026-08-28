/// 源登录相关共享组件：手动 API Key 输入框与登录方式选项卡片。
///
/// 底部面板 [showSourceLoginSheet] 与全屏页 [SourceLoginScreen] 共用同一套
/// 渲染逻辑，避免两处各自维护导致行为漂移。所有显隐均由源 `login` 声明驱动
/// （sendTokenAs / url / checkCookie），不写死任何站点。
library;

import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:provider/provider.dart';

import '../auth/source_auth_manager.dart';
import '../auth/source_key_store.dart';
import '../models/plugin_config.dart';
import '../theme/app_tokens.dart';
import 'app_card.dart';

/// 手动 API Key 输入卡片（`sendTokenAs:"key"` 模式专用）。
///
/// 用户在源站账户设置页复制 API Key 粘贴进来：保存即持久化到 [SourceKeyStore]，
/// 并经 [SourceAuthManager.refreshLoginState]（带 `Key <apiKey>` 头探测
/// `checkUrl`）即时校验有效性，反馈「有效/无效」。源即插件：仅按 `login` 声明
/// 渲染，不写死任何站点。
class ApiKeyTile extends StatefulWidget {
  final PluginConfig source;

  const ApiKeyTile({super.key, required this.source});

  @override
  State<ApiKeyTile> createState() => _ApiKeyTileState();
}

class _ApiKeyTileState extends State<ApiKeyTile> {
  late final TextEditingController _controller;
  final ValueNotifier<bool> _saved = ValueNotifier<bool>(false);
  final ValueNotifier<String?> _status = ValueNotifier<String?>(null);
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final param = widget.source.comments?.login?.apiKeyParam ?? 'apiKey';
    final existing = SourceKeyStore.get(widget.source.id, param);
    _controller = TextEditingController(text: existing ?? '');
    _saved.value = existing != null;
  }

  @override
  void dispose() {
    _controller.dispose();
    _saved.dispose();
    _status.dispose();
    super.dispose();
  }

  Future<void> _save(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final param = widget.source.comments?.login?.apiKeyParam ?? 'apiKey';
    final value = _controller.text.trim();
    if (value.isEmpty) {
      await SourceKeyStore.clear(widget.source.id, param);
      _saved.value = false;
      _status.value = null;
      if (context.mounted) {
        context.read<SourceAuthManager>().refreshLoginState(widget.source);
      }
      return;
    }
    setState(() => _saving = true);
    await SourceKeyStore.set(widget.source.id, param, value);
    _saved.value = true;
    if (!context.mounted) return;
    // 即时校验：带 Key 头探测 checkUrl（如 /api/v2/user 一类接口），
    // 401/403 或网络失败 → 无效；2xx + 选择器命中 → 有效。
    final ok = await context
        .read<SourceAuthManager>()
        .refreshLoginState(widget.source);
    _status.value = ok ? 'valid' : 'invalid';
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ok ? l10n.apiKeyValid : l10n.apiKeyInvalid)),
      );
    }
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ThemeData theme = Theme.of(context);
    return AppCard(
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.spaceMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(l10n.apiKeyTitle, style: theme.textTheme.labelLarge),
            const SizedBox(height: AppTokens.spaceXxs),
            Text(
              l10n.apiKeyHint,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: AppTokens.spaceSm),
            TextField(
              controller: _controller,
              decoration: InputDecoration(
                hintText: l10n.apiKeyPlaceholder,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppTokens.radiusMd),
                ),
                suffixIcon: ValueListenableBuilder<bool>(
                  valueListenable: _saved,
                  builder: (_, saved, __) => saved
                      ? Icon(Icons.check_circle,
                          color: theme.colorScheme.primary)
                      : const SizedBox.shrink(),
                ),
              ),
            ),
            const SizedBox(height: AppTokens.spaceSm),
            FilledButton.icon(
              onPressed: _saving ? null : () => _save(context),
              icon: const Icon(Icons.save),
              label: Text(l10n.apiKeySave),
            ),
            ValueListenableBuilder<String?>(
              valueListenable: _status,
              builder: (_, st, __) => st == null
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(top: AppTokens.spaceSm),
                      child: Text(
                        st == 'valid' ? l10n.apiKeyValid : l10n.apiKeyInvalid,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: st == 'valid'
                              ? theme.colorScheme.primary
                              : theme.colorScheme.error,
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 登录方式选项卡片（图标 + 标题 + 说明 + 右侧箭头）。
/// 底部面板与全屏页共用，保持样式一致。
class LoginOptionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const LoginOptionCard({
    super.key,
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
                const SizedBox(height: AppTokens.spaceXxs),
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

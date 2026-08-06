/// 添加订阅页 —— 独立全页（非底部弹窗）。
///
/// 布局：
/// - AppBar：标题「添加订阅」+ 返回按钮
/// - 订阅地址输入框（全宽，带前缀图标）
/// - 添加订阅按钮
/// - RSSHub 路由推荐列表（按 [moduleType] 显示不同类型的专有路由）
library;

import 'dart:async' show unawaited;
import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:provider/provider.dart';

import '../../../core/models/plugin_config.dart';
import '../../../core/rss/rsshub_routes.dart';
import '../../../core/rss/rss_manager.dart';
import '../../../core/settings/rsshub_config.dart';
import '../../../core/theme/app_tokens.dart';

class RssAddSubscriptionScreen extends StatefulWidget {
  /// 绑定的模块类型
  final SourceType? moduleType;
  const RssAddSubscriptionScreen({super.key, this.moduleType});

  @override
  State<RssAddSubscriptionScreen> createState() => _RssAddSubscriptionScreenState();
}

class _RssAddSubscriptionScreenState extends State<RssAddSubscriptionScreen> {
  final TextEditingController _urlController = TextEditingController();
  String _rssHubBase = 'https://rsshub.app';
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    RssHubConfigStore().load().then((cfg) {
      if (mounted) setState(() => _rssHubBase = cfg.effectiveUrl);
    });
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _submit(RssManager manager) async {
    final l10n = AppLocalizations.of(context);
    final url = _urlController.text.trim();
    if (url.isEmpty || _submitting) return;
    // 标记提交中：禁用按钮并显示进度，避免重复点击与「卡死」错觉。
    setState(() => _submitting = true);
    try {
      // 先即时入库并退出，避免抓取 / 解析阻塞主线程导致「停顿很久才能添加」。
      final feed = await manager.addFeed(
        url: url,
        title: url,
        moduleType: widget.moduleType,
      );
      if (!mounted) return;
      Navigator.of(context).pop(); // 返回并自动刷新列表
      // 后台异步补全标题 / 描述，不阻塞 UI。
      unawaited(manager.discoverAndUpdate(feed));
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.importFailed(e.toString()))),
      );
    }
  }

  void _useRoute(String basePath, RssManager manager) {
    final fullUrl = '$_rssHubBase$basePath';
    _urlController.text = fullUrl;
    // 只填入输入框，不自动提交——让用户可以编辑 URL 中的占位符（如 :id）
    // 后手动点击「添加订阅」按钮保存。
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final manager = context.read<RssManager>();
    final routes = routesForType(widget.moduleType, l10n);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.addSubscription)),
      body: ListView(
        padding: const EdgeInsets.all(AppTokens.spaceLg),
        children: <Widget>[
          // ── 订阅地址区域 ──
          Text(l10n.subscribeAddressLabel,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  )),
          const SizedBox(height: AppTokens.spaceSm),

          TextField(
            controller: _urlController,
            decoration: InputDecoration(
              hintText: l10n.addSubscription,
              prefixIcon: const Icon(Icons.link),
              border: const OutlineInputBorder(),
            ),
            keyboardType: TextInputType.url,
            autofocus: true,
            onSubmitted: (_) => _submit(manager),
          ),
          const SizedBox(height: AppTokens.spaceMd),

          // 添加按钮（全宽）
          FilledButton(
            onPressed: _submitting ? null : () => _submit(manager),
            child: _submitting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(l10n.addSubscription),
          ),

          // ── RSSHub 路由推荐 ──
          if (routes.isNotEmpty) ...<Widget>[
            const SizedBox(height: AppTokens.spaceXl),
            Text(l10n.rsshubRoutesTitle,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    )),
            const SizedBox(height: AppTokens.spaceSm),
            ...routes.map((route) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.add, size: 20),
                  title: Text(route.label),
                  subtitle: Text(
                    route.path,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                  trailing: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: scheme.outline),
                    ),
                    child: Icon(Icons.add, size: 16, color: scheme.onSurfaceVariant),
                  ),
                  onTap: () => _useRoute(route.path, manager),
                )),
          ],

          const SizedBox(height: AppTokens.spaceXl),
        ],
      ),
    );
  }
}

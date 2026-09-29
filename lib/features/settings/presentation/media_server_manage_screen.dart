/// 媒体服务器管理页：服务器列表（在线状态 / 账号）、添加、重命名、
/// 重新登录与删除。
///
/// - 列表项状态经 `MediaServerAuth.statusOf` 异步探测（在线 / 离线 /
/// 需重新登录），服务器增删后自动重查；
/// - 删除仅弹普通确认：本机配置与凭证被清除，服务器端数据不受影响；
/// - token 失效（401）不崩溃，列表项标「需重新登录」引导重登。
library;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:material_ui/material_ui.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:provider/provider.dart';

import '../../../core/navigation/app_page_route.dart';
import '../../../core/services/media_server/media_server_auth.dart';
import '../../../core/services/media_server/media_server_models.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/utils/app_haptics.dart';
import '../../../core/widgets/app_glass_bar.dart';
import 'media_server_add_screen.dart';
import 'widgets/settings_widgets.dart';

class MediaServerManageScreen extends StatefulWidget {
  const MediaServerManageScreen({super.key});

  @override
  State<MediaServerManageScreen> createState() =>
      _MediaServerManageScreenState();
}

class _MediaServerManageScreenState extends State<MediaServerManageScreen> {
  /// 服务器状态缓存：null = 检测中。
  final Map<String, MediaServerStatus?> _status =
      <String, MediaServerStatus?>{};

  /// 已发起状态检测的服务器 id 集合快照（防重复请求）。
  List<String> _statusRequestedFor = const <String>[];

  void _refreshStatuses(List<MediaServerInfo> servers) {
    final ids = servers.map((s) => s.id).toList(growable: false);
    if (listEquals(ids, _statusRequestedFor)) return;
    _statusRequestedFor = ids;
    _status.removeWhere((k, _) => !ids.contains(k));
    final auth = context.read<MediaServerAuth>();
    for (final s in servers) {
      if (!s.loggedIn || _status.containsKey(s.id)) continue;
      _status[s.id] = null;
      auth.statusOf(s.id).then((v) {
        if (mounted) setState(() => _status[s.id] = v);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final auth = context.watch<MediaServerAuth>();
    _refreshStatuses(auth.servers);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.mediaServerSettings),
        actions: <Widget>[
          IconButton(
            tooltip: l10n.mediaServerAddServer,
            icon: const Icon(Icons.add_rounded),
            onPressed: _openAdd,
          ),
        ],
      ),
      body: auth.servers.isEmpty
          ? _EmptyState(onAdd: _openAdd)
          : ListView(
              padding: context.pageInset(AppTokens.spaceLg),
              children: <Widget>[
                SettingsGroup(
                  children: <Widget>[
                    for (final s in auth.servers)
                      _serverTile(context, s, l10n),
                  ],
                ),
              ],
            ),
    );
  }

  Widget _serverTile(
    BuildContext context,
    MediaServerInfo s,
    AppLocalizations l10n,
  ) {
    final theme = Theme.of(context);
    final account = s.loggedIn
        ? l10n.mediaServerLoggedInAs(s.username)
        : l10n.mediaServerNotLoggedIn;
    return SettingsTile(
      icon: Icons.dns_rounded,
      title: s.name,
      subtitle: '${s.baseUrl} · $account',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _statusChip(theme, s, l10n),
          const SizedBox(width: AppTokens.spaceXs),
          PopupMenuButton<String>(
            onSelected: (v) => _onMenu(v, s),
            itemBuilder: (ctx) => <PopupMenuEntry<String>>[
              PopupMenuItem<String>(
                value: 'rename',
                child: ListTile(
                  leading: const Icon(Icons.edit_rounded),
                  title: Text(l10n.mediaServerRename),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem<String>(
                value: 'relogin',
                child: ListTile(
                  leading: const Icon(Icons.login_rounded),
                  title: Text(l10n.mediaServerRelogin),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuDivider(),
              PopupMenuItem<String>(
                value: 'delete',
                child: ListTile(
                  leading: Icon(
                    Icons.delete_outline_rounded,
                    color: theme.colorScheme.error,
                  ),
                  title: Text(
                    l10n.mediaServerDelete,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      onTap: () => AppHaptics.selectionClick(),
    );
  }

  Widget _statusChip(
    ThemeData theme,
    MediaServerInfo s,
    AppLocalizations l10n,
  ) {
    String text;
    Color bg;
    Color fg;
    if (!s.loggedIn) {
      text = l10n.mediaServerNotLoggedIn;
      bg = theme.colorScheme.surfaceContainerHighest;
      fg = theme.colorScheme.onSurfaceVariant;
    } else {
      switch (_status[s.id]) {
        case MediaServerStatus.ok:
          text = l10n.mediaServerStatusOnline;
          bg = theme.colorScheme.primaryContainer;
          fg = theme.colorScheme.onPrimaryContainer;
        case MediaServerStatus.needRelogin:
          text = l10n.mediaServerStatusNeedRelogin;
          bg = theme.colorScheme.errorContainer;
          fg = theme.colorScheme.onErrorContainer;
        case MediaServerStatus.offline:
          text = l10n.mediaServerStatusOffline;
          bg = theme.colorScheme.surfaceContainerHighest;
          fg = theme.colorScheme.onSurfaceVariant;
        case null:
          text = l10n.mediaServerStatusChecking;
          bg = theme.colorScheme.surfaceContainerHighest;
          fg = theme.colorScheme.onSurfaceVariant;
      }
    }
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTokens.spaceSm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppTokens.radiusSm),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(color: fg),
      ),
    );
  }

  Future<void> _onMenu(String action, MediaServerInfo s) async {
    switch (action) {
      case 'rename':
        await _rename(s);
      case 'relogin':
        await _openRelogin(s);
      case 'delete':
        await _delete(s);
    }
  }

  Future<void> _openAdd() async {
    AppHaptics.selectionClick();
    await Navigator.of(context).push(
      AppPageRoute<void>(builder: (_) => const MediaServerAddScreen()),
    );
  }

  Future<void> _openRelogin(MediaServerInfo s) async {
    await Navigator.of(context).push(
      AppPageRoute<void>(builder: (_) => MediaServerAddScreen(existing: s)),
    );
  }

  Future<void> _rename(MediaServerInfo s) async {
    final l10n = AppLocalizations.of(context);
    final controller = TextEditingController(text: s.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.mediaServerRenameTitle),
        content: TextField(
          controller: controller,
          autofocus: true,
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: Text(l10n.confirm),
          ),
        ],
      ),
    );
    if (name == null) return;
    if (!mounted) return;
    try {
      await context.read<MediaServerAuth>().renameServer(s.id, name);
    } on Object catch (e) {
      _showError(e);
    }
  }

  Future<void> _delete(MediaServerInfo s) async {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.mediaServerDeleteTitle),
        content: Text(l10n.mediaServerDeleteBody(s.name)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
              foregroundColor: theme.colorScheme.onError,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.mediaServerDelete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    try {
      await context.read<MediaServerAuth>().removeServer(s.id);
    } on Object catch (e) {
      _showError(e);
    }
  }

  void _showError(Object e) {
    final l10n = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.mediaServerOperationFailed('$e'))),
    );
  }
}

/// 空状态：尚未添加服务器。
class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.spaceXl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.dns_rounded, size: 56, color: theme.colorScheme.outline),
            const SizedBox(height: AppTokens.spaceMd),
            Text(l10n.mediaServerEmptyTitle, style: theme.textTheme.titleMedium),
            const SizedBox(height: AppTokens.spaceSm),
            Text(
              l10n.mediaServerEmptyHint,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: AppTokens.spaceLg),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add_rounded),
              label: Text(l10n.mediaServerAddServer),
            ),
          ],
        ),
      ),
    );
  }
}

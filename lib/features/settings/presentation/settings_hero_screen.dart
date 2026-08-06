import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../../../core/settings/general_settings.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_animations.dart';
import '../../../core/widgets/app_alert_dialog.dart';
import 'package:nexhub/generated/app_localizations.dart';

/// Hero 图片配置页：增删 / 网络 / 本地。
class SettingsHeroScreen extends StatefulWidget {
  const SettingsHeroScreen({super.key});

  @override
  State<SettingsHeroScreen> createState() => _SettingsHeroScreenState();
}

class _SettingsHeroScreenState extends State<SettingsHeroScreen> {
  late List<String> _urls;

  @override
  void initState() {
    super.initState();
    _urls = List<String>.from(GeneralSettingsStore.instance.settings.heroImageUrls);
    final store = GeneralSettingsStore.instance;
    if (!store.loaded) {
      store.load().then((s) {
        if (mounted) {
          setState(() => _urls = List<String>.from(s.heroImageUrls));
        }
      });
    }
  }

  Future<void> _save(List<String> next) async {
    setState(() => _urls = next);
    final s = GeneralSettingsStore.instance.settings.copyWith(heroImageUrls: next);
    await GeneralSettingsStore.instance.save(s);
  }

  Future<void> _addFromUrl() async {
    final l10n = AppLocalizations.of(context);
    final controller = TextEditingController();
    final String? url = await showDialog<String>(
      context: context,
      builder: (ctx) => AppAlertDialog(
        title: Text(l10n.heroUrlDialogTitle),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(hintText: l10n.heroUrlFieldHint),
          autofocus: true,
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(l10n.confirm),
          ),
        ],
      ),
    );
    if (url != null && url.isNotEmpty) {
      await _save(<String>[..._urls, url]);
    }
  }

  Future<void> _addFromDevice() async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return;
    final String? path = result.files.single.path;
    if (path == null) return;
    await _save(<String>[..._urls, path]);
  }

  void _remove(int index) {
    final next = List<String>.from(_urls)..removeAt(index);
    _save(next);
  }

  void _move(int from, int to) {
    if (to < 0 || to >= _urls.length) return;
    final next = List<String>.from(_urls);
    final String item = next.removeAt(from);
    next.insert(to, item);
    _save(next);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.heroSettingsTitle)),
      body: Entrance(
        offset: 10,
        fromScale: 0.985,
        duration: AppTokens.durBase,
        child: Column(
          children: <Widget>[
            Expanded(
              child: _urls.isEmpty
                  ? _Empty(scheme: scheme, hint: l10n.heroEmptyHint)
                  : ListView.separated(
                        padding: const EdgeInsets.all(AppTokens.spaceLg),
                        itemCount: _urls.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(height: AppTokens.spaceSm),
                        itemBuilder: (context, i) {
                          final String url = _urls[i];
                          return _HeroItem(
                            url: url,
                            onRemove: () => _remove(i),
                            onMoveUp: i > 0 ? () => _move(i, i - 1) : null,
                            onMoveDown:
                                i < _urls.length - 1 ? () => _move(i, i + 1) : null,
                          );
                        },
                      ),
            ),
            SafeArea(
              top: false,
              child: Container(
                padding: const EdgeInsets.all(AppTokens.spaceLg),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLow,
                  border: Border(
                    top: BorderSide(color: scheme.outlineVariant),
                  ),
                ),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: FilledButton.tonalIcon(
                        onPressed: _addFromUrl,
                        icon: const Icon(Icons.link),
                        label: Text(l10n.heroAddFromUrl),
                      ),
                    ),
                    const SizedBox(width: AppTokens.spaceSm),
                    Expanded(
                      child: FilledButton.tonalIcon(
                        onPressed: _addFromDevice,
                        icon: const Icon(Icons.photo_library_outlined),
                        label: Text(l10n.heroAddFromDevice),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeroItem extends StatelessWidget {
  final String url;
  final VoidCallback onRemove;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;

  const _HeroItem({
    required this.url,
    required this.onRemove,
    required this.onMoveUp,
    required this.onMoveDown,
  });

  bool _isLocal(String s) =>
      s.startsWith('/') ||
      (Platform.isWindows && s.contains(':\\')) ||
      s.startsWith('file://');

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    final ImageProvider img = _isLocal(url)
        ? FileImage(File(url.startsWith('file://') ? url.substring(7) : url))
        : NetworkImage(url);

    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: <Widget>[
          ClipRRect(
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(AppTokens.radiusMd),
              bottomLeft: Radius.circular(AppTokens.radiusMd),
            ),
            child: SizedBox(
              width: 96,
              height: 72,
              child: Image(
                image: img,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) =>
                    Container(color: scheme.surfaceContainerHighest),
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppTokens.spaceMd,
                vertical: AppTokens.spaceSm,
              ),
              child: Text(
                url,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
          Column(
            children: <Widget>[
              IconButton(
                onPressed: onMoveUp,
                icon: const Icon(Icons.keyboard_arrow_up),
                tooltip: '↑',
                visualDensity: VisualDensity.compact,
              ),
              IconButton(
                onPressed: onMoveDown,
                icon: const Icon(Icons.keyboard_arrow_down),
                tooltip: '↓',
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          IconButton(
            onPressed: onRemove,
            icon: const Icon(Icons.delete_outline),
            tooltip: l10n.heroRemoveTooltip,
            color: scheme.error,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  final ColorScheme scheme;
  final String hint;

  const _Empty({required this.scheme, required this.hint});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.spaceXl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.collections_outlined,
              size: 64,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.4),
            ),
            const SizedBox(height: AppTokens.spaceMd),
            Text(
              hint,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
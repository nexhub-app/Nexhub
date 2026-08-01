library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:provider/provider.dart';

import '../../../core/models/plugin_config.dart';
import '../../../core/scraper/collect_api_parser.dart';
import '../../../core/scraper/http_fetcher.dart';
import '../../../core/services/source_library_bookmarks.dart';
import '../../../core/services/source_repository.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_error_state.dart';
import '../../../core/widgets/app_form_field.dart';
import '../../../core/widgets/app_loading_indicator.dart';
import '../../../core/widgets/app_segmented_tabs.dart';
import '../../../core/widgets/app_url_input_bar.dart';
import 'collect_api_import_screen.dart';
import 'package:nexhub/core/navigation/app_page_route.dart';

enum _ImportTab { url, file, json, library }

/// 源导入页：支持 URL / 本地文件 / 手动 JSON 三种方式，校验后保存。
class SourceImportScreen extends StatefulWidget {
  const SourceImportScreen({super.key});

  @override
  State<SourceImportScreen> createState() => _SourceImportScreenState();
}

class _SourceImportScreenState extends State<SourceImportScreen> {
  _ImportTab _tab = _ImportTab.url;
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _jsonController = TextEditingController();
  final TextEditingController _libraryUrlController = TextEditingController();
  bool _loading = false;
  String? _error;
  /// 解析出的待导入源（批量，可能含小说/媒体/漫画）。
  List<PluginConfig> _previews = const <PluginConfig>[];

  /// 批量模式下勾选导入的源下标集合。
  Set<int> _selectedPreviewIndices = const <int>{};

  bool _collectApiDetected = false;
  String? _pickedFileName;

  @override
  void dispose() {
    _urlController.dispose();
    _jsonController.dispose();
    _libraryUrlController.dispose();
    super.dispose();
  }

  Future<void> _tryParse(String raw) async {
    final text = raw.trim();
    if (text.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
      _previews = const <PluginConfig>[];
      _selectedPreviewIndices = const <int>{};
    });
    try {
      // 统一批量解析：支持单源 / JSON 数组（小说+媒体+漫画混排）/
      // Legado 书源 / 包装对象 / NDJSON / XML，一次导入多种类型。
      final list = SourceRepository.parseMixedSources(text);
      if (mounted) {
        if (list.isEmpty) {
          setState(() {
            _error = AppLocalizations.of(context).sourceUnrecognized;
            _loading = false;
          });
        } else {
          setState(() {
            _previews = list;
            _selectedPreviewIndices = <int>{
              for (int i = 0; i < list.length; i++) i
            };
            _loading = false;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  Future<void> _importFromUrl() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;
    if (CollectApiParser.looksLikeCollectApi(url)) {
      if (mounted) setState(() => _collectApiDetected = true);
      return;
    }
    setState(() => _loading = true);
    try {
      final text = await HttpFetcher.instance.getHtml(url);
      await _tryParse(text);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  /// 库导入：拉取源库订阅地址内容，复用与 URL 导入相同的解析与预览流程。
  Future<void> _fetchLibrary() async {
    final url = _libraryUrlController.text.trim();
    if (url.isEmpty) return;
    setState(() => _loading = true);
    try {
      final text = await HttpFetcher.instance.getHtml(url);
      await _tryParse(text);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['json'],
    );
    final path = result?.files.single.path;
    if (path == null) return;
    _pickedFileName = result?.files.single.name;
    final text = await File(path).readAsString();
    _jsonController.text = text;
    await _tryParse(text);
  }

  void _retry() {
    if (_tab == _ImportTab.url) {
      _importFromUrl();
    } else if (_tab == _ImportTab.library) {
      _fetchLibrary();
    } else if (_tab == _ImportTab.json) {
      _tryParse(_jsonController.text);
    } else {
      _pickFile();
    }
  }

  void _save() {
    if (_previews.isEmpty) return;
    final selected = _selectedPreviewIndices
        .where((i) => i >= 0 && i < _previews.length)
        .map((i) => _previews[i])
        .toList();
    if (selected.isEmpty) return;
    final repo = context.read<SourceRepository>();
    for (final c in selected) {
      repo.addSource(c);
    }
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          AppLocalizations.of(context)
              .sourceImportResult(selected.length, _previews.length),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.importSource)),
      body: ListView(
        padding: const EdgeInsets.all(AppTokens.spaceLg),
        children: <Widget>[
          AppSegmentedTabs<_ImportTab>(
            selected: <_ImportTab>{_tab},
            onSelectionChanged: (Set<_ImportTab> s) =>
                setState(() => _tab = s.first),
            segments: <ButtonSegment<_ImportTab>>[
              ButtonSegment<_ImportTab>(
                  value: _ImportTab.url, label: Text(l10n.sourceImportFromUrl)),
              ButtonSegment<_ImportTab>(
                  value: _ImportTab.file, label: Text(l10n.sourceImportFromFile)),
              ButtonSegment<_ImportTab>(
                  value: _ImportTab.json, label: Text(l10n.sourceImportFromJson)),
              ButtonSegment<_ImportTab>(
                  value: _ImportTab.library, label: Text(l10n.importLibraryTab)),
            ],
          ),
          const SizedBox(height: AppTokens.spaceLg),
          if (_tab == _ImportTab.url) ...<Widget>[
            AppUrlInputBar(
              controller: _urlController,
              hintText: l10n.sourceImportUrlHint,
              submitLabel: l10n.import,
              isLoading: _loading && _tab == _ImportTab.url,
              onSubmit: (_) => _importFromUrl(),
            ),
            if (_collectApiDetected) ...<Widget>[
              const SizedBox(height: AppTokens.spaceMd),
              _collectApiHint(l10n),
            ],
          ] else if (_tab == _ImportTab.file) ...<Widget>[
            FilledButton.icon(
              onPressed: _loading ? null : _pickFile,
              icon: const Icon(Icons.file_open),
              label: Text(l10n.sourceImportFilePicker),
            ),
            if (_pickedFileName != null) ...<Widget>[
              const SizedBox(height: AppTokens.spaceMd),
              Text(
                _pickedFileName!,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ] else if (_tab == _ImportTab.json) ...<Widget>[
            AppFormField(
              label: l10n.sourceImportJsonHint,
              hint: l10n.sourceImportJsonHint,
              controller: _jsonController,
              maxLines: 10,
            ),
            const SizedBox(height: AppTokens.spaceMd),
            FilledButton.icon(
              onPressed: _loading ? null : () => _tryParse(_jsonController.text),
              icon: const Icon(Icons.check_circle_outline),
              label: Text(l10n.sourceImportValidate),
            ),
          ] else ...<Widget>[
            // 库导入：拉取源库订阅地址 + 常用书签
            AppUrlInputBar(
              controller: _libraryUrlController,
              hintText: l10n.libraryUrlHint,
              submitLabel: l10n.fetchLibrary,
              isLoading: _loading && _tab == _ImportTab.library,
              onSubmit: (_) => _fetchLibrary(),
            ),
            const SizedBox(height: AppTokens.spaceSm),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _loading
                    ? null
                    : () {
                        final url = _libraryUrlController.text.trim();
                        if (url.isEmpty) return;
                        context.read<SourceLibraryBookmarks>().add(url);
                      },
                icon: const Icon(Icons.bookmark_add_outlined, size: 20),
                label: Text(l10n.saveLibrary),
              ),
            ),
            const SizedBox(height: AppTokens.spaceMd),
            _buildLibraryBookmarks(l10n, scheme),
          ],
          const SizedBox(height: AppTokens.spaceLg),
          _buildPreview(l10n, scheme),
        ],
      ),
    );
  }

  Widget _collectApiHint(AppLocalizations l10n) => AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(l10n.sourceImportCollectApiDetected,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppTokens.spaceMd),
            FilledButton(
              onPressed: () => Navigator.of(context).push(
                AppPageRoute<void>(
                  builder: (_) => const CollectApiImportScreen(),
                ),
              ),
              child: Text(l10n.sourceImportCollectApiRedirect),
            ),
          ],
        ),
      );

  /// 库导入书签列表：点击填入地址并拉取，长按或删除图标移除。
  Widget _buildLibraryBookmarks(AppLocalizations l10n, ColorScheme scheme) {
    final bookmarks = context.watch<SourceLibraryBookmarks>();
    final urls = bookmarks.all();
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(l10n.libraryBookmarks,
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AppTokens.spaceSm),
          if (urls.isEmpty)
            Text(
              l10n.libraryEmpty,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            )
          else
            ...urls.map((u) => ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    u,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  leading: Icon(Icons.book_outlined,
                      size: 20, color: scheme.onSurfaceVariant),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, size: 20),
                    tooltip: l10n.delete,
                    onPressed: () => bookmarks.remove(u),
                  ),
                  onTap: () {
                    _libraryUrlController.text = u;
                    _fetchLibrary();
                  },
                )),
        ],
      ),
    );
  }

  Widget _buildPreview(AppLocalizations l10n, ColorScheme scheme) {
    if (_loading) {
      return AppLoadingIndicator(message: l10n.loading);
    }
    if (_error != null) {
      return AppErrorState(
        message: _error!,
        onRetry: _retry,
        retryLabel: l10n.retry,
      );
    }
    if (_previews.isEmpty) return const SizedBox.shrink();

    // 单源：沿用原卡片样式
    if (_previews.length == 1) {
      final c = _previews.first;
      return AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(c.name, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppTokens.spaceXs),
            Text(
              c.site.baseUrl,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: AppTokens.spaceSm),
            Chip(
              label: Text(_typeLabel(c.type, l10n)),
              visualDensity: VisualDensity.compact,
            ),
            const SizedBox(height: AppTokens.spaceSm),
            Row(
              children: <Widget>[
                Icon(Icons.check_circle, color: scheme.primary, size: 18),
                const SizedBox(width: AppTokens.spaceXs),
                Text(l10n.sourceImportValid),
              ],
            ),
            const SizedBox(height: AppTokens.spaceLg),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _save,
                child: Text(l10n.save),
              ),
            ),
          ],
        ),
      );
    }

    // 批量：勾选列表 + 按类型导入
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            l10n.batchImportHint(_previews.length),
            style: Theme.of(context).textTheme.labelMedium,
          ),
          const SizedBox(height: AppTokens.spaceSm),
          ..._previews.asMap().entries.map((e) {
            final i = e.key;
            final c = e.value;
            return CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              value: _selectedPreviewIndices.contains(i),
              onChanged: (v) => setState(() {
                final set = <int>{..._selectedPreviewIndices};
                if (v == true) {
                  set.add(i);
                } else {
                  set.remove(i);
                }
                _selectedPreviewIndices = set;
              }),
              title: Text(c.name),
              subtitle: Text(
                '${c.site.baseUrl}  ·  ${_typeLabel(c.type, l10n)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              controlAffinity: ListTileControlAffinity.leading,
            );
          }),
          const SizedBox(height: AppTokens.spaceMd),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _selectedPreviewIndices.isEmpty ? null : _save,
              child: Text(
                l10n.importSelectedCount(_selectedPreviewIndices.length),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _typeLabel(SourceType type, AppLocalizations l10n) {
    return switch (type) {
      SourceType.novelSource => l10n.sourceTypeNovel,
      SourceType.animeSource => l10n.sourceTypeAnime,
      SourceType.mangaSource => l10n.sourceTypeManga,
    };
  }
}

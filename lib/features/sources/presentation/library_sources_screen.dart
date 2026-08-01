/// 源库查看页：拉取某个 [SourceLibrary] 的 manifest，列出全部源（按 [SourceType] 分组
/// 显示），用户可勾选要导入的源，点底部「导入选中」一次性写入 [SourceRepository]。
///
/// 与 [SourceImportScreen] 的「库导入」区别：此处只拉一次 manifest，不预抓所有 rawUrl；
/// 真正导入时再按用户勾选按需抓取，避免大库全量拉取浪费流量与时间。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/models/plugin_config.dart';
import '../../../core/scraper/http_fetcher.dart';
import '../../../core/services/source_library_subscription.dart';
import '../../../core/services/source_repository.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_error_state.dart';
import '../../../core/widgets/app_loading_indicator.dart';

/// 源库查看页：列出库内全部源供用户勾选导入。
class LibrarySourcesScreen extends StatefulWidget {
  final SourceLibrary library;

  const LibrarySourcesScreen({super.key, required this.library});

  @override
  State<LibrarySourcesScreen> createState() => _LibrarySourcesScreenState();
}

class _LibrarySourcesScreenState extends State<LibrarySourcesScreen> {
  bool _loading = true;
  bool _importing = false;
  String? _error;

  /// manifest 解析出的条目（原始，不含 rawUrl 内容）。
  List<_LibEntry> _entries = const <_LibEntry>[];

  /// 选中的条目下标集合。
  Set<int> _selectedIndices = const <int>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 拉取库 manifest 并解析成 [_LibEntry] 列表（不抓 rawUrl，按需时再抓）。
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _entries = const <_LibEntry>[];
      _selectedIndices = const <int>{};
    });
    try {
      final text = await HttpFetcher.instance.getHtml(widget.library.url);
      final dynamic decoded = jsonDecode(text);
      final List<Map<String, dynamic>> raw;
      if (decoded is Map<String, dynamic> && decoded['sources'] is List) {
        raw = (decoded['sources'] as List)
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      } else if (decoded is List) {
        raw = decoded
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      } else {
        raw = const <Map<String, dynamic>>[];
      }
      final entries = <_LibEntry>[];
      for (final e in raw) {
        entries.add(_LibEntry.fromManifest(e, base: widget.library.url));
      }
      if (!mounted) return;
      setState(() {
        _entries = entries;
        // 默认全选
        _selectedIndices = <int>{for (int i = 0; i < entries.length; i++) i};
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// 把选中的条目按需拉取 rawUrl，解析为 [PluginConfig] 后批量入库。
  Future<void> _importSelected() async {
    if (_selectedIndices.isEmpty) return;
    final selected = _selectedIndices
        .where((i) => i >= 0 && i < _entries.length)
        .map((i) => _entries[i])
        .toList();
    setState(() => _importing = true);
    final repo = context.read<SourceRepository>();
    int success = 0;
    int failed = 0;
    for (final entry in selected) {
      try {
        List<PluginConfig> parsed = const <PluginConfig>[];
        // 优先用 rawUrl 抓远端源 JSON；若没有 rawUrl 或抓失败，回退用条目本身解析。
        if (entry.rawUrl != null && entry.rawUrl!.isNotEmpty) {
          try {
            final t = await HttpFetcher.instance.getHtml(entry.rawUrl!);
            parsed = SourceRepository.parseMixedSources(t);
          } on Object {
            // 抓 rawUrl 失败时回退到条目本身
          }
        }
        if (parsed.isEmpty) {
          parsed = SourceRepository.parseMixedSources(jsonEncode(entry.raw));
        }
        if (parsed.isEmpty) {
          failed++;
          continue;
        }
        // 单个源文件里可能打包了多个源，全部入库。
        for (final cfg in parsed) {
          repo.addSource(cfg);
        }
        success++;
      } on Object {
        failed++;
      }
    }
    if (!mounted) return;
    setState(() => _importing = false);
    final l10n = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          l10n.libraryImportResult(success, selected.length, failed),
        ),
      ),
    );
    if (success > 0) {
      Navigator.of(context).pop();
    }
  }

  /// 外链打开 rawUrl（备用，方便用户手动复制）。
  Future<void> _openRawUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri != null && uri.scheme.startsWith('http')) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.library.name),
        actions: <Widget>[
          IconButton(
            tooltip: l10n.retry,
            icon: const Icon(Icons.refresh),
            onPressed: _loading || _importing ? null : _load,
          ),
        ],
      ),
      body: _buildBody(l10n, scheme),
      bottomNavigationBar: _selectedIndices.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(AppTokens.spaceMd),
                child: FilledButton.icon(
                  onPressed:
                      _importing || _selectedIndices.isEmpty ? null : _importSelected,
                  icon: _importing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.file_download_outlined),
                  label: Text(l10n.importSelectedCount(_selectedIndices.length)),
                ),
              ),
            ),
    );
  }

  Widget _buildBody(AppLocalizations l10n, ColorScheme scheme) {
    if (_loading) {
      return AppLoadingIndicator(message: l10n.loading);
    }
    if (_error != null) {
      return AppErrorState(
        message: _error!,
        onRetry: _load,
        retryLabel: l10n.retry,
      );
    }
    if (_entries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppTokens.spaceXl),
          child: Text(
            l10n.libraryEmpty,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    // 按类型分组。manifest 里 type 字段可能有多种写法（官方库用短词
    // `anime`/`manga`/`novel`，Legado 老源用 `bookSource`，旧版用
    // `animeSource` 等长词），统一归到三类后再排序展示，未识别则归「未分类」。
    final groups = <String, List<int>>{};
    for (int i = 0; i < _entries.length; i++) {
      final t = _canonicalType(_entries[i].type);
      groups.putIfAbsent(t, () => <int>[]).add(i);
    }
    final orderedTypes = <String>[
      if (groups.containsKey('novelSource')) 'novelSource',
      if (groups.containsKey('animeSource')) 'animeSource',
      if (groups.containsKey('mangaSource')) 'mangaSource',
      if (groups.containsKey('unknown')) 'unknown',
    ];

    return ListView(
      padding: const EdgeInsets.all(AppTokens.spaceMd),
      children: <Widget>[
        for (final t in orderedTypes) ...<Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppTokens.spaceXs,
              vertical: AppTokens.spaceSm,
            ),
            child: Text(
              _groupLabel(t, l10n),
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: scheme.primary,
                  ),
            ),
          ),
          AppCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: <Widget>[
                for (int j = 0; j < groups[t]!.length; j++) ...<Widget>[
                  if (j > 0)
                    Divider(
                      height: 1,
                      color: scheme.outlineVariant.withValues(alpha: 0.3),
                    ),
                  _buildRow(groups[t]![j], l10n, scheme),
                ],
              ],
            ),
          ),
          const SizedBox(height: AppTokens.spaceMd),
        ],
      ],
    );
  }

  Widget _buildRow(int index, AppLocalizations l10n, ColorScheme scheme) {
    final entry = _entries[index];
    final selected = _selectedIndices.contains(index);
    return CheckboxListTile(
      value: selected,
      onChanged: (v) => setState(() {
        final s = <int>{..._selectedIndices};
        if (v == true) {
          s.add(index);
        } else {
          s.remove(index);
        }
        _selectedIndices = s;
      }),
      controlAffinity: ListTileControlAffinity.leading,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppTokens.spaceSm,
        vertical: AppTokens.spaceXs,
      ),
      title: Text(
        entry.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodyLarge,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (entry.rawUrl != null && entry.rawUrl!.isNotEmpty)
            InkWell(
              onTap: () => _openRawUrl(entry.rawUrl!),
              child: Text(
                entry.rawUrl!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.primary,
                      decoration: TextDecoration.underline,
                    ),
              ),
            ),
          Text(
            'id: ${entry.id}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }

  String _groupLabel(String type, AppLocalizations l10n) {
    switch (type) {
      case 'novelSource':
        return l10n.sourceCategoryNovel;
      case 'animeSource':
        return l10n.sourceCategoryMedia;
      case 'mangaSource':
        return l10n.sourceCategoryComic;
      default:
        return l10n.sourceTypeOther;
    }
  }

  /// 把 manifest 里的 type 字段统一归到三类长词，未知则返回 'unknown'。
  /// 兼容官方短词（`anime`/`manga`/`novel`）、Legado 老词（`bookSource`）
  /// 以及长词（`animeSource`/`mangaSource`/`novelSource`）。
  static String _canonicalType(String? raw) {
    final s = (raw ?? '').trim().toLowerCase();
    switch (s) {
      case 'anime':
      case 'animeSource':
      case 'media':
        return 'animeSource';
      case 'manga':
      case 'mangaSource':
      case 'comic':
      case 'manhua':
        return 'mangaSource';
      case 'novel':
      case 'novelSource':
      case 'booksource':
      case 'bookSource':
      case 'book':
        return 'novelSource';
      default:
        return 'unknown';
    }
  }
}

/// 单条库条目（解析 manifest 后，未抓 rawUrl）。
class _LibEntry {
  final String id;
  final String name;
  final String? rawUrl;
  final String? type;
  final Map<String, dynamic> raw;

  _LibEntry({
    required this.id,
    required this.name,
    required this.rawUrl,
    required this.type,
    required this.raw,
  });

  /// 从 manifest 条目构造。
  ///
  /// 字段名尽量宽容：不同社区库的清单写法不一致，除官方的 `rawUrl` 外，
  /// 还兼容 `url` / `file` / `path` / `download`；相对路径按 [base]（index.json
  /// 自身地址）解析成绝对地址，否则按需抓取时会 404。
  factory _LibEntry.fromManifest(Map<String, dynamic> m, {String? base}) {
    final id = (m['id'] ?? m['bookSourceUrl'] ?? '').toString();
    final name = (m['name'] ?? m['bookSourceName'] ?? id).toString();
    final rawUrl = _resolveRawUrl(m, base);
    final type = (m['type'] ?? m['sourceType']) as String?;
    return _LibEntry(
      id: id,
      name: name,
      rawUrl: rawUrl,
      type: type,
      raw: m,
    );
  }

  /// 取出条目里的源文件地址并补全为绝对 URL；没有可用地址时返回 null
  /// （此时条目本身就是一份完整源配置，走回退解析）。
  ///
  /// 注意 `url` / `path` 在「完整源配置」里通常是站点主页而非源文件，
  /// 因此这些备用键只在指向 `.json` 时才当作源文件地址；`rawUrl` 是官方
  /// 清单的约定字段，无条件采用。
  static String? _resolveRawUrl(Map<String, dynamic> m, String? base) {
    String? pick;
    final official = m['rawUrl'];
    if (official is String && official.trim().isNotEmpty) {
      pick = official.trim();
    } else {
      for (final key in const <String>['url', 'file', 'path', 'download']) {
        final v = m[key];
        if (v is! String || v.trim().isEmpty) continue;
        final s = v.trim();
        final pathPart = s.split('?').first.split('#').first.toLowerCase();
        if (!pathPart.endsWith('.json')) continue;
        pick = s;
        break;
      }
    }
    if (pick == null) return null;
    if (pick.startsWith('http://') || pick.startsWith('https://')) return pick;
    final baseUri = base == null ? null : Uri.tryParse(base);
    if (baseUri == null) return null;
    return baseUri.resolve(pick).toString();
  }
}

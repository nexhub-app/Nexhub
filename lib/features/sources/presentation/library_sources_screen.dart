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

  /// 已安装版本映射（id → 已装 version）；缺失即未安装。用于「源库」展示
  /// 当前版本、标记可更新（库版本 > 已装版本）。
  Map<String, int> _installedVersions = const <String, int>{};

  /// 是否存在「库版本 > 已装版本」的可更新源（控制 AppBar「一键更新」显示）。
  bool get _hasUpdatable => _entries.any((e) {
        final ins = _installedVersions[e.id];
        return ins != null && ins < e.version;
      });

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
      // 比对已安装版本，标记可更新；默认只勾选「未安装」或「可更新」的条目，
      // 已是最新的源不预勾选，避免误触「导入选中」重复写库。
      //
      // ⚠️ id 归一化：不同源库的 manifest 写法不一致——
      //   有的用「类型/名称」（如 novel/novel_linovelb），有的只用名称
      //   （如 novel_linovelib），有的用 bookSourceUrl（完整 URL）。
      //   PluginConfig.id 取的是源 JSON 本身的 id 字段（通常无类型前缀）。
      //   因此比对时需依次尝试：精确匹配 → 去前缀 → 按名称兜底。
      final repo = context.read<SourceRepository>();
      final installed = <String, int>{};
      final selected = <int>{};
      for (int i = 0; i < entries.length; i++) {
        final e = entries[i];
        // 1) 精确匹配
        var cfg = repo.getById(e.id);
        // 2) 去类型前缀（novel/novel_xxx → novel_xxx）
        if (cfg == null && e.id.contains('/')) {
          cfg = repo.getById(e.id.substring(e.id.lastIndexOf('/') + 1));
        }
        // 3) 按名称兜底（manifest 的 name 与 PluginConfig.name 一致时）
        if (cfg == null && e.name.isNotEmpty) {
          cfg = repo.all.where((c) => c.name == e.name).firstOrNull;
        }
        if (cfg != null) {
          installed[e.id] = cfg.version;
          if (cfg.version < e.version) selected.add(i); // 可更新
        } else {
          selected.add(i); // 未安装 → 默认勾选导入
        }
      }
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _installedVersions = installed;
        _selectedIndices = selected;
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

  /// 一键更新全部可更新的源：只勾选「库版本 > 已装版本」的条目并立即导入。
  Future<void> _updateAll() async {
    final updatable = <int>{};
    for (int i = 0; i < _entries.length; i++) {
      final e = _entries[i];
      final ins = _installedVersions[e.id];
      if (ins != null && ins < e.version) updatable.add(i);
    }
    if (updatable.isEmpty) return;
    setState(() => _selectedIndices = updatable);
    await _importSelected();
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
          if (_hasUpdatable)
            IconButton(
              tooltip: l10n.libraryUpdateAll,
              icon: const Icon(Icons.system_update_alt),
              onPressed: _loading || _importing ? null : _updateAll,
            ),
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
    final installed = _installedVersions[entry.id];
    final updateAvailable = installed != null && installed < entry.version;
    final versionText = installed == null
        ? '库 v${entry.version} · ${l10n.libraryNotInstalled}'
        : l10n.libraryVersion(entry.version, installed);
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
      secondary: updateAvailable
          ? Chip(
              label: Text(
                l10n.libraryUpdateAvailable,
                style: TextStyle(
                  color: scheme.onPrimaryContainer,
                  fontSize: 11,
                ),
              ),
              backgroundColor: scheme.primaryContainer,
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              side: BorderSide.none,
            )
          : null,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppTokens.spaceSm,
        vertical: AppTokens.spaceXs,
      ),
      title: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              entry.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ),
          const SizedBox(width: AppTokens.spaceXs),
          _ageChip(context, scheme, entry.ageRating),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            versionText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: updateAvailable
                      ? scheme.primary
                      : scheme.onSurfaceVariant,
                  fontWeight:
                      updateAvailable ? FontWeight.w600 : FontWeight.normal,
                ),
          ),
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

  /// 年龄分级徽章：general=中性灰 / teen=琥珀 / mature=红（与设置页一致）。
  Widget _ageChip(BuildContext context, ColorScheme scheme, SourceAgeRating rating) {
    final l10n = AppLocalizations.of(context);
    final (Color bg, Color fg, String label) = switch (rating) {
      SourceAgeRating.general => (
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
        l10n.ageRatingGeneral,
      ),
      SourceAgeRating.teen => (
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
        l10n.ageRatingTeen,
      ),
      SourceAgeRating.mature => (
        scheme.errorContainer,
        scheme.onErrorContainer,
        l10n.ageRatingMature,
      ),
    };
    return Chip(
      label: Text(label, style: const TextStyle(fontSize: 11)),
      backgroundColor: bg,
      labelStyle: TextStyle(color: fg, fontSize: 11),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      side: BorderSide.none,
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
  final int version;
  final SourceAgeRating ageRating;
  final Map<String, dynamic> raw;

  _LibEntry({
    required this.id,
    required this.name,
    required this.rawUrl,
    required this.type,
    this.version = 1,
    this.ageRating = SourceAgeRating.general,
    required this.raw,
  });

  /// 把 manifest 里的 version 规范为 int（缺省 1）。兼容 int / 数字 / "12" /
  /// "1.3.0"（取首段）。
  static int _coerceVersion(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) {
      final first = v.split('.').first;
      return int.tryParse(first) ?? 1;
    }
    return 1;
  }

  /// 从 manifest 条目构造。
  ///
  /// 字段名尽量宽容：不同社区库的清单写法不一致，除官方的 `rawUrl` 外，
  /// 还兼容 `url` / `file` / `path` / `download`；相对路径按 [base]（index.json
  /// 自身地址）解析成绝对地址，否则按需抓取时会 404。同时解析 `version` 与
  /// `ageRating`，供「源库」展示等级与版本、以及一键更新判断。
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
      version: _coerceVersion(m['version']),
      ageRating: SourceAgeRating.parse(m['ageRating']),
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

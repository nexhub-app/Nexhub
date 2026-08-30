/// 源管理页 —— 新版设计：Tab 式布局（源列表 / 源库 / 网络导入 / 本地导入）。
///
/// 支持按类型过滤，不同模块的源管理不互通。
/// 「源库」Tab 负责订阅第三方源仓库（index.json），并可进入库内挑选单个源导入。
library;

import 'dart:io';
import 'dart:convert';
import 'dart:ui' show lerpDouble;

import 'package:path/path.dart' as p;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:provider/provider.dart';

import '../../../core/auth/source_auth_manager.dart';
import '../../../core/models/plugin_config.dart';
import '../../../core/services/config_loader.dart';
import '../../../core/services/source_library_subscription.dart';
import '../../../core/services/source_repository.dart';
import '../../../core/utils/app_haptics.dart';
import '../../../core/local/local_content_manager.dart'
    show isAndroidSafUri;
import '../../../core/local/saf_bridge.dart'
    show listFolderSourceFilesSaf, pickFolderPath, readSourceText, safBaseName;
import '../../../core/utils/app_log.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_segmented_tabs.dart';
import '../../../core/widgets/app_empty_state.dart';
import '../../../core/widgets/app_url_input_bar.dart';
import '../../../core/widgets/unified_source_tile.dart';
import 'source_mirror_screen.dart';
import 'source_network_override_screen.dart';
import 'source_login_screen.dart';
import 'source_edit_screen.dart';
import 'package:nexhub/core/navigation/app_page_route.dart';
import 'package:nexhub/core/widgets/app_alert_dialog.dart';
import 'library_sources_screen.dart';
import 'collect_api_import_screen.dart';
import 'package:url_launcher/url_launcher.dart';

enum _SourceTab { list, library, network, local }

/// 源管理主页面。
class SourceManagerScreen extends StatefulWidget {
  /// 可选的类型过滤（null = 显示全部类型，用于设置页总入口）。
  final SourceType? filterType;

  /// 嵌入模式：为 [true] 时不包裹 Scaffold/AppBar/FAB，
  /// 仅输出 Tab 栏 + 内容区 Column，供各模块首页的 sourcesBody 使用。
  final bool embedded;

  /// 预览模式变化回调。嵌入模式下，外层 [LibraryShell] 用此回调
  /// 在预览期间隐藏自己的 FAB（避免遮挡底部的确认条）。
  final void Function(bool isPreview)? onPreviewModeChanged;

  const SourceManagerScreen({
    super.key,
    this.filterType,
    this.embedded = false,
    this.onPreviewModeChanged,
  });

  @override
  State<SourceManagerScreen> createState() => _SourceManagerScreenState();
}

class _SourceManagerScreenState extends State<SourceManagerScreen> {
  _SourceTab _tab = _SourceTab.list;
  final TextEditingController _urlController = TextEditingController();

  // 是否显示隐藏源
  bool _showHidden = false;

  // 网络导入状态
  bool _networkLoading = false;
  String? _networkError;
  PluginConfig? _networkPreview;
  List<String> _validationErrors = <String>[];
  final TextEditingController _collectApiUrlController =
      TextEditingController();

  // 因年龄限制被拦截（未进入导入预览）的 18+ 源数量，用于提示横幅。
  int _importAgeBlockedCount = 0;

  // 本地导入状态
  String? _pickedFileName;
  List<_ImportPreviewItem> _previewItems = <_ImportPreviewItem>[];
  Set<int> _selectedPreviewIndices = <int>{};
  bool _previewMode = false;

  // 类型筛选时被跳过的其他类型源数量（用于预览提示横幅）
  int _skippedByTypeCount = 0;

  // 库（library）tab 状态
  final TextEditingController _libraryUrlController = TextEditingController();
  final TextEditingController _libraryNameController = TextEditingController();
  bool _librarySubscribing = false;

  @override
  void dispose() {
    _urlController.dispose();
    _libraryUrlController.dispose();
    _libraryNameController.dispose();
    _collectApiUrlController.dispose();
    super.dispose();
  }

  // ── 源列表 ──
  List<PluginConfig> _getFilteredSources(SourceRepository repo) {
    var sources = repo.all;
    if (widget.filterType != null) {
      sources = sources.where((c) => c.type == widget.filterType).toList();
    }
    // 隐藏源默认不显示，除非用户开启「显示隐藏源」
    if (!_showHidden) {
      sources = sources.where((c) => !c.isHidden).toList();
    }
    // 年龄限制开启时隐藏 18+ 源（无法管理 / 无法浏览）
    sources = sources.where((c) => !repo.isAgeBlocked(c)).toList();
    return sources;
  }

  /// 按分类 Tab 过滤源（项 7）。
  /// [category] 对应 Tab 索引：0=novel, 1=media, 2=comic。
  List<PluginConfig> _getCategorySources(
    List<PluginConfig> sources,
    int category,
  ) {
    switch (category) {
      case 0:
        return sources.where((c) => c.type == SourceType.novelSource).toList();
      case 1:
        // 媒体 Tab：animeSource（无 type 的旧源默认归 media，但 PluginConfig
        // 强制 type 非空，因此此处无需额外兜底）。
        return sources.where((c) => c.type == SourceType.animeSource).toList();
      case 2:
        return sources.where((c) => c.type == SourceType.mangaSource).toList();
      default:
        return sources;
    }
  }

  // ── 网络导入逻辑 ──
  Future<void>_fetchFromUrl() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;
    final repo = context.read<SourceRepository>();

    setState(() {
      _networkLoading = true;
      _networkError = null;
      _networkPreview = null;
      _validationErrors = <String>[];
      _skippedByTypeCount = 0;
      _importAgeBlockedCount = 0;
    });

    try {
      // 这里需要 HttpFetcher，但为避免循环依赖，用基础的 HttpClient
      final httpClient = HttpClient();
      final request = await httpClient.getUrl(Uri.parse(url));
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      httpClient.close();

      // 统一批量解析：URL 返回合并 JSON（小说+媒体+漫画）也能一次导入。
      final configs = SourceRepository.parseMixedSources(text);

      if (!mounted) return;
      if (configs.isEmpty) {
        setState(() {
          _networkError = AppLocalizations.of(context).sourceUnrecognized;
          _networkLoading = false;
        });
        return;
      }

      // 专属类型页：只保留匹配类型的源，其他类型直接忽略。
      final matched = widget.filterType == null
          ? configs
          : configs.where((c) => c.type == widget.filterType).toList();
      final skippedByType = configs.length - matched.length;

      // 年龄限制开启时，18+ 源不可导入
      final ageBlocked = matched.where((c) => repo.isAgeBlocked(c)).toList();
      final importable = matched.where((c) => !repo.isAgeBlocked(c)).toList();
      _importAgeBlockedCount = ageBlocked.length;

      if (importable.isEmpty) {
        final l10n = AppLocalizations.of(context);
        setState(() {
          _networkError = ageBlocked.isNotEmpty
              ? l10n.ageRestrictionImportMatureBlocked
              : (skippedByType > 0
                  ? l10n.importNoMatchingType(
                      _typeLabel(widget.filterType!, l10n),
                      skippedByType,
                    )
                  : l10n.sourceUnrecognized);
          _networkLoading = false;
        });
        return;
      }

      if (importable.length == 1) {
        setState(() {
          _networkPreview = importable.first;
          _validationErrors = const <String>[];
          _networkLoading = false;
          _skippedByTypeCount = skippedByType;
        });
      } else {
        // 多源：复用本地导入的批量勾选预览
        setState(() {
          _previewItems = importable
              .map((c) => _ImportPreviewItem(
                    path: '',
                    fileName: url,
                    config: c,
                    type: c.type,
                    isValid: true,
                  ))
              .toList();
          _selectedPreviewIndices = <int>{
            for (int i = 0; i < importable.length; i++) i
          };
          _previewMode = true;
          _networkLoading = false;
          _skippedByTypeCount = skippedByType;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _networkError = e.toString();
          _networkLoading = false;
        });
      }
    }
  }

  void _openCollectApiImport() {
    final url = _collectApiUrlController.text.trim();
    Navigator.of(context).push(
      AppPageRoute<void>(
        builder: (_) => CollectApiImportScreen(
          initialUrl: url.isEmpty ? null : url,
        ),
      ),
    );
  }

  void _saveNetworkSource() {
    if (_networkPreview == null || _validationErrors.isNotEmpty) return;
    context.read<SourceRepository>().addSource(_networkPreview!);
    setState(() {
      _urlController.clear();
      _networkPreview = null;
      _validationErrors = <String>[];
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context).sourceImportSaved)),
    );
  }

  // ── 本地导入逻辑（支持文件 + 文件夹 + 预览勾选）──
  Future<void> _pickLocalFile() async {
    // 支持选择单个文件或文件夹
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['json', 'txt', 'xml'],
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty) return;

    _processPickedPaths(result.files.map((f) => f.path).whereType<String>().toList());
  }

  /// 选择文件夹导入。
  Future<void> _pickLocalFolder() async {
    // 安卓必须用 pickFolderPath()（内部走 saf.pickDirectory 拿 content:// tree URI）；
    // 直接 getDirectoryPath 在分区存储下返回真实路径，dart:io 列不出文件 → 误报空。
    final dirPath = await pickFolderPath();
    if (dirPath == null) {
      AppLog.instance.i('[源导入] 未选择文件夹（picker 返回 null）');
      return;
    }
    // 记录原始路径前缀 + 是否 SAF，便于在「运行日志」定位（之前日志为空的根因：
    // 空结果分支从未打日志，导致静默误报「未找到源文件」）。
    AppLog.instance.i('[源导入] 选目录 raw='
        '${dirPath.length > 90 ? '${dirPath.substring(0, 90)}…' : dirPath} '
        'isSaf=${isAndroidSafUri(dirPath)}');

    // 扫描目录下的所有支持的源文件。
    // Android 上 getDirectoryPath 返回 content:// SAF tree URI，dart:io 的
    // Directory 无法列举/读取，必须走 SAF 枚举；桌面则走真实文件系统。
    List<String> files;
    try {
      if (isAndroidSafUri(dirPath)) {
        files = await listFolderSourceFilesSaf(dirPath);
        AppLog.instance.i('[源导入] SAF 枚举得到 ${files.length} 个源文件');
      } else {
        final dir = Directory(dirPath);
        final exists = await dir.exists();
        AppLog.instance.i('[源导入] 文件系统模式 dir.exists=$exists');
        if (!exists) {
          // 目录不存在/不可访问（安卓分区存储下真实路径常读不到）→ 如实上报，
          // 不再静默 return 造成「未找到源文件」误报。
          AppLog.instance.e('[源导入] 目录不存在或不可访问: $dirPath');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(AppLocalizations.of(context).folderScanFailed)),
            );
          }
          return;
        }
        files = <String>[];
        await for (final entity in dir.list(recursive: true, followLinks: false)) {
          if (entity is File) {
            final ext = p.extension(entity.path).toLowerCase().replaceFirst('.', '');
            if (const ['json', 'txt', 'xml'].contains(ext)) {
              files.add(entity.path);
            }
          }
        }
        AppLog.instance.i('[源导入] 文件系统枚举得到 ${files.length} 个源文件');
      }
    } on Object catch (e, st) {
      // SAF 列举失败（权限不足 / URI 无效 / SecurityException）必须如实上报，
      // 不能静默当作「未找到源文件」。
      AppLog.instance.eWithStack('[源导入] 文件夹扫描失败 $dirPath', e, st);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).folderScanFailed)),
        );
      }
      return;
    }

    if (files.isEmpty) {
      AppLog.instance.w('[源导入] 扫描结果为空（未找到源文件）dirPath='
          '${dirPath.length > 90 ? '${dirPath.substring(0, 90)}…' : dirPath}');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).noLocalSource)),
        );
      }
      return;
    }

    _processPickedPaths(files);
  }

  /// 处理选中的文件路径列表：解析预览 → 弹出勾选对话框 → 导入选中项。
  Future<void> _processPickedPaths(List<String> paths) async {
    final repo = context.read<SourceRepository>();
    final items = <_ImportPreviewItem>[];
    _importAgeBlockedCount = 0;
    for (final path in paths) {
      final fileName =
          isAndroidSafUri(path) ? safBaseName(path) : p.basename(path);
      try {
        final text = await readSourceText(path);
        // 统一批量解析：单 PluginConfig / JSON 数组（小说+媒体+漫画混排）/
        // 通用书源格式 / XML 等，一个文件可解析出多个源。
        final configs = SourceRepository.parseMixedSources(text);
        if (configs.isEmpty) {
          items.add(_ImportPreviewItem(
            path: path,
            fileName: fileName,
            config: null,
            type: widget.filterType,
            isValid: false,
            error: AppLocalizations.of(context).sourceUnrecognized,
          ));
        } else {
          for (final c in configs) {
            // 年龄限制开启时，18+ 源不可导入
            if (repo.isAgeBlocked(c)) {
              _importAgeBlockedCount++;
              continue;
            }
            items.add(_ImportPreviewItem(
              path: path,
              fileName: fileName,
              config: c,
              type: c.type,
              isValid: true,
            ));
          }
        }
      } on Object catch (e) {
        AppLog.instance.e('[源导入] 读取/解析失败 $fileName: $e');
        items.add(_ImportPreviewItem(
          path: path,
          fileName: fileName,
          config: null,
          type: null,
          isValid: false,
          error: e.toString(),
        ));
      }
    }

    // 专属类型页（filterType != null）：只保留该类型的源，其他类型直接忽略。
    int skippedByType = 0;
    List<_ImportPreviewItem> shownItems = items;
    if (widget.filterType != null) {
      final kept = <_ImportPreviewItem>[];
      for (final it in items) {
        if (it.config != null && it.type != widget.filterType) {
          // 有效但类型不符 → 直接忽略，计入跳过数
          skippedByType++;
        } else {
          // 无效（解析失败，用于错误提示）或类型匹配 → 保留
          kept.add(it);
        }
      }
      shownItems = kept;
    }

    if (!mounted) return;

    // 年龄限制：所有可解析源均为 18+ → 直接提示，不进入预览
    if (_importAgeBlockedCount > 0 &&
        shownItems.where((e) => e.isValid).isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).ageRestrictionImportMatureBlocked)),
      );
      return;
    }

    if (items.isEmpty) {
      final l10n = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.sourceUnrecognized)),
      );
      return;
    }

    // 专属类型页：过滤后没有任何可显示源（全部为其他类型）→ 提示并退出预览。
    if (widget.filterType != null && shownItems.isEmpty && skippedByType > 0) {
      final l10n = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.importNoMatchingType(
            _typeLabel(widget.filterType!, l10n),
            skippedByType,
          )),
        ),
      );
      return;
    }

    setState(() {
      _previewItems = shownItems;
      _selectedPreviewIndices = shownItems
          .asMap()
          .entries
          .where((e) => e.value.isValid)
          .map((e) => e.key)
          .toSet();
      _previewMode = true;
      _pickedFileName = null;
      _skippedByTypeCount = skippedByType;
    });
    widget.onPreviewModeChanged?.call(true);
  }

  /// 将 SourceType 映射为本地化分类标签。
  String _typeLabel(SourceType type, AppLocalizations l10n) {
    switch (type) {
      case SourceType.novelSource:
        return l10n.sourceCategoryNovel;
      case SourceType.animeSource:
        return l10n.sourceCategoryMedia;
      case SourceType.mangaSource:
        return l10n.sourceCategoryComic;
    }
  }

  /// 确认导入选中的预览项。
  void _confirmImport() {
    final selected = _previewItems
        .asMap()
        .entries
        .where((e) => _selectedPreviewIndices.contains(e.key) && e.value.isValid)
        .map((e) => e.value)
        .toList();

    int successCount = 0;
    for (final item in selected) {
      try {
        context.read<SourceRepository>().addSource(item.config!);
        successCount++;
      } on Object { /* 单个失败不影响其他 */ }
    }

    if (mounted) {
      setState(() {
        _previewItems = <_ImportPreviewItem>[];
        _selectedPreviewIndices = <int>{};
        _previewMode = false;
        _skippedByTypeCount = 0;
      });
      widget.onPreviewModeChanged?.call(false);

      final l10n = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.sourceImportResult(successCount, selected.length)),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final repo = context.watch<SourceRepository>();
    final filteredSources = _getFilteredSources(repo);

    // 嵌入模式：直接返回 Tab 内容（由外层 LibraryShell 提供 Scaffold/FAB）。
    if (widget.embedded) return _buildBody(l10n, scheme, filteredSources);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.sourceManagementTitle),
        actions: <Widget>[
          IconButton(
            icon: Icon(
              _showHidden ? Icons.visibility : Icons.visibility_off_outlined,
            ),
            tooltip: l10n.sourceShowHidden,
            onPressed: () => setState(() => _showHidden = !_showHidden),
          ),
        ],
      ),
      body: _buildBody(l10n, scheme, filteredSources),

    );
  }

  /// 构建主体内容（Tab 栏 + 内容区），供嵌入模式和完整模式共用。
  Widget _buildBody(AppLocalizations l10n, ColorScheme scheme, List<PluginConfig> filteredSources) {
    return Column(
      children: <Widget>[
        // 顶部 Tab 切换（M3 等宽分段）
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppTokens.spaceLg,
              vertical: AppTokens.spaceSm,
            ),
            child: AppSegmentedTabs<_SourceTab>(
              selected: <_SourceTab>{_tab},
              onSelectionChanged: (sel) {
                if (sel.isNotEmpty) {
                  setState(() => _tab = sel.first);
                }
              },
              segments: <ButtonSegment<_SourceTab>>[
                ButtonSegment<_SourceTab>(
                  value: _SourceTab.list,
                  icon: const Icon(Icons.list),
                  label: Text(l10n.sourceListTab),
                ),
                ButtonSegment<_SourceTab>(
                  value: _SourceTab.library,
                  icon: const Icon(Icons.cloud_outlined),
                  label: Text(l10n.libraryBookmarks),
                ),
                ButtonSegment<_SourceTab>(
                  value: _SourceTab.network,
                  icon: const Icon(Icons.cloud_download_outlined),
                  label: Text(l10n.networkImportTab),
                ),
                ButtonSegment<_SourceTab>(
                  value: _SourceTab.local,
                  icon: const Icon(Icons.file_present_outlined),
                  label: Text(l10n.localImportTab),
                ),
              ],
            ),
          ),

          const Divider(height: 1),

          // Tab 内容
          Expanded(
            child: <Widget>[
              _buildListTab(l10n, filteredSources, scheme),
              _buildLibraryTab(l10n, scheme),
              _buildNetworkImportTab(l10n, scheme),
              _buildLocalImportTab(l10n, scheme),
            ][_tab.index],
          ),
        ],
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // Tab 1: 源列表
  // ═══════════════════════════════════════════════════════════════════════
  Widget _buildListTab(
    AppLocalizations l10n,
    List<PluginConfig> sources,
    ColorScheme scheme,
  ) {
    // 若指定了 filterType（从模块设置页进入），直接显示单列表，不加分类 Tab。
    if (widget.filterType != null) {
      if (sources.isEmpty) {
        return AppEmptyState(
          icon: Icons.extension,
          message: l10n.sourceListEmpty,
          actionLabel: l10n.addSource,
          onAction: () => setState(() => _tab = _SourceTab.network),
          secondaryActionLabel: l10n.enableRecommendedSources,
          onSecondaryAction: () => _enableRecommended(l10n),
        );
      }
      return Column(
        children: <Widget>[
          Expanded(child: _buildSourceListView(l10n, sources)),
        ],
      );
    }

    // filterType == null（设置页总入口）：3 分类 Tab（项 7）。
    return DefaultTabController(
      length: 3,
      child: Column(
        children: <Widget>[
          if (sources.isNotEmpty) _buildEnableRecommendedTile(l10n),
          Material(
            color: scheme.surface,
            child: TabBar(
              // 窄屏可滚动，避免图标+文案被挤压重叠（项 1 一并改内层分类栏）。
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              // 切换分类时轻震一下（onTap 不影响 DefaultTabController 自动切换）。
              onTap: (_) => AppHaptics.selectionClick(),
              tabs: <Widget>[
                Tab(icon: const Icon(Icons.book), text: l10n.sourceCategoryNovel),
                Tab(icon: const Icon(Icons.movie), text: l10n.sourceCategoryMedia),
                Tab(icon: const Icon(Icons.image), text: l10n.sourceCategoryComic),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              children: <Widget>[
                _buildCategoryList(l10n, _getCategorySources(sources, 0),
                    l10n.sourceCategoryNovel),
                _buildCategoryList(l10n, _getCategorySources(sources, 1),
                    l10n.sourceCategoryMedia),
                _buildCategoryList(l10n, _getCategorySources(sources, 2),
                    l10n.sourceCategoryComic),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 构建单个分类下的源列表（含空状态）。
  Widget _buildCategoryList(
    AppLocalizations l10n,
    List<PluginConfig> sources,
    String categoryLabel,
  ) {
    if (sources.isEmpty) {
      return AppEmptyState(
        icon: Icons.extension,
        message: l10n.sourceCategoryEmpty(categoryLabel),
        actionLabel: l10n.addSource,
        onAction: () => setState(() => _tab = _SourceTab.network),
      );
    }
    return _buildSourceListView(l10n, sources);
  }

  /// 构建源列表 ListView（复用于单列表与分类 Tab）。
  /// 支持长按拖动排序；拖拽指示器在左侧，更多按钮在右侧（避免挤在一起）。
  Widget _buildSourceListView(
    AppLocalizations l10n,
    List<PluginConfig> sources,
  ) {
    // 监听登录态：源登录/登出后列表实时刷新「未登录」徽章（项 2）。
    final SourceAuthManager auth = context.watch<SourceAuthManager>();
    final SourceRepository repo = context.watch<SourceRepository>();
    return ReorderableListView(
      padding: const EdgeInsets.all(AppTokens.spaceMd),
      header: const SizedBox.shrink(),
      // 禁用默认右侧拖动手柄，改用左侧自定义拖拽指示器（项 3）
      buildDefaultDragHandles: false,
      // 美化拖动动画：缓出曲线 + 上浮 + 主色描边 + 双层阴影（项 4）
      proxyDecorator: (Widget child, int index, Animation<double> animation) {
        return AnimatedBuilder(
          animation: animation,
          builder: (context, _) {
            // easeOut 曲线让缩放/阴影随拖拽进度先快后缓，更有弹性感。
            final double t = Curves.easeOut.transform(animation.value);
            final double scale = lerpDouble(1.0, 1.04, t)!;
            final ColorScheme scheme = Theme.of(context).colorScheme;
            return Transform.translate(
              // 轻微上浮：拖起时像被"拎"起来，松手回落。
              offset: Offset(0, -3 * t),
              child: Transform.scale(
                scale: scale,
                child: Opacity(
                  opacity: lerpDouble(1.0, 0.97, t)!,
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(AppTokens.radiusLg),
                      border: Border.all(
                        color: scheme.primary.withValues(alpha: 0.3 * t),
                      ),
                      boxShadow: <BoxShadow>[
                        // 主阴影：随拖拽加深、扩散、下移。
                        BoxShadow(
                          color: scheme.shadow.withValues(alpha: 0.26 * t),
                          blurRadius: 16 * t + 4,
                          offset: Offset(0, 7 * t + 2),
                        ),
                        // 次级辉光：主色光晕，增强"浮起"感。
                        BoxShadow(
                          color: scheme.primary.withValues(alpha: 0.12 * t),
                          blurRadius: 28 * t,
                          offset: Offset(0, 3 * t),
                        ),
                      ],
                    ),
                    child: child,
                  ),
                ),
              ),
            );
          },
        );
      },
      onReorder: (int oldIndex, int newIndex) {
        final ids = sources.map((s) => s.id).toList();
        if (newIndex > oldIndex) newIndex--;
        final moved = ids.removeAt(oldIndex);
        ids.insert(newIndex, moved);
        repo.setSourceOrder(ids);
      },
      children: <Widget>[
        for (final s in sources)
          Padding(
            key: Key(s.id),
            padding: const EdgeInsets.only(bottom: AppTokens.spaceSm),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                // 左侧拖拽手柄：ReorderableDragStartListener 包裹图标（项 1+3+4）
                ReorderableDragStartListener(
                  index: sources.indexOf(s),
                  child: Padding(
                    padding: const EdgeInsets.only(right: AppTokens.spaceXs),
                    child: Icon(Icons.drag_indicator,
                        color: Theme.of(context).colorScheme.onSurfaceVariant
                            .withValues(alpha: 0.45),
                        size: 20),
                  ),
                ),
                Expanded(
                  child: AppCard(
                    padding: EdgeInsets.zero,
                    child: UnifiedSourceTile(
                name: s.name,
                url: s.site.baseUrl,
                enabled: s.isEnabled,
                deprecated: s.isDeprecated,
                ageRating: s.ageRating,
                isHidden: s.isHidden,
                // 项 2：仅对声明了登录入口、且当前未登录的源显示「未登录」。
                showNotLoggedIn:
                    s.comments?.supportsLogin == true && !auth.isLoggedIn(s),
                deprecatedLabel: l10n.deprecated,
                mirrorSettingsTooltip: l10n.mirrorSettings,
                hideTooltip: l10n.sourceHide,
                unhideTooltip: l10n.sourceShowHidden,
                editTooltip: l10n.sourceEdit,
                deleteTooltip: l10n.sourceDelete,
                migrateTooltip: l10n.sourceMigrate,
                networkOverrideTooltip: l10n.sourceNetworkOverride,
                loginTooltip: l10n.sourceLogin,
                // 源管理页：操作收进「更多」菜单，更清爽
                useMoreMenu: true,
                moreMenuTooltip: l10n.moreActions,
                isIncognito: ConfigLoader.instance.isIncognito(s),
                incognitoTooltip: l10n.incognitoMode,
                onIncognitoToggle: (bool value) async {
                  await ConfigLoader.instance.setIncognito(s.id, value);
                  if (mounted) setState(() {});
                },
                onToggle: (bool value) =>
                    context.read<SourceRepository>().setEnabled(s.id, value),
                onMirrorSettings: () => Navigator.of(context).push(
                  AppPageRoute<void>(
                    builder: (_) => SourceMirrorScreen(source: s),
                  ),
                ),
                onNetworkOverride: () => Navigator.of(context).push(
                  AppPageRoute<void>(
                    builder: (_) => SourceNetworkOverrideScreen(source: s),
                  ),
                ),
                onLogin: () => Navigator.of(context).push(
                  AppPageRoute<void>(
                    builder: (_) => SourceLoginScreen(source: s),
                  ),
                ),
                onHide: () =>
                    context.read<SourceRepository>().setHidden(s.id, !s.isHidden),
                onEdit: () => _showEditDialog(s),
                onDelete: () => _showDeleteConfirm(s),
                onMigrate: s.migrationMessage != null
                    ? () => _showMigrateDialog(s)
                    : null,
              ),
            ),
                  ),
                ],
              ),
            ),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // Tab 4: 库（源库订阅 + 查看库内源 + 自定义导入）
  // ═══════════════════════════════════════════════════════════════════════

  /// 从 URL 推导默认名称（取 host，去掉 www.）。
  String _deriveNameFromUrl(String url) {
    final host = Uri.tryParse(url)?.host ?? url;
    return host.startsWith('www.') ? host.substring(4) : host;
  }

  /// 订阅一个新源库（按 url 去重），订阅后立即打开「查看源」让用户选择要导入的源。
  Future<void> _subscribeLibrary() async {
    final url = _libraryUrlController.text.trim();
    if (url.isEmpty) return;
    final name = _libraryNameController.text.trim().isNotEmpty
        ? _libraryNameController.text.trim()
        : _deriveNameFromUrl(url);
    final lib = SourceLibrary(
      id: url,
      name: name,
      url: url,
      addedAt: DateTime.now().millisecondsSinceEpoch,
    );
    setState(() => _librarySubscribing = true);
    try {
      await context.read<SourceLibrarySubscription>().add(lib);
      _libraryUrlController.clear();
      _libraryNameController.clear();
      if (!mounted) return;
      // 订阅成功后自动跳转到「查看源」页，方便用户立即选源导入。
      await Navigator.of(context).push(
        AppPageRoute<void>(
          builder: (_) => LibrarySourcesScreen(library: lib),
        ),
      );
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context).librarySubscribeFailed),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _librarySubscribing = false);
    }
  }

  /// 外链打开源库主页（如 GitHub 仓库）。失败时弹出可复制的 URL 对话框。
  Future<void> _openLibraryHomepage(String? url) async {
    if (url == null || url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.scheme.startsWith('http')) return;
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AppAlertDialog(
          title: Text(uri.host),
          content: SelectableText(url),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(AppLocalizations.of(ctx).ok),
            ),
          ],
        ),
      );
    }
  }

  /// 取消订阅（非官方库）。
  Future<void> _unsubscribeLibrary(SourceLibrary lib) async {
    final l10n = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AppAlertDialog(
        title: Text(l10n.unsubscribeLibrary),
        content: Text(l10n.unsubscribeLibraryConfirm(lib.name)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.unsubscribeLibrary),
          ),
        ],
      ),
    );
    if (ok == true) {
      await context.read<SourceLibrarySubscription>().remove(lib.id);
    }
  }

  Widget _buildLibraryTab(AppLocalizations l10n, ColorScheme scheme) {
    final subs = context.watch<SourceLibrarySubscription>();
    final libs = subs.all();
    return ListView(
      padding: const EdgeInsets.all(AppTokens.spaceLg),
      children: <Widget>[
        // 已订阅源库列表
        Text(l10n.libraryBookmarks,
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: AppTokens.spaceSm),
        if (libs.isEmpty)
          AppCard(
            child: Padding(
              padding: const EdgeInsets.all(AppTokens.spaceMd),
              child: Text(
                l10n.libraryEmpty,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          )
        else
          ...libs.map((lib) => Padding(
                padding: const EdgeInsets.only(bottom: AppTokens.spaceSm),
                child: AppCard(
                  padding: const EdgeInsets.all(AppTokens.spaceMd),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(lib.name,
                                style: Theme.of(context).textTheme.titleSmall),
                          ),
                          if (lib.isOfficial)
                            Chip(
                              label: Text(l10n.official),
                              visualDensity: VisualDensity.compact,
                            ),
                        ],
                      ),
                      const SizedBox(height: AppTokens.spaceXxs),
                      Text(
                        lib.url,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: AppTokens.spaceSm),
                      Wrap(
                        spacing: AppTokens.spaceSm,
                        runSpacing: AppTokens.spaceXs,
                        children: <Widget>[
                          // 主要操作：查看源 → 进入自定义导入页（可勾选）
                          FilledButton.icon(
                            onPressed: () => Navigator.of(context).push(
                              AppPageRoute<void>(
                                builder: (_) =>
                                    LibrarySourcesScreen(library: lib),
                              ),
                            ),
                            icon: const Icon(Icons.list_alt, size: 18),
                            label: Text(l10n.viewLibrarySources),
                          ),
                          if (lib.homepage != null)
                            OutlinedButton.icon(
                              onPressed: () =>
                                  _openLibraryHomepage(lib.homepage),
                              icon: const Icon(Icons.open_in_new, size: 18),
                              label: Text(l10n.openHomepage),
                            ),
                          if (!lib.isOfficial)
                            OutlinedButton.icon(
                              onPressed: () => _unsubscribeLibrary(lib),
                              icon: const Icon(
                                Icons.bookmark_remove_outlined,
                                size: 18,
                              ),
                              label: Text(l10n.unsubscribeLibrary),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              )),
        const SizedBox(height: AppTokens.spaceLg),

        // 添加新源库订阅
        AppCard(
          child: Padding(
            padding: const EdgeInsets.all(AppTokens.spaceMd),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(l10n.addLibraryTitle,
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: AppTokens.spaceSm),
                TextField(
                  controller: _libraryNameController,
                  decoration: InputDecoration(
                    labelText: l10n.libraryNameHint,
                    hintText: l10n.libraryNameHint,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: AppTokens.spaceSm),
                AppUrlInputBar(
                  controller: _libraryUrlController,
                  hintText: l10n.libraryUrlHint,
                  submitLabel: l10n.subscribeLibrary,
                  isLoading: _librarySubscribing,
                  onSubmit: (_) => _subscribeLibrary(),
                ),
              ],
            ),
          ),
        ),

      ],
    );
  }

  Widget _buildEnableRecommendedTile(AppLocalizations l10n) {
    final repo = context.read<SourceRepository>();
    final hasDisabled = repo.all.any(
      (c) =>
          !c.isDeprecated &&
          !c.id.toLowerCase().contains('example') &&
          !c.isEnabled,
    );
    if (!hasDisabled) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTokens.spaceSm),
      child: AppCard(
        onTap: () => _enableRecommended(l10n),
        child: ListTile(
          leading: const Icon(Icons.playlist_add_check),
          title: Text(l10n.enableRecommendedSources),
          subtitle: Text(l10n.enableRecommendedSourcesHint),
          trailing: const Icon(Icons.chevron_right),
        ),
      ),
    );
  }

  Future<void> _enableRecommended(AppLocalizations l10n) async {
    final count =
        await context.read<SourceRepository>().enableRecommendedSources();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.recommendedSourcesEnabled(count))),
      );
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // Tab 2: 网络导入
  // ═══════════════════════════════════════════════════════════════════════
  Widget _buildNetworkImportTab(AppLocalizations l10n, ColorScheme scheme) {
    // 多源导入时复用本地导入的批量勾选预览
    if (_previewMode && _previewItems.isNotEmpty) {
      return _buildImportPreview(l10n, scheme);
    }
    return ListView(
      padding: const EdgeInsets.all(AppTokens.spaceLg),
      children: <Widget>[
        Text(
          l10n.networkImportHint,
          style: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: AppTokens.spaceMd),

        TextField(
          controller: _urlController,
          decoration: InputDecoration(
            hintText: l10n.networkImportPasteHint,
            prefixIcon: const Icon(Icons.link),
            border: const OutlineInputBorder(),
            suffixIcon: _networkLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : IconButton(
                    icon: const Icon(Icons.check),
                    onPressed: _fetchFromUrl,
                  ),
          ),
          keyboardType: TextInputType.url,
          onSubmitted: (_) => _fetchFromUrl(),
        ),

        const SizedBox(height: AppTokens.spaceLg),
        Text(
          l10n.collectApiImportTitle,
          style: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: AppTokens.spaceMd),
        TextField(
          controller: _collectApiUrlController,
          decoration: InputDecoration(
            hintText: l10n.collectApiUrlHint,
            prefixIcon: const Icon(Icons.cloud_upload_outlined),
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              icon: const Icon(Icons.arrow_forward),
              tooltip: l10n.collectApiImportTitle,
              onPressed: _openCollectApiImport,
            ),
          ),
          keyboardType: TextInputType.url,
          onSubmitted: (_) => _openCollectApiImport(),
        ),

        // 预览区域
        const SizedBox(height: AppTokens.spaceLg),
        if (_networkLoading)
          Center(
            child: Padding(
              padding: const EdgeInsets.all(AppTokens.spaceXl),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const CircularProgressIndicator(),
                  const SizedBox(height: AppTokens.spaceMd),
                  Text(l10n.networkImportPasteHint),
                ],
              ),
            ),
          )
        else if (_networkError != null)
          Center(
            child: Padding(
              padding: const EdgeInsets.all(AppTokens.spaceXl),
              child: Text(
                _networkError!,
                style: TextStyle(color: scheme.error),
                textAlign: TextAlign.center,
              ),
            ),
          )
        else if (_networkPreview != null)
          _buildNetworkPreview(l10n, scheme)
        else
          Center(
            child: Padding(
              padding: const EdgeInsets.all(AppTokens.spaceXl),
              child: Text(
                l10n.networkImportPasteHint,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                textAlign: TextAlign.center,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildNetworkPreview(AppLocalizations l10n, ColorScheme scheme) {
    final config = _networkPreview!;
    final isValid = _validationErrors.isEmpty;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(config.name,
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AppTokens.spaceXs),
          Text(
            config.site.baseUrl,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: AppTokens.spaceSm),
          if (isValid)
            Row(
              children: <Widget>[
                Icon(Icons.check_circle, color: scheme.primary, size: 18),
                const SizedBox(width: AppTokens.spaceXs),
                Text(l10n.sourceImportValid),
              ],
            )
          else ...<Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.error_outline, color: scheme.error, size: 18),
                const SizedBox(width: AppTokens.spaceXs),
                Text(l10n.sourceImportInvalid,
                    style: TextStyle(color: scheme.error)),
              ],
            ),
            ..._validationErrors.map(
              (e) => Padding(
                padding: EdgeInsets.only(
                    left: AppTokens.spaceMd, top: 2),
                child: Text('• $e',
                    style:
                        Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.error,
                            )),
              ),
            ),
          ],
          const SizedBox(height: AppTokens.spaceLg),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: isValid ? _saveNetworkSource : null,
              child: Text(l10n.save),
            ),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // Tab 3: 本地导入（文件/文件夹 + 预览勾选）
  // ═══════════════════════════════════════════════════════════════════════
  Widget _buildLocalImportTab(AppLocalizations l10n, ColorScheme scheme) {
    // 预览模式：显示已扫描的源列表 + 勾选 + 确认
    if (_previewMode && _previewItems.isNotEmpty) {
      return _buildImportPreview(l10n, scheme);
    }

    // 默认模式：选择文件或文件夹
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.spaceXl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.description_outlined,
              size: 64,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.4),
            ),
            const SizedBox(height: AppTokens.spaceLg),
            Text(
              l10n.localImportTitle,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: AppTokens.spaceXs),
            Text(
              l10n.localImportFormats,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppTokens.spaceLg),

            // 导入方式：单文件 / 多文件 / 文件夹。
            // 窄屏兜底：两按钮 + 文案在部分手机（小屏/大字体）会横向溢出，
            // 改用 Wrap + Flexible 自动换行，不再固定 Row 单行（修复 130）。
            Wrap(
              alignment: WrapAlignment.center,
              spacing: AppTokens.spaceMd,
              runSpacing: AppTokens.spaceSm,
              children: <Widget>[
                FilledButton.icon(
                  onPressed: _pickLocalFile,
                  icon: const Icon(Icons.file_open, size: 18),
                  label: Text(l10n.selectFile),
                ),
                OutlinedButton.icon(
                  onPressed: _pickLocalFolder,
                  icon: const Icon(Icons.folder_outlined, size: 18),
                  label: Text(l10n.selectFolder),
                ),
              ],
            ),

            if (_pickedFileName != null) ...<Widget>[
              const SizedBox(height: AppTokens.spaceMd),
              Text(
                _pickedFileName!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.primary,
                    ),
              ),
            ],

            const SizedBox(height: AppTokens.spaceXl),
            Text(
              l10n.localImportHint,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  /// 预览勾选界面。
  Widget _buildImportPreview(AppLocalizations l10n, ColorScheme scheme) {
    final validCount = _previewItems.where((e) => e.isValid).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (_importAgeBlockedCount > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTokens.spaceMd,
              AppTokens.spaceMd,
              AppTokens.spaceMd,
              0,
            ),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                horizontal: AppTokens.spaceMd,
                vertical: AppTokens.spaceSm,
              ),
              decoration: BoxDecoration(
                color: scheme.errorContainer.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(AppTokens.radiusMd),
              ),
              child: Row(
                children: <Widget>[
                  Icon(Icons.lock_outline, size: 16, color: scheme.onErrorContainer),
                  const SizedBox(width: AppTokens.spaceXs),
                  Expanded(
                    child: Text(
                      l10n.ageBlockedImportHint(_importAgeBlockedCount),
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: scheme.onErrorContainer),
                    ),
                  ),
                ],
              ),
            ),
          ),
        // 标题栏
        Padding(
          padding: const EdgeInsets.all(AppTokens.spaceMd),
          child: Row(
            children: <Widget>[
              IconButton(
                icon: const Icon(Icons.arrow_back, size: 20),
                onPressed: () {
                  setState(() {
                    _previewMode = false;
                    _previewItems = <_ImportPreviewItem>[];
                    _selectedPreviewIndices = <int>{};
                    _skippedByTypeCount = 0;
                  });
                  widget.onPreviewModeChanged?.call(false);
                },
                tooltip: l10n.cancel,
              ),
              Expanded(
                child: Text(
                  l10n.importPreviewTitle(_previewItems.length),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (validCount > 0)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    TextButton(
                      onPressed: () {
                        // 全选有效项
                        setState(() {
                          _selectedPreviewIndices = _previewItems
                              .asMap()
                              .entries
                              .where((e) => e.value.isValid)
                              .map((e) => e.key)
                              .toSet();
                        });
                      },
                      child: Text(l10n.selectAll),
                    ),
                    TextButton(
                      onPressed: () {
                        // 全不选
                        setState(() {
                          _selectedPreviewIndices = <int>{};
                        });
                      },
                      child: Text(l10n.deselectAll),
                    ),
                  ],
                ),
            ],
          ),
        ),

        // 类型筛选提示：在专属类型页导入时，仅导入该类型源
        if (widget.filterType != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
              horizontal: AppTokens.spaceMd,
              vertical: AppTokens.spaceSm,
            ),
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
            child: Row(
              children: <Widget>[
                Icon(Icons.filter_alt_outlined, size: 16,
                    color: scheme.onSurfaceVariant),
                const SizedBox(width: AppTokens.spaceXs),
                Expanded(
                  child: Text(
                    _skippedByTypeCount > 0
                        ? l10n.importTypeFiltered(_skippedByTypeCount)
                        : l10n.importTypeOnly(_typeLabel(widget.filterType!, l10n)),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                ),
              ],
            ),
          ),

        const Divider(height: 1),

        // 文件列表（带复选框）
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(AppTokens.spaceSm),
            itemCount: _previewItems.length,
            itemBuilder: (context, i) {
              final item = _previewItems[i];
              final isSelected = _selectedPreviewIndices.contains(i);
              return Card(
                margin: const EdgeInsets.only(bottom: AppTokens.spaceXs),
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: AppTokens.spaceSm,
                    vertical: AppTokens.spaceXs,
                  ),
                  leading: Checkbox(
                    value: isSelected && item.isValid,
                    onChanged: item.isValid ? (v) {
                      setState(() {
                        if (v == true) {
                          _selectedPreviewIndices.add(i);
                        } else {
                          _selectedPreviewIndices.remove(i);
                        }
                      });
                    } : null,
                  ),
                  title: Text(
                    item.fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      if (item.isValid) ...<Widget>[
                        Text(
                          item.config?.name ?? '',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: scheme.primary,
                              ),
                        ),
                        Text(
                          item.config?.site.baseUrl ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                        ),
                        if (item.type != null)
                          Text(
                            '${l10n.sourceType}：${_typeLabel(item.type!, l10n)}',
                            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                          ),
                      ] else ...<Widget>[
                        Text(
                          item.error ?? l10n.sourceImportInvalid,
                          style: TextStyle(color: scheme.error, fontSize: 12),
                        ),
                      ],
                    ],
                  ),
                  trailing: Icon(
                    item.isValid ? Icons.check_circle : Icons.error_outline,
                    color: item.isValid
                        ? AppStatusColors.ok(scheme)
                        : scheme.error,
                    size: 20,
                  ),
                ),
              );
            },
          ),
        ),

        // 底部操作栏
        Container(
          padding: const EdgeInsets.all(AppTokens.spaceMd),
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.3)),
            ),
          ),
          child: Row(
            children: <Widget>[
              Text(
                l10n.importSelectedCount(_selectedPreviewIndices.length),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: _selectedPreviewIndices.isNotEmpty
                    ? _confirmImport
                    : null,
                icon: const Icon(Icons.file_download_outlined, size: 18),
                label: Text(l10n.confirmImport),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ─────────────────────── 编辑/删除/迁移（P6.1.1/P6.1.2） ───────────────────────

  /// 编辑源：打开独立的全字段编辑页（JSON 编辑，可设置所有模块的所有字段）。
  Future<void> _showEditDialog(PluginConfig source) async {
    if (!mounted) return;
    await Navigator.of(context).push(
      AppPageRoute<void>(
        builder: (_) => SourceEditScreen(source: source),
      ),
    );
  }

  /// 删除源确认对话框。
  Future<void> _showDeleteConfirm(PluginConfig source) async {
    final l10n = AppLocalizations.of(context);
    final repo = context.read<SourceRepository>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AppAlertDialog(
        title: Text(l10n.deleteConfirmTitle),
        content: Text(l10n.deleteConfirmContent(source.name)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final ok = repo.removeSource(source.id);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ok ? l10n.sourceDeleted : l10n.sourceDeleteFailed)),
      );
    }
  }

  /// 弃用源迁移提示对话框。
  Future<void> _showMigrateDialog(PluginConfig source) async {
    final l10n = AppLocalizations.of(context);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AppAlertDialog(
        title: Text(l10n.sourceMigrate),
        content: Text(source.migrationMessage ?? l10n.sourceDeprecatedHint),
        actions: <Widget>[
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.ok),
          ),
        ],
      ),
    );
  }
}

/// 本地导入预览项 —— 扫描到的单个源文件信息。
class _ImportPreviewItem {
  final String path;
  final String fileName;
  final PluginConfig? config;
  final SourceType? type;
  final bool isValid;
  final String? error;

  _ImportPreviewItem({
    required this.path,
    required this.fileName,
    required this.config,
    this.type,
    required this.isValid,
    this.error,
  });
}

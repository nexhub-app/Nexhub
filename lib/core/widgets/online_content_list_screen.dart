import 'package:flutter/material.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/category_entry.dart';
import '../models/media_item.dart';
import '../models/plugin_config.dart';
import '../history/media_watched_manager.dart';
import '../resolver/parse_diagnostics.dart';
import '../resolver/script_resolver.dart';
import '../scraper/http_fetcher.dart';
import '../scraper/verification_navigator.dart';
import '../services/config_loader.dart';
import '../services/source_repository.dart';
import '../settings/layout_settings.dart';
import '../novel/novel_progress_manager.dart';
import '../comic/comic_progress_manager.dart';
import '../theme/app_tokens.dart';
import 'app_alert_dialog.dart';
import 'app_card.dart';
import 'app_cover_image.dart';
import 'app_empty_state.dart';
import 'app_error_state.dart';
import 'app_loading_indicator.dart';
import 'content_card.dart';
import 'detail_action_utils.dart';
import 'online_filter_sheet.dart';
import 'online_home_section.dart';
import 'online_schedule_section.dart';
import 'layout_picker_button.dart';
import 'source_image.dart';
import 'source_url_browse_screen.dart';

/// 拉取某源在指定分类 / 页码下的内容列表。
typedef FetchItems = Future<List<MediaItem>> Function(
  PluginConfig source, {
  String? category,
  int page,
  String? extractedUrl,
  String? renderedHtml,
  Map<String, String> vars,
});

/// 拉取某源的分类（可选；返回空则隐藏分类栏）。
typedef FetchCategories = Future<List<CategoryEntry>> Function(PluginConfig source);

/// 解析某源的首页板块（共创式；返回空则回退单块「最新更新」）。
///
/// 对接 [MediaApiService.resolveHomeSections]，让「首页有几个榜单/分区」
/// 完全由源声明或兜底决定，app 只负责竖向堆叠渲染。
typedef ResolveHomeSections = List<HomeSectionConfig> Function(
    PluginConfig source);

/// 解析某源的动态筛选分组（共创式；返回空则该分类页不显示筛选按钮）。
///
/// 对接 [MediaApiService.resolveFilterGroups]，修复旧版「筛选写死年份/地区
/// /排序/状态」——筛选维度改为由源声明或从分类/标签兜底生成。
typedef ResolveFilters = Future<List<FilterGroupConfig>> Function(
    PluginConfig source, String categoryId);

/// 通用「在线内容列表」页骨架（动态多 Tab 结构）。
///
/// 动漫 / 漫画 / 小说 / 影视 四模块高度同构的浏览页（源选择 + 首页 + 周期表
/// + 动态分类 Tab + 可选排行 + 网格/列表 + 分页 + 加载/空/错状态）全部下沉到
/// 这里，**禁止**各 feature 重复实现。各模块只需传入源集合、拉取回调、
/// 点击行为即可。
///
/// **#7 A4-#7 动态多 Tab 结构**：
/// ```
/// [首页] [周期表?] [分类1] [分类2] ... [分类N] [排行?]
///   固定    可选     ←─ fetchCategories 动态生成 ─→  可选
/// ```
/// - Tab 1 首页：最新更新 + 热门推荐 + 分类入口（回退两段无 Banner）
/// - Tab 2 周期表?：仅当源有 latest route 且至少 1 条 item 有 updatedAt 时显示；
///   7 天分组（无 updatedAt 时整个 Tab 隐藏）
/// - Tab 3-N 动态分类：按 fetchCategories 生成，每个含筛选按钮 + 网格列表
/// - Tab Last 排行：仅当源有 `rank` route 时显示
class OnlineContentListScreen extends StatefulWidget {
  const OnlineContentListScreen({
    super.key,
    required this.title,
    required this.sources,
    this.initialSource,
    required this.fetchItems,
    required this.onItemTap,
    this.fetchCategories,
    this.resolveHomeSections,
    this.resolveFilters,
    this.onSearch,
    this.onAddSource,
    this.onEnableRecommended,
    this.verificationHandler,
    this.initialGrid = true,
    this.emptyIcon = Icons.video_library,
  });

  final String title;
  final List<PluginConfig> sources;
  final PluginConfig? initialSource;
  final FetchItems fetchItems;
  final FetchCategories? fetchCategories;

  /// 首页板块解析（可选）；为 null 时回退旧行为（最新更新 + 热门推荐两段）。
  final ResolveHomeSections? resolveHomeSections;

  /// 动态筛选分组解析（可选）；为 null 或返回空时分类页不显示筛选按钮。
  final ResolveFilters? resolveFilters;
  final void Function(MediaItem item, String? heroTag) onItemTap;
  final VoidCallback? onSearch;
  final VoidCallback? onAddSource;
  final VoidCallback? onEnableRecommended;
  final VerifyCallback? verificationHandler;
  final bool initialGrid;
  final IconData emptyIcon;

  @override
  State<OnlineContentListScreen> createState() => _OnlineContentListScreenState();
}

class _OnlineContentListScreenState extends State<OnlineContentListScreen>
    with TickerProviderStateMixin {
  PluginConfig? _source;
  /// 本页已弹过公告的源 id 集合（避免同一源反复弹窗）。
  final Set<String> _announcedIds = <String>{};
  /// 用户选择「以后再不显示」的公告（按 源id@更新时间 去重），跨会话持久化；
  /// 源作者发布新公告（updatedAt 变化）时 key 不同，仍会弹出。
  final Set<String> _dismissedAnnouncements = <String>{};
  static const String _kDismissedAnnouncements = 'announcement_dismissed_v1';
  late TabController _tabController;
  final List<CategoryEntry> _categories = <CategoryEntry>[];

  /// 布局设置存储——监听变化以即时刷新网格/列表。
  final LayoutSettingsStore _layoutStore = LayoutSettingsStore.instance;

  /// 每个源 chip 的唯一 key（按「源id#序号」生成，避免重复 key）：
  /// 切换源时用选中项的 key 把它自动滚入可视区域（横向源栏项多时选中项可能在屏外）。
  /// 用「序号」做后缀，可保证同一源列表里即使出现同名/重复源（如某源同时存在于
  /// 内置与已导入列表），各 chip 的 key 仍唯一，不会触发「Duplicate keys found」崩溃。
  final Map<String, GlobalKey> _chipKeys = <String, GlobalKey>{};
  GlobalKey _chipKey(int index, String id) =>
      _chipKeys.putIfAbsent('$id#$index', () => GlobalKey(debugLabel: 'src-$id-$index'));

  // 各分类 Tab 的独立状态（用 category id 作为 key）。
  final Map<String, _CategoryTabState> _tabStates = <String, _CategoryTabState>{};

  // 按源缓存的动态筛选分组（key = source.id）；切源时清空。
  final Map<String, List<FilterGroupConfig>> _filterGroupsCache =
      <String, List<FilterGroupConfig>>{};

  // 按源缓存的首页板块数据（key = section.id → 该板块 items）。
  Map<String, List<MediaItem>> _homeSectionItems =
      <String, List<MediaItem>>{};
  // 当前源解析出的首页板块配置（顺序即竖向堆叠顺序）。
  List<HomeSectionConfig> _homeSections = <HomeSectionConfig>[];

  // 进度计算的 Future 缓存（按 item id），避免列表重建时重复触发异步读取。
  final Map<String, Future<double?>> _progressFutures =
      <String, Future<double?>>{};

  // 首页数据（多板块由 _homeSections + _homeSectionItems 驱动）
  bool _homeLoading = false;
  String? _homeError;

  // 首屏冷启动保护：主页解析完成（JS 引擎已热）后自动预载第一个分类，
  // 这样用户首次点分类不再撞冷启动首调失败，也不会弹出错误提示。
  bool _firstCategoryPreloaded = false;

  // 周期表数据（进入周期表 Tab 时按需抓取，见 [_ensureScheduleData]）
  List<MediaItem> _scheduleItems = <MediaItem>[];
  bool _scheduleLoading = false;

  // 网络收藏数据（源站书架；进入该 Tab 时按需抓取，见 [_loadWebFavorite]）
  List<MediaItem> _webFavoriteItems = <MediaItem>[];
  // 网络收藏文件夹列表（源声明 `folders:true` 时由解析器解析得到）。
  List<WebFavoriteFolder> _webFavoriteFolders = <WebFavoriteFolder>[];
  bool _webFavoriteLoading = false;
  String? _webFavoriteError;

  // 首页板块懒加载：每个板块的加载状态（未加载 / 加载中 / 已加载 / 失败）。
  // 方案 A：只抓取进入视口的板块，其余滑到/点开才抓（配合 HttpFetcher 信号量限流）。
  final Map<String, _SectionStatus> _sectionStatus =
      <String, _SectionStatus>{};
  // 各板块的 GlobalKey（用于滚动时计算是否在视口内）。
  final Map<String, GlobalKey> _sectionKeys = <String, GlobalKey>{};
  // 首页板块抓取串行链：保证同一首页内多个板块**顺序**抓取（一次一个），
  // 而非并发突发。方案 A 下首屏可见板块可能不止一个，若不串行会短时间向
  // 同一站点打出多个请求，触发风控 / IP 封禁（如幻梦ACG轻小说一打开就跳验证
  // 被封）。串行后第一个板块若触发验证，用户处理完 cookie 同步，后续板块
  // 带 cookie 不再触发验证，整源只需验证一次。
  Future<void>? _sectionFetchChain;
  // 首页 ListView 的 key（用于取视口尺寸/位置计算可见性）。
  final GlobalKey _homeListKey = GlobalKey();

  // 排行数据
  List<MediaItem> _rankItems = <MediaItem>[];
  bool _rankLoading = false;
  String? _rankError;

  // 是否已显示过 TabBar（避免 Tab 数变化时 index 越界）
  int _lastTabCount = 3;

  @override
  void initState() {
    super.initState();
    // 载入「以后再不显示」的公告集合（跨会话）。
    SharedPreferences.getInstance().then((prefs) {
      final list = prefs.getStringList(_kDismissedAnnouncements);
      if (list != null && mounted) {
        setState(() => _dismissedAnnouncements.addAll(list));
      }
    });
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(_onTabChanged);
    // 监听布局设置变化，切换预设/列数/间距后即时刷新网格
    _layoutStore.addListener(_onLayoutChanged);
    if (widget.initialSource != null &&
        widget.sources.any((s) => s.id == widget.initialSource!.id)) {
      _source = widget.initialSource;
    } else if (widget.sources.isNotEmpty) {
      _source = widget.sources.first;
    }
    _loadCategories();
    _loadHome();
    // 进入浏览页时把预选源滚动到可视区域（源很多时选中项可能在屏外，item 9），
    // 并在首帧后弹出该源公告（item 7）。
    if (_source != null) {
      _scrollSelectedSourceIntoView();
      _maybeShowAnnouncement(_source!);
    }
  }

  @override
  void didUpdateWidget(covariant OnlineContentListScreen old) {
    super.didUpdateWidget(old);
    if (old.sources != widget.sources) {
      if (widget.initialSource != null &&
          widget.sources.any((s) => s.id == widget.initialSource!.id)) {
        _source = widget.initialSource;
      } else {
        _source = widget.sources.isNotEmpty ? widget.sources.first : null;
      }
      _loadCategories();
      _loadHome();
    }
  }

  @override
  void dispose() {
    _layoutStore.removeListener(_onLayoutChanged);
    _tabController.dispose();
    super.dispose();
  }

  /// 布局设置变化回调——触发重建以应用新布局参数。
  void _onLayoutChanged() {
    if (mounted) setState(() {});
  }

  /// 根据当前源能力决定 Tab 总数。
  ///
  /// Tab 顺序：首页 / [周期表?] / [网络收藏?] / [动态分类...] / [排行?]
  int get _tabCount {
    int count = 1; // 首页
    if (_hasScheduleData) count += 1; // 周期表（条件显示）
    if (_hasWebFavorite) count += 1; // 网络收藏（条件显示）
    count += _categories.length; // 动态分类
    if (_source != null && _source!.routes.containsKey('rank')) {
      count += 1; // 排行
    }
    return count;
  }

  /// 源是否提供 `rank` route。
  bool get _hasRank => _source != null && _source!.routes.containsKey('rank');

  /// 源是否提供周期表能力（有 latest route 即认为可展示；数据由
  /// [_ensureScheduleData] 在切到周期表 Tab 时按需抓取，不再依赖已抓数据）。
  bool get _hasScheduleData =>
      _source != null && _source!.routes.containsKey('latest');

  /// 源是否声明了网络收藏（`webFavorite` 段）。未声明 → 不显示该 Tab。
  bool get _hasWebFavorite => _source?.hasWebFavoriteBrowse ?? false;

  /// 网络收藏 Tab 索引（紧随周期表之后；不显示时为 -1）。
  int get _webFavoriteTabIndex =>
      _hasWebFavorite ? (_hasScheduleData ? 2 : 1) : -1;

  /// 动态分类 Tab 的起始索引（首页 + 可选周期表 + 可选网络收藏之后）。
  ///
  /// **所有涉及 Tab 索引偏移的地方都必须走这个 getter**，否则新增/删除
  /// 条件 Tab 时极易漏改造成错位。
  int get _catStart =>
      1 + (_hasScheduleData ? 1 : 0) + (_hasWebFavorite ? 1 : 0);

  void _rebuildTabController() {
    final newCount = _tabCount;
    if (newCount == _lastTabCount) return;
    final prevIndex = _tabController.index.clamp(0, newCount - 1);
    _tabController.dispose();
    _tabController = TabController(
      length: newCount,
      vsync: this,
      initialIndex: prevIndex,
    );
    _lastTabCount = newCount;
    _tabController.addListener(_onTabChanged);
  }

  void _onTabChanged() {
    if (!_tabController.indexIsChanging) {
      final idx = _tabController.index;
      // idx 0 = 首页（已加载）
      // 可选 Tab 依次为：周期表 → 网络收藏，之后才是动态分类，排行在最后。
      final catStart = _catStart;
      final rankIdx = catStart + _categories.length;
      if (_hasScheduleData && idx == 1 && _scheduleItems.isEmpty && !_scheduleLoading) {
        // 进入周期表 Tab：按需抓取周期表数据（懒加载）。
        _ensureScheduleData();
      } else if (idx == _webFavoriteTabIndex) {
        // 进入网络收藏 Tab：按需抓取源站书架（懒加载）。
        _loadWebFavorite();
      } else if (idx == rankIdx && _hasRank && _rankItems.isEmpty) {
        _loadRank();
      } else if (idx >= catStart && idx < rankIdx) {
        final cat = _categories[idx - catStart];
        _ensureTabLoaded(cat.id);
      }
    }
  }

  Future<void> _loadCategories() async {
    if (_source == null || widget.fetchCategories == null) {
      setState(() {
        _categories.clear();
        _rebuildTabController();
      });
      return;
    }
    try {
      final cats = await widget.fetchCategories!(_source!);
      if (mounted) {
        setState(() {
          _categories..clear()..addAll(cats);
          _tabStates.clear();
          _rebuildTabController();
        });
        // 分类就绪（若主页也已就绪）即触发首个分类预载，缩短首次点击的冷启动窗口。
        _tryPreloadFirstCategory();
      }
    } on Object {
      if (mounted) {
        setState(() {
          _categories.clear();
          _rebuildTabController();
        });
      }
    }
  }

  /// 加载首页数据（最新更新 + 热门推荐）。
  /// Default category id for the home page: when the source's latest route
  /// URL contains `{category}` and the source declares static
  /// [CategoryConfig.categoryEntries], use the first entry's id (typically
  /// "全部"/"all"). Otherwise return null. This prevents malformed URLs like
  /// `/vodshow/{category}--------1---.html` when loading the home tab without
  /// an explicit category.
  String? get _defaultHomeCategory {
    final source = _source;
    if (source == null) return null;
    final latestUrl = source.routes['latest']?.url ?? '';
    if (!latestUrl.contains('{category}')) return null;
    final entries = source.category.categoryEntries;
    if (entries.isEmpty) return null;
    return entries.first['id'];
  }

  /// 加载首页数据（按源声明的多板块竖向堆叠；缺省回退单块「最新更新」）。
  Future<void> _loadHome() async {
    if (_source == null) return;
    setState(() {
      _homeLoading = true;
      _homeError = null;
    });
    final source = _source!;
    try {
      final result = await _fetchHomeSections(source);
      if (!mounted) return;
      setState(() {
        _homeSections = result.sections;
        _homeLoading = false;
      });
      // 首屏懒加载：布局完成后扫描进入视口的板块并触发抓取。
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _scanVisibleSections());
      // 主页解析完成（引擎已热）→ 预载首个分类，避免首次点分类撞冷启动弹错。
      _tryPreloadFirstCategory();
    } on Object catch (e) {
      if (!mounted) return;
      // 验证后重试若仍失败，必须把错误透出到 UI；否则 finally 只清掉
      // loading，会留下空列表 + 无错误状态，UI 误显示「暂无内容」。
      String? retryError;
      // webview 型源：验证/抽取阶段可能返回真实地址，重试时必须带上，
      // 否则又请求到被拦截的原始 URL → 验证白过、首页仍空。
      String? extractedUrl;
      String? renderedHtml;
      final handled = await VerificationNavigator.handleVerificationAndRetry(
        context,
        e,
        () async {
          final result = await _fetchHomeSections(
            source,
            extractedUrl: extractedUrl,
            renderedHtml: renderedHtml,
          );
          if (!mounted) return;
          setState(() {
            _homeSections = result.sections;
            _homeLoading = false;
          });
          WidgetsBinding.instance
              .addPostFrameCallback((_) => _scanVisibleSections());
        },
        verifyHandler: widget.verificationHandler,
        onExtracted: (url) => extractedUrl = url,
        onRenderedHtml: (html) => renderedHtml = html,
        onErrorText: (msg) => retryError = msg,
      );

      if (!handled && mounted) {
        setState(() {
          _homeError = AppLocalizations.of(context).loadFailed;
          _homeLoading = false;
        });
      } else if (handled && retryError != null && mounted) {
        // 验证完成但重试仍失败：展示加载失败，避免被空列表掩盖。
        setState(() {
          _homeError = AppLocalizations.of(context).loadFailed;
          _homeLoading = false;
        });
      }
    } finally {
      if (mounted) setState(() => _homeLoading = false);
    }
  }

  /// 按源解析首页板块并逐个拉取数据。
  ///
  /// 返回 (sections, 各板块 items 映射, 周期表数据源)。[extractedUrl]/
  /// [renderedHtml] 仅在验证重试时透传（webview 型源抽取到真实地址后复用）。
  Future<_HomeSectionsResult> _fetchHomeSections(
    PluginConfig source, {
    String? extractedUrl,
    String? renderedHtml,
  }) async {
    // 懒加载：板块数据不再在此统一抓取，改为进入视口按需抓取（见 [_ensureSection]）。
    // 周期表数据由 [_ensureScheduleData] 在进入周期表 Tab 时按需抓取。
    final sections = widget.resolveHomeSections?.call(source) ??
        const <HomeSectionConfig>[];
    return _HomeSectionsResult(
      sections: sections,
      items: const <String, List<MediaItem>>{},
      schedule: const <MediaItem>[],
    );
  }

  /// 返回周期表数据源板块。
  ///
  /// 优先 `style == 'schedule'` 的专属板块（如 233动漫 的 `/week` 路由，
  /// 服务端按天块渲染、解析器注入开播星期）；没有专属板块的源才回退
  /// latest 板块（按 `updatedAt`/status 中的星期分组）。注意不能用单个
  /// firstWhere 的 OR 条件——latest 常排在 homeSections 首位，会抢占
  /// schedule 专属板块导致周期表抓错路由。
  HomeSectionConfig _scheduleSourceSection() {
    for (final s in _homeSections) {
      if (s.style == 'schedule') return s;
    }
    return _homeSections.firstWhere(
      (s) =>
          s.id == 'latest' ||
          (s.route.isEmpty ? 'latest' : s.route) == 'latest',
      orElse: () =>
          const HomeSectionConfig(id: 'latest', title: '', route: 'latest'),
    );
  }

  /// 按需抓取单个首页板块（进入视口或重试时调用）。
  ///
  /// 已加载 / 加载中直接跳过；失败（error）允许重试。
  /// 实际网络抓取通过 [_sectionFetchChain] **串行化**：下一个板块的抓取在前
  /// 一个完成后才开始，彻底消除首屏并发突发（防 IP 封禁）。
  void _ensureSection(HomeSectionConfig sec) {
    final source = _source;
    if (source == null) return;
    final status = _sectionStatus[sec.id];
    if (status == _SectionStatus.loading || status == _SectionStatus.loaded) {
      return;
    }
    if (!mounted) return;
    setState(() => _sectionStatus[sec.id] = _SectionStatus.loading);
    // 串行入队：后续板块在前一个完成（含网络耗时 + HttpFetcher 同站间隔）后
    // 才开始，避免同一时刻向同一站点并发多个请求。
    _sectionFetchChain =
        (_sectionFetchChain ?? Future<void>.value()).then((_) => _fetchSection(source, sec));
  }

  /// 串行链中的单个板块抓取（由 [_ensureSection] 入队调用）。
  Future<void> _fetchSection(PluginConfig source, HomeSectionConfig sec) async {
    if (!mounted) return;
    if (source != _source) return; // 已切换源，丢弃旧请求结果，避免污染新源状态。
    try {
      debugPrint(
        '[OnlineContentList] _fetchSection 开始 section=${sec.id} route=${sec.route}',
      );
      final list = await widget.fetchItems(
        source,
        category: '',
        page: 1,
        vars: _homeSectionVars(source, sec),
      );
      debugPrint(
        '[OnlineContentList] _fetchSection 完成 section=${sec.id} route=${sec.route} count=${list.length}',
      );
      if (!mounted) return;
      if (source != _source) return; // 完成前又切了源。
      final limited =
          sec.limit > 0 ? list.take(sec.limit).toList(growable: false) : list;
      setState(() {
        _homeSectionItems[sec.id] = limited;
        _sectionStatus[sec.id] = _SectionStatus.loaded;
      });
    } on Object catch (e) {
      if (!mounted) return;
      if (source != _source) return;
      // webview 型源（如 hanime1.me）：无 cf_clearance Cookie 时无头 WebView
      // 返回 about:blank，SilentHtmlCapture 判内容过小返回 null →
      // WebViewResolver 抛 WebViewHtmlRequest。必须像 _loadHome/_loadRank
      // 那样弹出可见验证页并带重试回调，否则异常被吞 → 用户卡在错误/空态。
      String? retryError;
      String? extractedUrl;
      String? renderedHtml;
      final handled = await VerificationNavigator.handleVerificationAndRetry(
        context,
        e,
        () async {
          final list = await widget.fetchItems(
            source,
            category: '',
            page: 1,
            extractedUrl: extractedUrl,
            renderedHtml: renderedHtml,
            vars: _homeSectionVars(source, sec),
          );
          if (!mounted) return;
          if (source != _source) return;
          final limited =
              sec.limit > 0 ? list.take(sec.limit).toList(growable: false) : list;
          setState(() {
            _homeSectionItems[sec.id] = limited;
            _sectionStatus[sec.id] = _SectionStatus.loaded;
          });
        },
        verifyHandler: widget.verificationHandler,
        onExtracted: (url) => extractedUrl = url,
        onRenderedHtml: (html) => renderedHtml = html,
        onErrorText: (msg) => retryError = msg,
      );
      if (!mounted) return;
      if (source != _source) return;
      if (!handled) {
        setState(() => _sectionStatus[sec.id] = _SectionStatus.error);
      } else if (retryError != null) {
        // 验证已弹但重试仍失败：保留错误态，避免被空列表掩盖。
        setState(() => _sectionStatus[sec.id] = _SectionStatus.error);
      }
      // handled && retryError == null → 重试回调已成功 setState loaded，无需再处理。
    }
  }

  /// 扫描首页可见板块：进入视口的未加载板块触发抓取（方案 A 核心）。
  ///
  /// 通过各板块 GlobalKey 相对 ListView 视口的位置判断是否可见；
  /// 未布局（如被收缩）的板块跳过，待其出现后再捕获。
  void _scanVisibleSections() {
    final listCtx = _homeListKey.currentContext;
    if (listCtx == null) return;
    final listBox = listCtx.findRenderObject() as RenderBox?;
    if (listBox == null) return;
    final vpTop = listBox.localToGlobal(Offset.zero).dy;
    final vpBottom = vpTop + listBox.size.height;
    for (final sec in _homeSections) {
      if (sec.style == 'schedule') continue; // 周期表数据由 _ensureScheduleData 单独抓
      final status = _sectionStatus[sec.id];
      if (status == _SectionStatus.loading || status == _SectionStatus.loaded) {
        continue;
      }
      final key = _sectionKeys.putIfAbsent(sec.id, () => GlobalKey());
      final sctx = key.currentContext;
      if (sctx == null) continue; // 尚未布局（如被收缩）
      final box = sctx.findRenderObject() as RenderBox;
      final top = box.localToGlobal(Offset.zero).dy;
      final bottom = top + box.size.height;
      if (bottom >= vpTop && top <= vpBottom) _ensureSection(sec);
    }
  }

  /// 进入周期表 Tab 时按需抓取周期表数据（最新更新 / schedule 风格板块）。
  Future<void> _ensureScheduleData() async {
    final source = _source;
    if (source == null || !mounted) return;
    if (_scheduleItems.isNotEmpty || _scheduleLoading) return;
    setState(() => _scheduleLoading = true);
    try {
      final sec = _scheduleSourceSection();
      final items = await widget.fetchItems(
        source,
        category: '',
        page: 1,
        vars: _homeSectionVars(source, sec),
      );
      if (!mounted) return;
      setState(() {
        _scheduleItems = items.take(300).toList(growable: false);
        _scheduleLoading = false;
      });
    } on Object {
      if (mounted) setState(() => _scheduleLoading = false);
    }
  }

  /// 构造某首页板块的请求 `vars`。
  ///
  /// - [HomeSectionConfig.route] 非 `latest` 时写入特殊键 `__route`，触发
  ///   [MediaApiService.fetchApiResults] 的路由覆盖钩子，让各板块走各自路由；
  /// - [HomeSectionConfig.params] 原样并入（如 `{'category': 'kr'}`）；
  /// - 安全兜底：某源 `latest` 路由 URL 含 `{category}` 占位符但本板块未提供
  ///   category 时，补上默认分类（首个静态分类 id），避免生成畸形 URL。
  Map<String, String> _homeSectionVars(
      PluginConfig source, HomeSectionConfig sec) {
    final route = sec.route.isEmpty ? 'latest' : sec.route;
    final vars = <String, String>{
      'page': '1',
      if (route != 'latest') '__route': route,
      ...sec.params,
    };
    final latestUrl = source.routes['latest']?.url ?? '';
    if (route == 'latest' &&
        latestUrl.contains('{category}') &&
        !vars.containsKey('category') &&
        _defaultHomeCategory != null) {
      vars['category'] = _defaultHomeCategory!;
    }
    return vars;
  }


  /// 加载排行数据。
  Future<void> _loadRank() async {
    if (_source == null || !_hasRank) return;
    setState(() {
      _rankLoading = true;
      _rankError = null;
    });
    try {
      final items = await widget.fetchItems(
        _source!,
        category: null,
        page: 1,
        extractedUrl: null,
        vars: <String, String>{'page': '1'},
      );
      if (mounted) {
        setState(() {
          _rankItems = items.take(50).toList(growable: false);
          _rankLoading = false;
        });
      }
    } on Object catch (e) {
      if (!mounted) return;
      // 与 _loadHome 同理：重试失败需透出错误，避免空列表被当成「暂无内容」。
      String? retryError;
      String? extractedUrl;
      String? renderedHtml;
      final handled = await VerificationNavigator.handleVerificationAndRetry(
        context,
        e,
        () async {
          final items = await widget.fetchItems(
            _source!,
            category: null,
            page: 1,
            extractedUrl: extractedUrl,
            renderedHtml: renderedHtml,
            vars: <String, String>{'page': '1'},
          );
          _rankItems = items.take(50).toList(growable: false);
        },
        verifyHandler: widget.verificationHandler,
        onExtracted: (url) => extractedUrl = url,
        onRenderedHtml: (html) => renderedHtml = html,
        onErrorText: (msg) => retryError = msg,
      );
      if (!handled && mounted) {
        setState(() {
          _rankError = AppLocalizations.of(context).loadFailed;
          _rankLoading = false;
        });
      } else if (handled && retryError != null && mounted) {
        setState(() {
          _rankError = AppLocalizations.of(context).loadFailed;
          _rankLoading = false;
        });
      }
    } finally {
      if (mounted) setState(() => _rankLoading = false);
    }
  }

  /// 确保某分类 Tab 的状态已初始化（仅建状态，不触发拉取）。
  ///
  /// 实际首次拉取由 [_ensureTabLoaded] 在 Tab 激活时触发，避免一次性并发拉取
  /// 所有分类页占满主线程（筛选卡顿根因）。
  _CategoryTabState _ensureTabState(String categoryId) {
    return _tabStates.putIfAbsent(categoryId, () {
      return _CategoryTabState(categoryId: categoryId);
    });
  }

  /// 配合 [_onTabChanged] / [_buildTabViews] 实现「进入分类 Tab 才拉取」：
  /// 取/建状态后，仅当尚未成功加载且未在加载中时才拉首屏。
  void _ensureTabLoaded(String categoryId) {
    final state = _ensureTabState(categoryId);
    if (!state.loaded && !state.loading) {
      _loadCategoryPage(state, reset: true);
    }
  }

  /// 主页解析完成（JS 引擎已热）后，自动预载第一个分类页。
  /// 这样用户首次点任意分类时引擎已就绪，不会再因冷启动首调失败而弹出错误提示。
  /// 仅在主页与分类都就绪、且尚未预载过时执行一次；[_ensureTabLoaded] 自身会
  /// 防止重复拉取（loaded/loading 守卫）。
  void _tryPreloadFirstCategory() {
    if (_firstCategoryPreloaded) return;
    if (_source == null || _categories.isEmpty) return;
    if (_homeLoading) return; // 等主页也加载完，引擎才真正热
    _firstCategoryPreloaded = true;
    _ensureTabLoaded(_categories.first.id);
  }

  /// 构造分类页请求 vars，并做安全兜底：
  /// 当筛选把路由覆盖到需要 `{category}` 占位符的路由（如 233 动漫的 `show`
  /// 排序路由 `/show/{category}--{sort}---.html`）而当前 Tab 又没有分类
  /// （「全部」Tab 的 [categoryId] 为空）时，补入首个非空的静态分类 id，
  /// 避免生成 `/show/--hits---.html` 这类空分类坏链（用户反馈「筛选的分类不对」）。
  /// 真实分类 Tab（categoryId 非空）或筛选已显式选了分类时不干预，保持原行为。
  Map<String, String> _categoryPageVars(
      PluginConfig source, _CategoryTabState state) {
    final filterVars = state.filter.toVars();
    // 按分类默认筛选值（如国漫需 sort=hits、year=2026）：用户未选的占位由源声明补齐，
    // 用户选中值优先覆盖默认，避免 show 路由拼出空 sort/year 段导致服务端不匹配、筛选无结果。
    // source.filters 可能为 null（源未声明 filters 时走兜底生成），空 map 即不补默认。
    final defaults =
        source.filters?.defaultsFor(state.categoryId) ?? const <String, String>{};
    final merged = <String, String>{
      ...defaults,
      ...filterVars, // 用户选中覆盖默认
    };
    final vars = <String, String>{
      'page': '${state.page}',
      if (state.categoryId.isNotEmpty) 'category': state.categoryId,
      ...merged,
    };
    final routeOverride = merged['__route'];
    if (routeOverride != null &&
        routeOverride.isNotEmpty &&
        !vars.containsKey('category')) {
      final routeUrl = source.routes[routeOverride]?.url ?? '';
      if (routeUrl.contains('{category}')) {
        final defaultCat = _defaultCategoryId(source);
        if (defaultCat != null) vars['category'] = defaultCat;
      }
    }
    return vars;
  }

  /// 取源首个非空静态分类 id（兜底用，对齐 [_homeSectionVars] 的默认分类思路）。
  String? _defaultCategoryId(PluginConfig source) {
    for (final e in source.category.categoryEntries) {
      final id = e['id'] ?? '';
      if (id.isNotEmpty) return id;
    }
    return null;
  }

  /// 封装单次分类页拉取，供 [_loadCategoryPage] 在冷启动失败时重试。
  Future<List<MediaItem>> _fetchCategoryOnce(_CategoryTabState state) {
    return widget.fetchItems(
      _source!,
      category: state.categoryId,
      page: state.page,
      extractedUrl: state.extractedUrl,
      vars: _categoryPageVars(_source!, state),
    );
  }

  Future<void> _loadCategoryPage(
    _CategoryTabState state, {
    bool reset = false,
  }) async {
    if (_source == null || state.loading) return;
    if (reset) {
      state.page = 1;
      state.items.clear();
      state.hasMore = true;
      state.error = null;
    }
    setState(() => state.loading = true);
    try {
      List<MediaItem> list;
      // 首屏(page==1 且 reset)冷启动保护：JS 引擎首调不稳 / HttpFetcher 节流未就绪时，
      // 静默重试最多 2 次（800ms、1500ms）。重试期间不写 error，避免向用户弹错误提示；
      // 校验类错误（Cloudflare 等）不在此重试，交由下方 VerificationNavigator 处理。
      int attempts = 0;
      const maxAttempts = 3;
      while (true) {
        try {
          list = await _fetchCategoryOnce(state);
          break;
        } on Object catch (e) {
          final coldStart = reset && state.page == 1;
          final verifyErr = VerificationNavigator.isVerificationError(e);
          if (coldStart && !verifyErr && attempts < maxAttempts - 1) {
            attempts++;
            await Future.delayed(
                Duration(milliseconds: attempts == 1 ? 800 : 1500));
            continue;
          }
          rethrow;
        }
      }
      // 首屏冷启动偶发返回空列表（引擎/节流未就绪），再静默重试一次。
      if (reset && state.page == 1 && list.isEmpty) {
        await Future.delayed(const Duration(milliseconds: 800));
        list = await _fetchCategoryOnce(state);
      }
      if (reset) state.items.clear();
      state.items.addAll(list);
      state.hasMore = list.isNotEmpty;
      state.page++;
      state.loaded = true;
      state.error = null;
      state.extractedUrl = null;
    } on Object catch (e) {
      if (!mounted) return;
      final handled = await VerificationNavigator.handleVerificationAndRetry(
        context,
        e,
        () async {
          final list = await widget.fetchItems(
            _source!,
            category: state.categoryId,
            page: state.page,
            extractedUrl: state.extractedUrl,
            renderedHtml: state.renderedHtml,
            vars: _categoryPageVars(_source!, state),
          );
          if (reset) state.items.clear();
          state.items.addAll(list);
          state.hasMore = list.isNotEmpty;
          state.page++;
          state.loaded = true;
          state.extractedUrl = null;
          state.renderedHtml = null;
        },
        verifyHandler: widget.verificationHandler,
        onExtracted: (url) => state.extractedUrl = url,
        onRenderedHtml: (html) => state.renderedHtml = html,
        onErrorText: (_) {
          state.error = AppLocalizations.of(context).verificationFailed;
        },
      );
      if (!handled && mounted) {
        final errText = VerificationNavigator.isVerificationError(e)
            ? AppLocalizations.of(context).errorVerification
            : e.toString();
        state.error = errText;
        // 同时写入诊断本，即使不是脚本源也能看到错误原因
        final sid = _source?.id ?? 'unknown';
        ParseDiagnostics.log(sid, '❌ 加载异常: $errText');
        // 也记下是否有诊断日志可供参考
        if (ParseDiagnostics.lastLog != null) {
          ParseDiagnostics.log(sid, '(上方为本次解析的完整轨迹)');
        }
      }
    } finally {
      if (mounted) setState(() => state.loading = false);
    }
  }

  void _onSource(PluginConfig s) {
    if (s.id == _source?.id) return;
    setState(() {
      _source = s;
      _tabStates.clear();
      _filterGroupsCache.remove(s.id);
      _homeSectionItems.clear();
      _homeSections = <HomeSectionConfig>[];
      _sectionStatus.clear();
      _sectionFetchChain = null; // 断开旧源的串行链，避免旧请求结果混入新源。
      _scheduleItems = <MediaItem>[];
      _scheduleLoading = false;
      _webFavoriteItems = <MediaItem>[];
      _webFavoriteFolders = <WebFavoriteFolder>[];
      _webFavoriteLoading = false;
      _webFavoriteError = null;
      _rankItems = <MediaItem>[];
    });
    _loadCategories();
    _loadHome();
    _scrollSelectedSourceIntoView();
    _maybeShowAnnouncement(s);
  }

  /// 切换源后把选中的源 chip 平滑滚入可视区域（横向源栏项多时选中项可能在屏外）。
  void _scrollSelectedSourceIntoView() {
    final source = _source;
    if (source == null) return;
    final idx = widget.sources.indexWhere((s) => s.id == source.id);
    if (idx < 0) return;
    final key = _chipKey(idx, source.id);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = key.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.5,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  /// 进入/切换到某源时，若该源声明了公告、本页未弹过、且用户未选择「以后再不显示」，
  /// 则弹窗展示（item 7）。
  void _maybeShowAnnouncement(PluginConfig source) {
    final ann = source.announcement;
    if (ann == null || ann.title.isEmpty) return;
    if (_announcedIds.contains(source.id)) return; // 同会话不重复弹
    final key = _announcementKey(source.id, ann);
    if (_dismissedAnnouncements.contains(key)) return; // 用户选过「以后再不显示」
    _announcedIds.add(source.id);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _showAnnouncementDialog(ann, key);
    });
  }

  /// 公告去重 key：源 id + 更新时间（无更新时间则取标题）。源作者发新公告即 key 变化，
  /// 即便用户此前对该源选过「以后再不显示」，新公告仍会弹出。
  String _announcementKey(String sourceId, AnnouncementConfig ann) =>
      '$sourceId@${ann.updatedAt?.toString() ?? ann.title}';

  /// 记录用户对某公告选择「以后再不显示」并持久化。
  void _dismissAnnouncement(String key) {
    _dismissedAnnouncements.add(key);
    SharedPreferences.getInstance().then((prefs) {
      prefs.setStringList(
          _kDismissedAnnouncements, _dismissedAnnouncements.toList());
    });
  }

  /// 源公告弹窗：展示标题 / 正文 / 更新时间 / 外链；主按钮「以后再不显示」
  /// 关闭并持久跳过该公告（除非作者发布新公告），另提供「关闭」仅本次关闭。
  Future<void> _showAnnouncementDialog(
      AnnouncementConfig ann, String dismissKey) async {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AppAlertDialog(
        title: Row(
          children: <Widget>[
            Icon(Icons.campaign_outlined, color: scheme.primary),
            const SizedBox(width: AppTokens.spaceSm),
            Expanded(child: Text(ann.title)),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (ann.body != null && ann.body!.isNotEmpty) Text(ann.body!),
              if (ann.updatedAt != null) ...<Widget>[
                const SizedBox(height: AppTokens.spaceSm),
                Text(
                  l10n.updatedAt(_formatAnnouncementTime(ann.updatedAt!)),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ],
              if (ann.url != null && ann.url!.isNotEmpty) ...<Widget>[
                const SizedBox(height: AppTokens.spaceSm),
                InkWell(
                  onTap: () {
                    Navigator.of(ctx).pop();
                    openInAppBrowser(context, ann.url!);
                  },
                  child: Text(
                    l10n.sourceAnnouncementView,
                    style: TextStyle(
                      color: scheme.primary,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () {
              _dismissAnnouncement(dismissKey);
              Navigator.of(ctx).pop();
            },
            child: Text(l10n.announcementDontShowAgain),
          ),
        ],
      ),
    );
  }

  /// 把公告的 Unix 秒时间戳格式化为「YYYY-MM-DD HH:MM」（本地时区）。
  String _formatAnnouncementTime(int seconds) {
    final dt = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    final y = dt.year;
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $hh:$mm';
  }

  void _onCategoryScroll(_CategoryTabState state) {
    if (state.scroll.position.pixels >=
            state.scroll.position.maxScrollExtent - 240 &&
        !state.loading &&
        state.hasMore) {
      _loadCategoryPage(state);
    }
  }

  /// 弹「动态筛选」Sheet，应用后重新加载该分类。
  ///
  /// 筛选分组由源驱动（[ResolveFilters] → [MediaApiService.resolveFilterGroups]），
  /// 修复旧版写死年份/地区/排序/状态。无分组时静默返回（按钮本就不显示）。
  Future<void> _showFilter(_CategoryTabState state) async {
    final source = _source;
    if (source == null) return;
    final groups = await _resolveFilterGroups(source, state.categoryId);
    if (groups.isEmpty || !mounted) return;
    await showDynamicFilterSheet(
      context,
      groups: groups,
      initial: state.filter,
      onApply: (filter) {
        setState(() {
          state.filter = filter;
        });
        _loadCategoryPage(state, reset: true);
      },
    );
  }

  /// 按「源 + 当前分类」缓存筛选分组（不同分类筛选维度可能不同，故 key 含
  /// categoryId；避免每次开筛选面板都重新解析）。
  Future<List<FilterGroupConfig>> _resolveFilterGroups(
      PluginConfig source, String categoryId) async {
    final resolver = widget.resolveFilters;
    if (resolver == null) return const <FilterGroupConfig>[];
    final cacheKey = '${source.id}:$categoryId';
    final cached = _filterGroupsCache[cacheKey];
    if (cached != null) return cached;
    final groups = await resolver(source, categoryId);
    _filterGroupsCache[cacheKey] = groups;
    return groups;
  }

  /// 某源（在指定分类下）是否有可用的筛选分组（决定分类页是否显示筛选按钮）。
  /// 首次为 null（未解析），触发异步解析后重建；解析完成缓存布尔结果。
  bool _hasFilters(PluginConfig source, String categoryId) {
    final cacheKey = '${source.id}:$categoryId';
    final cached = _filterGroupsCache[cacheKey];
    if (cached != null) return cached.isNotEmpty;
    // 未解析：后台解析后刷新 UI（按钮随之出现/隐藏）。
    if (widget.resolveFilters != null) {
      _resolveFilterGroups(source, categoryId).then((_) {
        if (mounted) setState(() {});
      });
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    if (widget.sources.isEmpty) {
      return Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.maybePop(context),
          ),
          title: Text(l10n.onlineBrowse),
        ),
        body: AppEmptyState(
          icon: widget.emptyIcon,
          message: l10n.emptySources,
          actionLabel: widget.onEnableRecommended != null
              ? l10n.enableRecommendedSources
              : l10n.addSource,
          onAction: widget.onEnableRecommended ?? widget.onAddSource,
          secondaryActionLabel:
              widget.onEnableRecommended != null ? l10n.addSource : null,
          onSecondaryAction:
              widget.onEnableRecommended != null ? widget.onAddSource : null,
        ),
      );
    }

    _rebuildTabController();
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.maybePop(context),
        ),
        title: Text(_source?.name ?? l10n.onlineBrowse),
        actions: _source == null
            ? null
            : <Widget>[
                IconButton(
                  icon: const Icon(Icons.public),
                  tooltip: l10n.openSourceWebsite,
                  onPressed: () =>
                      openInAppBrowser(context, _source!.site.baseUrl),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: l10n.refreshList,
                  onPressed: () {
                    _loadHome();
                    _tabStates.forEach((_, s) =>
                        _loadCategoryPage(s, reset: true));
                    if (_hasRank) _loadRank();
                  },
                ),
                const LayoutPickerButton(),
              ],
      ),
      body: _source == null
          ? AppEmptyState(icon: widget.emptyIcon, message: l10n.emptySources)
          : Column(
              children: <Widget>[
                _buildSourceBar(l10n),
                // 分类 TabBar 置于源选择栏下方（结构重排：源在上、分类在下）
                _buildCategoryTabBar(l10n),
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: _buildTabViews(l10n),
                  ),
                ),
              ],
            ),
    );
  }

  /// 分类 TabBar（源选择栏下方的第二行）。与 TabBarView 共用同一 [_tabController]，
  /// 并在顶部加细分隔线以区分层级（源栏 / 分类栏）。
  ///
  /// 筛选按钮内嵌 TabBar 行右端：仅当当前 Tab 落在「分类区间」
  /// （首页 / 周期表 / 排行 之外）且该分类存在筛选分组时显示；已应用筛选条件时
  /// 图标着色为 [scheme.primary] 提示当前处于筛选态。随 [_tabController] 切换自动重建。
  Widget _buildCategoryTabBar(AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(
          bottom: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: TabBar(
              controller: _tabController,
              isScrollable: true,
              indicatorSize: TabBarIndicatorSize.tab,
              indicator: BoxDecoration(
                borderRadius: BorderRadius.circular(AppTokens.radiusFull),
                color: scheme.primaryContainer,
              ),
              labelColor: scheme.onPrimaryContainer,
              unselectedLabelColor: scheme.onSurfaceVariant,
              labelStyle: const TextStyle(fontWeight: FontWeight.w600),
              tabs: _buildTabs(l10n),
            ),
          ),
          AnimatedBuilder(
            animation: _tabController,
            builder: (context, _) {
              final catStart = _catStart;
              final idx = _tabController.index;
              // 仅「分类区间」(idx ∈ [catStart, catStart + _categories.length)) 显示筛选按钮。
              if (idx < catStart || idx >= catStart + _categories.length) {
                return const SizedBox.shrink();
              }
              final cat = _categories[idx - catStart];
              final state = _ensureTabState(cat.id);
              if (!_hasFilters(_source!, cat.id)) {
                return const SizedBox.shrink();
              }
              final applied = state.filter.toVars().isNotEmpty;
              return IconButton(
                icon: Icon(
                  Icons.filter_list,
                  color: applied ? scheme.primary : null,
                ),
                tooltip: l10n.filter,
                onPressed: () => _showFilter(state),
              );
            },
          ),
        ],
      ),
    );
  }

  List<Widget> _buildTabs(AppLocalizations l10n) {
    final tabs = <Widget>[
      Tab(text: l10n.onlineTabHome),
    ];
    if (_hasScheduleData) {
      tabs.add(Tab(text: l10n.onlineTabSchedule));
    }
    if (_hasWebFavorite) {
      tabs.add(Tab(text: l10n.onlineTabWebFavorite));
    }
    for (final c in _categories) {
      tabs.add(Tab(text: c.title));
    }
    if (_hasRank) {
      tabs.add(Tab(text: l10n.onlineTabRanking));
    }
    return tabs;
  }

  List<Widget> _buildTabViews(AppLocalizations l10n) {
    final views = <Widget>[
      _buildHomeTab(l10n),
    ];
    if (_hasScheduleData) {
      views.add(_buildScheduleTab(l10n));
    }
    if (_hasWebFavorite) {
      views.add(_buildWebFavoriteTab(l10n));
    }
    for (final c in _categories) {
      final state = _ensureTabState(c.id);
      views.add(_buildCategoryTab(l10n, state, c.title));
    }
    // 仅对当前激活的分类 Tab 触发首次拉取；其余分类进入时才由 [_onTabChanged] 加载。
    final activeIdx = _tabController.index;
    if (activeIdx >= _catStart && activeIdx < _catStart + _categories.length) {
      _ensureTabLoaded(_categories[activeIdx - _catStart].id);
    }
    if (_hasRank) {
      views.add(_buildRankTab(l10n));
    }
    return views;
  }

  Widget _buildSourceBar(AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTokens.spaceLg,
        vertical: AppTokens.spaceSm,
      ),
      decoration: BoxDecoration(
        color: scheme.surface,
        boxShadow: AppShadows.card(scheme),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: widget.sources.asMap().entries.map((e) {
                  final int i = e.key;
                  final s = e.value;
                  final selected = s.id == _source?.id;
                  return Padding(
                    key: selected ? _chipKey(i, s.id) : null,
                    padding: const EdgeInsets.only(right: AppTokens.spaceSm),
                    child: _SourceChip(
                      label: s.name,
                      selected: selected,
                      onTap: () => _onSource(s),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
          if (widget.onSearch != null)
            IconButton(
              icon: const Icon(Icons.search),
              tooltip: l10n.search,
              onPressed: widget.onSearch,
            ),
        ],
      ),
    );
  }

  /// Tab 1: 首页（最新更新 + 热门推荐 + 分类入口）。
  /// Tab 1: 首页（按源声明的多板块竖向堆叠；缺省回退单块「最新更新」）。
  Widget _buildHomeTab(AppLocalizations l10n) {
    if (_homeLoading) {
      return const Center(child: AppLoadingIndicator());
    }
    if (_homeError != null) {
      return AppErrorState(
        message: _homeError!,
        onRetry: () => _loadHome(),
        retryLabel: l10n.retry,
      );
    }
    if (_homeSections.isEmpty) {
      return _buildEmptyWithDiagnostics(
        l10n,
        message: l10n.emptyContent,
        sourceId: _source?.id,
      );
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (ScrollNotification _) {
        _scanVisibleSections();
        return false;
      },
      child: ListView(
        key: _homeListKey,
        children: <Widget>[
          const SizedBox(height: AppTokens.spaceSm),
          for (final sec in _homeSections) ...<Widget>[
            if (sec.style != 'schedule')
              ...<Widget>[
                OnlineHomeSection(
                  key: _sectionKeys.putIfAbsent(sec.id, () => GlobalKey()),
                  title: _sectionTitle(l10n, sec),
                  items: _homeSectionItems[sec.id] ?? const <MediaItem>[],
                  onItemTap: widget.onItemTap,
                  onViewAll: _sectionViewAll(sec),
                  heroPrefix: 'home-${sec.id}',
                  loading: _sectionStatus[sec.id] != _SectionStatus.loaded &&
                      _sectionStatus[sec.id] != _SectionStatus.error,
                  errorMessage: _sectionStatus[sec.id] == _SectionStatus.error
                      ? l10n.loadFailed
                      : null,
                  onRetry: () => _ensureSection(sec),
                ),
                const SizedBox(height: AppTokens.spaceMd),
              ],
          ],
        ],
      ),
    );
  }

  /// 板块标题：源声明的 title 优先；缺省按 id 映射到 l10n（避免 Dart 硬编码中文）。
  String _sectionTitle(AppLocalizations l10n, HomeSectionConfig sec) {
    if (sec.title.isNotEmpty) return sec.title;
    return switch (sec.id) {
      'latest' => l10n.latestUpdates,
      'hots' => l10n.hotRecommendations,
      'explore' => l10n.latestUpdates,
      'rank' => l10n.onlineTabRanking,
      _ => sec.id,
    };
  }

  /// 「查看全部」回调：板块若对应某分类分区则跳到该分类 Tab，否则跳到首个分类 Tab。
  VoidCallback? _sectionViewAll(HomeSectionConfig sec) {
    if (sec.style == 'schedule') return null;
    if (_categories.isEmpty) return null;
    final catId = sec.params['category'];
    final idx = catId != null
        ? _categories.indexWhere((c) => c.id == catId)
        : -1;
    return () {
      final catStart = _catStart;
      _tabController.animateTo(catStart + (idx >= 0 ? idx : 0));
    };
  }

  /// Tab 2: 周期表（7 天分组 + 当天列表）。
  Widget _buildScheduleTab(AppLocalizations l10n) {
    if (_scheduleLoading) {
      return const Center(child: AppLoadingIndicator());
    }
    if (_scheduleItems.isEmpty) {
      return AppEmptyState(
        icon: Icons.calendar_today_outlined,
        message: l10n.emptyContent,
      );
    }
    return SingleChildScrollView(
      child: OnlineScheduleSection(
        items: _scheduleItems,
        source: _source,
        onItemTap: widget.onItemTap,
      ),
    );
  }

  /// Tab 2.5: 网络收藏（源站书架 / 收藏夹）。
  ///
  /// 两种形态：
  /// - 源声明了列表 `route` → 进入 Tab 时懒加载（[_loadWebFavorite]），网格展示；
  /// - 仅声明网页 `url`（无 route）→ Tab 内提供「在浏览器打开」按钮，
  ///   不在此拉取列表（列表数据在源站内，app 无法结构化获取）。
  Widget _buildWebFavoriteTab(AppLocalizations l10n) {
    final source = _source;
    if (source == null) return const SizedBox.shrink();
    final wf = source.webFavorite;
    final scheme = Theme.of(context).colorScheme;

    // 纯网页入口（无 route）：提供「在浏览器打开」按钮。
    final isUrlOnly = wf != null &&
        (wf.route == null || !source.routes.containsKey(wf.route)) &&
        (wf.url ?? '').isNotEmpty;
    if (isUrlOnly) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppTokens.spaceLg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.bookmark_outline, size: 48, color: scheme.onSurfaceVariant),
              const SizedBox(height: AppTokens.spaceMd),
              Text(
                wf!.title ?? l10n.onlineTabWebFavorite,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: AppTokens.spaceSm),
              FilledButton.icon(
                icon: const Icon(Icons.open_in_browser),
                label: Text(l10n.openInBrowser),
                onPressed: () => openInAppBrowser(
                  context,
                  _resolveWebFavoriteUrl(source, wf.url!),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // route 列表：懒加载 + 网格/列表展示。
    if (_webFavoriteLoading) {
      return const Center(child: AppLoadingIndicator());
    }
    if (_webFavoriteError != null) {
      return AppErrorState(
        message: _webFavoriteError!,
        onRetry: () => _loadWebFavorite(),
        retryLabel: l10n.retry,
      );
    }
    if (_webFavoriteItems.isEmpty) {
      return AppEmptyState(
        icon: Icons.bookmark_outline,
        message: l10n.emptyContent,
      );
    }
    final hasFolders = _webFavoriteFolders.isNotEmpty;
    return Column(
      children: <Widget>[
        if (hasFolders) _buildWebFavoriteFolderChips(l10n, source, wf!),
        Expanded(child: _buildMediaItemGrid(l10n, _webFavoriteItems)),
      ],
    );
  }

  /// 网络收藏文件夹切换条：横向滚动 chip。「全部」为当前内联视图；
  /// 点文件夹跳转该文件夹 URL 的浏览页（复用 [SourceUrlBrowseScreen] 解析/分页）。
  Widget _buildWebFavoriteFolderChips(
    AppLocalizations l10n,
    PluginConfig source,
    WebFavoriteConfig wf,
  ) {
    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          horizontal: AppTokens.spaceLg,
          vertical: 6,
        ),
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text(l10n.imageFavoriteAllFolders),
              selected: true,
              onSelected: (_) {},
            ),
          ),
          ..._webFavoriteFolders.map(
            (WebFavoriteFolder f) => Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ActionChip(
                label: Text(
                  f.title.isEmpty ? l10n.webFavoriteDefaultFolder : f.title,
                ),
                onPressed: () => _openWebFavoriteFolder(source, f),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 点击文件夹：跳转该文件夹 URL 的浏览页（复用 [SourceUrlBrowseScreen]）。
  void _openWebFavoriteFolder(PluginConfig source, WebFavoriteFolder f) {
    final url = _resolveWebFavoriteUrl(source, f.url);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SourceUrlBrowseScreen(
          source: source,
          title: f.title.isEmpty ? (source.webFavorite?.title ?? '') : f.title,
          seedUrl: url,
          onItemTap: widget.onItemTap,
        ),
      ),
    );
  }

  /// 网络收藏（route 列表）懒加载：进入该 Tab 时按需抓取源站书架。
  ///
  /// 与 [_ensureScheduleData] 同理走 `__route` 路由覆盖钩子；纯网页入口
  /// 不走此路径（由 Tab 内按钮打开浏览器）。
  Future<void> _loadWebFavorite() async {
    final source = _source;
    if (source == null || !mounted) return;
    final wf = source.webFavorite;
    if (wf == null || !wf.enabled) return;
    // 纯网页入口不拉列表。
    if ((wf.route == null || !source.routes.containsKey(wf.route)) &&
        (wf.url ?? '').isNotEmpty) {
      return;
    }
    if (_webFavoriteItems.isNotEmpty || _webFavoriteLoading) return;
    setState(() => _webFavoriteLoading = true);
    try {
      if (wf.folders) {
        await _loadWebFavoriteWithFolders(source, wf);
      } else {
        final items = await widget.fetchItems(
          source,
          category: '',
          page: 1,
          vars: <String, String>{
            'page': '1',
            if (wf.route != null) '__route': wf.route!,
          },
        );
        if (!mounted) return;
        setState(() {
          _webFavoriteItems = items.take(200).toList(growable: false);
          _webFavoriteLoading = false;
        });
      }
    } on Object {
      if (mounted) setState(() => _webFavoriteLoading = false);
    }
  }

  /// 多文件夹模式：直接抓收藏页 HTML，解析文件夹列表 + 「全部」列表。
  Future<void> _loadWebFavoriteWithFolders(
    PluginConfig source,
    WebFavoriteConfig wf,
  ) async {
    final routeUrl = wf.route != null && source.routes.containsKey(wf.route)
        ? source.routes[wf.route]!.url
        : (wf.url ?? '');
    final url = _resolveWebFavoriteUrl(source, routeUrl);
    final html =
        await HttpFetcher.instance.getHtml(url, referer: source.site.baseUrl);
    if (!mounted) return;
    if (html.isEmpty) {
      setState(() => _webFavoriteLoading = false);
      return;
    }
    // 解析文件夹列表（失败不影响列表展示）。
    try {
      final fr = await ScriptResolver().resolveFromHtml(
        source,
        'folders',
        html,
        vars: <String, String>{
          'baseUrl': ConfigLoader.instance.getActiveMirror(source),
          'page': '1',
        },
      );
      if (fr is List) {
        final list = <WebFavoriteFolder>[];
        for (final e in fr) {
          if (e is Map) {
            list.add(WebFavoriteFolder(
              (e['title'] ?? '').toString(),
              (e['url'] ?? '').toString(),
              (e['value'] ?? '').toString(),
            ));
          }
        }
        _webFavoriteFolders = list;
      }
    } on Object {
      _webFavoriteFolders = const <WebFavoriteFolder>[];
    }
    // 解析「全部」列表（与源列表解析器一致）。
    final entry = _webFavoriteListEntry(source);
    final items = await ScriptResolver().resolveFromHtml(
      source,
      entry,
      html,
      vars: <String, String>{
        'baseUrl': ConfigLoader.instance.getActiveMirror(source),
        'page': '1',
      },
    );
    if (!mounted) return;
    setState(() {
      _webFavoriteItems = items is List<MediaItem>
          ? items.take(200).toList(growable: false)
          : const <MediaItem>[];
      _webFavoriteLoading = false;
    });
  }

  /// 选取源的「列表解析入口」（与 [SourceUrlBrowseScreen] 一致）。
  static String _webFavoriteListEntry(PluginConfig source) {
    for (final k in const <String>['explore', 'category', 'search', 'latest']) {
      if (source.parser.overrides?.containsKey(k) ?? false) return k;
      if (source.selectors?.containsKey(k) ?? false) return k;
      if (source.routes.containsKey(k)) return k;
    }
    return 'search';
  }

  /// 通用 MediaItem 网格/列表渲染（网络收藏列表复用，避免与分类 Tab 的
  /// 分页状态耦合）。无分页（源站书架为有限集合）。
  Widget _buildMediaItemGrid(AppLocalizations l10n, List<MediaItem> items) {
    final layout = _layoutStore.settings;
    final cross =
        layout.layoutMode == LayoutMode.list ? 1 : layout.gridColumns;
    final spacing = layout.gridSpacing;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final width = c.maxWidth;
        var itemW = layout.layoutMode == LayoutMode.list
            ? width - AppTokens.spaceLg * 2
            : (width - AppTokens.spaceLg * 2 - spacing * (cross - 1)) / cross;
        // 极端窄屏 + 高列数时 itemW 可能非正（负的 childAspectRatio 会直接
        // 抛布局断言崩溃）。下限保护：至少一列能放下 96px 封面（修复 130）。
        if (itemW < 96) itemW = 96;
        if (layout.layoutMode == LayoutMode.list) {
          return ListView.builder(
            padding: const EdgeInsets.all(AppTokens.spaceLg),
            itemCount: items.length,
            itemBuilder: (BuildContext c, int i) =>
                _buildListItem(l10n, items[i]),
          );
        }
        return GridView.builder(
          padding: const EdgeInsets.all(AppTokens.spaceLg),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cross,
            mainAxisSpacing: spacing,
            crossAxisSpacing: spacing,
            childAspectRatio: itemW /
                (itemW / AppTokens.coverAspectRatio + _textAreaHeight(layout)),
          ),
          itemCount: items.length,
          itemBuilder: (BuildContext c, int i) =>
              _buildContentCard(l10n, items[i], itemW),
        );
      },
    );
  }

  /// 将源声明的相对 URL 解析为绝对地址（相对基址直接拼接，绝对地址原样返回）。
  String _resolveWebFavoriteUrl(PluginConfig source, String url) {
    if (url.startsWith('http://') || url.startsWith('https://')) return url;
    final base = source.site.baseUrl;
    if (base.endsWith('/') && url.startsWith('/')) {
      return '${base.substring(0, base.length - 1)}$url';
    }
    if (!base.endsWith('/') && !url.startsWith('/')) return '$base/$url';
    return '$base$url';
  }

  /// Tab 3-N: 动态分类（网格列表 + 分页）。
  ///
  /// 布局按钮保留在 AppBar（与其他页面惯例一致），筛选入口已内嵌到
  /// [_buildCategoryTabBar] 行右端 —— 此处直接返回分类主体，消除重复按钮与空白占位。
  Widget _buildCategoryTab(
    AppLocalizations l10n,
    _CategoryTabState state,
    String categoryTitle,
  ) {
    return _buildCategoryBody(l10n, state);
  }

  Widget _buildCategoryBody(AppLocalizations l10n, _CategoryTabState state) {
    if (state.loading && state.items.isEmpty) {
      return const Center(child: AppLoadingIndicator());
    }
    if (state.error != null && state.items.isEmpty) {
      return _buildErrorWithDiagnostics(
        l10n,
        errorMessage: l10n.loadFailed,
        detailError: state.error,
        sourceId: _source?.id,
        onRetry: () => _loadCategoryPage(state, reset: true),
        retryLabel: l10n.retry,
      );
    }
    if (state.items.isEmpty) {
      return _buildEmptyWithDiagnostics(
        l10n,
        message: l10n.emptyCategory,
        sourceId: _source?.id,
      );
    }
    return _buildCategoryGrid(l10n, state);
  }

  /// 带调试信息的错误状态：当加载失败且属于脚本源时，显示错误详情 + 解析诊断记录。
  Widget _buildErrorWithDiagnostics(
    AppLocalizations l10n, {
    required String errorMessage,
    String? detailError,
    String? sourceId,
    VoidCallback? onRetry,
    String? retryLabel,
  }) {
    final showDiag = ParseDiagnostics.lastLog?.isNotEmpty == true;
    return ListView(
      padding: const EdgeInsets.all(AppTokens.spaceLg),
      children: <Widget>[
        AppErrorState(
          message: errorMessage,
          onRetry: onRetry,
          retryLabel: retryLabel,
        ),
        if (detailError != null && detailError!.isNotEmpty) ...<Widget>[
          const SizedBox(height: AppTokens.spaceMd),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(AppTokens.spaceSm),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.errorContainer.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(AppTokens.radiusSm),
            ),
            child: Text(
              '详情: $detailError',
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 12,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
        if (showDiag) ...<Widget>[
          const SizedBox(height: AppTokens.spaceMd),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(AppTokens.spaceMd),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.errorContainer.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(AppTokens.radiusMd),
              border: Border.all(
                color: Theme.of(context).colorScheme.error.withValues(alpha: 0.3),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '诊断信息（截图发给开发者）：',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: AppTokens.spaceSm),
                SelectableText(
                  ParseDiagnostics.lastLog!,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// 带调试信息的空状态：当列表为空且属于脚本源时，显示解析诊断记录，
  /// 方便不懂技术的用户直接截图发给开发者（无需 adb/logcat）。
  Widget _buildEmptyWithDiagnostics(
    AppLocalizations l10n, {
    required String message,
    String? sourceId,
  }) {
    final showDiag = sourceId != null &&
        ParseDiagnostics.lastSourceId == sourceId &&
        ParseDiagnostics.lastLog != null &&
        ParseDiagnostics.lastLog!.isNotEmpty;
    return ListView(
      padding: const EdgeInsets.all(AppTokens.spaceLg),
      children: <Widget>[
        AppEmptyState(icon: widget.emptyIcon, message: message),
        if (showDiag) ...<Widget>[
          const SizedBox(height: AppTokens.spaceMd),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(AppTokens.spaceMd),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.errorContainer.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(AppTokens.radiusMd),
              border: Border.all(
                color: Theme.of(context).colorScheme.error.withValues(alpha: 0.3),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '调试信息（截图发给开发者）：',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: AppTokens.spaceSm),
                SelectableText(
                  ParseDiagnostics.lastLog!,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildCategoryGrid(AppLocalizations l10n, _CategoryTabState state) {
    // 从全局布局设置读取参数（替代硬编码 cross=3）
    final layout = _layoutStore.settings;
    final cross = layout.layoutMode == LayoutMode.list ? 1 : layout.gridColumns;
    final spacing = layout.gridSpacing;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final width = c.maxWidth;
        // 列表模式：单列全宽；网格模式：按列数均分
        var itemW = layout.layoutMode == LayoutMode.list
            ? width - AppTokens.spaceLg * 2
            : (width - AppTokens.spaceLg * 2 - spacing * (cross - 1)) / cross;
        // 极端窄屏 + 高列数时 itemW 可能非正（负的 childAspectRatio 会直接
        // 抛布局断言崩溃）。下限保护：至少一列能放下 96px 封面（修复 130）。
        if (itemW < 96) itemW = 96;

        // 列表模式直接返回 ListView
        if (layout.layoutMode == LayoutMode.list) {
          return _buildCategoryList(l10n, state, itemW);
        }

        // 网格模式
        return GridView.builder(
          controller: state.scroll
            ..removeListener(state.scrollListener)
            ..addListener(state.scrollListener = () => _onCategoryScroll(state)),
          padding: const EdgeInsets.all(AppTokens.spaceLg),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cross,
            mainAxisSpacing: spacing,
            crossAxisSpacing: spacing,
            childAspectRatio: itemW / (itemW / AppTokens.coverAspectRatio + _textAreaHeight(layout)),
          ),
          itemCount: state.items.length + (state.hasMore ? 1 : 0),
          itemBuilder: (BuildContext c, int i) {
            if (i >= state.items.length) {
              return const Center(child: AppLoadingIndicator());
            }
            final item = state.items[i];
            return _buildContentCard(l10n, item, itemW);
          },
        );
      },
    );
  }

  /// 根据布局设置计算文本区域高度（标题+可选的作者/状态）。
  double _textAreaHeight(LayoutSettings layout) {
    if (!layout.showTitle && !layout.showAuthor) return 4; // 全隐藏时最小间距
    final lineHeight = layout.titleFontSize * 1.4;
    var lines = 0.0;
    if (layout.showTitle) lines += layout.titleMaxLines.toDouble();
    if (layout.showAuthor) lines += 1.0;
    // 进度条/徽标额外占一行（进度条3px + 间距约9px ≈ 1行高）
    if (layout.showProgress && layout.progressDisplay == ProgressDisplayMode.bar) {
      lines += 0.3;
    }
    return lineHeight * lines + 12;
  }

  /// 列表模式构建器（单列 ListTile 风格）。
  Widget _buildCategoryList(AppLocalizations l10n, _CategoryTabState state, double width) {
    return ListView.builder(
      controller: state.scroll
        ..removeListener(state.scrollListener)
        ..addListener(state.scrollListener = () => _onCategoryScroll(state)),
      padding: const EdgeInsets.all(AppTokens.spaceLg),
      itemCount: state.items.length + (state.hasMore ? 1 : 0),
      itemBuilder: (BuildContext c, int i) {
        if (i >= state.items.length) {
          return const Center(child: AppLoadingIndicator());
        }
        final item = state.items[i];
        return _buildListItem(l10n, item);
      },
    );
  }

  /// 构建单个列表项（列表模式下使用）。
  Widget _buildListItem(AppLocalizations l10n, MediaItem item) {
    final layout = _layoutStore.settings;
    final isCompact = layout.listStyle == ListLayoutStyle.compact;
    return AppCard(
      onTap: () => widget.onItemTap(item, '${widget.title}-${item.id}-list'),
      padding: EdgeInsets.zero,
      child: ListTile(
        contentPadding: EdgeInsets.symmetric(
          horizontal: AppTokens.spaceMd,
          vertical: isCompact ? AppTokens.spaceXs : AppTokens.spaceSm,
        ),
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(layout.coverRadius.toDouble()),
          child: SizedBox(
            width: isCompact ? 40 : 56,
            height: isCompact ? 56 : 78,
            child: AppCoverImage(
              coverUrl: item.coverUrl,
              source: context.read<SourceRepository>().getById(item.sourceId ?? ''),
              title: item.title,
              width: isCompact ? 40 : 56,
              height: isCompact ? 56 : 78,
              heroTag: '${widget.title}-${item.id}-list',
              radius: layout.coverRadius,
            ),
          ),
        ),
        title: layout.showTitle
            ? Text(
                item.title,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      fontSize: layout.titleFontSize,
                    ),
                maxLines: layout.titleMaxLines,
                overflow: TextOverflow.ellipsis,
              )
            : null,
        subtitle: (layout.showAuthor && (item.author != null || item.status != null))
            ? Text(
                item.author ?? item.status ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              )
            : null,
        trailing: layout.showProgress
            ? FutureBuilder<double?>(
                future: _progressFutures.putIfAbsent(
                  '${item.id}#list',
                  () => _computeProgress(item),
                ),
                builder: (context, snap) {
                  final double? p = snap.data;
                  if (p == null || p <= 0) return const SizedBox.shrink();
                  return Text(
                    '${(p * 100).round()}%',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.primary,
                        ),
                  );
                },
              )
            : null,
      ),
    );
  }

  /// 构建网格内容卡片（应用布局设置 + 进度显示）。
  Widget _buildContentCard(AppLocalizations l10n, MediaItem item, double itemW) {
    final layout = _layoutStore.settings;
    // 以「条目 + 是否显示进度」为键缓存，确保用户切换「显示进度」开关后能重新计算。
    final String progKey = '${item.id}#${layout.showProgress}';
    final future = _progressFutures.putIfAbsent(
      progKey,
      () => layout.showProgress
          ? _computeProgress(item)
          : Future<double?>.value(null),
    );
    return FutureBuilder<double?>(
      future: future,
      builder: (ctx, snap) => ContentCard(
        title: item.title,
        coverUrl: item.coverUrl,
        source: context.read<SourceRepository>().getById(item.sourceId ?? ''),
        subtitle: (layout.showAuthor && item.status != null) ? item.status : null,
        meta: (layout.showAuthor && item.author != null) ? item.author : null,
        width: itemW,
        heroTag: '${widget.title}-${item.id}',
        progress: snap.data,
        onTap: () => widget.onItemTap(item, '${widget.title}-${item.id}'),
      ),
    );
  }

  /// 计算某内容的进度值（0.0 .. 1.0）。
  ///
  /// - 影视/动漫：用 [MediaWatchedManager] 的精确已看集数比例。
  /// - 小说/漫画：用 [NovelProgressManager]/[ComicProgressManager] 的
  ///   `chapterIndex` 占 `totalChapters` 的真实百分比；若尚未缓存总章数，
  ///   仅以极小进度（0.02）标记「已开始」。
  Future<double?> _computeProgress(MediaItem item) async {
    final SourceType? type = item.sourceType;

    if (type == SourceType.animeSource) {
      try {
        final watchedMgr = context.read<MediaWatchedManager>();
        final watched = watchedMgr.watchedCount(item.id);
        if (watched > 0 &&
            item.episodeCount != null &&
            item.episodeCount! > 0) {
          return (watched / item.episodeCount!).clamp(0.0, 1.0);
        }
      } on Object {/* 继续尝试 */}
    }

    if (type == SourceType.novelSource) {
      try {
        final p = await NovelProgressManager().get(item.id);
        if (p != null) {
          if (p.totalChapters != null && p.totalChapters! > 0) {
            return ((p.chapterIndex + 1) / p.totalChapters!)
                .clamp(0.0, 1.0);
          }
          if (p.chapterIndex > 0) return 0.02;
        }
      } on Object {/* 忽略 */}
    }

    if (type == SourceType.mangaSource) {
      try {
        final p = await ComicProgressManager().get(item.id);
        if (p != null) {
          if (p.totalChapters != null && p.totalChapters! > 0) {
            return ((p.chapterIndex + 1) / p.totalChapters!)
                .clamp(0.0, 1.0);
          }
          if (p.chapterIndex > 0) return 0.02;
        }
      } on Object {/* 忽略 */}
    }

    return null;
  }

  /// Tab Last: 排行榜（Top 50）。
  Widget _buildRankTab(AppLocalizations l10n) {
    if (_rankLoading) {
      return const Center(child: AppLoadingIndicator());
    }
    if (_rankError != null) {
      return AppErrorState(
        message: _rankError!,
        onRetry: () => _loadRank(),
        retryLabel: l10n.retry,
      );
    }
    if (_rankItems.isEmpty) {
      return AppEmptyState(
        icon: Icons.emoji_events_outlined,
        message: l10n.emptyContent,
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(AppTokens.spaceLg),
      itemCount: _rankItems.length,
      separatorBuilder: (_, __) => const SizedBox(height: AppTokens.spaceMd),
      itemBuilder: (BuildContext c, int i) {
        final item = _rankItems[i];
        final rank = i + 1;
        return AppCard(
          onTap: () => widget.onItemTap(item, null),
          child: Row(
            children: <Widget>[
              Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: rank <= 3
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.surfaceContainerHighest,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  '$rank',
                  style: TextStyle(
                    color: rank <= 3
                        ? Theme.of(context).colorScheme.onPrimary
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: AppTokens.spaceMd),
              Container(
                width: 40,
                height: 56,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(AppTokens.radiusSm),
                ),
                child: item.coverUrl != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(AppTokens.radiusSm),
                        child: SourceImage(
                          url: item.coverUrl,
                          source: _source,
                          width: 40,
                          height: 56,
                          fit: BoxFit.cover,
                          placeholder: const Icon(Icons.movie, size: 20),
                        ),
                      )
                    : const Icon(Icons.movie, size: 20),
              ),
              const SizedBox(width: AppTokens.spaceMd),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      item.title,
                      style: Theme.of(context).textTheme.titleSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (item.status != null && item.status!.isNotEmpty)
                      Text(
                        item.status!,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant),
                      ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        );
      },
    );
  }
}

/// 源选择栏的胶囊/卡片式芯片。
///
/// 选中态填充 [ColorScheme.primaryContainer] + [ColorScheme.onPrimaryContainer] 文字
/// + 圆角胶囊 + primary 描边；未选中态低强调描边、背景为 surface。全部取 ColorScheme，
/// 深浅色自适应，禁止硬编码颜色。
class _SourceChip extends StatelessWidget {
  const _SourceChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(AppTokens.radiusFull),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppTokens.spaceMd,
          vertical: AppTokens.spaceSm,
        ),
        decoration: BoxDecoration(
          color: selected ? scheme.primaryContainer : scheme.surface,
          borderRadius: BorderRadius.circular(AppTokens.radiusFull),
          border: Border.all(
            color: selected
                ? scheme.primary
                : scheme.outlineVariant.withValues(alpha: 0.8),
          ),
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: selected
                    ? scheme.onPrimaryContainer
                    : scheme.onSurfaceVariant,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              ),
        ),
      ),
    );
  }
}

/// 每个动态分类 Tab 的独立状态。
class _CategoryTabState {
  _CategoryTabState({required this.categoryId});

  final String categoryId;
  final List<MediaItem> items = <MediaItem>[];
  final ScrollController scroll = ScrollController();
  // 必须作为字段持有以避免被 GC（removeListener 用）。
  // ignore: prefer_function_declarations_over_variables
  late VoidCallback scrollListener = () {};
  int page = 1;
  bool loading = false;
  bool hasMore = true;
  /// 是否已成功拉取过首屏：用于「进入分类 Tab 才拉取」的去重，
  /// 避免 [_buildTabViews] 一次性并发拉取所有分类页占满主线程（筛选卡顿根因）。
  bool loaded = false;
  String? error;
  String? extractedUrl;
  String? renderedHtml;
  DynamicOnlineFilter filter = const DynamicOnlineFilter();
}

/// 首页多板块拉取结果（[_OnlineContentListScreenState._fetchHomeSections] 内部使用）。
///
/// 顶层类（Dart 不允许类嵌套），用于把「板块配置 / 各板块数据 / 周期表数据」
/// 一并返回，避免 [_OnlineContentListScreenState] 内多值传递的样板代码。
class _HomeSectionsResult {
  const _HomeSectionsResult({
    required this.sections,
    required this.items,
    required this.schedule,
  });
  final List<HomeSectionConfig> sections;
  final Map<String, List<MediaItem>> items;
  final List<MediaItem> schedule;
}

/// 首页板块懒加载状态（未加载以 Map 中不存在表示）。
enum _SectionStatus {
  /// 抓取中。
  loading,
  /// 已抓取成功。
  loaded,
  /// 抓取失败。
  error,
}

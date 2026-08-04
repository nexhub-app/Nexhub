import 'dart:io';
import 'dart:async';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../../core/comic/comic_progress_manager.dart';
import '../../../core/comic/models/reader_preferences.dart';
import 'reader_settings_sheet.dart';
import '../../../core/settings/general_settings.dart';
import '../../../core/settings/reader_default_settings.dart';
import '../../../core/favorites/favorites_manager.dart';
import '../../../core/history/history_manager.dart';
import '../../../core/history/media_watched_manager.dart';
import '../../../core/local/local_content_manager.dart';
import '../../../core/models/episode.dart';
import '../../../core/models/media_item.dart';
import '../../../core/models/plugin_config.dart';
import '../../../core/scraper/media_api_service.dart';
import '../../../core/services/source_repository.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_loading_indicator.dart';
import '../../../core/widgets/chapter_list_sheet.dart';
import '../../../core/widgets/detail_action_utils.dart';
import '../../../core/widgets/web_favorite_action.dart';
import '../../../core/resolver/webview_resolver.dart';
import '../../../core/widgets/source_image.dart';
import '../../verification/presentation/webview_verification_screen.dart';
import 'reader_image_actions.dart';
import 'reader_image_filter.dart';
import 'reader_tap_zones.dart';

/// 漫画阅读器（Phase 4）。
///
/// 支持 5 种阅读模式、点击区域布局、双击/滚轮缩放、进度自动保存、
/// 末页前预加载下一章。复用统一 Token 与 [ReaderPreferences]。
///
/// 本地模式（Task O4.B.1）：传入 [localImages] 或 [localCbzPath] 时进入本地模式，
/// 跳过在线源解析，直接渲染本地图片。本地模式下隐藏章节列表 / WebView / 分享等
/// 在线专属 UI，保留书签、进度、点击区域、图像滤镜。调用方需将 [comicId] 设为
/// `'local_${file.path.hashCode}'` 以隔离本地与在线进度。
class ComicReaderScreen extends StatefulWidget {
  final String comicId;
  final String title;
  final String sourceId;
  final List<Episode> chapters;
  final int initialChapterIndex;

  /// 本地模式：直接传入本地图片路径列表（跳过在线源解析）。
  final List<String>? localImages;

  /// 本地模式：传入本地 CBZ/ZIP 文件路径，阅读器内部解压取图。
  final String? localCbzPath;

  /// 是否用已保存的阅读进度恢复章节/页码。
  /// - true（默认）：从书架/历史「继续阅读」进入时恢复上次进度；
  /// - false：从详情页明确选择某话进入时，以 [initialChapterIndex] 为准。
  final bool restoreProgress;

  /// 详情页 URL（用于收藏时透传，避免历史/收藏详情灰屏）。
  final String? detailUrl;

  /// 封面 URL（用于收藏时透传，避免收藏书架缺封面）。
  final String? coverUrl;

  const ComicReaderScreen({
    super.key,
    required this.comicId,
    required this.title,
    required this.sourceId,
    required this.chapters,
    this.initialChapterIndex = 0,
    this.localImages,
    this.localCbzPath,
    this.restoreProgress = true,
    this.detailUrl,
    this.coverUrl,
  });

  @override
  State<ComicReaderScreen> createState() => _ComicReaderScreenState();
}

class _ComicReaderScreenState extends State<ComicReaderScreen>
    with SingleTickerProviderStateMixin {
  final ReaderPreferencesStore _store = ReaderPreferencesStore();
  final ComicProgressManager _progress = ComicProgressManager();
  final TransformationController _zoomController = TransformationController();

  /// 顶部 / 底部控制栏与点击热区覆盖层的全局键：用于 [ReaderTapZones.isToolbarRegion]
  /// 回调里把指针坐标换算到全局，判定是否落在控制栏上（点在按钮上不触发翻页）。
  final GlobalKey _topBarKey = GlobalKey();
  final GlobalKey _bottomBarKey = GlobalKey();
  final GlobalKey _tapZonesKey = GlobalKey();

  late ReaderPreferences _prefs;
  int _chapterIndex = 0;
  int _savedPage = 0;

  /// 是否正在把视图恢复到保存的页码。
  ///
  /// 恢复期间滚动回调产生的页码是「过渡值」（通常是 0），若照常写盘会把
  /// 上次的阅读位置冲掉 —— 这是「记住阅读进度没作用」的根因之一。
  bool _restoringPage = false;

  List<String> _images = const <String>[];
  bool _loading = true;
  String? _error;
  PluginConfig? _source;

  /// 章节加载令牌：每次发起加载自增，仅最新请求的加载结果会被应用，
  /// 避免快速翻章时旧章节覆盖新章节（竞态导致「显示的章节与 _chapterIndex 不一致」）。
  int _loadToken = 0;
  final Map<int, List<String>> _preload = <int, List<String>>{};
  /// 正在预加载的章节下标集合（防止同一章重复发起请求）。
  final Set<int> _preloading = <int>{};

  /// 渲染后抽取请求（webview-html 模式，如 manga_goda / manga_baozimh 的
  /// images 脚本路由）：非 null 时显示「抓取本页渲染内容」引导，抓取后回填
  /// 渲染 HTML 重试（修复 useWebview 脚本源「漫画图片解析不到内容」）。
  WebViewHtmlRequest? _htmlCaptureRequest;

  /// 按章节缓存渲染后 HTML：每个章节 images 路由 URL 不同，需分别抓取回灌。
  final Map<int, String> _renderedHtmlByChapter = <int, String>{};

  PageController? _pageController;
  ItemScrollController? _itemScrollController;
  ItemPositionsListener? _itemPositionsListener;
  /// 条漫模式待恢复的页码（_setupControllers 设置，_buildWebtoon 首次渲染后清除）。
  int? _pendingWebtoonRestore;

  /// 条漫单步翻页的滚动结果检查定时器：滚动动画结束后比对位置，
  /// 若画面未移动（已被边界夹紧）则换章。用定时器而非滚动 Future，
  /// 因为列表在切章/重建期间可能不再调度新帧，使 Future 永不完成而永久哑火。
  Timer? _webtoonStepTimer;

  /// 条漫「先落首页 → 加载完成后滚动到底」的收尾定时器（回到上一话时使用）。
  Timer? _webtoonRestoreTimer;

  /// 「回到上一话末页」的尺寸稳定轮询定时器：回到上一话首帧后启动，
  /// 每 ~80ms 检查末页项尺寸是否已稳定，稳定后再滚动到底。
  Timer? _webtoonLastPageTimer;

  /// 轮询超时兜底定时器：3s 内末页尺寸仍未稳定也强制滚动收尾，避免卡死。
  Timer? _webtoonLastPageTimeout;

  /// 轮询期间最近一次读到的末页项 trailingEdge，用于两两比对判稳定。
  double? _lastPageLastEdge;

  /// 条漫模式待执行的「滚动到本章末页」标记：回到上一话时置位，
  /// 由 [_buildWebtoon] 首帧后消费。
  bool _pendingWebtoonScrollToLast = false;

  /// 条漫边界拖拽累计位移（像素）：正=持续拖出底部，负=持续拖出顶部。
  /// 超过 [_kChapterOverscroll] 即换章，松手或重新开始滚动时清零。
  double _overscrollAccum = 0;

  /// 边界拖拽换章阈值（像素）。
  static const double _kChapterOverscroll = 160;

  int _currentPage = 0;
  bool _uiVisible = false;
  bool _isFav = false;
  bool _showInlineSettings = false;

  /// 整体是否处于放大状态（共享 [_zoomController] 的 scale > 1）。用于在放大时
  /// 关闭底层 PageView / ListView 的滚动手势，避免「放大图片拖动平移」与「翻页 /
  /// 滚动」在手势竞技场里互相抢手势、导致两种行为都失灵。未放大时恢复原生手势。
  bool _zoomed = false;

  /// 每页旋转的 quarterTurns（0/1/2/3），仅在用户主动旋转时记录。
  final Map<int, int> _pageRotations = <int, int>{};

  /// 进度保存防抖定时器，合并频繁翻页产生的写入。
  Timer? _saveProgressDebounce;

  /// 翻页闪光动画控制器与覆盖层状态。
  late final AnimationController _flashController;
  double _flashOpacity = 0.0;
  Color _flashColor = Colors.black;

  /// 章节切换过渡标题卡状态。
  bool _transitionVisible = false;
  String _transitionTitle = '';
  Timer? _transitionTimer;

  MediaApiService get _service => context.read<MediaApiService>();
  SourceRepository get _repo => context.read<SourceRepository>();

  /// 是否为本地文件模式（Task O4.B.1）。
  bool get _isLocalMode =>
      widget.localImages != null || widget.localCbzPath != null;

  @override
  void initState() {
    super.initState();
    _flashController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
    );
    _zoomController.addListener(_onZoomChanged);
    _chapterIndex = widget.initialChapterIndex;
    _prefs = const ReaderPreferences();
    _init();
  }

  Future<void> _init() async {
    final defaults = await ReaderDefaultSettingsStore().load();
    _prefs = (await _store.get(widget.comicId))
        .mergedWith(defaults.toReaderPreferences());
    // 从详情页明确选择某话时，不要覆盖成「继续阅读」的进度。
    if (widget.restoreProgress) {
      final saved = await _progress.get(widget.comicId);
      if (saved != null && saved.chapterIndex < widget.chapters.length) {
        _chapterIndex = saved.chapterIndex;
        _savedPage = saved.currentPage;
      }
    }
    _refreshFavorite();
    // 本地漫画（无章节/无在线源）默认显示控制栏，避免「只有图片没有操控面板」。
    // 联网漫画仍保持沉浸式（点屏切换显隐）。
    if (_isLocalMode) _uiVisible = true;
    if (mounted) setState(() {});
    _applyOrientation();
    _applyFullscreen();
    _applyWakelock();
    if (_isLocalMode) {
      await _loadLocalImages(restorePage: _savedPage);
    } else {
      await _loadChapter(_chapterIndex, restorePage: _savedPage);
    }
  }

  /// 本地模式加载图片：优先使用 [widget.localImages]，否则解压 [widget.localCbzPath]。
  Future<void> _loadLocalImages({int restorePage = 0}) async {
    if (mounted) setState(() => _loading = true);
    try {
      List<String> imgs;
      if (widget.localImages != null && widget.localImages!.isNotEmpty) {
        imgs = List<String>.unmodifiable(widget.localImages!);
      } else if (widget.localCbzPath != null) {
        imgs = await _extractCbz(widget.localCbzPath!);
      } else {
        imgs = const <String>[];
      }
      if (!mounted) return;
      if (imgs.isEmpty) {
        setState(() {
          _images = const <String>[];
          _loading = false;
          _error = AppLocalizations.of(context).localFileLoadFailed;
        });
        return;
      }
      setState(() {
        _images = imgs;
        _loading = false;
        _error = null;
      });
      _setupControllers(restorePage: restorePage);
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  /// 解压 CBZ/ZIP 文件取图片路径（参考 local_media_viewer._extractCbz）。
  ///
  /// R3 修复：若 [path] 为 Android SAF URI（`content://`），`File(path)` 无法
  /// 读取，抛出明确异常由上层 `_loadLocalImages` 的 catch 转为 `localFileLoadFailed`
  /// 错误态展示给用户，而非静默吞异常导致空白页。
  Future<List<String>> _extractCbz(String path) async {
    if (isAndroidSafUri(path)) {
      throw FileSystemException(
        'Android SAF URI cannot be read via dart:io File',
        path,
      );
    }
    final bytes = await File(path).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    final tempDir = await getTemporaryDirectory();
    final out = <String>[];
    for (final file in archive) {
      if (file.isFile && isImageFile(file.name)) {
        final content = file.content;
        if (content == null) continue;
        final target = File(
          p.join(tempDir.path, '${file.name.hashCode}_${p.basename(file.name)}'),
        );
        await target.writeAsBytes(content as List<int>);
        out.add(target.path);
      }
    }
    out.sort();
    return out;
  }

  /// 刷新收藏状态（init 与切换收藏后调用）。
  void _refreshFavorite() {
    final fav = context.read<FavoritesManager>();
    _isFav = fav.isFavorite(widget.comicId, SourceType.mangaSource);
  }

  /// 切换收藏状态（顶栏收藏按钮回调）。
  Future<void> _toggleFavorite() async {
    final l10n = AppLocalizations.of(context);
    final fav = context.read<FavoritesManager>();
    final wasFavorite = _isFav;
    final item = MediaItem(
      id: widget.comicId,
      title: widget.title,
      sourceId: widget.sourceId,
      sourceType: SourceType.mangaSource,
      detailUrl: widget.detailUrl,
      coverUrl: widget.coverUrl,
    );
    await fav.toggleFavorite(item);
    if (mounted) {
      setState(() => _isFav = !wasFavorite);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(wasFavorite ? l10n.favoriteRemoved : l10n.favoriteAdded),
        ),
      );
    }
  }

  /// 收藏按钮入口：源声明网络收藏时弹「本地/网络」双选项，否则直接本地收藏。
  Future<void> _onFavoritePressed() async {
    final MediaItem item = MediaItem(
      id: widget.comicId,
      title: widget.title,
      sourceId: widget.sourceId,
      sourceType: SourceType.mangaSource,
      detailUrl: widget.detailUrl,
      coverUrl: widget.coverUrl,
    );
    final PluginConfig? source =
        context.read<SourceRepository>().getById(widget.sourceId);
    if (source == null) {
      await _toggleFavorite();
      return;
    }
    await showFavoriteSheet(
      context: context,
      source: source,
      item: item,
      toggleLocalFavorite: _toggleFavorite,
    );
  }

  @override
  void dispose() {
    _zoomController.removeListener(_onZoomChanged);
    _pageController?.dispose();
    _itemPositionsListener?.itemPositions.removeListener(_onWebtoonScroll);
    _zoomController.dispose();
    _flashController.dispose();
    _transitionTimer?.cancel();
    _saveProgressDebounce?.cancel();
    _webtoonStepTimer?.cancel();
    _webtoonRestoreTimer?.cancel();
    _webtoonLastPageTimer?.cancel();
    _webtoonLastPageTimeout?.cancel();
    try {
      SystemChrome.setPreferredOrientations(<DeviceOrientation>[]);
    } on Object {
      // 测试环境忽略。
    }
    try {
      // 退出阅读器：恢复系统 UI 模式（沉浸全屏 → edgeToEdge）。
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } on Object {
      // 测试环境忽略。
    }
    try {
      // 退出阅读器：关闭屏幕常亮。
      WakelockPlus.disable();
    } on Object {
      // 测试环境忽略。
    }
    // 退出时兜底保存偏好，确保设置退出后仍保留。
    unawaited(_store.save(widget.comicId, _prefs));
    super.dispose();
  }

  // ─────────────────────── 数据加载 ───────────────────────

  Future<void> _loadChapter(int index,
      {int restorePage = 0, bool restoreToLast = false}) async {
    final int token = ++_loadToken;
    if (mounted) setState(() => _loading = true);
    try {
      final source = _repo.getById(widget.sourceId);
      if (source == null) throw Exception('source not found: ${widget.sourceId}');
      _source = source;
      final chapter = widget.chapters[index];
      final List<String> imgs = _preload.remove(index) ??
          await _service.fetchImages(
            source,
            comicId: widget.comicId,
            chapterId: chapter.id,
            renderedHtml: _renderedHtmlByChapter[index],
          );
      // 期间若又发起了更新的加载（快速翻章），丢弃本次过期结果，
      // 避免旧章节的图片覆盖到新 _chapterIndex 上导致显示错乱。
      if (token != _loadToken || !mounted) return;
      // 回到上一话末页时 restoreToLast=true。
      // 翻页模式直接把落点设为末页（PageView 首帧即定位，无中间态）。
      // 条漫模式则先落首页、待首帧布局完成后再主动滚动到底：切章瞬间图片尚未
      // 完成布局，此时若直接以末页作为初始索引，后续图片加载引起的高度变化会
      // 让「当前页」的测量回退到倒数几页（表现为进度回弹）。改为加载后主动滚动，
      // 结束时直接赋值末页，不依赖任何测量结果。
      final bool lastPage = restoreToLast && imgs.isNotEmpty;
      final bool deferToLast = lastPage && _prefs.readingMode.isWebtoon;
      final int rp = lastPage && !deferToLast ? imgs.length - 1 : restorePage;
      setState(() {
        _images = imgs;
        _loading = false;
        _error = null;
      });
      _setupControllers(restorePage: deferToLast ? 0 : rp);
      if (deferToLast) {
        // 首帧后由 _buildWebtoon 消费：滚动到底并在收尾时写入末页进度。
        _pendingWebtoonScrollToLast = true;
      } else {
        _saveProgress(rp);
      }
    } on WebViewHtmlRequest catch (req) {
      // useWebview 脚本源（manga_goda / manga_baozimh 等）需在内嵌 WebView
      // 加载章节页、等待 JS 渲染后取回整页 HTML，再回灌给脚本解析图片。
      // 捕获请求后展示「抓取本页渲染内容」引导，用户触发回填并重试。
      if (token != _loadToken || !mounted) return;
      if (mounted) {
        setState(() {
          _htmlCaptureRequest = req;
          _loading = false;
          _error = null;
        });
      }
    } on Object catch (e) {
      if (token != _loadToken || !mounted) return;
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  /// 渲染后抽取完成后回填 HTML 并重试抓取当前章节图片（webview-html 源）。
  Future<void> _captureAndRetry() async {
    final req = _htmlCaptureRequest;
    if (req == null || !mounted) return;
    final outcome = await navigateToHtmlCapture(context, request: req);
    if (!mounted) return;
    if (outcome?.hasRenderedHtml == true && outcome!.renderedHtml != null) {
      _renderedHtmlByChapter[_chapterIndex] = outcome.renderedHtml!;
      setState(() => _htmlCaptureRequest = null);
      await _loadChapter(_chapterIndex, restorePage: _currentPage);
    } else {
      // 用户取消或未取到渲染 HTML：退回错误态，可重试或退出。
      if (mounted) {
        setState(() {
          _htmlCaptureRequest = null;
          _error = AppLocalizations.of(context).loadFailed;
          _loading = false;
        });
      }
    }
  }

  void _setupControllers({int restorePage = 0, bool wasDoublePage = false}) {
    // 旧控制器延迟到下一帧释放：避免旧 PageView 在 dispose→setState 之间
    // 访问已释放控制器导致崩溃/白屏，从而进度条/页码没有更新。
    final PageController? oldPageController = _pageController;
    _pageController = null;
    _itemScrollController = null;
    _itemPositionsListener = null;
    // 双页→单页修正：双页模式下 _currentPage 指向跨页左页（如 20 页的第 18 页），
    // 切回单页后 PageView 实际显示左页（18），但用户感知在右页（19，末页）。
    // 将 restorePage 修正为右页，确保末页点击「下一张」能正确跳下一章。
    if (wasDoublePage && !_isDoublePage && _images.isNotEmpty) {
      final lastLeftPage = ((_images.length - 1) ~/ 2) * 2;
      if (restorePage >= lastLeftPage && restorePage < _images.length) {
        restorePage = _images.length - 1;
      }
    }

    if (_prefs.readingMode.isPaged) {
      // 越界保护：initialPage 必须在 [0, itemCount-1]，否则 PageView 抛异常
      // 导致双页/单页切换后白屏（隐藏崩溃防护）。
      final int maxInitial = (_controllerPageCount - 1).clamp(0, 1 << 30);
      final int initial = _isDoublePage
          ? (restorePage ~/ 2).clamp(0, maxInitial)
          : restorePage.clamp(0, maxInitial);
      // 逻辑页码：双页模式取当前跨页左页，与 _onPagedScroll 保持一致，
      // 保证进度条 / 保存值与可见跨页对齐。
      final int logicalPage = _isDoublePage
          ? (initial * 2).clamp(0, _images.length - 1)
          : initial;

      // 每章使用独立 Key（见 _buildPaged / _buildPagedSpread），PageView 会创建
      // 全新的 ScrollPosition，initialPage 必定生效，不再依赖 jumpToPage 强跳。
      // 这彻底消除了「切章后图片停在旧页 / 回上一话末页却回弹到倒数几页」两类问题
      // —— 它们都源于复用旧 ScrollPosition 时 initialPage 被忽略。
      _pageController = PageController(initialPage: initial)
        ..addListener(_onPagedScroll);

      _currentPage = logicalPage;
      // 首帧布局期间（旧控制器残留通知 / 新 position 初始化）屏蔽进度写盘，
      // 防止脏页码冲掉存档。首帧后即可恢复。
      _restoringPage = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // 兜底纠偏：每章已用独立 Key 重建全新 ScrollPosition，initialPage 必定生效，
        // 此处仅在极端布局时序下 position 未停在目标页时，以「瞬时」jumpToPage 纠正。
        // jumpToPage 为瞬时跳转（不经动画），不会产生回弹；且下方 _restoringPage
        // 解除前的通知已被 _onPagedScroll 忽略，不会污染 _currentPage / 存档。
        if (_pageController != null && _pageController!.hasClients) {
          final cur = _pageController!.page?.round() ?? -1;
          if (cur != initial) _pageController!.jumpToPage(initial);
        }
        // 先解除屏蔽再释放旧控制器：确保即便 dispose 抛异常，_restoringPage
        // 也一定复位，否则会永久冻结进度保存与进度条同步。
        _restoringPage = false;
        oldPageController?.dispose();
        if (mounted) setState(() {});
      });
    } else {
      // 条漫模式：使用 ScrollablePositionedList，通过 initialScrollIndex
      // 直接定位到目标页，不再依赖滚动比例估算。
      // 先摘除旧监听器并断开旧列表引用：旧列表在卸载/重布局时会把「上一章页码」
      // 经 _onWebtoonScroll 推过来，而此时 _images 已是新章，旧页码被截断后落到
      // 新章末页，导致进度条显示在末页（实际需要显示首页）。这是进度条错乱的根因。
      _itemPositionsListener?.itemPositions.removeListener(_onWebtoonScroll);
      _itemScrollController = null;
      _itemPositionsListener = null;
      // 换章后取消上一章遗留的翻页/恢复定时器与边界拖拽累计，
      // 避免旧列表的未决判定误触发换章。
      _webtoonStepTimer?.cancel();
      _webtoonStepTimer = null;
      _webtoonRestoreTimer?.cancel();
      _webtoonRestoreTimer = null;
      _webtoonLastPageTimer?.cancel();
      _webtoonLastPageTimer = null;
      _webtoonLastPageTimeout?.cancel();
      _webtoonLastPageTimeout = null;
      _lastPageLastEdge = null;
      _pendingWebtoonScrollToLast = false;
      _overscrollAccum = 0;
      // 切章/恢复期间屏蔽进度回写：直到 _buildWebtoon 首帧后由 _restoringPage=false
      // 解除。期间任何滚动通知（旧列表残留或初始布局）都不会污染 _currentPage/存档。
      _restoringPage = true;
      _itemScrollController = ItemScrollController();
      final listener = ItemPositionsListener.create();
      _itemPositionsListener = listener;
      // 立即注册监听：_restoringPage 期间 _onWebtoonScroll 会早退，初始布局不会污染。
      listener.itemPositions.addListener(_onWebtoonScroll);
      // 用完整值（含 0）作为一次性恢复标记，确保首帧后无论恢复到第几页都解除屏蔽。
      _pendingWebtoonRestore = restorePage;
      _currentPage = restorePage.clamp(0, _images.length - 1);
      oldPageController?.dispose();
    }
    if (mounted) setState(() {});
  }

  void _onPagedScroll() {
    // 恢复进度期间的过渡页码不回写，避免冲掉存档。
    if (_restoringPage) return;
    final p = _pageController?.page;
    if (p == null) return;
    if (_controllerPageCount == 0) return;
    final controllerMax = _controllerPageCount - 1;
    final spreadIdx = p.round().clamp(0, controllerMax);
    // 双页模式以跨页的【左页】作为当前逻辑页。
    // 这样切回单页时不会跳到右页，进度条/保存也更稳定。
    final idx = _isDoublePage
        ? (spreadIdx * 2).clamp(0, _images.length - 1)
        : spreadIdx;
    if (idx != _currentPage) {
      _currentPage = idx;
      _scheduleProgressSave(idx);
      // 索引变化时刷新进度条（页码/滑条），否则点按翻页后进度条不更新。
      if (mounted) setState(() {});
    }
    _maybePreload(idx);
  }

  void _onWebtoonScroll() {
    // 恢复进度期间的过渡位置不回写，避免冲掉存档。
    if (_restoringPage) return;
    final listener = _itemPositionsListener;
    if (listener == null) return;
    final positions = listener.itemPositions.value;
    if (positions.isEmpty) return;
    // 仅保留真正在视口内的 item（leadingEdge<1 未完全滚出底部，trailingEdge>0 未完全滚出顶部）。
    final visible = positions
        .where((p) => p.itemLeadingEdge < 1 && p.itemTrailingEdge > 0)
        .toList();
    if (visible.isEmpty) return;
    // 当前页 = 视口内【最顶部】可见项：你正在读的是贴在视口顶部的那一页。
    // 这是连续滚动阅读器的通用模型：读倒数第二页时顶部项是 N-2，进度条不会提前满格；
    // 落回上一话末页时末页贴底、其顶边仍在视口内，顶部项=末页，进度精确显示末页；
    // 连续滚动时顶部项随滚动单调变化，不会乱跳页。恢复期间由 _restoringPage 屏蔽，
    // 故切章/恢复时不会污染 _currentPage。
    int idx = visible
        .map((p) => p.index)
        .reduce((a, b) => a < b ? a : b)
        .clamp(0, _images.length - 1);
    // 到底修正：最后一项的底边 == 列表内容末端，一旦它不在视口下方（trailingEdge<=1）
    // 就说明已经滚到底、再也滚不动了，当前页必然是末页。窄屏（或末页为短图）时一屏能
    // 容下多张，顶部项会停在 N-2/N-3，仅靠顶部模型永远到不了末页 —— 这里补齐该边界。
    // 未到底时最后一项底边仍在视口下方（trailingEdge>1），不触发，故进度不会提前满格。
    final int lastIndex = _images.length - 1;
    if (lastIndex >= 0) {
      for (final p in positions) {
        // 容差 2e-3 覆盖 itemTrailingEdge 的像素取整误差（约 0.5px / 视口高）。
        if (p.index == lastIndex && p.itemTrailingEdge <= 1.0 + 2e-3) {
          idx = lastIndex;
          break;
        }
      }
    }
    if (idx != _currentPage) {
      _currentPage = idx;
      _scheduleProgressSave(idx);
      if (mounted) setState(() {});
    }
    _maybePreload(idx);
  }

  /// 防抖进度保存：合并频繁翻页产生的写入，避免高频 IO。
  /// 滚动回调中使用；_jumpToPage / _setupControllers 中仍直接调用 _saveProgress。
  void _scheduleProgressSave(int page) {
    _saveProgressDebounce?.cancel();
    _saveProgressDebounce = Timer(const Duration(seconds: 1), () {
      _saveProgress(page);
    });
  }

  void _maybePreload(int idx) {
    // 接近章末：预加载下一章（末页翻下一张不再等待网络）。
    if (idx >= _images.length - 4) _preloadChapter(_chapterIndex + 1);
    // 接近章首：预加载上一章（首页翻上一张回到上一话末页不卡顿）。
    if (idx <= 3) _preloadChapter(_chapterIndex - 1);
  }

  /// 预加载指定章节图片到 [_preload] 缓存（best-effort，失败静默忽略）。
  void _preloadChapter(int index) {
    if (index < 0 || index >= widget.chapters.length) return;
    if (_preload.containsKey(index) || _preloading.contains(index)) return;
    _preloading.add(index);
    final source = _repo.getById(widget.sourceId);
    if (source == null) {
      _preloading.remove(index);
      return;
    }
    _service
        .fetchImages(
          source,
          comicId: widget.comicId,
          chapterId: widget.chapters[index].id,
          renderedHtml: _renderedHtmlByChapter[index],
        )
        .then((imgs) {
          if (mounted) _preload[index] = imgs;
        })
        .catchError((Object _) {})
        .whenComplete(() => _preloading.remove(index));
  }

  void _saveProgress(int page) {
    if (widget.chapters.isEmpty) return;
    final chapter = widget.chapters[_chapterIndex];
    _progress.save(
      widget.comicId,
      chapter.id,
      page,
      _chapterIndex,
      totalChapters: widget.chapters.length,
    );
    // 更新收藏条目的 lastRead 时间戳（P8.1.3 §廿一 收藏切换不丢 lastRead）
    try {
      context.read<FavoritesManager>().updateLastRead(
            widget.comicId,
            SourceType.mangaSource,
          );
    } catch (_) {
      // FavoritesManager 不可用时静默忽略。
    }
    // 写浏览历史：仅在详情页 initState 写一次时「lastChapter」恒为 null，
    // 书架历史 Tab 与「继续阅读」入口都看不到进度；这里每次翻页都更新
    // 最近章节标题，让历史 Tab 排序与续读定位都生效。
    try {
      final history = context.read<HistoryManager>();
      final item = MediaItem(
        id: widget.comicId,
        title: widget.title,
        sourceId: widget.sourceId,
        sourceType: SourceType.mangaSource,
        coverUrl: widget.coverUrl,
        detailUrl: widget.detailUrl,
      );
      unawaited(history.addHistory(
        item,
        lastChapter: chapter.title,
        sourceType: SourceType.mangaSource,
      ));
    } catch (_) {
      // HistoryManager 不可用时静默忽略。
    }
    // 章节阅读进度达到「已看」阈值时标记该章已读（每章仅标记一次）。
    _maybeMarkChapterWatched(page);
  }

  /// 章节阅读进度达到「已看」阈值时标记当前章已读。
  ///
  /// 阈值取自 [GeneralSettingsStore.watchedThresholdPercent]（默认 90）。
  /// 已读章节由 [MediaWatchedManager] 统一记录（与详情页 isRead 共用），
  /// `markWatched` 本身幂等，此处额外用 `isWatched` 跳过已读章节。
  void _maybeMarkChapterWatched(int page) {
    final total = _images.length;
    if (total <= 0) return;
    final ratio = (page + 1) / total;
    final threshold = GeneralSettingsStore.instance.watchedThresholdPercent;
    if (!progressReachesWatchedThreshold(ratio, threshold)) return;
    try {
      final watched = context.read<MediaWatchedManager>();
      if (watched.isWatched(widget.comicId, _chapterIndex)) return;
      unawaited(watched.markWatched(widget.comicId, _chapterIndex));
    } catch (_) {
      // Manager 不可用时静默忽略。
    }
  }

  // ─────────────────────── 导航 ───────────────────────

  void _goNextPage() {
    _triggerFlash();
    if (_prefs.readingMode.isWebtoon) {
      _webtoonStep(1);
      return;
    }
    final pc = _pageController;
    if (pc == null || !pc.hasClients) return;
    final total = _controllerPageCount;
    if (total <= 1) {
      _goNextChapter();
      return;
    }
    // 用 _currentPage 做边界判断，避免 pc.page 在控制器重建/恢复期间不稳定。
    // 双页模式下 _currentPage 指向跨页左页，末页判断：左页 >= 倒数第二个跨页左页。
    final int lastLeftPage = _isDoublePage
        ? ((_images.length - 1) ~/ 2) * 2
        : _images.length - 1;
    if (_currentPage >= lastLeftPage) {
      _goNextChapter();
    } else {
      pc.nextPage(duration: AppTokens.durFast, curve: Curves.easeInOut);
    }
  }

  void _goPrevPage() {
    _triggerFlash();
    if (_prefs.readingMode.isWebtoon) {
      _webtoonStep(-1);
      return;
    }
    final pc = _pageController;
    if (pc == null || !pc.hasClients) return;
    // 用 _currentPage 做边界判断，避免 pc.page 在控制器重建/恢复期间不稳定。
    if (_currentPage <= 0) {
      _goPrevChapter();
    } else {
      pc.previousPage(duration: AppTokens.durFast, curve: Curves.easeInOut);
    }
  }

  /// 条漫当前滚动位置的锚点：视口内最靠前一项的索引 + 其顶边偏移（视口高度归一化）。
  /// 用于比对一次滚动请求前后画面是否真的移动过。
  ({int index, double edge})? _webtoonScrollAnchor() {
    final positions = _itemPositionsListener?.itemPositions.value;
    if (positions == null || positions.isEmpty) return null;
    final first = positions.reduce((a, b) => a.index <= b.index ? a : b);
    return (index: first.index, edge: first.itemLeadingEdge);
  }

  /// 条漫单步翻页（[dir] = +1 下一页 / -1 上一页）。
  ///
  /// 采用「意图驱动」而非「测量驱动」：先算出想去的目标页，目标越界就直接换章，
  /// 不再要求「当前页」的测量值必须精确等于末页/首页。旧实现把换章闸门绑在测量
  /// 值上，而窄屏（一屏可容纳多张短图）时视口顶部项永远停在倒数几页，闸门就再也
  /// 打不开，表现为末页点击完全没反应。
  ///
  /// 目标未越界时正常滚动，并在动画结束后比对画面是否真的移动过：没动即说明已被
  /// 边界夹紧（内容不足以再滚一页），同样兜底换章。该检查用定时器驱动，必定执行。
  void _webtoonStep(int dir) {
    if (_images.isEmpty) return;
    final int last = _images.length - 1;
    final isc = _itemScrollController;
    // 列表尚未挂载（切章/重建中）时不再静默吞掉操作，直接按方向换章。
    if (isc == null || !isc.isAttached) {
      dir > 0 ? _goNextChapter() : _goPrevChapter();
      return;
    }
    final int target = _currentPage + dir;
    if (target > last) {
      _goNextChapter();
      return;
    }
    if (target < 0) {
      _goPrevChapter();
      return;
    }
    final before = _webtoonScrollAnchor();
    final int token = _loadToken;
    isc.scrollTo(
      index: target.clamp(0, last),
      duration: AppTokens.durFast,
      curve: Curves.easeInOut,
    );
    _webtoonStepTimer?.cancel();
    _webtoonStepTimer = Timer(
      AppTokens.durFast + const Duration(milliseconds: 120),
      () {
        _webtoonStepTimer = null;
        // 章节已切换 / 页面已销毁则放弃本次判定，避免误触发换章。
        if (!mounted || token != _loadToken) return;
        final after = _webtoonScrollAnchor();
        if (before == null || after == null) return;
        // 锚点未变 = 滚动被夹紧（已到边界），此时才换章。比较的是整段动画前后的
        // 位置差，故即便读到的是上一帧布局也不影响结论。
        final bool stalled = before.index == after.index &&
            (before.edge - after.edge).abs() < 0.002;
        if (!stalled) return;
        dir > 0 ? _goNextChapter() : _goPrevChapter();
      },
    );
  }

  void _scrollByPage(int dir) {
    if (_prefs.readingMode.isWebtoon) {
      _webtoonStep(dir);
      return;
    }
    final pc = _pageController;
    if (pc == null || !pc.hasClients) return;
    if (dir > 0) {
      pc.nextPage(duration: AppTokens.durFast, curve: Curves.easeInOut);
    } else {
      pc.previousPage(duration: AppTokens.durFast, curve: Curves.easeInOut);
    }
  }

  /// 翻页闪光：仅在 [ReaderPreferences.flashEnabled] 时触发，延迟
  /// [ReaderPreferences.flashInterval] 毫秒后播放一次。
  void _triggerFlash() {
    final p = _prefs;
    if (!p.flashEnabled || !mounted) return;
    final dur = Duration(milliseconds: p.flashTime);
    Future.delayed(Duration(milliseconds: p.flashInterval), () {
      if (!mounted) return;
      switch (p.flashColor) {
        case ReaderFlashColor.black:
          _runFlash(Colors.black, dur);
        case ReaderFlashColor.white:
          _runFlash(Colors.white, dur);
        case ReaderFlashColor.blackWhite:
          _runFlash(Colors.black, dur, () => _runFlash(Colors.white, dur));
      }
    });
  }

  /// 播放一段「淡入→淡出」的闪光（opacity 0→1→0）。[onDone] 用于黑→白连续闪。
  void _runFlash(Color color, Duration dur, [VoidCallback? onDone]) {
    _flashController.stop();
    _flashController.duration = dur;
    _flashController.clearListeners();
    _flashController.addListener(() {
      if (mounted) setState(() => _flashOpacity = _flashController.value);
    });
    setState(() => _flashColor = color);
    _flashController.forward(from: 0).then((_) {
      _flashController.reverse(from: 1).then((_) {
        if (mounted) setState(() => _flashOpacity = 0.0);
        onDone?.call();
      });
    });
  }

  void _goNextChapter() {
    if (_chapterIndex < widget.chapters.length - 1) {
      final next = _chapterIndex + 1;
      _triggerChapterTransition(widget.chapters[next].title);
      _chapterIndex = next;
      _loadChapter(_chapterIndex);
      return;
    }
    // 已无下一话：给出提示而不是静默无响应，否则用户会误以为按钮失灵。
    _showBoundaryHint(AppLocalizations.of(context).readerLastChapterReached);
  }

  void _goPrevChapter() {
    if (_chapterIndex > 0) {
      final prev = _chapterIndex - 1;
      _triggerChapterTransition(widget.chapters[prev].title);
      _chapterIndex = prev;
      // 回到上一话的【最后一页】，保证「首页翻上一张」连贯。
      _loadChapter(_chapterIndex, restoreToLast: true);
      return;
    }
    _showBoundaryHint(AppLocalizations.of(context).readerFirstChapterReached);
  }

  /// 章节边界提示（已是第一话 / 最后一话）。短暂 SnackBar，避免遮挡阅读区。
  void _showBoundaryHint(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(milliseconds: 1400),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  /// 判断指针（热区覆盖层局部坐标）是否落在顶部 / 底部控制栏区域内。
  ///
  /// 控制栏展开时，点在按钮上应交给按钮自身处理，不应再触发上一页 / 下一页；
  /// 沉浸阅读（控制栏隐藏）时返回 false，交还全部区域给热区翻页。
  ///
  /// 实现：把指针坐标换算到全局空间，再与各控制栏 Container 的全局包围盒比对
  /// （自动涵盖 SafeArea 内边距，无需手动计算状态栏 / 底部安全区高度）。
  bool _isInToolbarRegion(Offset localPos) {
    if (!_uiVisible) return false;
    final overlayBox = _tapZonesKey.currentContext?.findRenderObject();
    if (overlayBox is! RenderBox) return false;
    final Offset global = overlayBox.localToGlobal(localPos);
    for (final key in <GlobalKey>[_topBarKey, _bottomBarKey]) {
      final box = key.currentContext?.findRenderObject();
      if (box is RenderBox) {
        final Offset topLeft = box.localToGlobal(Offset.zero);
        final rect = Rect.fromLTWH(
          topLeft.dx,
          topLeft.dy,
          box.size.width,
          box.size.height,
        );
        if (rect.contains(global)) return true;
      }
    }
    return false;
  }

  /// 章节切换过渡标题卡：若开启 [ReaderPreferences.showChapterTransition]，
  /// 在章节切换时短暂居中显示章节标题，约 1.2s 后淡出。
  void _triggerChapterTransition(String title) {
    if (!_prefs.showChapterTransition || !mounted) return;
    setState(() {
      _transitionTitle = title;
      _transitionVisible = true;
    });
    _transitionTimer?.cancel();
    _transitionTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _transitionVisible = false);
    });
  }

  /// 双击缩放：在「适配宽下限」与 [ReaderPreferences.doubleTapZoomScale] 之间切换。
  /// 以 [focal]（视口坐标）或视口中心为锚点；preventShrink 时下限锁定为 1.0（适配宽）。
  /// [focal] 为 null 时使用中心（双击兜底），非空时用于桌面 Shift+左键定点缩放。
  void _toggleZoom([Offset? focal]) {
    final m = _zoomController.value;
    final cur = m.getMaxScaleOnAxis();
    final double floor = _prefs.preventShrink ? 1.0 : 0.5;
    final target = cur > floor * 1.01 ? floor : _prefs.doubleTapZoomScale;
    final Offset anchor = focal ??
        Offset(
          MediaQuery.of(context).size.width / 2,
          MediaQuery.of(context).size.height / 2,
        );
    final realFactor = target / cur;
    _zoomController.value = Matrix4.identity()
      ..translate(anchor.dx * (1 - realFactor), anchor.dy * (1 - realFactor))
      ..scale(realFactor)
      ..multiply(m);
  }

  /// 监听共享 [_zoomController]：放大状态变化时同步 [_zoomed]，使底层 PageView /
  /// ListView 在放大时关闭滚动手势（避免与图片平移手势打架），未放大时恢复。
  void _onZoomChanged() {
    final zoomed = _zoomController.value.getMaxScaleOnAxis() > 1.001;
    if (zoomed != _zoomed && mounted) setState(() => _zoomed = zoomed);
  }

  /// 打开 / 关闭内联阅读设置面板。
  ///
  /// 与小说阅读器对齐：桌面（宽度 ≥ [AppTokens.desktopBreakpoint]）面板停在
  /// 右侧、移动端停在底部；改动通过 [onChanged] 即时预览并落盘（[_applySettingsAuto]），
  /// 关闭时草稿已应用，无需额外提交。
  void _openSettings() {
    _toggleInlineSettings();
  }

  /// 切换内联设置面板的显隐。
  void _toggleInlineSettings() {
    setState(() => _showInlineSettings = !_showInlineSettings);
  }

  /// 设置面板内的改动：即时预览 + 自动保存。
  ///
  /// 仅对「影响系统 UI / 控制器结构」的字段做重应用，避免亮度/滤镜等连续
  /// 滑块拖动时反复重建控制器或切换全屏造成卡顿：
  /// - orientation / fullscreen / keepScreenOn 变化 → 重应用系统 UI；
  /// - readingMode / splitDoublePage 变化 → 重建控制器（paged↔webtoon、单↔双页）。
  ///
  /// 注意：先同步更新 [_prefs]（不单独 setState），再由 [_setupControllers]
  /// 一次性 setState，避免「新 prefs + 旧控制器」的中间帧导致进度条/页码不同步。
  Future<void> _applySettingsAuto(ReaderPreferences next) async {
    if (!mounted) return;
    final prev = _prefs;
    _prefs = next;
    await _store.save(widget.comicId, next);
    if (prev.orientation != next.orientation) _applyOrientation();
    if (prev.fullscreen != next.fullscreen) _applyFullscreen();
    if (prev.keepScreenOn != next.keepScreenOn) _applyWakelock();
    if (prev.readingMode != next.readingMode ||
        prev.splitDoublePage != next.splitDoublePage) {
      if (_images.isNotEmpty) {
        _setupControllers(
          restorePage: _currentPage,
          wasDoublePage: prev.splitDoublePage && prev.readingMode.isPaged,
        );
        return;
      }
    }
    if (mounted) setState(() {});
  }

  /// 即时落盘偏好变更（用于底栏快捷工具栏的开关，例如裁剪 / 模式切换）。
  /// 同样避免「新 prefs + 旧控制器」的中间帧。
  Future<void> _onPrefsChanged(ReaderPreferences next) async {
    if (!mounted) return;
    final bool wasDouble =
        _prefs.splitDoublePage && _prefs.readingMode.isPaged;
    _prefs = next;
    await _store.save(widget.comicId, next);
    _applyOrientation();
    _applyWakelock();
    _applyFullscreen();
    if (_images.isNotEmpty) {
      _setupControllers(
        restorePage: _currentPage,
        wasDoublePage: wasDouble,
      );
    } else {
      if (mounted) setState(() {});
    }
  }

  /// 给当前页旋转 90°（quarterTurns +1，模 4）。
  void _rotateCurrentPage() {
    final idx = _currentPage.clamp(0, _images.length - 1);
    final cur = _pageRotations[idx] ?? 0;
    final next = (cur + 1) % 4;
    setState(() {
      _pageRotations[idx] = next;
      // 单页旋转 + rotateLandscape：强制横屏。
      if (_prefs.rotateLandscape && next != 0) {
        // 与 _applyOrientation 协同：仅当 orientation 为 default/followSystem 时
        // 才临时切横屏，否则尊重用户锁定的方向。
        if (_prefs.orientation == ScreenOrientation.defaultMode ||
            _prefs.orientation == ScreenOrientation.followSystem) {
          try {
            SystemChrome.setPreferredOrientations(<DeviceOrientation>[
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ]);
          } on Object {
            // 测试环境忽略。
          }
        }
      }
    });
  }

  /// 屏幕常亮：按 [ReaderPreferences.keepScreenOn] 启用 / 关闭 wakelock。
  void _applyWakelock() {
    try {
      if (_prefs.keepScreenOn) {
        WakelockPlus.enable();
      } else {
        WakelockPlus.disable();
      }
    } on Object {
      // 测试环境忽略。
    }
  }

  /// 沉浸全屏：进入阅读器时切到 immersiveSticky；dispose 时恢复 edgeToEdge。
  /// 与 [_applyOrientation] 协同：orientation 改 preferredOrientations，不动 system UI mode。
  void _applyFullscreen() {
    try {
      // 按 [ReaderPreferences.fullscreen] 决定：开启=沉浸全屏，关闭=恢复系统栏。
      SystemChrome.setEnabledSystemUIMode(
        _prefs.fullscreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
      );
    } on Object {
      // 测试环境忽略。
    }
  }

  /// 章内跳页：paged 用 PageController，webtoon 用 ItemScrollController。
  void _jumpToPage(int target) {
    final total = _images.length;
    if (total == 0) return;
    final t = target.clamp(0, total - 1);
    if (_prefs.readingMode.isWebtoon) {
      _itemScrollController?.scrollTo(
        index: t,
        duration: const Duration(milliseconds: 1),
      );
    } else {
      _pageController?.jumpToPage(_isDoublePage ? (t ~/ 2) : t);
    }
    _currentPage = t;
    _saveProgress(t);
    _maybePreload(t);
    if (mounted) setState(() {});
  }

  void _applyOrientation() {
    List<DeviceOrientation>? orient;
    switch (_prefs.orientation) {
      case ScreenOrientation.portrait:
      case ScreenOrientation.lockPortrait:
        orient = const <DeviceOrientation>[DeviceOrientation.portraitUp];
      case ScreenOrientation.landscape:
        orient = const <DeviceOrientation>[
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight
        ];
      case ScreenOrientation.lockLandscape:
        orient = const <DeviceOrientation>[DeviceOrientation.landscapeLeft];
      case ScreenOrientation.reversePortrait:
        orient = const <DeviceOrientation>[DeviceOrientation.portraitDown];
      case ScreenOrientation.defaultMode:
      case ScreenOrientation.followSystem:
        orient = const <DeviceOrientation>[];
    }
    try {
      SystemChrome.setPreferredOrientations(orient);
    } on Object {
      // 测试环境忽略。
    }
  }

  // ─────────────────────── 构建 ───────────────────────

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = _prefs.resolveBackgroundColor(isDark);
    final l10n = AppLocalizations.of(context);

    return ScrollConfiguration(
      // 全局关闭滚动回弹（橡皮筋）与 overscroll 发光，覆盖 PageView / ListView /
      // 设置面板滚动等所有内部滚动组件。
      behavior: _NoOverscrollBehavior(),
      child: Scaffold(
        backgroundColor: bg,
      body: Stack(
        children: <Widget>[
          _buildContent(l10n),
          if (!_loading && _error == null && _images.isNotEmpty)
            ReaderTapZones(
              key: _tapZonesKey,
              layout: _prefs.tapZoneLayout,
              tapZoneInvert: _prefs.tapZoneInvert,
              isVertical: _prefs.readingMode.isWebtoon ||
                  _prefs.readingMode == ReadingMode.singleVertical,
              isWebtoon: _prefs.readingMode.isWebtoon,
              isRTL: _prefs.readingMode == ReadingMode.singleRTL,
              onPrev: _goPrevPage,
              onNext: _goNextPage,
              onDragPage: (next) => next ? _goNextPage() : _goPrevPage(),
              onToggleUi: () {
                setState(() => _uiVisible = !_uiVisible);
              },
              onZoom: _toggleZoom,
              onZoomAt: (pos) => _toggleZoom(pos),
              onTapIntercept: () {
                if (_showInlineSettings) {
                  _toggleInlineSettings();
                  return true;
                }
                return false;
              },
              onLongPress: (_images.isEmpty || !_prefs.showLongPressMenu)
                  ? null
                  : () => showReaderImageActions(
                        context: context,
                        url: _images[_currentPage.clamp(0, _images.length - 1)],
                        source: _source,
                        comicId: widget.comicId,
                        sourceType: SourceType.mangaSource,
                      ),
              // 控制栏区域保护：点在顶部/底部控制栏上时交给按钮自身处理，不触发翻页。
              isToolbarRegion: (pos) => _isInToolbarRegion(pos),
            ),
          if (_prefs.flashEnabled)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: _flashColor.withValues(alpha: _flashOpacity),
                ),
              ),
            ),
          if (_transitionVisible)
            Center(
              child: IgnorePointer(
                child: AnimatedOpacity(
                  opacity: _transitionVisible ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 200),
                  child: Card(
                    color: Colors.black54,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 24, vertical: 12),
                      child: Text(
                        _transitionTitle,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 18),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (_uiVisible)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: _buildTopBar(l10n, bg),
            ),
          if (_uiVisible)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: _buildBottomBar(l10n),
            ),
          if (_uiVisible && _prefs.progressBarOnRight && _images.isNotEmpty)
            _buildRightProgressBar(l10n),
          if (_showInlineSettings) _buildInlineSettings(l10n),
        ],
      ),
      ),
    );
  }

  // ─────────────────────── 内联设置面板 ───────────────────────

  /// 与小说阅读器对齐的内联设置面板：桌面（宽 ≥ [AppTokens.desktopBreakpoint]）
  /// 停靠右侧、移动端停靠底部。点阅读区任意处关闭（见 [ReaderTapZones.onTapIntercept]）。
  Widget _buildInlineSettings(AppLocalizations l10n) {
    final isDesktop =
        MediaQuery.sizeOf(context).width >= AppTokens.desktopBreakpoint;

    final panel = Material(
      elevation: 4,
      child: buildComicSettingsSheet(
        initial: _prefs,
        onChanged: _applySettingsAuto,
        onClose: _toggleInlineSettings,
      ),
    );

    if (isDesktop) {
      return Align(
        alignment: Alignment.centerRight,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: panel,
        ),
      );
    }
    return Align(
      alignment: Alignment.bottomCenter,
      child: FractionallySizedBox(
        heightFactor: 0.55,
        child: panel,
      ),
    );
  }

  Widget _buildContent(AppLocalizations l10n) {
    if (_loading) {
      return const Center(child: AppLoadingIndicator());
    }
    // useWebview 脚本源：需先抓取渲染后 HTML 才能解析图片（见 _captureAndRetry）。
    if (_htmlCaptureRequest != null) {
      return _CenterMessage(
        icon: Icons.cloud_download_outlined,
        message: l10n.captureHint,
        onRetry: _captureAndRetry,
      );
    }
    if (_error != null) {
      return _CenterMessage(
        icon: Icons.error_outline,
        message: _isLocalMode ? l10n.localFileLoadFailed : l10n.loadFailed,
        onRetry: _isLocalMode
            ? () => _loadLocalImages(restorePage: _currentPage)
            : () => _loadChapter(_chapterIndex, restorePage: _currentPage),
      );
    }
    if (_images.isEmpty) {
      return _CenterMessage(icon: Icons.image_not_supported, message: l10n.noImages);
    }
    if (_prefs.readingMode.isWebtoon) return _buildWebtoon();
    return _buildPaged();
  }

  /// 双页并排是否生效：仅横排单页模式（LTR/RTL）支持。
  /// 竖排 / 长条模式下「双页拆分」开关会被自动关闭（见设置面板 _buildReadingMode /
  /// _buildSplitDoublePage 的联动），以保证开关始终「有作用」。
  bool get _isDoublePage =>
      _prefs.splitDoublePage &&
      (_prefs.readingMode == ReadingMode.singleLTR ||
          _prefs.readingMode == ReadingMode.singleRTL);

  /// 左右留白像素值（sideMargin 占屏宽比例 → 实际像素）。
  double get _sideMarginPx =>
      _prefs.sideMargin * MediaQuery.of(context).size.width;

  /// 跨页（spread）数量：双页模式下 PageView 的 itemCount。
  int get _spreadCount => (_images.length / 2).ceil();

  /// PageController 的单位总数：双页模式 = 跨页数，否则 = 单页数。
  int get _controllerPageCount => _isDoublePage ? _spreadCount : _images.length;

  Widget _buildPaged() {
    if (_isDoublePage) return _buildPagedSpread();
    final pc = _pageController;
    if (pc == null) return const SizedBox.shrink();
    return PageView.builder(
      // 每章独立 Key：确保切章时 PageView 重建为全新 ScrollPosition，
      // 使 PageController 的 initialPage 必定生效，避免图片停在旧页 / 回弹。
      key: ValueKey<int>(_chapterIndex),
      controller: pc,
      // 拖拽翻页统一由覆盖层 ReaderTapZones 的 onDragPage 处理（桌面鼠标拖拽 /
      // 触屏滑动都走这条），故此处禁用 PageView 原生拖拽，避免「两次翻页」冲突。
      // 程序化翻页（_goNextPage / _pageController.animateToPage / 点按热区 / 滚轮）
      // 不受影响。放大时同理禁用，交给图片自身平移。
      physics: const NeverScrollableScrollPhysics(),
      scrollDirection: _prefs.readingMode == ReadingMode.singleVertical
          ? Axis.vertical
          : Axis.horizontal,
      reverse: _prefs.readingMode == ReadingMode.singleRTL,
      itemCount: _images.length,
      itemBuilder: (ctx, i) => Padding(
        padding: EdgeInsets.symmetric(horizontal: _sideMarginPx),
        child: MangaPageImage(
          url: _images[i],
          prefs: _prefs,
          zoomController: _zoomController,
          source: _source,
          rotationQuarterTurns: _pageRotations[i] ?? 0,
          cropEdge: _prefs.cropEdge,
          onWheelPage: (next) => next ? _goNextPage() : _goPrevPage(),
        ),
      ),
    );
  }

  /// 双页并排：仅在 splitDoublePage 且横排单页模式（singleLTR/singleRTL）下使用。
  /// PageController 以「跨页(spread)」为单位，每屏展示两页；[_currentPage] 仍记录逻辑单页索引（取当前跨页的首页）。
  Widget _buildPagedSpread() {
    final pc = _pageController;
    if (pc == null) return const SizedBox.shrink();
    final rtl = _prefs.readingMode == ReadingMode.singleRTL;
    return PageView.builder(
      // 每章独立 Key：双页模式同样需要确保切章时 PageView 重建为全新 ScrollPosition。
      key: ValueKey<String>('spread-$_chapterIndex'),
      controller: pc,
      // 拖拽翻页统一由覆盖层处理，禁用 PageView 原生拖拽（避免两次翻页冲突）。
      physics: const NeverScrollableScrollPhysics(),
      scrollDirection: Axis.horizontal,
      reverse: rtl,
      itemCount: _spreadCount,
      itemBuilder: (ctx, spreadIdx) {
        final a = spreadIdx * 2;
        final b = a + 1;
        final aImg = _images[a];
        final bImg = b < _images.length ? _images[b] : null;
        final List<Widget> rowChildren = <Widget>[
          Expanded(
            child: MangaPageImage(
              url: aImg,
              prefs: _prefs,
              zoomController: _zoomController,
              source: _source,
              rotationQuarterTurns: _pageRotations[a] ?? 0,
              cropEdge: _prefs.cropEdge,
              onWheelPage: (next) => next ? _goNextPage() : _goPrevPage(),
            ),
          ),
        ];
        if (bImg != null) {
          rowChildren.add(
            Expanded(
            child: MangaPageImage(
              url: bImg,
              prefs: _prefs,
              zoomController: _zoomController,
              source: _source,
              rotationQuarterTurns: _pageRotations[b] ?? 0,
              cropEdge: _prefs.cropEdge,
              onWheelPage: (next) => next ? _goNextPage() : _goPrevPage(),
            ),
            ),
          );
        }
        // RTL 阅读顺序为右→左：跨页内两页交换位置（单页奇数尾页不变）。
        if (rtl) rowChildren.insert(0, rowChildren.removeLast());
        return Padding(
          padding: EdgeInsets.symmetric(horizontal: _sideMarginPx),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: rowChildren,
          ),
        );
      },
    );
  }

  Widget _buildWebtoon() {
    final isc = _itemScrollController;
    final ipl = _itemPositionsListener;
    if (isc == null || ipl == null) return const SizedBox.shrink();
    final gap = _prefs.readingMode == ReadingMode.webtoonWithGap
        ? AppTokens.spaceMd
        : 0.0;
    // 恢复标记消费后回退到 _currentPage（二者在进入本章首帧时一致），避免后续
    // 重建时把 initialScrollIndex 误置 0；didUpdateWidget 虽不重应用该值，仍保持稳健。
    final restoreIndex = _pendingWebtoonRestore ?? _currentPage;
    // 一次性恢复：仅在本章首次渲染时（_pendingWebtoonRestore 非空）锁定当前页并解除
    // 写盘屏蔽。监听器已在 _setupControllers 注册，此处不再重复添加（避免每次
    // setState 重注册导致重复回调）。恢复标记在此消费，后续重建不再触发。
    if (_pendingWebtoonRestore != null) {
      final target = _pendingWebtoonRestore!;
      final bool toLast = _pendingWebtoonScrollToLast;
      _pendingWebtoonRestore = null;
      _pendingWebtoonScrollToLast = false;
      final int token = _loadToken;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || token != _loadToken) return;
        final int last = _images.isEmpty ? 0 : _images.length - 1;
        if (toLast && last > 0 && isc.isAttached) {
          // 「回到上一话末页」的两段式落点：首帧先停在上一话首页，等图片陆续加载、
          // 末页项尺寸稳定后，再主动滚动到底。整个过程 _restoringPage 保持为 true，
          // 中途因图片加载引起的位置抖动一律不回写，故不会回弹。
          //
          // 关键：ScrollablePositionedList.scrollTo 是按「当前（占位）高度」换算像素
          // 距离后滚动，图片未加载时占位高度≈0，若立即滚动会停在开头附近。因此这里
          // 改为轮询等待末页项（index==last）的 itemTrailingEdge 连续两次读数一致
          // （尺寸已稳定），再 scrollTo(alignment: 1.0) 把末页底边对齐视口底（真正的
          // 「到底」）。同时加 3s 超时兜底，慢网/图片加载失败时也不会卡死。
          final lastIdx = last;
          _lastPageLastEdge = null;
          _webtoonLastPageTimer?.cancel();
          _webtoonLastPageTimer = Timer.periodic(
            const Duration(milliseconds: 80),
            (timer) {
              if (!mounted || token != _loadToken) {
                timer.cancel();
                _webtoonLastPageTimer = null;
                _webtoonLastPageTimeout?.cancel();
                _webtoonLastPageTimeout = null;
                return;
              }
              final positions = ipl.itemPositions.value;
              double? trailing;
              for (final p in positions) {
                if (p.index == lastIdx) {
                  trailing = p.itemTrailingEdge;
                  break;
                }
              }
              if (trailing == null) return; // 末页项尚未进入布局，继续等。
              if (_lastPageLastEdge != null &&
                  (trailing - _lastPageLastEdge!).abs() < 1e-3) {
                // 尺寸已稳定：取消轮询与超时，滚动到底并走收尾。
                timer.cancel();
                _webtoonLastPageTimer = null;
                _webtoonLastPageTimeout?.cancel();
                _webtoonLastPageTimeout = null;
                _lastPageLastEdge = null;
                _scrollToWebtoonLast(lastIdx, token);
              } else {
                _lastPageLastEdge = trailing;
              }
            },
          );
          // 超时兜底：3s 内未稳定也强制滚动收尾，绝不卡死。
          _webtoonLastPageTimeout?.cancel();
          _webtoonLastPageTimeout = Timer(const Duration(seconds: 3), () {
            _webtoonLastPageTimeout = null;
            if (!mounted || token != _loadToken) return;
            if (_webtoonLastPageTimer == null) return; // 已稳定并滚动，无需兜底。
            _webtoonLastPageTimer?.cancel();
            _webtoonLastPageTimer = null;
            _lastPageLastEdge = null;
            _scrollToWebtoonLast(lastIdx, token);
          });
          return;
        }
        // initialScrollIndex 已在首帧把目标页顶边对齐到视口顶部（末页则夹到最大滚动、
        // 即底部对齐，属标准章末行为），无需再 scrollTo（避免引入额外动画/回弹）。
        // 此处仅同步进度变量并解除屏蔽，此后滚动通知才是用户真实翻页。
        _currentPage = (toLast ? last : target).clamp(0, last);
        // 解除进度回写/存档屏蔽：从此滚动通知才是用户真实翻页。
        _restoringPage = false;
        setState(() {});
      });
    }
    return NotificationListener<ScrollNotification>(
      // 边界拖拽换章：手指在列表顶端/末端继续拖动时，滚动位置被夹紧，多余位移会
      // 以 overscroll 上报。累计超过阈值即换章 —— 这是连续滚动阅读的标准手势，
      // 让换章彻底摆脱对「当前页」测量值的依赖。
      onNotification: _handleWebtoonScrollNotification,
      child: _buildWebtoonList(isc, ipl, restoreIndex, gap),
    );
  }

  /// 回到上一话末页时，把条漫列表滚动到底（末页底边对齐视口底）并收尾。
  /// [last] 为末页下标，[token] 为本次加载令牌，用于竞态时放弃。整个过程
  /// _restoringPage 保持为 true，收尾时才把当前页赋成末页并解除屏蔽，避免回弹。
  void _scrollToWebtoonLast(int last, int token) {
    final isc = _itemScrollController;
    if (isc == null || !isc.isAttached) {
      // 列表已卸载：直接收尾，不滚动（极端竞态下不会卡死）。
      _finishWebtoonRestore(last, token);
      return;
    }
    isc.scrollTo(
      index: last,
      alignment: 1.0,
      duration: AppTokens.durFast,
      curve: Curves.easeOut,
    );
    _webtoonRestoreTimer?.cancel();
    _webtoonRestoreTimer = Timer(
      AppTokens.durFast + const Duration(milliseconds: 150),
      () => _finishWebtoonRestore(last, token),
    );
  }

  /// 回到上一话末页的收尾：把当前页赋成末页、解除屏蔽、写盘。
  void _finishWebtoonRestore(int last, int token) {
    _webtoonRestoreTimer = null;
    if (!mounted || token != _loadToken) return;
    _currentPage = last;
    _restoringPage = false;
    _saveProgress(last);
    setState(() {});
  }

  /// 条漫列表的边界拖拽换章判定。返回 false 让通知继续向上冒泡。
  bool _handleWebtoonScrollNotification(ScrollNotification n) {
    if (n is ScrollStartNotification || n is ScrollEndNotification) {
      // 回到上一话末页的自动滚动过程中，用户主动拖动则放弃自动滚到底（已接管）。
      // 程序滚动动画的 dragDetails 为 null，不会误触发。
      if (n is ScrollStartNotification &&
          n.dragDetails != null &&
          _restoringPage &&
          _webtoonLastPageTimer != null) {
        _webtoonLastPageTimer?.cancel();
        _webtoonLastPageTimer = null;
        _webtoonLastPageTimeout?.cancel();
        _webtoonLastPageTimeout = null;
        _lastPageLastEdge = null;
        _restoringPage = false;
      }
      _overscrollAccum = 0;
      return false;
    }
    if (n is! OverscrollNotification) return false;
    // 仅响应手指拖拽产生的越界，忽略惯性滑动的余量，避免快速甩动误换章。
    if (n.dragDetails == null) return false;
    _overscrollAccum += n.overscroll;
    if (_overscrollAccum >= _kChapterOverscroll) {
      _overscrollAccum = 0;
      _goNextChapter();
    } else if (_overscrollAccum <= -_kChapterOverscroll) {
      _overscrollAccum = 0;
      _goPrevChapter();
    }
    return false;
  }

  Widget _buildWebtoonList(
    ItemScrollController isc,
    ItemPositionsListener ipl,
    int restoreIndex,
    double gap,
  ) {
    return ScrollablePositionedList.separated(
      key: ValueKey('webtoon-$_chapterIndex'),
      itemScrollController: isc,
      itemPositionsListener: ipl,
      initialScrollIndex: restoreIndex,
      // 连续滚动（条漫）：用 ClampingScrollPhysics 平滑滚动，边界夹紧、无回弹。
      // 放大时改为 NeverScrollable：把拖拽让给图片自身的平移手势，避免与滚动打架。
      physics: _zoomed
          ? const NeverScrollableScrollPhysics()
          : const ClampingScrollPhysics(),
      padding: EdgeInsets.zero,
      itemCount: _images.length,
      separatorBuilder: (_, __) => SizedBox(height: gap),
      itemBuilder: (ctx, i) => Padding(
        padding: EdgeInsets.symmetric(horizontal: _sideMarginPx),
        child: MangaPageImage(
          url: _images[i],
          prefs: _prefs,
          zoomController: _zoomController,
          source: _source,
          rotationQuarterTurns: _pageRotations[i] ?? 0,
          cropEdge: _prefs.cropEdge,
          onWheelPage: (next) => next ? _goNextPage() : _goPrevPage(),
        ),
      ),
    );
  }

  Widget _buildTopBar(AppLocalizations l10n, Color bg) {
    final chapter = widget.chapters.isEmpty
        ? null
        : widget.chapters[_chapterIndex];
    final String? chapterUrl = chapter?.url;
    final String? absoluteChapterUrl = (chapterUrl != null &&
            chapterUrl.isNotEmpty)
        ? (_source != null && _source!.site.baseUrl.isNotEmpty
            ? _source!.site.baseUrl + chapterUrl
            : chapterUrl)
        : null;
    // 本地模式标题：文件名 · 本地文件（无章节概念）。
    final String titleText = _isLocalMode
        ? '${widget.title} · ${l10n.localFileLabel}'
        : '${widget.title} · ${l10n.chapterN(_chapterIndex + 1)}'
            '${chapter != null && chapter.title.isNotEmpty ? ' · ${chapter.title}' : ''}';
    // 控制栏底色跟随应用主题（暗色即深色），而非读者背景色：
    // 这样无论读者背景设为黑/白/护眼绿，图标文字都始终与底色形成对比，夜色模式不会看不清。
    final Color scrim = Theme.of(context).colorScheme.surface;
    return SafeArea(
      child: Container(
        key: _topBarKey,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[scrim.withValues(alpha: 0.95), scrim.withValues(alpha: 0)],
          ),
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: AppTokens.spaceMd,
          vertical: AppTokens.spaceSm,
        ),
        child: Row(
          children: <Widget>[
            IconButton(
              icon: const Icon(Icons.arrow_back),
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: () => Navigator.of(context).pop(),
            ),
            Expanded(
              child: Text(
                titleText,
                style: Theme.of(context).textTheme.titleMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              icon: Icon(_isFav ? Icons.favorite : Icons.favorite_border),
              tooltip: l10n.favorite,
              onPressed: _onFavoritePressed,
            ),
            IconButton(
              icon: const Icon(Icons.settings),
              tooltip: l10n.readerSettings,
              onPressed: _openSettings,
            ),
            // 章节列表按钮：本地模式无章节概念，隐藏。
            if (!_isLocalMode)
              IconButton(
                icon: const Icon(Icons.toc),
                tooltip: l10n.chapterList,
                onPressed: () async {
                  final index = await showChapterList(
                    context,
                    widget.chapters,
                    _chapterIndex,
                  );
                  if (index != null && index != _chapterIndex && mounted) {
                    _chapterIndex = index;
                    _loadChapter(_chapterIndex);
                  }
                },
              ),
            // WebView / 浏览器 / 分享菜单：本地模式无在线 URL，隐藏。
            if (!_isLocalMode)
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert),
                tooltip: l10n.moreActions,
                onSelected: (String value) {
                  if (absoluteChapterUrl == null) return;
                  switch (value) {
                    case 'webview':
                      openInAppBrowser(context, absoluteChapterUrl);
                    case 'browser':
                      openInExternalBrowser(context, absoluteChapterUrl);
                    case 'share':
                      shareContent(
                        context,
                        '${widget.title} - ${chapter?.title ?? ''}',
                        absoluteChapterUrl,
                      );
                  }
                },
                itemBuilder: (BuildContext ctx) => <PopupMenuEntry<String>>[
                  PopupMenuItem<String>(
                    value: 'webview',
                    enabled: absoluteChapterUrl != null,
                    child: ListTile(
                      leading: const Icon(Icons.public),
                      title: Text(l10n.openInAppBrowser),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                    ),
                  ),
                  PopupMenuItem<String>(
                    value: 'browser',
                    enabled: absoluteChapterUrl != null,
                    child: ListTile(
                      leading: const Icon(Icons.open_in_new),
                      title: Text(l10n.openInBrowser),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                    ),
                  ),
                  PopupMenuItem<String>(
                    value: 'share',
                    enabled: absoluteChapterUrl != null,
                    child: ListTile(
                      leading: const Icon(Icons.share_outlined),
                      title: Text(l10n.share),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar(AppLocalizations l10n) {
    // 控制栏底色跟随应用主题（暗色即深色），保证图标文字对比度（见 _buildTopBar）。
    final Color scrim = Theme.of(context).colorScheme.surface;
    return SafeArea(
      top: false,
      child: Container(
        key: _bottomBarKey,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: <Color>[
              scrim.withValues(alpha: 0.95),
              scrim.withValues(alpha: 0),
            ],
          ),
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: AppTokens.spaceMd,
          vertical: AppTokens.spaceSm,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // 章内进度滑条（仅底横形态；右竖形态由 _buildRightProgressBar 单独覆盖）。
            _buildProgressBar(l10n),
            const SizedBox(height: AppTokens.spaceXs),
            _buildBottomToolbar(l10n),
          ],
        ),
      ),
    );
  }

  /// 底部横向进度滑条（progressBarOnRight=false 时渲染）。
  /// 左右翻页箭头 + 滑条 + 页码（受 showPageNumber 控制）。
  /// 双页模式下以「跨页」为单位，标签显示当前跨页包含的页码范围。
  Widget _buildProgressBar(AppLocalizations l10n) {
    if (_prefs.progressBarOnRight) return const SizedBox.shrink();
    final bool doubleMode = _isDoublePage;
    final int totalImages = _images.length;
    final int total = doubleMode ? _spreadCount : totalImages;
    final int currentIndex =
        doubleMode ? (_currentPage ~/ 2) : _currentPage;
    final double base = total > 1 ? currentIndex / (total - 1) : 0.0;
    final double value = base.clamp(0.0, 1.0);
    return Semantics(
      label: l10n.readerProgress,
      child: Directionality(
        // RTL 模式下滑条方向反转（视觉与翻页方向一致）。
        textDirection: _prefs.readingMode == ReadingMode.singleRTL
            ? TextDirection.rtl
            : TextDirection.ltr,
        child: Row(
          children: <Widget>[
            IconButton(
              icon: const Icon(Icons.chevron_left),
              tooltip: l10n.prevPage,
              onPressed: _goPrevPage,
            ),
            Expanded(
              child: Slider(
                value: value,
                onChanged: total > 1
                    ? (v) {
                        final target = doubleMode
                            ? (v * (total - 1)).round() * 2
                            : (v * (total - 1)).round();
                        _jumpToPage(target);
                      }
                    : null,
              ),
            ),
            if (_prefs.showPageNumber)
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: AppTokens.spaceSm),
                child: Text(
                  doubleMode
                      ? _doublePageIndicatorText(l10n, currentIndex, totalImages)
                      : l10n.pageIndicator(
                          totalImages == 0 ? 0 : _currentPage + 1,
                          totalImages,
                        ),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            IconButton(
              icon: const Icon(Icons.chevron_right),
              tooltip: l10n.nextPage,
              onPressed: _goNextPage,
            ),
          ],
        ),
      ),
    );
  }

  /// 双页跨页页码标签，例如 1-2 / 10。
  String _doublePageIndicatorText(
    AppLocalizations l10n,
    int spreadIndex,
    int totalImages,
  ) {
    final first = spreadIndex * 2 + 1;
    final last = ((spreadIndex + 1) * 2).clamp(1, totalImages);
    return l10n.readerDoublePageIndicator(first, last, totalImages);
  }

  /// 双页跨页范围文本（不含总数），例如 1-2。
  String _doublePageRangeText(int spreadIndex, int totalImages) {
    final first = spreadIndex * 2 + 1;
    final last = ((spreadIndex + 1) * 2).clamp(1, totalImages);
    return '$first-$last';
  }

  /// 右侧竖向进度滑条（progressBarOnRight=true 时渲染）。
  /// 靠右 Positioned：上/下翻页箭头 + 顶/底页码 + 旋转 90° 的 Slider。
  /// 双页模式下以「跨页」为单位。
  Widget _buildRightProgressBar(AppLocalizations l10n) {
    final bool doubleMode = _isDoublePage;
    final int totalImages = _images.length;
    final int total = doubleMode ? _spreadCount : totalImages;
    final int currentIndex =
        doubleMode ? (_currentPage ~/ 2) : _currentPage;
    final double base = total > 1 ? currentIndex / (total - 1) : 0.0;
    final double value = base.clamp(0.0, 1.0);
    final bool showNum = _prefs.showPageNumber;
    return Positioned(
      right: AppTokens.spaceXs,
      top: 0,
      bottom: 0,
      child: SafeArea(
        child: Center(
          child: Semantics(
            label: l10n.readerProgress,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                IconButton(
                  icon: const Icon(Icons.expand_less),
                  tooltip: l10n.prevPage,
                  onPressed: _goPrevPage,
                ),
              if (showNum)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: AppTokens.spaceXs,
                  ),
                  child: Text(
                    doubleMode
                        ? _doublePageRangeText(currentIndex, totalImages)
                        : '${totalImages == 0 ? 0 : _currentPage + 1}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                SizedBox(
                  // 旋转 90° 后，Slider 的横向宽度变成竖向高度。
                  height: MediaQuery.of(context).size.height * 0.4,
                  child: RotatedBox(
                    quarterTurns: 1,
                    child: Slider(
                      value: value,
                      onChanged: total > 1
                          ? (v) {
                              final target = doubleMode
                                  ? (v * (total - 1)).round() * 2
                                  : (v * (total - 1)).round();
                              _jumpToPage(target);
                            }
                          : null,
                    ),
                  ),
                ),
                if (showNum)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: AppTokens.spaceXs,
                    ),
                    child: Text(
                      // 与单页模式保持一致：底部始终显示总页数。
                      '$totalImages',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                IconButton(
                  icon: const Icon(Icons.expand_more),
                  tooltip: l10n.nextPage,
                  onPressed: _goNextPage,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 底部快捷工具栏：阅读模式选择 / Spacer / 裁剪 / 旋转 / 设置。
  Widget _buildBottomToolbar(AppLocalizations l10n) {
    return Row(
      children: <Widget>[
        IconButton(
          icon: Icon(_readingModeIcon(_prefs.readingMode)),
          tooltip: l10n.readerMode,
          onPressed: () => _showReadingModePicker(l10n),
        ),
        const Spacer(),
        IconButton(
          icon: Icon(_prefs.cropEdge ? Icons.crop : Icons.crop_free),
          tooltip: l10n.readerCropEdge,
          onPressed: () => _onPrefsChanged(
            _prefs.copyWith(cropEdge: !_prefs.cropEdge),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.rotate_right),
          tooltip: l10n.readerRotatePage,
          onPressed: _rotateCurrentPage,
        ),
        IconButton(
          icon: const Icon(Icons.tune),
          tooltip: l10n.readerSettings,
          onPressed: _openSettings,
        ),
      ],
    );
  }

  IconData _readingModeIcon(ReadingMode mode) => switch (mode) {
        ReadingMode.singleLTR => Icons.arrow_forward,
        ReadingMode.singleRTL => Icons.arrow_back,
        ReadingMode.singleVertical => Icons.arrow_downward,
        ReadingMode.webtoon => Icons.view_stream,
        ReadingMode.webtoonWithGap => Icons.view_agenda,
      };

  /// 阅读模式选择：弹出白色底部面板，用 ChoiceChip 列出 5 种模式
  ///（用户决策：与小说阅读器一致的形式）。
  void _showReadingModePicker(AppLocalizations l10n) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppTokens.spaceLg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(l10n.readerMode,
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: AppTokens.spaceMd),
              Wrap(
                spacing: AppTokens.spaceSm,
                runSpacing: AppTokens.spaceSm,
                children: ReadingMode.values.map((m) {
                  return ChoiceChip(
                    label: Text(_readingModeLabel(l10n, m)),
                    selected: _prefs.readingMode == m,
                    onSelected: (_) {
                      _onPrefsChanged(_prefs.copyWith(readingMode: m));
                      Navigator.of(ctx).pop();
                    },
                  );
                }).toList(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _readingModeLabel(AppLocalizations l10n, ReadingMode m) => switch (m) {
        ReadingMode.singleLTR => l10n.readerModeSingleLTR,
        ReadingMode.singleRTL => l10n.readerModeSingleRTL,
        ReadingMode.singleVertical => l10n.readerModeSingleVertical,
        ReadingMode.webtoon => l10n.readerModeWebtoon,
        ReadingMode.webtoonWithGap => l10n.readerModeWebtoonWithGap,
      };

}

/// 居中的提示信息（错误 / 空）。
class _CenterMessage extends StatelessWidget {
  final IconData icon;
  final String message;
  final VoidCallback? onRetry;
  const _CenterMessage({required this.icon, required this.message, this.onRetry});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.spaceLg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 48, color: scheme.onSurfaceVariant),
            const SizedBox(height: AppTokens.spaceMd),
            Text(message, style: Theme.of(context).textTheme.bodyMedium),
            if (onRetry != null) ...<Widget>[
              const SizedBox(height: AppTokens.spaceMd),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: Text(AppLocalizations.of(context).retry),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 单页漫画图：支持以指针为中心的双击/滚轮缩放（缩放由外部
/// [zoomController] 统一驱动，便于阅读器在点击区域覆盖层上响应双击缩放）。
///
/// 增强：[rotationQuarterTurns] 让用户对单页 90° 旋转（不影响其他页）；
/// [cropEdge] 为 true 时改用 [BoxFit.cover] / 居中裁切去四周留白（简单版）。
class MangaPageImage extends StatefulWidget {
  final String url;
  final ReaderPreferences prefs;
  final TransformationController? zoomController;
  final PluginConfig? source;

  /// 该页旋转的 quarterTurns（0/1/2/3 = 0°/90°/180°/270°）。
  final int rotationQuarterTurns;

  /// 是否裁边（true 时图片 fit 切换为 cover + 居中对齐，去除四周留白）。
  final bool cropEdge;

  /// 滚轮翻页回调（参数为 true 表示下一页、false 表示上一页）；仅在
  /// [ReaderPreferences.mouseWheelAction] 为 [MouseWheelAction.page] 时使用。
  final void Function(bool next)? onWheelPage;

  const MangaPageImage({
    super.key,
    required this.url,
    required this.prefs,
    this.zoomController,
    this.source,
    this.rotationQuarterTurns = 0,
    this.cropEdge = false,
    this.onWheelPage,
  });

  @override
  State<MangaPageImage> createState() => _MangaPageImageState();
}

class _MangaPageImageState extends State<MangaPageImage> {
  final TransformationController _local = TransformationController();
  TransformationController get _tc => widget.zoomController ?? _local;

  /// 当前是否处于放大状态（scale > 1）。仅放大时才在 build 里挂载 GestureDetector
  /// 处理平移 / 捏合；未放大时把指针事件让给底层 PageView / ListView，使翻页 /
  /// 滚动生效。
  bool _zoomed = false;

  /// pan / pinch 手势起点的初始矩阵（[_handleScaleStart] 时复制 [_tc.value]）。
  Matrix4? _scaleStartMatrix;

  /// pan / pinch 手势起点的局部焦点（用于单指 pan 的累计偏移计算）。
  Offset? _scaleStartFocal;

  @override
  void initState() {
    super.initState();
    _tc.addListener(_onTransformChanged);
    _syncZoomed();
  }

  void _onTransformChanged() {
    final zoomed = _tc.value.getMaxScaleOnAxis() > 1.001;
    if (zoomed != _zoomed && mounted) setState(() => _zoomed = zoomed);
  }

  void _syncZoomed() =>
      _zoomed = _tc.value.getMaxScaleOnAxis() > 1.001;

  @override
  void dispose() {
    _tc.removeListener(_onTransformChanged);
    _local.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 初始缩放（initialZoom）+ 裁边（cropEdge）共同决定图片 fit 与尺寸约束。
    // cropEdge 优先：用 BoxFit.cover 居中裁切，去掉页面四周留白（按文档简单版实现）。
    // 非裁边时按 initialZoom 选择适配方式。
    final (BoxFit fit, double? width) = _resolveFit();
    final Widget raw = widget.cropEdge
        ? SizedBox.expand(
            child: SourceImage(
              url: widget.url,
              source: widget.source,
              fit: BoxFit.cover,
              placeholder: const Center(child: AppLoadingIndicator()),
            ),
          )
        : Align(
            alignment: Alignment.center,
            child: SourceImage(
              url: widget.url,
              source: widget.source,
              fit: fit,
              width: width,
              placeholder: const Center(child: AppLoadingIndicator()),
            ),
          );
    final img = ReaderImageFiltered(
      brightness: widget.prefs.filterBrightness,
      contrast: widget.prefs.filterContrast,
      colorTemp: widget.prefs.filterColorTemp,
      saturation: widget.prefs.filterSaturation,
      hue: widget.prefs.filterHue,
      inverted: widget.prefs.filterInverted,
      grayscale: widget.prefs.filterGrayscale,
      child: raw,
    );
    // 旋转包裹在 img 外：仅对该页生效，不影响其他页。
    final rotated = RotatedBox(
      quarterTurns: widget.rotationQuarterTurns,
      child: img,
    );
    // 把 [_tc] 的矩阵应用到 rotated 上，得到「已缩放/已平移」的最终图像。
    // 必须用 AnimatedBuilder 监听 [_tc]：滚轮 / 双击 / 捏合每次改值都会即时重建
    // Transform，画面才「跟手」。否则只有 [_zoomed] 翻转那一瞬间才 setState，
    // 连续捏合时画面完全不动，表现为「放缩不是实时更新」。
    // [rotated] 作为 child 传入并缓存，避免每帧重建图片加载子树。
    final transformed = AnimatedBuilder(
      animation: _tc,
      builder: (context, child) => Transform(
        transform: _tc.value,
        alignment: Alignment.center,
        child: child,
      ),
      child: rotated,
    );
    return Listener(
      // 用 translucent：让外层 Listener 始终在命中路径中（即便内部 GestureDetector
      // 是 opaque）。我们的 Listener 是路径里唯一的 wheel 处理者（替换掉原来的
      // InteractiveViewer 后，不会再有更深的 Listener 与我们竞争 resolver），所
      // 以滚轮缩放 / 翻页在「未放大」与「已放大」两种状态都生效。
      behavior: HitTestBehavior.translucent,
      onPointerSignal: (e) {
        if (e is! PointerScrollEvent) return;
        // 条漫（连续滚动）模式：未放大时滚轮交给原生 ListView 连续滚动（翻页），
        // 已放大时由我们接管缩放。条漫下「作用」设置无意义，这里按上下文自动分派：
        // 没放大=滚动，已放大=缩放；双击任意处可进入放大态。
        if (widget.prefs.readingMode.isWebtoon) {
          final bool isZoomed = _tc.value.getMaxScaleOnAxis() > 1.001;
          if (!isZoomed) return; // 原生连续滚动（翻页）
        }
        // 通过 pointerSignalResolver 抢占滚轮事件：我们的 Listener 比底层 Scrollable
        // 更深（先注册 → 胜出），从而阻止 Scrollable 同时翻页/滚动。由 [_onWheel] 决定缩放。
        GestureBinding.instance.pointerSignalResolver
            .register(e, (_) => _onWheel(e));
      },
      // 放缩手势常驻：翻页模式下一律挂载 GestureDetector（translucent），使「未放大时
      // 双指捏合也能直接放大」；条漫模式为避免与列表原生竖向滚动抢手势，仅在已放大时
      // 挂载（未放大时用双击缩放进入放大态、再捏合微调）。单指平移仅在已放大时生效，
      // 未放大的单指交给底层 PageView / ListView 翻页或滚动，避免误吞原生手势。
      //
      // 重要：不要在这里用 InteractiveViewer。它的内部 Listener
      // （interactive_viewer.dart:1088 `_receivedPointerSignal`）始终在命中路径
      // 中——比我们的外层 Listener 更深，会先于我们注册到 pointerSignalResolver
      // 抢走滚轮事件；且即使 `scaleEnabled: false`，它也只是让 handler 静默返回，
      // 事件依然被消费掉，导致「已放大后滚轮失效」（设置面板的「作用 / 方向」按
      // 钮点击都看似无效）。这里自管 Transform + GestureDetector 是根治方案。
      child: (!widget.prefs.readingMode.isWebtoon || _zoomed)
          ? GestureDetector(
              behavior: HitTestBehavior.translucent,
              onScaleStart: _handleScaleStart,
              onScaleUpdate: _handleScaleUpdate,
              onScaleEnd: _handleScaleEnd,
              child: transformed,
            )
          : transformed,
    );
  }

  /// 由 [ReaderPreferences.initialZoom] 推导非裁边状态下的图片 fit 与宽度约束。
  /// - fitWidth：按宽度适配（width=∞）。
  /// - fitHeight：按高度适配（width=∞，由父容器高度约束）。
  /// - original：原始像素大小（不加宽高约束，由 InteractiveViewer 裁剪/平移）。
  ///
  /// 裁边（cropEdge）在 [build] 中单独用 [SizedBox.expand] + [BoxFit.cover] 处理，
  /// 不再经过本方法。
  (BoxFit, double?) _resolveFit() {
    switch (widget.prefs.initialZoom) {
      case ReaderInitialZoom.fitWidth:
        return (BoxFit.fitWidth, double.infinity);
      case ReaderInitialZoom.fitHeight:
        return (BoxFit.fitHeight, double.infinity);
      case ReaderInitialZoom.original:
        return (BoxFit.none, null);
    }
  }

  void _onWheel(PointerScrollEvent e) {
    // 条漫（连续滚动）模式：能进入此分支说明已放大（onPointerSignal 仅在已放大时
    // 注册滚轮）。滚轮一律缩放（微调），方向（自然/反向）照常生效，配合单指/鼠标
    // 拖动平移。未放大时滚轮走原生连续滚动（翻页），不经过此处。
    if (widget.prefs.readingMode.isWebtoon) {
      final double base = e.scrollDelta.dy < 0 ? 1.1 : 0.9;
      final double factor =
          widget.prefs.scrollWheelInverted ? (base == 1.1 ? 0.9 : 1.1) : base;
      _zoomAround(e.localPosition, factor);
      return;
    }
    // 翻页模式：按「作用」区分翻页 / 缩放。
    if (widget.prefs.mouseWheelAction == MouseWheelAction.page) {
      // 下滚=下一页，上滚=上一页；scrollWheelInverted 反转「下一/上一页」方向。
      final bool down = e.scrollDelta.dy > 0;
      final bool next = widget.prefs.scrollWheelInverted ? !down : down;
      widget.onWheelPage?.call(next);
      return;
    }
    // 滚轮缩放：scrollWheelInverted 反转方向（上滚放大、下滚缩小；反向则互换）。
    final double base = e.scrollDelta.dy < 0 ? 1.1 : 0.9;
    final double factor =
        widget.prefs.scrollWheelInverted ? (base == 1.1 ? 0.9 : 1.1) : base;
    _zoomAround(e.localPosition, factor);
  }

  void _zoomAround(Offset focal, double factor) {
    final m = _tc.value;
    final cur = m.getMaxScaleOnAxis();
    final newScale =
        (cur * factor).clamp(widget.prefs.minScale, widget.prefs.maxScale);
    final realFactor = newScale / cur;
    final dx = focal.dx * (1 - realFactor);
    final dy = focal.dy * (1 - realFactor);
    _tc.value = Matrix4.identity()
      ..translate(dx, dy)
      ..scale(realFactor)
      ..multiply(m);
  }

  // ──────────────────── 平移 / 捏合手势（仅 [_zoomed] = true 时挂载） ─────

  /// 记录 pan / pinch 起点的初始矩阵与焦点。
  ///
  /// 未放大且为单指时不接管手势（交给底层翻页 / 滚动），不记录基准矩阵；
  /// 双指捏合即便从未放大也立即接管，实现「未放大即可直接捏合放大」。
  void _handleScaleStart(ScaleStartDetails details) {
    if (!_zoomed && details.pointerCount < 2) {
      _scaleStartMatrix = null;
      _scaleStartFocal = null;
      return;
    }
    _scaleStartMatrix = Matrix4.copy(_tc.value);
    _scaleStartFocal = details.localFocalPoint;
  }

  /// pan / pinch 更新：双指 → 捏合缩放（以起手时的矩阵为基准、累计 scale 应用，
  /// 常驻生效，未放大也能直接放大）；单指 → 仅在已放大时平移（以起手焦点为基准、
  /// 累计 focal 偏移应用），未放大时单指交还底层滚动 / 翻页。
  void _handleScaleUpdate(ScaleUpdateDetails details) {
    if (_scaleStartMatrix == null || _scaleStartFocal == null) return;
    if (details.pointerCount >= 2) {
      // 捏合：以起手矩阵为基准，按累计 [details.scale] 缩放并夹紧到 [minScale, maxScale]。
      // 此分支常驻生效，即便当前 scale == 1（未放大）也能直接放大。
      final Matrix4 base = _scaleStartMatrix!;
      final double startScale = base.getMaxScaleOnAxis();
      final double target =
          (startScale * details.scale)
              .clamp(widget.prefs.minScale, widget.prefs.maxScale);
      final double realFactor = startScale == 0 ? 1.0 : target / startScale;
      final Offset focal = details.localFocalPoint;
      final double dx = focal.dx * (1 - realFactor);
      final double dy = focal.dy * (1 - realFactor);
      _tc.value = Matrix4.identity()
        ..translate(dx, dy)
        ..scale(realFactor)
        ..multiply(base);
    } else {
      // 单指 pan：仅在已放大时平移；未放大时不处理，由底层 PageView / ListView 接管。
      if (!_zoomed) return;
      final Offset delta = details.localFocalPoint - _scaleStartFocal!;
      final Matrix4 m = Matrix4.copy(_scaleStartMatrix!)
        ..leftTranslate(delta.dx, delta.dy);
      _tc.value = m;
    }
  }

  void _handleScaleEnd(ScaleEndDetails details) {
    _scaleStartMatrix = null;
    _scaleStartFocal = null;
  }
}

/// 关闭阅读器内所有滚动组件的「回弹」（橡皮筋）与 overscroll 发光指示器。
///
/// 配合各滚动组件显式声明的 `PageScrollPhysics().applyTo(ClampingScrollPhysics())`，
/// 既保留条漫逐图吸附 / 翻页分页，又在边界夹紧、不再回弹。
class _NoOverscrollBehavior extends ScrollBehavior {
  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const ClampingScrollPhysics();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) =>
      child;
}

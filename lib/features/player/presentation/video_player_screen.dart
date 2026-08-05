import 'dart:async';
import 'dart:convert';

import 'package:canvas_danmaku/canvas_danmaku.dart' as cd;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:hive/hive.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/danmaku/bilibili_danmaku_service.dart';
import '../../../core/danmaku/danmaku_repository.dart';
import '../../../core/danmaku/danmaku_settings.dart';
import '../../../core/danmaku/danmaku_settings_store.dart';
import '../../../core/danmaku/danmaku_source.dart';
import '../../../core/danmaku/dandanplay_service.dart';
import '../../../core/favorites/favorites_manager.dart';
import '../../../core/history/media_playback_position_manager.dart';
import '../../../core/history/media_watched_manager.dart';
import '../../../core/models/episode.dart';
import '../../../core/models/media_item.dart';
import '../../../core/models/plugin_config.dart';
import '../../../core/player/player_controller.dart';
import '../../../core/settings/general_settings.dart';
import '../../../core/settings/player_settings.dart';
import '../../../core/player/widgets/seek_bar.dart';
import '../../../core/resolver/webview_resolver.dart';
import '../../../core/scraper/media_api_service.dart';
import '../../../core/services/source_repository.dart';
import '../../../core/widgets/web_favorite_action.dart';
import '../../verification/presentation/webview_verification_screen.dart';
import '../../../core/settings/danmaku_config.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_error_state.dart';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:cast/cast.dart';
import 'package:floating/floating.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/widgets/danmaku.dart';
import '../../../core/widgets/danmaku_overlay.dart';
import '../cast/cast_service.dart';
import 'danmaku_settings_sheet.dart';
import 'danmaku_source_sheet.dart';
import 'danmaku_match_sheet.dart';
import 'subtitle_panel.dart';
import 'package:nexhub/core/widgets/app_alert_dialog.dart';

/// 发送弹幕时可选择的预设颜色（与主流弹幕站一致）。
const List<Color> _danmakuPresetColors = <Color>[
  Colors.white,
  Colors.red,
  Colors.orange,
  Colors.yellow,
  Color(0xFF00E676), // 绿
  Color(0xFF40C4FF), // 青
  Colors.blue,
  Colors.purple,
  Color(0xFFFF4081), // 粉
];

/// 视频手势坐标轴状态机：避免横滑（seek）与竖滑（亮度 / 音量）冲突。
///
/// 一旦 [onVerticalDragStart] / [onHorizontalDragStart] 判定方向，即锁定该轴
/// 直到对应 `onEnd` 重置回 [none]，update 期间不切换轴。
enum _GestureAxis { none, horizontal, verticalLeft, verticalRight }

/// 视频播放页（Phase 5）。
///
/// - 从源解析真实可播放地址（[MediaApiService.fetchVideoUrl]）
/// - [PlayerController] + [MediaKitBackend] 提供播放内核
/// - 自定义控件：播放/暂停/进度/锁定/连播/解码模式/音频通道/画面比例
/// - 弹幕覆盖层按视频进度注入（[DanmakuController] + [DanmakuOverlay]）
/// - 弹幕来源：弹弹play（签名 + 搜索匹配）→ Bilibili fallback
///
/// 本地模式（Task O4.B.2）：传入 [localUri] 时进入本地模式，跳过在线源解析，
/// 直接用 [Player] + [VideoController] 打开本地文件。本地模式下隐藏切换线路 /
/// 下一集等在线专属按钮，保留弹幕（可选）、进度记忆（用 [itemId] =
/// `'local_${file.path.hashCode}'`）、播放器设置。调用方需将 [itemId] 设为
/// `'local_${file.path.hashCode}'`，[episode] 可用文件名构造占位 Episode。
class VideoPlayerScreen extends StatefulWidget {
  final String title;
  final Episode episode;
  final String sourceId;
  final String itemId;

  /// 可选：全集列表（用于自动连播与上下集切换）。
  final List<Episode>? episodes;

  /// 可选：初始剧集索引（在 [episodes] 中的位置）。
  final int? initialEpisodeIndex;

  /// 可选：切集回调（外部刷新详情页状态时使用）。
  final ValueChanged<Episode>? onEpisodeChange;

  /// 可选：收藏类型（用于播放器内收藏按钮）。若提供则顶栏显示收藏按钮。
  final SourceType? favoriteType;

  /// 本地模式：本地视频文件路径（跳过在线源解析，直接打开）。
  final String? localUri;

  /// 直链播放地址（视频嗅探器等场景）：非空时跳过在线源解析，直接播放该 URL。
  final String? directUrl;

  /// 直链播放请求头（防盗链 Referer / UA 等；仅 [directUrl] 模式使用）。
  final Map<String, String>? directHeaders;

  /// 详情页 URL（用于收藏时透传，避免历史/收藏详情灰屏）。
    final String? detailUrl;

  /// 是否恢复上次播放位置（默认 true）。
  ///
  /// 由全局「记住播放/阅读位置」开关门控：关闭时打开即从头播放，
  /// 不跳到上次进度。
  final bool restoreProgress;

  /// 封面 URL（用于收藏时透传，避免收藏书架缺封面）。
  final String? coverUrl;

  const VideoPlayerScreen({
    super.key,
    required this.title,
    required this.episode,
    required this.sourceId,
    required this.itemId,
    this.episodes,
    this.initialEpisodeIndex,
    this.onEpisodeChange,
    this.favoriteType,
    this.localUri,
    this.directUrl,
    this.directHeaders,
    this.detailUrl,
    this.coverUrl,
    this.restoreProgress = true,
  });

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  // 注意：_controller 不在 initState 同步创建，而是在 _init() 中、等上一次播放器
  // 原生释放完成后再创建。否则新 Player 的 mpv 上下文会与尚未释放的旧 surface
  // 重叠，连续多次打开会在第三次冲突杀进程（Lost connection to device）。
  late final PlayerController _controller;
  bool _controllerCreated = false;
  VideoController? _videoController;

  final DanmakuController _danmakuController = DanmakuController();
  final GlobalKey<DanmakuOverlayState> _danmakuKey =
      GlobalKey<DanmakuOverlayState>();
  DanmakuSettings _danmakuSettings = const DanmakuSettings();
  DanmakuRepository? _danmakuRepo;
  bool _danmakuOn = true;

  /// 是否为本地文件 / 直链模式（跳过在线源解析，直接打开给定地址）。
  bool get _isDirectMode => widget.localUri != null || widget.directUrl != null;

  /// 当前弹幕源（持久化到 SharedPreferences，键 `danmaku_source`）。
  DanmakuSourceType _danmakuSource = DanmakuSourceType.dandanplay;

  /// SharedPreferences 中保存弹幕源选择的键。
  static const String _kDanmakuSourceKey = 'danmaku_source';

  /// #6 A4-#6: 自定义弹幕 URL（持久化键 `danmaku_custom_url`）。
  String _customDanmakuUrl = '';

  /// #6 A4-#6: SharedPreferences 中保存自定义 URL 的键。
  static const String _kDanmakuCustomUrlKey = 'danmaku_custom_url';

  /// 旧方案遗留键（文件 + SharedPreferencesAsync）。仅用于一次性迁移，
  /// 迁移后播放器统一写入与全局页共用的 `danmaku_display_settings_v1`。
  static const String _kLegacyDanmakuSettingsKey = 'danmaku_settings';

  /// 每集手动 / 即时匹配得到的 dandanplay episodeId 覆盖（键 = 剧集 id）。
  /// 用于自动匹配失败时的兜底，以及用户从「手动匹配」面板指定。
  final Map<String, int> _dandanOverride = <String, int>{};

  /// Current playable URL (used for sharing).
  String? _playUrl;

  /// 自定义截图保存目录（空 = 默认 Documents/screenshots）。
  String? _customScreenshotDir;

  /// 当前播放地址所需的 HTTP 请求头（反盗链 Referer / UA 等），
  /// 与解析抓取 m3u8 文本时一致；打开地址（mpv 拉分片）必须带上，
  /// 否则 CDN 返回 403、解不出帧、画面全黑。
  Map<String, String>? _playHeaders;

  /// Sleep timer for auto-pausing playback.
  Timer? _sleepTimer;

  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<bool>? _completedSub;
  StreamSubscription<void>? _stallSub;
  StreamSubscription<String>? _decodeFallbackSub;

  /// 标记 widget 已进入 deactivate/dispose 流程。仅用 [mounted] 不够：
  /// Flutter 在 deactivate() 阶段元素已「失活」但 [mounted] 仍为 true，此时
  /// 访问依赖 InheritedWidget 的 [AppLocalizations.of]/[ScaffoldMessenger.of]
  /// 会抛「Looking up a deactivated widget's ancestor is unsafe」。
  /// 因此在 stall/position/completed 等异步回调入口用此标记二次兜底，
  /// 彻底避免播放在后台/退场瞬间的崩溃。
  bool _disposed = false;

  /// 下一集是否已预解析（进度>80% 时后台拉取地址写入 VideoSourceCache）。
  /// 切集时重置为 false。
  bool _nextEpisodePreloaded = false;

  /// 本次会话内已自动标记「已看」的剧集索引，避免对同一集重复触发
  /// `MediaWatchedManager.markWatched`（每集仅标记一次）。
  final Set<int> _watchedMarkedEpisodes = <int>{};

  Duration _position = Duration.zero;

  /// 可信的「最近一次非零播放位置」。用于重连时恢复到断流前的进度，
  /// 避免 open() 重置后若 [_position] 被瞬时的 0 位置事件覆盖而从头播放。
  Duration _lastGoodPosition = Duration.zero;

  /// 重连（stall 恢复）进行中标记，防止 stall 事件重入导致多次重连叠加。
  bool _reconnecting = false;

  /// 自动重连次数上限。超过后不再自动重连，改为提示用户手动重试，
  /// 避免「重连失败→又卡顿→又重连」的死循环。
  static const int _kMaxReconnectAttempts = 3;

  /// 已尝试的自动重连次数。达到上限后置位 [_reconnectExhausted]。
  int _reconnectAttempts = 0;

  /// 自动重连已耗尽：置位后由 UI 展示「视频链接已失效，点击重试」，用户手动触发
  /// 重新解析并重新打开播放器（拿到未过期的新直链）。
  bool _reconnectExhausted = false;

  Duration _duration = Duration.zero;
  bool _isPlaying = false;
  bool _uiVisible = true;
  bool _isFav = false;

  /// 控制层（顶栏 / 底栏 / 中央按钮）自动隐藏计时器。
  ///
  /// 修复「视频已开始播放但暂停键 / 控制条一直挂在画面上」：播放中若约
  /// [_kUiAutoHide] 无任何交互，则自动隐藏控制层；暂停 / 锁定 / 用户点击时
  /// 重新显示并重置计时。
  Timer? _uiHideTimer;

  /// 控制层自动隐藏延时。
  static const Duration _kUiAutoHide = Duration(seconds: 4);

  // ─────────────────────── 播放器设置（PlayerSettings 消费） ───────────────────────
  /// 全局播放器默认设置。_init 中从 PlayerSettingsStore 加载并应用到底层播放器。
  PlayerSettings _playerSettings = const PlayerSettings();

  /// 横滑 seek 倍率（来自 PlayerSettings.seekMultiplier，0.5/1.0/2.0）。
  double _seekMultiplierFactor = 1.0;

  // ─────────────────────── 解析进度条（功能3） ───────────────────────
  /// 解析进度 notifier（null=隐藏）。放 State 而非 PlayerController：_initFuture
  /// 转圈帧时 _controller 尚未创建，State 级 notifier 可安全在加载态渲染。
  final ValueNotifier<double?> _resolveProgress =
      ValueNotifier<double?>(null);

  // ─────────────────────── 缓冲加载动画（功能2） ───────────────────────
  bool _isBuffering = false;
  StreamSubscription<bool>? _bufferingSub;

  /// 播放状态订阅（P8.3.x §加载指示器）：订阅底层 playing 流同步 [_isPlaying]，
  /// 避免「视频已开始播放但中央大播放按钮仍显示」「缓冲转圈不消失」等 UI 滞后。
  StreamSubscription<bool>? _playingSub;

  // ─────────────────────── 长按倍速（功能4） ───────────────────────
  /// 长按加速前的原倍速，松手恢复。
  double _speedBeforeLongPress = 1.0;

  // ─────────────────────── 手势 / 亮度 / 音量（P8.3.4 §廿四 + 视频还原） ───────────────────────

  /// 当前手势轴（横滑 / 左竖滑 / 右竖滑），锁定后直到 onEnd 才重置。
  _GestureAxis _dragAxis = _GestureAxis.none;

  /// 手势起点系统亮度（0..1），用于左竖滑按 delta 计算新亮度。
  double _dragStartBrightness = 0;

  /// 手势起点播放器音量（0..100），用于右竖滑按 delta 计算新音量。
  double _dragStartVolume = 50;

  /// 横滑 seek 预览目标时间，松手后跳转。
  Duration _seekPreview = Duration.zero;

  /// 当前系统亮度缓存（init 时从 [ScreenBrightness.instance.application] 读取）。
  double _brightness = 0.5;

  /// 手势指示器当前展示的内容（任一非 null 即显示对应数值）。
  String? _gestureIndicatorText;

  /// 手势指示器可见性（[AnimatedOpacity] 驱动）。
  bool _gestureIndicatorVisible = false;

  /// 手势指示器自动淡出计时器（约 800ms）。
  Timer? _gestureIndicatorTimer;

  /// 上次自动保存播放位置的时间（节流，每 5 秒存一次）。
  DateTime _lastPositionSaveAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 当前集「续播位置恢复」是否已完成（成功 seek / 无记录 / 放弃）。
  ///
  /// 修复「记住播放进度没作用」：媒体刚 open 时会立刻推送 position=0 的事件，
  /// 若此时就允许写盘，上一次的存档会被 0 覆盖，之后再怎么恢复也拿不到值。
  /// 因此恢复完成前一律不保存位置。切集时重置为 false。
  bool _positionRestoreDone = false;

  /// 当前剧集索引（若有全集列表）。
  late int _episodeIndex;

  /// 当前选中的播放线路名（来自 [Episode.lineName]）。由 [widget.episode]
  /// 初始化，切换剧集时跟随新 ep 同步。
  /// 详情页 chips（全部/天堂/精品/暴风/量子）选中后，`_openContent` 传入的
  /// `ep.lineName` 就是该选择，本字段在播放器内跟踪并驱动"播放线路"面板
  /// 的选中态；线路面板里点线路只切换要显示的集分组，不立即解析。
  String? _selectedLine;

  late Future<void> _initFuture;

  final CastService _castService = CastService();
  bool _isCasting = false;

  /// 键盘焦点节点（P8.3.4 §廿四 键盘快捷键）。
  final FocusNode _focusNode = FocusNode();

  /// 屏幕亮度插件实例（手势调节系统亮度）。
  final ScreenBrightness _brightnessPlugin = ScreenBrightness();

  @override
  void initState() {
    super.initState();
    // 首帧后把默认弹幕设置（字号/不透明度/区域）同步到弹幕层，
    // 否则覆盖层会沿用 canvas_danmaku 的默认值（区域=全屏、字号=16）。
    // 注意：此时 _controller 尚未创建（在 _init 中等旧播放器释放后才建），
    // _applyDanmakuOption 内部读取 _controller.playbackSpeed 已用 try/catch 兜底。
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _applyDanmakuOption());
    _episodeIndex = widget.initialEpisodeIndex ?? 0;
    // 详情页 chips 选中的线路名会透传到 widget.episode.lineName（chips
    // 过滤后的 ep 副本），未提供时退化为 null 表示"未分组 / 全部"。
    _selectedLine = widget.episode.lineName;
    _initFuture = _init();
  }

  /// PlayerController 状态变更（字幕显隐 / 全屏 / 音量 / 线路）触发 UI 重建。
  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  /// 为视频结果附加播放所需请求头（Referer / UA 等），与源反盗链配置一致。
  ///
  /// 直连解析的视频会由 [builtin_resolver] 的 [_withVideoHeaders] 自动附加头；
  /// 但 WebView 抽取路径拿到的是裸直链，需在此补齐，否则 CDN 返回 403 黑屏。
  Map<String, String> _videoHeadersFor(PluginConfig source) {
    final ah = source.antiHotlinking;
    final headers = <String, String>{};
    if (ah.userAgent != null && ah.userAgent!.isNotEmpty) {
      headers['User-Agent'] = ah.userAgent!;
    }
    final referer = ah.referer ?? source.site.baseUrl;
    if (referer != null && referer.isNotEmpty) {
      headers['Referer'] = referer;
    }
    if (ah.headers != null) headers.addAll(ah.headers!);
    return headers;
  }

  /// 解析视频地址。
  ///
  /// 默认「自动嗅探优先」：直接加载剧集播放页，靠通用嗅探链路
  /// （JS 钩子 fetch/XHR/HTMLMediaElement/MediaSource + 网络拦截 + DOM 扫描）
  /// 捕获网站真实视频直链——不依赖源写死的 selectors/script，适配加密 player、
  /// MacCMS 等手动解析失败的站点。捕获到 http 直链即作为解析结果返回。
  ///
  /// 嗅探未捕获到直链（超时/页面不自动播放等）时，回退到源声明的手动解析：
  /// - webview-html：弹出内嵌 WebView 取回渲染 HTML 回填重试；
  /// - video 路由 `webview` + jsExtractor：弹出 WebView 执行脚本抽到真实直链；
  /// - 普通 selectors/script：离线解析。
  Future<VideoResult> _resolveVideoWithCapture(
    MediaApiService service,
    PluginConfig source,
    String episodeUrl, {
    String? renderedHtml,
  }) async {
    // 解析进度条（功能3）：仅最外层调用写入进度，递归（renderedHtml 非空）不重复写。
    final isOuter = renderedHtml == null;
    if (isOuter) _resolveProgress.value = 0.05;
    try {
    // 1) 自动嗅探优先（网站视频通用捕获，与源无关）
    final pageUrl = _absolutePageUrl(source, episodeUrl);
    if (pageUrl != null) {
      try {
        final outcome = await navigateToSnifferCapture(
          context,
          url: pageUrl,
          timeout: const Duration(seconds: 12),
          autoPopOnTimeout: true,
        );
        if (outcome?.hasExtractedUrl == true && outcome!.extractedUrl != null) {
          return _capturedVideoResult(source, outcome);
        }
      } on Object {
        // 嗅探自身异常（如 WebView 不可用），落回手动解析
      }
    }
    if (isOuter) _resolveProgress.value = 0.5;
    // 2) 嗅探未命中 → 回退源声明的手动解析
    try {
      return await service.fetchVideoUrl(source, episodeUrl,
          renderedHtml: renderedHtml);
    } on WebViewHtmlRequest catch (e) {
      if (!mounted) rethrow;
      final outcome = await navigateToHtmlCapture(context, request: e);
      if (outcome?.hasRenderedHtml == true) {
        return _resolveVideoWithCapture(
          service,
          source,
          episodeUrl,
          renderedHtml: outcome!.renderedHtml,
        );
      }
      if (outcome?.hasExtractedUrl == true && outcome!.extractedUrl != null) {
        return _capturedVideoResult(source, outcome);
      }
      throw Exception('video capture cancelled');
    } on WebViewExtractionRequest catch (e) {
      if (!mounted) rethrow;
      final outcome = await navigateToExtraction(context, request: e);
      if (outcome?.hasExtractedUrl == true && outcome!.extractedUrl != null) {
        return _capturedVideoResult(source, outcome);
      }
      throw Exception('video extraction cancelled');
    }
    } finally {
      if (isOuter) _resolveProgress.value = null;
    }
  }

  /// 将 WebView 抽取 / 嗅探回传的裸直链包装为可播放结果（补齐防盗链头）。
  ///
  /// 头优先级：源 antiHotlinking 配置（含 site.baseUrl 兜底的 Referer）优先；
  /// 仅当配置未产出 Referer 时，才用嗅探捕获时记录的 [WebViewExtractionOutcome.extractedReferer]。
  VideoResult _capturedVideoResult(
      PluginConfig source, WebViewExtractionOutcome outcome) {
    final url = outcome.extractedUrl!;
    final type = url.toLowerCase().contains('m3u8') ? 'm3u8' : null;
    final headers = _videoHeadersFor(source);
    final ref = outcome.extractedReferer;
    if (!headers.containsKey('Referer') && ref != null && ref.isNotEmpty) {
      headers['Referer'] = ref;
    }
    return VideoResult(
      url: url,
      type: type,
      headers: headers.isNotEmpty ? headers : null,
    );
  }

  /// 把剧集 URL 解析为绝对页面地址（相对路径按源 baseUrl 补全；无法补全返回 null）。
  String? _absolutePageUrl(PluginConfig source, String url) {
    if (url.startsWith('http://') || url.startsWith('https://')) return url;
    final base = source.site.baseUrl;
    if (base == null || base.isEmpty) return null;
    return Uri.tryParse(base)?.resolve(url).toString();
  }

  Future<void> _init() async {
    // 优先恢复弹幕相关持久化设置（源选择 / 显示设置 / 自定义 URL）。
    // 必须放在视频打开之前：一旦视频解析或打开抛异常，_init 后续代码不会执行，
    // 设置就会永远停留在默认值，表现为「退出重进无法保持」。
    await _loadDanmakuSourcePref();

    // 加载全局播放器默认设置（解码/音频/比例/倍速/音量/方向/手势等）。
    // 在创建 Player 之前加载，创建后立即应用到底层播放器。
    await _loadPlayerSettings();

    // 创建 Player + VideoController 并打开媒体。
    // 关键：先等待上一次播放器的原生 VideoOutput 释放完成（见 PlayerController.pendingDisposal），
    // 再把「新 Player」创建出来。Player 的 mpv 上下文与原生视频纹理是崩溃高发点，
    // 必须保证「旧播放器完全销毁」先于「新播放器创建」，否则连续多次打开会在
    // 第三次冲突杀进程（Lost connection to device）。
    await PlayerController.pendingDisposal;
    if (_disposed) return;
    _controller = PlayerController();
    _controller.addListener(_onControllerChanged);
    _controllerCreated = true;
    _videoController = VideoController(_controller.player);

    // 同步当前系统亮度（手势起点基准）与播放器音量（PlayerController.volume）。
    try {
      _brightness = await _brightnessPlugin.current;
    } on Object {
      _brightness = 0.5;
    }
    try {
      _controller.volume = _controller.player.state.volume;
      _dragStartVolume = _controller.volume;
    } on Object {
      // 取底层音量失败，沿用默认 50。
    }

    // 应用全局播放器默认设置（解码/音频/比例/倍速/音量/方向/手势/字幕样式）。
    // 这是让 PlayerSettings 13 个字段真正生效的「地基」调用。
    await _applyPlayerSettings();

    if (_isDirectMode) {
      // 本地 / 直链模式：跳过在线源解析，直接打开给定地址。
      // 直链带防盗链请求头（嗅探到的 m3u8 常需 Referer，缺了会被 CDN 403）。
      final direct = widget.directUrl ?? widget.localUri!;
      final headers =
          (widget.directUrl != null && widget.directHeaders?.isNotEmpty == true)
              ? widget.directHeaders
              : null;
      _playUrl = direct;
      _playHeaders = headers;
      await _controller.open(direct, headers: headers);
    } else {
      final repo = context.read<SourceRepository>();
      final service = context.read<MediaApiService>();
      final source = repo.getById(widget.sourceId);
      if (source == null) {
        throw Exception('source not found: ${widget.sourceId}');
      }

      // 解析视频地址（自动处理渲染后抽取）
      final video =
          await _resolveVideoWithCapture(service, source, widget.episode.url);
      _playUrl = video.url;
      _playHeaders = video.headers;

      // 由解析结果构造播放线路：源提供多线路（video.lines）时使用，
      // 否则以单线路 url 兜底为「线路 1」。播放页「选集 / 线路」面板据此切换。
      if (video.url.isNotEmpty) {
        _controller.lines = _buildLines(video);
        _controller.currentLineIndex = 0;
      }

      await _controller.open(video.url, headers: video.headers);
      // 解析成功后自动开始播放
      _controller.play();
    }

    // 恢复上次播放位置（P8.1.2 §廿一 续读进度跨章节恢复）。
    // 不 await：[_seekWhenReady] 需要等底层 duration 就绪（可能 1~10 秒），
    // 阻塞 _init 会让整页一直转圈。恢复完成前 [_positionRestoreDone] 为 false，
    // 位置写盘被挡住，不存在「被 0 覆盖」的竞态。
    // 关闭「记住播放/阅读位置」时不再恢复上次进度，直接从头播放；
    // 但仍置位 [_positionRestoreDone]，允许本集继续保存进度（仅不跳转）。
    if (widget.restoreProgress) {
      unawaited(_restoreSavedPosition());
    } else {
      _positionRestoreDone = true;
      _lastPositionSaveAt = DateTime.now();
    }

    // 监听播放状态
    _positionSub = _controller.positionStream.listen(_onPositionChanged);
    _completedSub = _controller.completedStream.listen(_onCompleted);
    // 监听 stall（卡顿）事件：提示并自动重连
    _stallSub = _controller.stallStream.listen((_) => _onStall());
    // 监听解码自动降级（花屏 / 硬解失败自愈）：提示并 re-open 生效
    _decodeFallbackSub =
        _controller.decodeFallbackStream.listen(_onDecodeFallback);
    // 监听缓冲状态：缓冲中显示加载动画（功能2）
    _bufferingSub = _controller.bufferingStream.listen((b) {
      if (_disposed || !mounted) return;
      setState(() => _isBuffering = b);
    });
    // 播放状态同步：底层播放/暂停时同步 [_isPlaying]，驱动中央大播放按钮、
    // 底栏播放图标、缓冲指示器收敛。修复「视频已自动播放但 UI 仍显示暂停态」
    // 及「_togglePlayPause 首次点击行为反了」的问题。
    _playingSub = _controller.playingStream.listen((p) {
      if (_disposed || !mounted) return;
      setState(() {
        _isPlaying = p;
        // 暂停时控制层常显（用户需要看到播放键 / 进度条）。
        if (!p) _uiVisible = true;
      });
      // 播放 → 启动自动隐藏倒计时；暂停 → 取消倒计时保持常显。
      if (p) {
        _scheduleUiHide();
      } else {
        _uiHideTimer?.cancel();
      }
    });
    // 兜底同步一次当前播放态：playingStream 是广播流，若在 open()/play() 之后
    // 才订阅，可能错过已发出的 true，导致「实际在播放但 UI 停在暂停态」。
    if (mounted && _controller.isPlaying != _isPlaying) {
      setState(() => _isPlaying = _controller.isPlaying);
      if (_isPlaying) _scheduleUiHide();
    }

    // 初始化弹幕仓库（弹幕源选择已在 _init 开头恢复）
    _initDanmakuRepository();

    // 读取自定义截图保存目录
    try {
      final prefs = await SharedPreferences.getInstance();
      _customScreenshotDir = prefs.getString('screenshot_custom_dir');
    } on Object {
      // 读取失败，使用默认路径
    }

    // 尝试加载弹幕（本地 / 直链模式无剧集元数据，跳过自动匹配；
    // 用户仍可通过弹幕源面板切换到自定义 URL 手动加载）。
    if (!_isDirectMode) {
      _loadDanmaku();
    }

    // 刷新收藏状态（P9.1.7 §16.1 顶栏收藏按钮）
    _refreshFavorite();

    if (mounted) setState(() {});
    // 关键：_initFuture 完成后 FutureBuilder 才会渲染播放器 UI（含弹幕覆盖层），
    // 覆盖层此刻才真正挂载。用 postFrameCallback 把「套用弹幕显示设置」延到这一帧之后，
    // 确保 _danmakuKey.currentState 非空、保存的字号/不透明度/区域真正生效。
    // 否则（如 _init 开头调度的 apply）会在转圈帧触发、覆盖层尚未挂载而被 `?.` 短路，
    // 导致重进时弹幕用默认设置（表现为「设置不对」）。
    if (mounted) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _applyDanmakuOption());
    }
  }

  /// 加载全局播放器默认设置（PlayerSettings）。
  Future<void> _loadPlayerSettings() async {
    try {
      _playerSettings = await PlayerSettingsStore().load();
    } on Object {
      _playerSettings = const PlayerSettings();
    }
  }

  /// 把 [PlayerSettings] 应用到底层播放器与 UI 状态。
  ///
  /// 这是让"播放器设置页"字段真正生效的地基调用：解码/音频/比例/倍速/音量/
  /// 连播/方向锁定/seek 倍率/字幕样式。长按倍速与双击行为开关在对应手势处读取。
  Future<void> _applyPlayerSettings() async {
    final s = _playerSettings;
    try {
      await _controller.setHwdec(_decodeModeToMpv(s.decodeMode));
      await _controller.setAudioChannel(_audioChannelToMpv(s.audioChannel));
      await _controller.setAspectRatio(_aspectRatioToMpv(s.aspectRatio));
      if (s.defaultVolume >= 0 && s.defaultVolume <= 100) {
        await _controller.setVolume(s.defaultVolume);
        _dragStartVolume = _controller.volume;
      }
      _controller.autoPlayNext = s.autoPlayNext;
      if (s.playbackSpeed > 0) {
        await _controller.setPlaybackSpeed(s.playbackSpeed);
      }
      // 字幕样式（字号 / 描边；底部边距因 mpv sub-pos 语义复杂，暂按默认底部位置）
      await _controller.setSubtitleFontSize(s.subtitleFontSize);
      await _controller.setSubtitleBorderSize(s.subtitleOutline ? 2.0 : 0.0);
      await _applyLockOrientation(s.lockOrientation);
      _seekMultiplierFactor = _seekMultiplierToFactor(s.seekMultiplier);
    } on Object {
      // 部分属性设置失败（如平台不支持）不影响播放，忽略。
    }
  }

  Future<void> _applyLockOrientation(PlayerLockOrientation o) async {
    // 桌面端（短边 ≥ 600）不强制方向，窗口自由调整（项 3：仅手机自动横屏）。
    final bool isPhone = MediaQuery.of(context).size.shortestSide < 600;
    final List<DeviceOrientation> orients;
    switch (o) {
      case PlayerLockOrientation.portrait:
        orients = const <DeviceOrientation>[DeviceOrientation.portraitUp];
      case PlayerLockOrientation.landscape:
        orients = const <DeviceOrientation>[
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ];
      case PlayerLockOrientation.auto:
        orients = const <DeviceOrientation>[];
    }
    // 记录退出全屏后要恢复的方向（全屏按钮临时强制横屏，退出回到此处）。
    _controller.setBaseOrientations(isPhone ? orients : const <DeviceOrientation>[]);
    if (!isPhone) return;
    try {
      await SystemChrome.setPreferredOrientations(orients);
    } on Object {
      // 平台不支持，忽略。
    }
  }

  static String _decodeModeToMpv(DecodeMode m) {
    switch (m) {
      case DecodeMode.auto:
        return 'auto';
      case DecodeMode.sw:
        return 'sw';
      case DecodeMode.hw:
        return 'hw';
      case DecodeMode.hwPlus:
        return 'hw+';
    }
  }

  static String _audioChannelToMpv(AudioChannel c) {
    switch (c) {
      case AudioChannel.auto:
        return 'auto';
      case AudioChannel.stereo:
        return 'stereo';
      case AudioChannel.mono:
        return 'mono';
    }
  }

  static String _aspectRatioToMpv(PlayerAspectRatio a) {
    switch (a) {
      case PlayerAspectRatio.defaultRatio:
        return 'default';
      case PlayerAspectRatio.ratio43:
        return '4:3';
      case PlayerAspectRatio.ratio169:
        return '16:9';
      case PlayerAspectRatio.fill:
        return 'fill';
    }
  }

  static double _seekMultiplierToFactor(SeekMultiplier m) {
    switch (m) {
      case SeekMultiplier.half:
        return 0.5;
      case SeekMultiplier.normal:
        return 1.0;
      case SeekMultiplier.double:
        return 2.0;
    }
  }

  /// 双击中央：切换播放/暂停（功能1）。
  void _togglePlayPause() {
    if (_controller.isLocked) return;
    if (_controller.isPlaying) {
      unawaited(_controller.pause());
      // 暂停：取消自动隐藏并让控制层常显，用户能立刻看到播放键。
      _uiHideTimer?.cancel();
      if (mounted) {
        setState(() {
          _isPlaying = false;
          _uiVisible = true;
        });
      }
    } else {
      unawaited(_controller.play());
      if (mounted) setState(() => _isPlaying = true);
      _scheduleUiHide();
    }
  }

  /// 长按开始：切到自定义倍速（功能4，受 longPressSpeedUp 开关控制）。
  void _onLongPressSpeedStart() {
    if (_controller.isLocked) return;
    if (!_playerSettings.longPressSpeedUp) return;
    _speedBeforeLongPress = _controller.playbackSpeed;
    final target = _playerSettings.longPressSpeed;
    if (target > 0 && target != _speedBeforeLongPress) {
      unawaited(_controller.setPlaybackSpeed(target));
      _showGestureIndicator('${target}x');
    }
  }

  /// 长按结束：恢复原倍速。
  void _onLongPressSpeedEnd() {
    if (!_playerSettings.longPressSpeedUp) return;
    if (_controller.playbackSpeed != _speedBeforeLongPress) {
      unawaited(_controller.setPlaybackSpeed(_speedBeforeLongPress));
    }
  }

  /// 更新播放器设置（更多菜单内调用）：写回 [_playerSettings] 并持久化，
  /// 部分项立即生效。
  Future<void> _updatePlayerSettings(PlayerSettings next) async {
    _playerSettings = next;
    setState(() {});
    unawaited(PlayerSettingsStore().save(next));
  }

  /// 从 SharedPreferences 读取弹幕源选择。
  Future<void> _loadDanmakuSourcePref() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final name = prefs.getString(_kDanmakuSourceKey);
      if (name != null) {
        _danmakuSource = DanmakuSourceType.values.firstWhere(
          (e) => e.name == name,
          orElse: () => DanmakuSourceType.dandanplay,
        );
      }
      // #6 A4-#6: 同步加载自定义 URL。
      _customDanmakuUrl = prefs.getString(_kDanmakuCustomUrlKey) ?? '';
      // 恢复弹幕显示设置：与全局「弹幕显示设置」页共用同一存储（单一数据源）。
      _danmakuSettings = await _loadDanmakuSettings();
      debugPrint(
          '[_loadDanmakuSourcePref] 已恢复弹幕显示设置: '
          'area=${_danmakuSettings.area} fontSize=${_danmakuSettings.fontSize} '
          'opacity=${_danmakuSettings.opacity} lineHeight=${_danmakuSettings.lineHeight} '
          'duration=${_danmakuSettings.duration}');
      // 覆盖层在首帧才会挂载，而 _init 此刻尚未结束、_danmakuKey.currentState
      // 仍为空，直接调用 apply 会被 `?.` 短路成空操作。改为延到下一帧
      // （覆盖层必然已挂载）再同步到渲染层，彻底解决「退出重进无法保持」。
      if (mounted) {
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _applyDanmakuOption());
      }
    } on Object catch (e, st) {
      debugPrint('[_loadDanmakuSourcePref] 读取弹幕设置失败: $e\n$st');
    }
  }

  /// 弹幕显示设置存储：与全局「弹幕显示设置」页共用同一实例，单一数据源。
  /// 底层走 [DanmakuDisplaySettingsStore] → SharedPreferences.getInstance()，稳定可靠。
  final DanmakuDisplaySettingsStore _danmakuSettingsStore =
      DanmakuDisplaySettingsStore();

  /// 加载弹幕显示设置：优先读取与全局页共用的存储；若该存储为空，
  /// 尝试从旧方案（文件 / SharedPreferencesAsync）一次性迁移，避免历史设置丢失。
  Future<DanmakuSettings> _loadDanmakuSettings() async {
    if (await _danmakuSettingsStore.hasData()) {
      return _danmakuSettingsStore.load();
    }
    final legacy = await _readLegacyDanmakuSettings();
    if (legacy != null) {
      await _danmakuSettingsStore.save(legacy);
      return legacy;
    }
    return _danmakuSettingsStore.load();
  }

  /// 读取旧方案保存的弹幕设置（仅用于一次性迁移，迁移后清理文件）。
  Future<DanmakuSettings?> _readLegacyDanmakuSettings() async {
    // 旧方案主写文件 danmaku_settings.json。
    try {
      final file = File(
          '${(await getApplicationSupportDirectory()).path}/danmaku_settings.json');
      if (await file.exists()) {
        final decoded =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        final s = DanmakuSettings.fromJson(decoded);
        await file.delete().catchError((Object _) {});
        return s;
      }
    } on Object catch (e, st) {
      debugPrint('[_readLegacyDanmakuSettings] 读旧文件失败: $e\n$st');
    }
    // 旧方案兼容副本：SharedPreferencesAsync 键 danmaku_settings。
    try {
      final raw = await SharedPreferencesAsync()
          .getString(_kLegacyDanmakuSettingsKey);
      if (raw != null && raw.isNotEmpty) {
        return DanmakuSettings.fromJson(
            jsonDecode(raw) as Map<String, dynamic>);
      }
    } on Object catch (e, st) {
      debugPrint(
          '[_readLegacyDanmakuSettings] 读旧 SharedPreferences 失败: $e\n$st');
    }
    return null;
  }

  /// 持久化弹幕显示设置：写入与全局「弹幕显示设置」页共用的存储
  /// （key `danmaku_display_settings_v1`，SharedPreferences.getInstance()）。
  Future<void> _saveDanmakuSettings() async {
    try {
      await _danmakuSettingsStore.save(_danmakuSettings);
      debugPrint('[_saveDanmakuSettings] 已保存弹幕显示设置: '
          'area=${_danmakuSettings.area} fontSize=${_danmakuSettings.fontSize} '
          'opacity=${_danmakuSettings.opacity} lineHeight=${_danmakuSettings.lineHeight} '
          'duration=${_danmakuSettings.duration}');
    } on Object catch (e, st) {
      debugPrint('[_saveDanmakuSettings] 保存失败: $e\n$st');
    }
  }

  void _initDanmakuRepository() {
    try {
      final cacheBox = Hive.box<dynamic>('danmaku_cache');
      final configStore = DanmakuConfigStore();
      _danmakuRepo = DanmakuRepository(
        dandanplay: DandanplayService(configStore: configStore),
        bilibili: BilibiliDanmakuService(),
        cacheBox: cacheBox,
      );
    } on Object {
      // Hive box 未打开或服务不可用，静默降级（无弹幕）。
      _danmakuRepo = null;
    }
  }

  /// 解析当前集的 dandanplay episodeId。
  ///
  /// 优先级：剧集预填值 → 已缓存的手动/即时匹配结果 → 若源为 dandanplay 则按
  /// 「番剧名 + 集名」即时 match 并缓存。返回 null 表示无法获得（如源为 bilibili）。
  Future<int?> _resolveDandanId(Episode ep) async {
    final pre = ep.dandanplayEpisodeId ?? _dandanOverride[ep.id];
    if (pre != null) return pre;
    if (_danmakuSource != DanmakuSourceType.dandanplay) return null;
    if (_danmakuRepo == null) return null;
    final id = await _danmakuRepo!.matchEpisode(
      '${widget.title} ${ep.title}',
      animeTitle: widget.title,
    );
    if (id != null) _dandanOverride[ep.id] = id;
    return id;
  }

  Future<void> _loadDanmaku() async {
    if (_danmakuRepo == null) return;
    // 关闭弹幕源：清空并跳过加载。
    if (_danmakuSource == DanmakuSourceType.off) {
      _danmakuController.clear();
      return;
    }
    // #6 A4-#6: 自定义 URL 源且 URL 为空时，提示并跳过。
    if (_danmakuSource == DanmakuSourceType.customUrl &&
        _customDanmakuUrl.isEmpty) {
      _danmakuController.clear();
      return;
    }
    try {
      final ep = widget.episode;
      final dandanId = await _resolveDandanId(ep);
      final items = await _danmakuRepo!.getDanmaku(
        sourceId: widget.sourceId,
        episodeId: ep.id,
        dandanplayEpisodeId: _danmakuSource == DanmakuSourceType.bilibili
            ? null
            : dandanId,
        bilibiliCid: _danmakuSource == DanmakuSourceType.dandanplay
            ? null
            : ep.bilibiliCid,
        bangumiId: ep.bangumiId,
        danmakuUrl: _danmakuSource == DanmakuSourceType.customUrl
            ? _customDanmakuUrl
            : ep.danmakuUrl,
      );
      // 过滤并转换为 DanmakuItem
      final filtered = items
          .where((i) => !_danmakuSettings.shouldFilter(i.text))
          .map((i) => i.toDanmakuItem())
          .toList();
      _danmakuController.setItems(filtered);
    } on Object catch (e) {
      // 凭据未配置时给出提示，其余错误静默忽略。
      final msg = e.toString();
      if (msg.contains('credentials not configured') && mounted) {
        final l10n = AppLocalizations.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.danmakuLoadFailed),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  void _onPositionChanged(Duration position) {
    if (!mounted || _disposed) return;
    _position = position;
    // 记录可信的非零进度：open() 重置或缓冲瞬间可能产生 0 位置事件，
    // 不能据此把恢复点清零（避免重连后从头播放）。
    if (position > Duration.zero) _lastGoodPosition = position;
    if (_duration == Duration.zero) {
      _duration = _controller.duration;
    }
    // 注入弹幕
    if (_danmakuOn) {
      final adjusted = position +
          Duration(
              milliseconds:
                  (_danmakuSettings.timeOffset * 1000).round());
      _danmakuController.tick(adjusted);
    }
    // 预解析下一集（进度>80% 触发，后台拉地址写入 VideoSourceCache）
    _maybePreloadNextEpisode();
    // 节流保存播放位置（每 5 秒）
    _maybeSavePosition();
    // 达到「已看」阈值时自动标记当前集
    _maybeMarkWatched();
    if (mounted) setState(() {});
  }

  /// 节流保存播放位置：每 5 秒写一次到 MediaPlaybackPositionManager。
  void _maybeSavePosition() {
    // 续播恢复完成前禁止写盘，避免刚 open 时的 position=0 覆盖旧存档。
    if (!_positionRestoreDone) return;
    final now = DateTime.now();
    if (now.difference(_lastPositionSaveAt) < const Duration(seconds: 5)) return;
    _lastPositionSaveAt = now;
    try {
      final mgr = context.read<MediaPlaybackPositionManager>();
      unawaited(mgr.savePosition(
          widget.itemId, _episodeIndex, _position.inMilliseconds));
    } on Object {
      // Manager 不可用时静默忽略。
    }
  }

  /// 播放进度达到「已看」阈值时自动标记当前集已看（每集仅标记一次）。
  ///
  /// 阈值取自 [GeneralSettingsStore.watchedThresholdPercent]（默认 90）。
  /// 用本地 [_watchedMarkedEpisodes] 集合避免每帧读取 Manager / 重复标记。
  void _maybeMarkWatched() {
    final durationMs = _duration.inMilliseconds;
    if (durationMs <= 0) return;
    if (_watchedMarkedEpisodes.contains(_episodeIndex)) return;
    final ratio = _position.inMilliseconds / durationMs;
    final threshold = GeneralSettingsStore.instance.watchedThresholdPercent;
    if (!progressReachesWatchedThreshold(ratio, threshold)) return;
    _watchedMarkedEpisodes.add(_episodeIndex);
    try {
      final watched = context.read<MediaWatchedManager>();
      unawaited(watched.markWatched(widget.itemId, _episodeIndex));
    } on Object {
      // Manager 不可用时静默忽略。
    }
  }

  /// 恢复上次播放位置：从 MediaPlaybackPositionManager 读取并 seek。
  ///
  /// 完成（含「无记录」「恢复失败」）后置位 [_positionRestoreDone]，此后才允许
  /// 自动保存位置。
  Future<void> _restoreSavedPosition() async {
    try {
      final mgr = context.read<MediaPlaybackPositionManager>();
      final savedMs = mgr.getPosition(widget.itemId, _episodeIndex);
      if (savedMs > 5000) {
        // 超过 5 秒才恢复，避免片头闪现
        await _seekWhenReady(Duration(milliseconds: savedMs));
      }
    } on Object {
      // Manager 不可用时静默忽略。
    } finally {
      _positionRestoreDone = true;
      _lastPositionSaveAt = DateTime.now();
    }
  }

  /// 等媒体真正就绪后再 seek，并校验一次实际落点。
  ///
  /// 根因：`player.open()` 返回时底层往往还没完成 demux（`duration` 仍为 0），
  /// 此刻调用 `seek` 会被 mpv 静默丢弃——表现为「记住的播放进度没有作用」。
  /// 这里先等 `durationStream` 给出非零时长（最多 10 秒），再 seek；随后延迟
  /// 校验实际位置，偏差超过 3 秒说明首次 seek 被吞，补发一次。
  Future<void> _seekWhenReady(Duration target) async {
    if (_controller.duration <= Duration.zero) {
      try {
        await _controller.durationStream
            .firstWhere((Duration d) => d > Duration.zero)
            .timeout(const Duration(seconds: 10));
      } on Object {
        // 超时或流异常：仍尝试 seek 一次，失败也不影响正常播放。
      }
    }
    if (_disposed || !mounted) return;
    final Duration dur = _controller.duration;
    // 目标越界（换源后时长变短 / 已接近片尾）则放弃恢复，避免直接跳到结尾。
    if (dur > Duration.zero && target >= dur - const Duration(seconds: 5)) {
      return;
    }
    await _controller.seek(target);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (_disposed || !mounted) return;
    final Duration diff = _controller.position - target;
    if (diff.abs() > const Duration(seconds: 3)) {
      await _controller.seek(target);
    }
  }

  void _onCompleted(bool completed) {
    if (!mounted || _disposed) return;
    if (!completed) return;
    // 播完清除该集播放位置，避免下次续播已看完的集
    try {
      final mgr = context.read<MediaPlaybackPositionManager>();
      unawaited(mgr.clearPosition(widget.itemId, _episodeIndex));
    } on Object {
      // Manager 不可用时静默忽略。
    }
    // 自动连播
    if (_controller.autoPlayNext &&
        widget.episodes != null &&
        _episodeIndex < widget.episodes!.length - 1) {
      _goNextEpisode();
    }
  }

  void _goNextEpisode() {
    if (widget.episodes == null || _episodeIndex >= widget.episodes!.length - 1) {
      return;
    }
    _changeEpisode(_episodeIndex + 1);
  }

  /// 预解析下一集：当前集播放进度>80% 时后台拉取下一集地址，
  /// 命中 [VideoSourceCache] 后 `_changeEpisode` 切集时秒切。
  /// 每集只触发一次，切集时重置。
  void _maybePreloadNextEpisode() {
    if (_nextEpisodePreloaded) return;
    if (widget.episodes == null || _duration == Duration.zero) return;
    if (_episodeIndex >= widget.episodes!.length - 1) return;
    // 进度 > 80% 触发
    if (_position.inMilliseconds <= _duration.inMilliseconds * 0.8) return;
    _nextEpisodePreloaded = true;
    final repo = context.read<SourceRepository>();
    final service = context.read<MediaApiService>();
    final source = repo.getById(widget.sourceId);
    if (source == null) return;
    final nextEp = widget.episodes![_episodeIndex + 1];
    // 后台拉取，结果由 BuiltinResolver 写入 VideoSourceCache；不 await、不阻塞 UI。
    unawaited(
      service.fetchVideoUrl(source, nextEp.url).catchError((_) =>
          const VideoResult(url: '', type: 'unknown')),
    );
  }

  /// Stall（卡顿）处理：弹 SnackBar 提示并自动重新 open 当前地址恢复播放。
  void _onStall() {
    if (!mounted || _disposed) return;
    // 重连进行中或已耗尽：不再重复发起重连（避免重复提示 / 死循环）。
    if (_reconnecting || _reconnectExhausted) return;
    // seek / 重连 seek 后的重新缓冲属正常现象，宽限期内忽略，避免误判卡顿触发
    // 重连（重连会从头播放）。统一用 PlayerController 的 seekGracePeriod 作为唯一标准，
    // 否则两侧窗口不一致会导致「慢速 seek 缓冲 >3s 但 <15s」时仍被误判。
    if (_controller.isWithinSeekGrace) return;
    // 异步 stall 回调可能在 widget 失活后到达：deactivate 虽已置 _disposed 并取消
    // 订阅，但事件可能已排队；此时访问 context（AppLocalizations / ScaffoldMessenger）
    // 会抛「deactivated widget」未捕获异常。用 try 兜底，避免崩溃。
    try {
      final l10n = AppLocalizations.of(context);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.playerStallDetected),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (_) {
      // context 已失活，忽略。
    }
    unawaited(_reconnect());
  }

  /// 解码自动降级回调（PlayerController 检测到硬解异常后已切换 hwdec）：
  /// 提示用户并 re-open 当前地址——mpv 的 hwdec 属性对已在播的解码器
  /// 不一定即时生效，重新 open 才能确保新解码路径落地。
  void _onDecodeFallback(String mode) {
    if (!mounted || _disposed) return;
    try {
      final l10n = AppLocalizations.of(context);
      final String label = switch (mode) {
        'hw+' => l10n.playerDecodeHwPlus,
        'sw' => l10n.playerDecodeSw,
        _ => mode,
      };
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.playerDecodeFallback(label)),
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (_) {
      // context 已失活，忽略提示。
    }
    // 降级仅对本次会话生效，不写回全局 PlayerSettings。
    final url = _playUrl;
    if (url == null || url.isEmpty || _reconnecting) return;
    _reconnecting = true;
    unawaited(() async {
      try {
        await _reopenAndResume(url, _playHeaders, _lastGoodPosition);
      } on Object {
        // 重开失败静默忽略，stall 检测会接管后续恢复。
      } finally {
        _reconnecting = false;
      }
    }());
  }

  /// 手动切换解码模式：设置 hwdec 后 re-open 当前地址。
  ///
  /// 与 [_onDecodeFallback] 同理——mpv 的 hwdec 属性对已在播的解码器
  /// 不一定即时生效，不 re-open 的话用户手动切“软解”形同虚设。
  Future<void> _applyHwdecAndReopen(String mode) async {
    if (_disposed || mode == _controller.currentHwdec) return;
    await _controller.setHwdec(mode);
    final url = _playUrl;
    if (url == null || url.isEmpty || _reconnecting) return;
    _reconnecting = true;
    try {
      await _reopenAndResume(url, _playHeaders, _lastGoodPosition);
    } on Object {
      // 重开失败静默忽略，stall 检测会接管后续恢复。
    } finally {
      _reconnecting = false;
    }
  }

  /// 重新 open 当前播放地址恢复播放。
  ///
  /// 关键点：
  /// 1) 重连前用 [_lastGoodPosition]（可信非零进度）作为恢复点；open() 会把播放器重置到
  ///    起点且短暂的 position 事件可能为 0，若直接用 [_position] 可能被瞬间的 0 覆盖而从头播放。
  /// 2) open 后 m3u8 元数据可能尚未就绪，立即 seek 会落空；故先 [_waitUntilReady] 等元数据，
  ///    再采用「seek + 短暂等待 + 校验，接近 0 则重试」的稳健策略。
  /// 3) 重连的 seek 经 [PlayerController.seek] 更新 lastSeekAt，使重连后的重新缓冲处于 seek
  ///    宽限期内，避免「重连→卡顿→再重连」的死循环。
  /// 自动重连（stall 恢复）。
  ///
  /// 关键修复（修正前一轮）：前一轮改为"中途重建播放器"反而必现黑屏（进度对但无画面），
  /// 且浏览器对同一链接 seek 正常，说明问题在播放器实例需 re-open 自愈而非重建；故改为
  /// 同实例 stop() + open() + 稳健 seek 恢复。
  ///
  /// 为防止无限循环，限制自动重连次数 [_kMaxReconnectAttempts]；耗尽后不再自动重连，
  /// 由 UI 展示「视频链接已失效，点击重试」，用户手动触发（会重新解析拿到未过期的新直链）。
  Future<void> _reconnect() async {
    if (_reconnecting || _reconnectExhausted || _disposed) return;
    _reconnecting = true;
    _reconnectAttempts++;
    try {
      final url = _playUrl;
      final headers = _playHeaders;
      if (url == null || url.isEmpty) return;
      await _reopenAndResume(url, headers, _lastGoodPosition);
    } on Object {
      // 重开失败，受 max attempts 限制，不会无限循环。
    } finally {
      _reconnecting = false;
      if (_reconnectAttempts >= _kMaxReconnectAttempts && !_reconnectExhausted) {
        _reconnectExhausted = true;
        if (mounted) setState(() {});
      }
    }
  }

  /// 在同一 Player 实例上重新打开并恢复到 [resumeAt]。
  ///
  /// 不走"中途 dispose/recreate 播放器"：实测重建 VideoController 会导致黑屏
  /// （进度对但无画面），且浏览器对同一链接 seek 正常，说明问题不在 URL/服务端，
  /// 而在播放器实例需通过 re-open 自愈。故先 stop() 清空可能卡死的播放状态，
  /// 再 open + 等元数据就绪 + 稳健 seek 回断流点并播放。流订阅与 stall 检测沿用同一
  /// 实例，无需重新绑定；倍速/解码/比例等 player 级属性也自然保留。
  Future<void> _reopenAndResume(
    String url,
    Map<String, String>? headers,
    Duration resumeAt,
  ) async {
    // 清空可能卡死的播放状态，避免 open() 在异常态下无法重新拉流。
    try {
      await _controller.player.stop();
    } on Object {
      // stop 失败忽略，open 仍会重建当前媒体。
    }
    await _controller.open(url, headers: headers);
    await _waitUntilReady(const Duration(seconds: 8));
    // 稳健 seek：open 后首帧/分片可能未到位，校验位置，接近 0 则重试。
    for (var attempt = 0; attempt < 6; attempt++) {
      await _controller.seek(resumeAt);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (resumeAt <= Duration.zero) break;
      final cur = _controller.position;
      if (cur > Duration.zero && cur >= resumeAt - const Duration(seconds: 3)) {
        break;
      }
    }
    await _controller.play();
  }

  /// 用户手动重试：重新解析拿到未过期的新直链，再重新打开播放器恢复播放。
  ///
  /// 自动重连耗尽（[_kMaxReconnectAttempts]）后，旧签名直链多半已失效，必须重新解析；
  /// 解析可能弹出 WebView 验证，故仅由用户主动触发，不自动进行。
  Future<void> _manualRetry() async {
    if (_disposed) return;
    _reconnectExhausted = false;
    _reconnectAttempts = 0;
    if (mounted) setState(() {});
    String? url = _playUrl;
    Map<String, String>? headers = _playHeaders;
    if (!_isDirectMode) {
      try {
        final repo = context.read<SourceRepository>();
        final service = context.read<MediaApiService>();
        final source = repo.getById(widget.sourceId);
        if (source != null) {
          final video = await _resolveVideoWithCapture(
              service, source, widget.episode.url);
          if (video.url.isNotEmpty) {
            url = video.url;
            headers = video.headers;
            _playUrl = video.url;
            _playHeaders = video.headers;
          }
        }
      } on Object {
        // 重新解析失败（如需要人工验证），沿用旧地址继续尝试。
      }
    }
    if (url == null || url.isEmpty) return;
    _reconnecting = true;
    try {
      await _reopenAndResume(url, headers, _lastGoodPosition);
    } on Object {
      // 重开失败，静默忽略。
    } finally {
      _reconnecting = false;
    }
  }

  /// 等待播放器元数据就绪（duration 变为正数），超时返回 false。
  ///
  /// open() 之后 m3u8 需要重新拉取 playlist 与首段分片，元数据就绪前 seek 会失效，
  /// 因此重连恢复前先等到 duration 已知（或超时兜底）。
  Future<bool> _waitUntilReady(Duration timeout) async {
    if (_controller.duration > Duration.zero) return true;
    final completer = Completer<bool>();
    late final StreamSubscription<Duration> sub;
    final timer = Timer(timeout, () {
      if (!completer.isCompleted) completer.complete(false);
    });
    sub = _controller.durationStream.listen((d) {
      if (d > Duration.zero && !completer.isCompleted) {
        completer.complete(true);
      }
    });
    final result = await completer.future;
    timer.cancel();
    await sub.cancel();
    return result;
  }

  void _goPrevEpisode() {
    if (_episodeIndex <= 0) return;
    _changeEpisode(_episodeIndex - 1);
  }

  Future<void> _changeEpisode(int index) async {
    if (widget.episodes == null || index < 0 || index >= widget.episodes!.length) {
      return;
    }
    _sleepTimer?.cancel();
    _sleepTimer = null;
    // 保存当前集播放位置（P8.1.2）
    _saveCurrentPosition();
    // 新一集的续播恢复尚未开始：先关闸，防止新媒体 open 时的 position=0
    // 覆盖这一集原有的存档。
    _positionRestoreDone = false;
    setState(() {
      _episodeIndex = index;
      _position = Duration.zero;
      _nextEpisodePreloaded = false;
      _lastPositionSaveAt = DateTime.fromMillisecondsSinceEpoch(0);
      // 切集重置重连状态：上一集的重连耗尽不应影响本集。
      _reconnectExhausted = false;
      _reconnectAttempts = 0;
    });

    final ep = widget.episodes![index];
    widget.onEpisodeChange?.call(ep);
    // 跟随新 ep 的 lineName 同步（详情页 chips 选定后保持同一线路）。
    _selectedLine = ep.lineName;

    final repo = context.read<SourceRepository>();
    final service = context.read<MediaApiService>();
    final source = repo.getById(widget.sourceId);
    if (source == null) return;

    try {
      final video =
          await _resolveVideoWithCapture(service, source, ep.url);
      _playUrl = video.url;
      _playHeaders = video.headers;
      // 切集后刷新线路列表（源提供多线路时直接使用 video.lines）。
      if (video.url.isNotEmpty) {
        _controller.lines = _buildLines(video);
        _controller.currentLineIndex = 0;
      }
      await _controller.open(video.url, headers: video.headers);
      // 切集后自动播放
      _controller.play();
      _danmakuController.clear();
      _danmakuController.reset();
      // 重新加载弹幕（使用新剧集 ID）
      _loadDanmakuForEpisode(ep);
      // 恢复新剧集的上次播放位置（关闭记住位置时跳过，但需开闸以允许本集保存进度）
      if (widget.restoreProgress) {
        await _restoreSavedPosition();
      } else {
        _positionRestoreDone = true;
        _lastPositionSaveAt = DateTime.now();
      }
    } on Object {
      // 切集失败，静默忽略；但要开闸，否则该集永远不再保存进度。
      _positionRestoreDone = true;
    }
  }

  /// 保存当前集播放位置到 MediaPlaybackPositionManager。
  void _saveCurrentPosition() {
    // 与 [_maybeSavePosition] 同理：恢复未完成时（如加载中就退出）不写盘，
    // 否则会把上次的续播点抹成 0。
    if (!_positionRestoreDone) return;
    try {
      final mgr = context.read<MediaPlaybackPositionManager>();
      unawaited(mgr.savePosition(
          widget.itemId, _episodeIndex, _position.inMilliseconds));
    } on Object {
      // Manager 不可用时静默忽略。
    }
  }

  Future<void> _loadDanmakuForEpisode(Episode ep) async {
    if (_danmakuRepo == null) return;
    // 关闭弹幕源：清空并跳过加载。
    if (_danmakuSource == DanmakuSourceType.off) {
      _danmakuController.clear();
      return;
    }
    try {
      final dandanId = await _resolveDandanId(ep);
      final items = await _danmakuRepo!.getDanmaku(
        sourceId: widget.sourceId,
        episodeId: ep.id,
        dandanplayEpisodeId: _danmakuSource == DanmakuSourceType.bilibili
            ? null
            : dandanId,
        bilibiliCid: _danmakuSource == DanmakuSourceType.dandanplay
            ? null
            : ep.bilibiliCid,
        bangumiId: ep.bangumiId,
        danmakuUrl: ep.danmakuUrl,
      );
      final filtered = items
          .where((i) => !_danmakuSettings.shouldFilter(i.text))
          .map((i) => i.toDanmakuItem())
          .toList();
      _danmakuController.setItems(filtered);
    } on Object {
      // 静默忽略。
    }
  }

  void _toggleDanmaku() {
    setState(() => _danmakuOn = !_danmakuOn);
    if (!_danmakuOn) {
      _danmakuKey.currentState?.clear();
    }
  }

  void _toggleUi() {
    setState(() => _uiVisible = !_uiVisible);
    if (_uiVisible) {
      _scheduleUiHide();
    } else {
      _uiHideTimer?.cancel();
    }
  }

  /// 启动 / 重启控制层自动隐藏倒计时。
  ///
  /// 仅在「正在播放」时生效：暂停、锁定态或已隐藏时不安排隐藏，避免用户
  /// 暂停后找不到播放键。
  void _scheduleUiHide() {
    _uiHideTimer?.cancel();
    if (_disposed || !mounted) return;
    if (!_isPlaying) return;
    _uiHideTimer = Timer(_kUiAutoHide, () {
      if (_disposed || !mounted) return;
      // 二次校验：倒计时期间可能已暂停 / 已手动隐藏。
      if (!_isPlaying || !_uiVisible) return;
      setState(() => _uiVisible = false);
    });
  }

  /// 任意指针按下时延长控制层停留时间（不改变可见性，仅重置倒计时）。
  ///
  /// 挂在播放器最外层 [Listener] 上：即便点击被底栏按钮消费，祖先 Listener
  /// 仍会收到 pointer down，从而实现「操作中控制条不消失」。
  void _bumpUiHideTimer() {
    if (!_uiVisible) return;
    _scheduleUiHide();
  }

  // 单击显隐控制栏统一由 GestureDetector.onTap → _toggleUi 处理；
  // 双击分区（中=播放/暂停·左=快退·右=快进）见 onDoubleTapDown。

  void _toggleLock() {
    _controller.toggleLock();
    // 延迟 setState 到当前事件帧结束后，避免在手势回调栈中
    // 销毁控制层子 widget（如 TextField / FocusNode）导致异常。
    if (mounted) {
      Future<void>.microtask(() {
        if (mounted) setState(() {});
      });
    }
  }

  // ─────────────────────── 手势 / 亮度 / 音量（视频还原） ───────────────────────

  /// 生成线路展示名（线路 1 / 线路 2 …），按 1 起编号。
  String _lineName(int index) {
    final l10n = AppLocalizations.of(context);
    return '${l10n.playerLine} ${index + 1}';
  }

  /// 由解析结果构造播放线路列表。
  ///
  /// 详情页 chips（天堂/精品/暴风/量子 等）选中后，`widget.episodes` 全集
  /// 里同名 [Episode.lineName] 字段反映该选择。本方法从全集按 lineName
  /// 分组，每组取当前 `_episodeIndex` 在该组里的同 position 副本：
  /// - 当前选中 lineName：用 [video] 的已解析 URL 直接 open；
  /// - 其他 lineName：暂用对应 ep.url 占位（剧集页 URL，未解析），
  ///   切到时由 [_changeEpisode] 重新解析（点该线路的某集才解析）；
  ///   不可用则 url 为空，open 时 [PlayerController._openCurrentLine]
  ///   会静默忽略。
  ///
  /// 单 line / 无 lineName 时按旧行为兜底为单条 "线路 1"，保持向后兼容。
  List<VideoLine> _buildLines(VideoResult video) {
    final episodes = widget.episodes;
    if (episodes == null || episodes.isEmpty) {
      return <VideoLine>[
        VideoLine(name: _lineName(0), url: video.url, headers: video.headers),
      ];
    }

    // 全集按 lineName 分组（保留原始顺序以便稳定映射 position）。
    final byLine = <String, List<int>>{};
    for (var i = 0; i < episodes.length; i++) {
      final ln = episodes[i].lineName ?? '';
      byLine.putIfAbsent(ln, () => <int>[]).add(i);
    }
    if (byLine.isEmpty) {
      return <VideoLine>[
        VideoLine(name: _lineName(0), url: video.url, headers: video.headers),
      ];
    }

    final String currentLine = _selectedLine ?? widget.episode.lineName ?? '';
    final List<int> currentGroup = byLine[currentLine] ?? <int>[];
    final int currentPos = currentGroup.contains(_episodeIndex)
        ? currentGroup.indexOf(_episodeIndex)
        : 0;

    // 按 lineName 排序保证 UI 顺序稳定。
    final sortedLines = byLine.keys.toList()..sort();
    return <VideoLine>[
      for (final ln in sortedLines)
        if (ln == currentLine)
          VideoLine(
            name: ln.isEmpty ? _lineName(0) : ln,
            url: video.url,
            headers: video.headers,
          )
        else
          VideoLine(
            name: ln.isEmpty ? '线路' : ln,
            url: _episodeUrlAt(byLine, episodes, ln, currentPos),
            headers: const <String, String>{},
          ),
    ];
  }

  /// 取出指定 lineName 组里第 [pos] 个全集 ep 的剧集页 URL；越界返回空串。
  String _episodeUrlAt(
    Map<String, List<int>> byLine,
    List<Episode> episodes,
    String line,
    int pos,
  ) {
    final group = byLine[line];
    if (group == null || pos < 0 || pos >= group.length) return '';
    return episodes[group[pos]].url;
  }

  /// 相对当前播放位置 seek 指定偏移（负值快退，正值快进），自动 clamp 到 [0, _duration]。
  Future<void> _seekBy(Duration offset) async {
    if (_duration == Duration.zero) return;
    final target = _position + offset;
    final clamped = target < Duration.zero
        ? Duration.zero
        : (target > _duration ? _duration : target);
    await _onSeek(clamped);
  }

  /// 设置系统亮度（0..1）并刷新手势指示器。
  Future<void> _setBrightness(double v) async {
    final clamped = v.clamp(0.0, 1.0);
    final l10n = AppLocalizations.of(context);
    _brightness = clamped;
    try {
      await _brightnessPlugin.setScreenBrightness(clamped);
    } on Object {
      // 平台不支持时静默忽略。
    }
    _showGestureIndicator('${l10n.playerBrightness}: ${(clamped * 100).round()}%');
  }

  /// 设置播放器音量（0..100，经 PlayerController 透传）并刷新手势指示器。
  Future<void> _setVolume(double v) async {
    final l10n = AppLocalizations.of(context);
    await _controller.setVolume(v);
    _showGestureIndicator(
        '${l10n.playerVolume}: ${_controller.volume.round()}%');
  }

  /// 显示手势指示器约 800ms 后自动淡出。
  ///
  /// 多次连续触发会重置计时器，指示器保持显示直到最后一次触发后 800ms。
  void _showGestureIndicator(String text) {
    _gestureIndicatorTimer?.cancel();
    setState(() {
      _gestureIndicatorText = text;
      _gestureIndicatorVisible = true;
    });
    _gestureIndicatorTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted) {
        setState(() => _gestureIndicatorVisible = false);
      }
    });
  }

  /// 中央手势指示器浮层：显示双击 ±10s / 亮度 % / 音量 % / 横滑 seek 目标时间。
  Widget _buildGestureIndicator() {
    return IgnorePointer(
      child: Center(
        child: AnimatedOpacity(
          opacity: _gestureIndicatorVisible ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 200),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppTokens.spaceMd,
              vertical: AppTokens.spaceSm,
            ),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(AppTokens.spaceSm),
            ),
            child: Text(
              _gestureIndicatorText ?? '',
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
          ),
        ),
      ),
    );
  }

  // ─────────────────────── 截图（边缘按钮 + 菜单共用） ───────────────────────

  /// 抽出 [_takeScreenshot] 的核心实现，供边缘常驻按钮与「更多」菜单共用。
  ///
  /// 使用 media_kit 的 [Player.screenshot] 截取当前帧，
  /// 保存为 PNG 到截图目录（默认 Documents/screenshots 或用户自定义）。
  Future<void> _captureAndSaveScreenshot(AppLocalizations l10n) async {
    try {
      final Uint8List? bytes = await _controller.player.screenshot();
      if (bytes == null || bytes.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.screenshotFailed)),
          );
        }
        return;
      }
      Directory baseDir;
      if (_customScreenshotDir != null && _customScreenshotDir!.isNotEmpty) {
        baseDir = Directory(_customScreenshotDir!);
        if (!await baseDir.exists()) {
          await baseDir.create(recursive: true);
        }
      } else {
        final docDir = await getApplicationDocumentsDirectory();
        baseDir = Directory(p.join(docDir.path, 'screenshots'));
        if (!await baseDir.exists()) {
          await baseDir.create(recursive: true);
        }
      }
      final String fileName =
          'nexhub_${DateTime.now().millisecondsSinceEpoch}.png';
      final File file = File(p.join(baseDir.path, fileName));
      await file.writeAsBytes(bytes);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.screenshotSaved)),
        );
      }
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${l10n.screenshotFailed}: $e')),
        );
      }
    }
  }

  /// 选择自定义截图保存目录。
  Future<void> _pickScreenshotDirectory(AppLocalizations l10n) async {
    try {
      final String? selected = await FilePicker.platform.getDirectoryPath(
        dialogTitle: l10n.playerScreenshot,
      );
      if (selected == null || selected.isEmpty) return;
      setState(() => _customScreenshotDir = selected);
      // 持久化到 SharedPreferences
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('screenshot_custom_dir', selected);
      } on Object {
        // 写入失败不影响功能
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(selected)),
        );
      }
    } on Object {
      // 用户取消或平台不支持，静默忽略
    }
  }

  /// 刷新收藏状态（P9.1.7 §16.1 顶栏收藏按钮）。
  void _refreshFavorite() {
    final type = widget.favoriteType;
    if (type == null) return;
    try {
      final fav = context.read<FavoritesManager>();
      _isFav = fav.isFavorite(widget.itemId, type);
    } on Object {
      // FavoritesManager 不可用时静默忽略。
    }
  }

  /// 切换收藏状态（P9.1.7 §16.1 顶栏收藏按钮）。
  Future<void> _toggleFavorite() async {
    final type = widget.favoriteType;
    if (type == null) return;
    final l10n = AppLocalizations.of(context);
    final fav = context.read<FavoritesManager>();
    final wasFavorite = _isFav;
    final item = MediaItem(
      id: widget.itemId,
      title: widget.title,
      sourceId: widget.sourceId,
      sourceType: type,
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
    final type = widget.favoriteType;
    if (type == null) {
      await _toggleFavorite();
      return;
    }
    final MediaItem item = MediaItem(
      id: widget.itemId,
      title: widget.title,
      sourceId: widget.sourceId,
      sourceType: type,
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

  // ─────────────────────── 键盘快捷键（P8.3.4 §廿四） ───────────────────────

  /// 处理键盘事件：空格=播放/暂停，左右=seek ±10s，F=全屏，M=静音。
  /// 返回 `KeyEventResult.handled` 表示已处理，否则 `ignored`。
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    // 仅响应 key down（避免重复触发），且锁定时不响应（除解锁外）。
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.space) {
      if (_controller.isLocked) return KeyEventResult.handled;
      if (_isPlaying) {
        _controller.pause();
      } else {
        _controller.play();
      }
      setState(() {
        _isPlaying = !_isPlaying;
        // 暂停时控制层常显，播放时重启自动隐藏倒计时。
        if (!_isPlaying) _uiVisible = true;
      });
      if (_isPlaying) {
        _scheduleUiHide();
      } else {
        _uiHideTimer?.cancel();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      if (_controller.isLocked) return KeyEventResult.handled;
      final target = (_position - const Duration(seconds: 10));
      final clamped = target < Duration.zero ? Duration.zero : target;
      unawaited(_onSeek(clamped));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      if (_controller.isLocked) return KeyEventResult.handled;
      final target = (_position + const Duration(seconds: 10));
      final clamped = target > _duration ? _duration : target;
      unawaited(_onSeek(clamped));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyF) {
      // 全屏切换即使在锁定状态也允许（与播放器 UI 解耦）。
      unawaited(_controller.toggleFullscreen());
      setState(() {});
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyM) {
      if (_controller.isLocked) return KeyEventResult.handled;
      unawaited(_controller.toggleMute());
      setState(() {});
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _onSeek(Duration position) async {
    await _controller.seek(position);
    _danmakuController.clear();
    _danmakuController.reset();
    setState(() => _position = position);
  }

  /// 打开弹幕设置面板（底部 modal bottom sheet）。
  Future<void> _openDanmakuSettings() async {
    await DanmakuSettingsSheet.show(
      context,
      settings: _danmakuSettings,
      onChanged: (next) {
        setState(() => _danmakuSettings = next);
        _applyDanmakuOption();
        unawaited(_saveDanmakuSettings());
      },
      onMatch: _openDanmakuMatch,
    );
  }

  /// 打开「手动匹配弹幕」面板，用户搜索番剧并选定集数后应用到当前集。
  Future<void> _openDanmakuMatch() async {
    if (_danmakuRepo == null) return;
    final id = await DanmakuMatchSheet.show(
      context,
      repo: _danmakuRepo!,
      initialKeyword: widget.title,
      currentEpisodeId: widget.episode.id,
    );
    if (id != null) {
      _dandanOverride[widget.episode.id] = id;
      _danmakuController.clear();
      _danmakuController.reset();
      _loadDanmaku();
    }
  }

  void _openDanmakuSource() async {
    await DanmakuSourceSheet.show(
      context,
      currentSource: _danmakuSource,
      currentCustomUrl: _customDanmakuUrl,
      onChanged: (next) async {
        if (next == _danmakuSource) return;
        setState(() => _danmakuSource = next);
        // 持久化用户选择。
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_kDanmakuSourceKey, next.name);
        } on Object {
          // 写入失败静默忽略。
        }
        // 清空并重新加载弹幕。
        _danmakuController.clear();
        _danmakuController.reset();
        _loadDanmaku();
      },
      onCustomUrl: (url) async {
        setState(() {
          _customDanmakuUrl = url;
          _danmakuSource = DanmakuSourceType.customUrl;
        });
        // 持久化 URL 和源选择。
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_kDanmakuCustomUrlKey, url);
          await prefs.setString(_kDanmakuSourceKey, DanmakuSourceType.customUrl.name);
        } on Object {
          // 写入失败静默忽略。
        }
        _danmakuController.clear();
        _danmakuController.reset();
        _loadDanmaku();
      },
    );
  }

  /// 倍速选择面板（底部弹出，点击即生效）。
  void _showSpeedPicker(AppLocalizations l10n) {
    const speeds = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0];
    final current = _controller.playbackSpeed;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext ctx) {
        final mq = MediaQuery.of(ctx);
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: mq.size.height * 0.85),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.all(AppTokens.spaceMd),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          l10n.playerPlaybackSpeed,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      Text(
                        '${current}x',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(width: AppTokens.spaceSm),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView(
                    shrinkWrap: true,
                    children: speeds.map((s) => ListTile(
                      dense: true,
                      title: Center(child: Text('${s}x')),
                      tileColor: (s == current)
                          ? Theme.of(ctx).colorScheme.primaryContainer
                          : null,
                      onTap: () {
                        unawaited(_controller.setPlaybackSpeed(s));
                        _applyDanmakuOption();
                        Navigator.pop(ctx);
                      },
                    )).toList(),
                  ),
                ),
                const SizedBox(height: AppTokens.spaceSm),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 功能5：选择长按自定义倍速值（更多菜单入口）。
  Future<void> _pickLongPressSpeed(BuildContext ctx) async {
    const options = <double>[1.5, 2.0, 2.5, 3.0];
    final selected = await showModalBottomSheet<double>(
      context: ctx,
      isScrollControlled: true,
      builder: (BuildContext sheetCtx) => SafeArea(
        child: ConstrainedBox(
          constraints:
              BoxConstraints(maxHeight: MediaQuery.of(sheetCtx).size.height * 0.85),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                ...options.map((s) => ListTile(
                      dense: true,
                      title: Center(child: Text('${s}x')),
                      tileColor: s == _playerSettings.longPressSpeed
                          ? Theme.of(sheetCtx).colorScheme.primaryContainer
                          : null,
                      onTap: () => Navigator.pop(sheetCtx, s),
                    )),
                const SizedBox(height: AppTokens.spaceSm),
              ],
            ),
          ),
        ),
      ),
    );
    if (selected != null) {
      await _updatePlayerSettings(
          _playerSettings.copyWith(longPressSpeed: selected));
    }
  }

  void _applyDanmakuOption() {
    if (!mounted || _disposed) return;
    // _controller 在 initState 同步创建，正常非空；但为防止极端时序下
    // playbackSpeed 读取抛异常（release 下未捕获即崩进程），此处做兜底。
    double speed = 1.0;
    try {
      speed = _controller.playbackSpeed;
    } on Object {
      // 读取失败则回退到 1.0（speed 已初始化为此值）。
    }
    final effectiveDuration = _danmakuSettings.effectiveDuration(speed);
    final option = cd.DanmakuOption(
      duration: effectiveDuration,
      fontSize: _danmakuSettings.fontSize,
      opacity: _danmakuSettings.opacity,
      area: _danmakuSettings.area,
      lineHeight: _danmakuSettings.lineHeight,
      hideTop: _danmakuSettings.hideTop,
      hideBottom: _danmakuSettings.hideBottom,
      hideScroll: _danmakuSettings.hideScroll,
    );
    try {
      _danmakuKey.currentState?.updateOption(option);
    } on Object catch (e, st) {
      debugPrint('[_applyDanmakuOption] updateOption 失败（已忽略）: $e\n$st');
    }
  }

  /// 显示弹幕输入框（支持选择弹幕颜色与样式）。
  /// 横屏：底部弹层（项 4a）；竖屏：可滚动对话框，避免小屏显示不全。
  void _showDanmakuInput() {
    final l10n = AppLocalizations.of(context);
    final controller = TextEditingController();
    Color selectedColor = Colors.white;
    cd.DanmakuItemType selectedType = cd.DanmakuItemType.scroll;
    final bool landscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    // 内容区（输入框 + 样式 + 颜色），横竖屏共用，由 setSt 驱动重建。
    Widget buildContent(
      BuildContext ctx,
      void Function(VoidCallback) setSt,
    ) {
      final theme = Theme.of(ctx);
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              hintText: l10n.danmakuSendHint ?? '输入弹幕内容',
              border: const OutlineInputBorder(),
            ),
            maxLength: 50,
          ),
          const SizedBox(height: AppTokens.spaceMd),
          Text(l10n.danmakuStyle, style: theme.textTheme.bodyMedium),
          const SizedBox(height: AppTokens.spaceSm),
          Wrap(
            spacing: AppTokens.spaceSm,
            children: <Widget>[
              for (final (type, label) in <(cd.DanmakuItemType, String)>[
                (cd.DanmakuItemType.scroll, l10n.danmakuStyleScroll),
                (cd.DanmakuItemType.top, l10n.danmakuStyleTop),
                (cd.DanmakuItemType.bottom, l10n.danmakuStyleBottom),
              ])
                ChoiceChip(
                  label: Text(label),
                  selected: selectedType == type,
                  onSelected: (_) => setSt(() => selectedType = type),
                ),
            ],
          ),
          const SizedBox(height: AppTokens.spaceMd),
          Text(l10n.presetColor, style: theme.textTheme.bodyMedium),
          const SizedBox(height: AppTokens.spaceSm),
          Wrap(
            spacing: AppTokens.spaceSm,
            runSpacing: AppTokens.spaceSm,
            children: <Widget>[
              for (final color in _danmakuPresetColors)
                GestureDetector(
                  onTap: () => setSt(() => selectedColor = color),
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selectedColor == color
                            ? theme.colorScheme.primary
                            : Colors.black38,
                        width: selectedColor == color ? 3 : 1,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      );
    }

    // 发送逻辑（横竖屏共用）。
    void send(BuildContext ctx) {
      final text = controller.text.trim();
      if (text.isNotEmpty) {
        final item = DanmakuItem(
          text: text,
          time: _position +
              Duration(milliseconds: (_danmakuSettings.timeOffset * 1000).round()),
          color: selectedColor,
          type: selectedType,
          selfSend: true,
        );
        _danmakuKey.currentState?.addSingle(item);
      }
      Navigator.pop(ctx);
    }

    if (landscape) {
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (BuildContext ctx) => SafeArea(
          child: ConstrainedBox(
            constraints:
                BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AppTokens.spaceMd),
              child: StatefulBuilder(
                builder: (BuildContext ctx, void Function(VoidCallback) setSt) =>
                    Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    buildContent(ctx, setSt),
                    const SizedBox(height: AppTokens.spaceMd),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: <Widget>[
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: Text(l10n.cancel),
                        ),
                        TextButton(
                          onPressed: () => send(ctx),
                          child: Text(l10n.ok),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    } else {
      showDialog<void>(
        context: context,
        builder: (BuildContext ctx) => StatefulBuilder(
          builder: (BuildContext ctx, void Function(VoidCallback) setSt) =>
              AppAlertDialog(
            title: Text(l10n.danmakuSend ?? '发送弹幕'),
            content: SingleChildScrollView(child: buildContent(ctx, setSt)),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(l10n.cancel),
              ),
              TextButton(
                onPressed: () => send(ctx),
                child: Text(l10n.ok),
              ),
            ],
          ),
        ),
      );
    }
  }

  void _showMoreMenu(AppLocalizations l10n) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext ctx) => SafeArea(
        child: ConstrainedBox(
          constraints:
              BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                _menuHeader(l10n),
            // 自动连播（本地 / 直链模式无下一集，隐藏）
            if (!_isDirectMode)
              ListTile(
                leading: Icon(
                  _controller.autoPlayNext
                      ? Icons.play_circle
                      : Icons.play_circle_outline,
                ),
                title: Text(l10n.playerAutoPlayNext),
                trailing: Switch(
                  value: _controller.autoPlayNext,
                  onChanged: (v) {
                    setState(() => _controller.autoPlayNext = v);
                    Navigator.pop(ctx);
                  },
                  activeColor: Theme.of(ctx).colorScheme.primary,
                ),
              ),
            // 功能5：长按手势设置（开关 + 自定义倍速值）
            ListTile(
              leading: Icon(_playerSettings.longPressSpeedUp
                  ? Icons.fast_forward
                  : Icons.fast_forward_outlined),
              title: Text(l10n.playerLongPressSpeedUp),
              trailing: Switch(
                value: _playerSettings.longPressSpeedUp,
                onChanged: (v) {
                  unawaited(_updatePlayerSettings(
                      _playerSettings.copyWith(longPressSpeedUp: v)));
                  Navigator.pop(ctx);
                },
                activeColor: Theme.of(ctx).colorScheme.primary,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.speed),
              title: Text(l10n.playerLongPressSpeed),
              subtitle: Text('${_playerSettings.longPressSpeed}x'),
              enabled: _playerSettings.longPressSpeedUp,
              onTap: () {
                Navigator.pop(ctx);
                unawaited(_pickLongPressSpeed(context));
              },
            ),
            // 画中画（从顶栏移入更多菜单）
            ListTile(
              leading: const Icon(Icons.picture_in_picture),
              title: Text(l10n.playerPip),
              onTap: () {
                Navigator.pop(ctx);
                _togglePip(l10n);
              },
            ),
            ListTile(
              leading: const Icon(Icons.memory),
              title: Text(l10n.playerDecodeMode),
              trailing: DropdownButton<String>(
                value: _controller.currentHwdec,
                // 收起时只显短名，避免 hw+ 的提示后缀撑爆 trailing 宽度。
                selectedItemBuilder: (BuildContext _) => <Widget>[
                  Text(l10n.playerDecodeAuto),
                  Text(l10n.playerDecodeSw),
                  Text(l10n.playerDecodeHw),
                  Text(l10n.playerDecodeHwPlus),
                ],
                items: <DropdownMenuItem<String>>[
                  DropdownMenuItem<String>(
                      value: 'auto', child: Text(l10n.playerDecodeAuto)),
                  DropdownMenuItem<String>(
                      value: 'sw', child: Text(l10n.playerDecodeSw)),
                  DropdownMenuItem<String>(
                      value: 'hw', child: Text(l10n.playerDecodeHw)),
                  // hw+（auto-copy）绕开硬解直通纹理路径，是花屏设备的首选。
                  DropdownMenuItem<String>(
                      value: 'hw+',
                      child: Text(
                          '${l10n.playerDecodeHwPlus} · ${l10n.playerDecodeHwPlusHint}')),
                ],
                onChanged: (String? v) {
                  Navigator.pop(ctx);
                  // 与自动降级一致：设完 hwdec 后必须 re-open，否则对已在播的
                  // 解码器不生效（用户切“软解”看不到任何变化）。
                  if (v != null) unawaited(_applyHwdecAndReopen(v));
                },
              ),
            ),
            ListTile(
              leading: const Icon(Icons.graphic_eq),
              title: Text(l10n.playerAudioChannel),
              trailing: DropdownButton<String>(
                value: _controller.currentAudioChannel,
                items: <DropdownMenuItem<String>>[
                  DropdownMenuItem<String>(
                      value: 'auto', child: Text(l10n.playerDecodeAuto)),
                  DropdownMenuItem<String>(
                      value: 'auto-safe', child: Text(l10n.playerAudioAutoProtect)),
                  DropdownMenuItem<String>(
                      value: 'stereo', child: Text(l10n.playerAudioStereo)),
                  DropdownMenuItem<String>(
                      value: 'mono', child: Text(l10n.playerAudioMono)),
                  DropdownMenuItem<String>(
                      value: 'reverse-stereo', child: Text(l10n.playerAudioReverseStereo)),
                ],
                onChanged: (String? v) {
                  if (v != null) _controller.setAudioChannel(v);
                  Navigator.pop(ctx);
                },
              ),
            ),
            ListTile(
              leading: const Icon(Icons.bedtime),
              title: Text(l10n.playerTimer),
              onTap: () {
                Navigator.pop(ctx);
                _showSleepTimerPicker(l10n);
              },
            ),
            // #4 A4-#4: 媒体信息
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text(l10n.mediaInfo),
              onTap: () {
                Navigator.pop(ctx);
                _showMediaInfo(l10n);
              },
            ),
            // 播放统计（实际软/硬解状态、编码、掉帧等，1s 刷新）
            ListTile(
              leading: const Icon(Icons.query_stats),
              title: Text(l10n.playerStats),
              onTap: () {
                Navigator.pop(ctx);
                _showPlaybackStats(l10n);
              },
            ),
            // #4 A4-#4: 外部播放
            ListTile(
              leading: const Icon(Icons.open_in_new),
              title: Text(l10n.playExternal),
              onTap: () {
                Navigator.pop(ctx);
                _playInExternal(l10n);
              },
            ),
            // #4 A4-#4: 分享（复用 _share）
            ListTile(
              leading: const Icon(Icons.share_outlined),
              title: Text(l10n.share),
              onTap: () {
                Navigator.pop(ctx);
                _share(l10n);
              },
            ),
            // 截图保存路径设置
            ListTile(
              leading: const Icon(Icons.folder_open),
              title: Text(l10n.screenshotPathSetting),
              subtitle: _customScreenshotDir != null
                  ? Text(_customScreenshotDir!,
                      maxLines: 1, overflow: TextOverflow.ellipsis)
                  : Text(l10n.screenshotPathDefault),
              onTap: () {
                Navigator.pop(ctx);
                _pickScreenshotDirectory(l10n);
              },
            ),
            const SizedBox(height: AppTokens.spaceSm),
          ],
        ),
      ),
    ),
  ),
);
  }

  void _showCastSheet(AppLocalizations l10n) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext ctx) => SafeArea(
        child: ConstrainedBox(
          constraints:
              BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
          child: SingleChildScrollView(
            child: FutureBuilder<List<CastDevice>>(
          future: _castService.discover(),
          builder: (BuildContext _, AsyncSnapshot<List<CastDevice>> snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final List<CastDevice> devices = snap.data ?? <CastDevice>[];
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.all(AppTokens.spaceMd),
                  child: Text(
                    l10n.castToDevice,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (_isCasting)
                  ListTile(
                    leading: const Icon(Icons.cast_connected),
                    title: Text(l10n.castingTo(_castService.deviceName ?? '')),
                    trailing: TextButton(
                      onPressed: () {
              Navigator.pop(context);
                        _disconnectCast(l10n);
                      },
                      child: Text(l10n.castDisconnect),
                    ),
                  ),
                if (!_isCasting && snap.hasError)
                  Padding(
                    padding: const EdgeInsets.all(AppTokens.spaceMd),
                    child: Text(l10n.castNotSupportedOnDevice),
                  ),
                if (!_isCasting && !snap.hasError && devices.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(AppTokens.spaceMd),
                    child: Text(l10n.castNoDevices),
                  ),
                for (final CastDevice d in devices)
                  ListTile(
                    leading: const Icon(Icons.tv),
                    title: Text(d.name),
                    onTap: () {
                      Navigator.pop(ctx);
                      _connectCast(d, l10n);
                    },
                  ),
                const SizedBox(height: AppTokens.spaceSm),
              ],
            );
          },
        ),
        ),
        ),
      ),
    );
  }

  Future<void> _connectCast(CastDevice device, AppLocalizations l10n) async {
    final String url = _playUrl ?? widget.episode.url;
    try {
      await _castService.connectAndPlay(device, url, title: _episodeTitle);
      await _controller.pause();
      if (mounted) {
        setState(() => _isCasting = true);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.castingTo(device.name))),
        );
      }
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.castNotSupportedOnDevice)),
        );
      }
    }
  }

  Future<void> _disconnectCast(AppLocalizations l10n) async {
    await _castService.disconnect();
    if (mounted) {
      setState(() => _isCasting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.castDisconnect)),
      );
    }
  }

  Future<void> _togglePip(AppLocalizations l10n) async {
    final floating = Floating();
    try {
      final bool available = await floating.isPipAvailable;
      if (!available) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.pipNotSupportedOnDevice)),
          );
        }
        return;
      }
      await floating.enable(ImmediatePiP());
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.pipNotSupportedOnDevice)),
        );
      }
    }
  }

  Widget _menuHeader(AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTokens.spaceLg,
        AppTokens.spaceMd,
        AppTokens.spaceSm,
        AppTokens.spaceSm,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              l10n.playerPlayInfo,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          // 投屏入口（打开设备选择面板）。
          IconButton(
            icon: Icon(Icons.cast,
                color: _isCasting
                    ? Theme.of(context).colorScheme.primary
                    : null),
            tooltip: l10n.cast,
            onPressed: () {
              Navigator.pop(context);
              _showCastSheet(l10n);
            },
          ),
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }

  @override
  void deactivate() {
    // 关键：deactivate 阶段元素已失活但 mounted 仍为 true，必须在此切断
    // stall/position/completed 流订阅并置位 _disposed，否则退场瞬间流回调
    // 仍可能访问 context（InheritedWidget）触发「deactivated widget」崩溃。
    _disposed = true;
    _positionSub?.cancel();
    _completedSub?.cancel();
    _stallSub?.cancel();
    _decodeFallbackSub?.cancel();
    _bufferingSub?.cancel();
    _playingSub?.cancel();
    // 关闭可能残留的 SnackBar：其退出动画的 AnimationController 在 widget 失活后
    // 仍会 tick，并尝试访问已销毁的 Scaffold 祖先 → 抛「deactivated widget」
    // （见用户日志 AnimationController#...for SnackBar）。deactivate 阶段 context
    // 仍有效，用 maybeOf 安全隐藏（ScaffoldMessenger.of 会抛同一异常）。
    // 必须在 super.deactivate() 前调用（之后 element 即从树中摘下）。
    ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
    super.deactivate();
  }

  @override
  void dispose() {
    // 退出时保存最后播放位置
    _saveCurrentPosition();
    // 兜底保存弹幕显示设置（滑块即时保存之外，确保离开页面必定落盘）。
    unawaited(_saveDanmakuSettings());
    _sleepTimer?.cancel();
    _gestureIndicatorTimer?.cancel();
    _uiHideTimer?.cancel();
    _positionSub?.cancel();
    _completedSub?.cancel();
    _stallSub?.cancel();
    _decodeFallbackSub?.cancel();
    _bufferingSub?.cancel();
    _playingSub?.cancel();
    _resolveProgress.dispose();
    unawaited(_castService.disconnect());
    _focusNode.dispose();
    // _controller 可能未创建（如 _init 在创建前就抛异常退出），需判空避免
    // LateInitializationError。正常情况下 _init 成功后 _controllerCreated 为 true。
    if (_controllerCreated) {
      _controller.removeListener(_onControllerChanged);
    }
    // 关键：释放视频渲染层。VideoController 在 media_kit_video 2.0.1 没有 dispose()
    // 方法——它的原生 VideoOutput（media_kit 纹理）由底层 Player.dispose() 通过 release
    // 回调统一释放。PlayerController.dispose() 会把该释放的 Future 记入静态
    // PlayerController._pendingDisposal；下一次进入播放器时 _init 会 await
    // PlayerController.pendingDisposal，确保「旧播放器销毁」先于「新播放器创建」，
    // 避免退出重进时新旧 surface 冲突（Lost connection to device）。
    _videoController = null;
    if (_controllerCreated) {
      _controller.dispose();
    }
    // 还原系统亮度（避免退出后保留手势调节值）。
    // 注意：resetScreenBrightness 是异步方法，其 PlatformException 在后续微任务抛出，
    // 同步 try/catch 捕获不到，会形成「Uncaught zone error」；故用 .catchError 兜底。
    _brightnessPlugin.resetScreenBrightness().catchError((Object _) {});
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      body: FutureBuilder<void>(
        future: _initFuture,
        builder: (BuildContext c, AsyncSnapshot<void> snap) {
          if (snap.connectionState != ConnectionState.done) {
            // 初始化转圈期间叠加解析进度条（功能3），让用户看到"找视频地址"的进度。
            return Stack(
              children: <Widget>[
                const Center(child: CircularProgressIndicator()),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: ValueListenableBuilder<double?>(
                    valueListenable: _resolveProgress,
                    builder: (BuildContext _, double? v, Widget? __) {
                      if (v == null) return const SizedBox.shrink();
                      return LinearProgressIndicator(
                        value: v >= 0 ? v : null,
                        minHeight: 3,
                        backgroundColor: Colors.white24,
                        valueColor: const AlwaysStoppedAnimation<Color>(
                            Colors.white),
                      );
                    },
                  ),
                ),
              ],
            );
          }
          if (snap.hasError || _videoController == null) {
            return AppErrorState(
              message: l10n.playerVideoExpired,
              // 注意：setState 的回调必须是 void，不能写 `() => _initFuture = _init()`
              // （赋值表达式会返回 _init() 这个 Future，触发「setState callback returned a Future」崩溃）。
              onRetry: () {
                setState(() {
                  _initFuture = _init();
                });
              },
            );
          }
          return _buildPlayer(l10n);
        },
      ),
    );
  }

  Widget _buildPlayer(AppLocalizations l10n) {
    // 自动重连耗尽：展示「视频链接已失效，点击重试」覆盖层，由用户手动触发
    // 重新解析 + 重新打开播放器（拿到未过期的新直链）。
    if (_reconnectExhausted) {
      return AppErrorState(
        message: l10n.playerVideoExpired,
        onRetry: _manualRetry,
      );
    }
    // 包裹 Focus 以响应键盘快捷键（P8.3.4 §廿四）。
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      // 最外层 Listener：任何指针按下（含被底栏按钮消费的点击）都会经过祖先
      // 命中路径，用来重置控制层自动隐藏倒计时，保证「操作过程中控制条不消失」。
      child: Listener(
        onPointerDown: (_) => _bumpUiHideTimer(),
        child: Stack(
        children: <Widget>[
          // 视频画面 + 手势系统（双击 中=播放/暂停·左=快退·右=快进 / 左竖滑亮度 / 右竖滑音量 / 横滑 seek 预览）
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            // 功能1：单击显隐控制栏。
            onTap: _toggleUi,
            // 功能4：长按切自定义倍速，松手恢复（受 longPressSpeedUp 开关控制）。
            onLongPressStart: (_) => _onLongPressSpeedStart(),
            onLongPressEnd: (_) => _onLongPressSpeedEnd(),
            // 双击：左=快退 10s；中=播放/暂停；右=快进 10s（锁定态忽略）。
            onDoubleTapDown: (TapDownDetails d) {
              if (_controller.isLocked) return;
              final width = context.size?.width ?? 0;
              final dx = d.localPosition.dx;
              if (dx < width / 3) {
                // 左三分之一：快退 10s
                unawaited(_seekBy(const Duration(seconds: -10)));
                _showGestureIndicator(l10n.seekBackward10);
              } else if (dx > width * 2 / 3) {
                // 右三分之一：快进 10s
                unawaited(_seekBy(const Duration(seconds: 10)));
                _showGestureIndicator(l10n.seekForward10);
              } else {
                // 中间三分之一：播放/暂停
                _togglePlayPause();
              }
            },
            onVerticalDragStart: (DragStartDetails d) {
              if (_controller.isLocked) return;
              final width = context.size?.width ?? 1;
              _dragAxis = d.localPosition.dx < width / 2
                  ? _GestureAxis.verticalLeft
                  : _GestureAxis.verticalRight;
              _dragStartBrightness = _brightness;
              _dragStartVolume = _controller.volume;
            },
            onVerticalDragUpdate: (DragUpdateDetails d) {
              if (_controller.isLocked) return;
              if (_dragAxis == _GestureAxis.none) return;
              final height = context.size?.height ?? 1;
              // 上滑为正（增量），下滑为负
              final delta = -d.delta.dy / height;
              if (_dragAxis == _GestureAxis.verticalLeft) {
                unawaited(
                    _setBrightness(_dragStartBrightness + delta));
              } else if (_dragAxis == _GestureAxis.verticalRight) {
                unawaited(_setVolume(_dragStartVolume + delta * 100));
              }
            },
            onVerticalDragEnd: (_) {
              _dragAxis = _GestureAxis.none;
            },
            onHorizontalDragStart: (_) {
              if (_controller.isLocked) return;
              _dragAxis = _GestureAxis.horizontal;
              _seekPreview = _position;
            },
            onHorizontalDragUpdate: (DragUpdateDetails d) {
              if (_controller.isLocked) return;
              if (_dragAxis != _GestureAxis.horizontal) return;
              final width = context.size?.width ?? 1;
              final delta = -d.delta.dx / width;
              final next = _seekPreview +
                  Duration(
                      seconds: (delta *
                              _duration.inSeconds *
                              _seekMultiplierFactor)
                          .round());
              _seekPreview = next < Duration.zero
                  ? Duration.zero
                  : (next > _duration ? _duration : next);
              _showGestureIndicator(
                  '${_formatDuration(_seekPreview)} / ${_formatDuration(_duration)}');
            },
            onHorizontalDragEnd: (_) {
              if (_controller.isLocked) {
                _dragAxis = _GestureAxis.none;
                return;
              }
              if (_dragAxis == _GestureAxis.horizontal) {
                unawaited(_controller.seek(_seekPreview));
              }
              _dragAxis = _GestureAxis.none;
            },
            child: Center(
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Video(
                  controller: _videoController!,
                  controls: NoVideoControls,
                ),
              ),
            ),
          ),

          // 弹幕覆盖层
          Positioned.fill(
            child: IgnorePointer(
              child: DanmakuOverlay(
                key: _danmakuKey,
                enabled: _danmakuOn,
                controller: _danmakuController,
              ),
            ),
          ),

          // 中央手势指示器（锁定态不显示）
          if (!_controller.isLocked) _buildGestureIndicator(),

          // 功能2：缓冲加载动画（播放中缓冲时显示中央转圈）。
          if (_isBuffering && !_controller.isLocked)
            const Center(
              child: SizedBox(
                width: 56,
                height: 56,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white70),
                ),
              ),
            ),

          // 功能3：解析进度条（顶部细进度条，类似网站加载条）。
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: ValueListenableBuilder<double?>(
              valueListenable: _resolveProgress,
              builder: (BuildContext _, double? v, Widget? __) {
                if (v == null) return const SizedBox.shrink();
                return LinearProgressIndicator(
                  value: v >= 0 ? v : null,
                  minHeight: 3,
                  backgroundColor: Colors.white24,
                  valueColor:
                      const AlwaysStoppedAnimation<Color>(Colors.white),
                );
              },
            ),
          ),

          // 左边缘常驻锁定按钮（垂直居中；锁定时仍可见，作解锁入口）
          Positioned(
            left: AppTokens.spaceLg,
            top: 0,
            bottom: 0,
            child: Center(
              child: _ControlButton(
                key: const Key('player_lock_edge'),
                icon: _controller.isLocked ? Icons.lock : Icons.lock_open,
                tooltip: _controller.isLocked
                    ? l10n.playerUnlock
                    : l10n.playerLock,
                onTap: _toggleLock,
              ),
            ),
          ),

          // 右边缘常驻截图按钮（垂直居中；锁定态隐藏，避免误触）
          if (!_controller.isLocked)
            Positioned(
              right: AppTokens.spaceLg,
              top: 0,
              bottom: 0,
              child: Center(
                child: _ControlButton(
                  key: const Key('player_screenshot_edge'),
                  icon: Icons.camera_alt,
                  tooltip: l10n.playerScreenshot,
                  onTap: () => unawaited(_captureAndSaveScreenshot(l10n)),
                ),
              ),
            ),

          // 控制层（未锁定时显示）
          if (!_controller.isLocked) ...<Widget>[
            // 顶栏（_buildTopBar 自身已返回 Positioned，无需再包一层，否则嵌套
            // Positioned 触发「Incorrect use of ParentDataWidget」并使视频区塌缩为 0）
            if (_uiVisible) _buildTopBar(l10n),

            // 底栏
            if (_uiVisible) _buildBottomBar(l10n),

            // 中央播放/暂停按钮（仅暂停态显示）
            if (_uiVisible && !_isPlaying)
              Center(
                child: IconButton.filled(
                  key: const Key('player_play_pause'),
                  iconSize: 48,
                  icon: const Icon(Icons.play_arrow),
                  onPressed: () {
                    _controller.play();
                    setState(() => _isPlaying = true);
                  },
                ),
              ),
          ],
        ],
        ),
      ),
    );
  }

  Widget _buildTopBar(AppLocalizations l10n) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[Colors.black54, Colors.transparent],
          ),
        ),
        padding: EdgeInsets.only(
          top: MediaQuery.of(context).padding.top,
          left: AppTokens.spaceSm,
          right: AppTokens.spaceSm,
        ),
        child: Row(
          children: <Widget>[
            IconButton(
              key: const Key('player_back'),
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: () => Navigator.of(context).pop(),
            ),
            // 滚动媒体名 + 集数（长标题自动横向滚动）
            Expanded(
              child: _MarqueeText(
                text: _episodeTitle,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            // 投屏
            IconButton(
              key: const Key('player_cast'),
              icon: Icon(Icons.cast,
                  color: _isCasting ? Colors.amber : Colors.white),
              tooltip: l10n.playerCast,
              onPressed: () => _showCastSheet(l10n),
            ),
            // 字幕
            IconButton(
              key: const Key('player_subtitle'),
              icon: Icon(
                _controller.subtitleVisible
                    ? Icons.subtitles
                    : Icons.subtitles_outlined,
                color: Colors.white,
              ),
              tooltip: l10n.playerSubtitle,
              onPressed: () => SubtitlePanel.show(context, controller: _controller),
            ),
            // 收藏按钮（P9.1.7 §16.1 顶栏收藏，仅 favoriteType 提供时显示）
            if (widget.favoriteType != null)
              IconButton(
                key: const Key('player_favorite'),
                icon: Icon(
                  _isFav ? Icons.favorite : Icons.favorite_border,
                  color: _isFav ? Colors.redAccent : Colors.white,
                ),
                tooltip: l10n.favorite,
                onPressed: _onFavoritePressed,
              ),
            // 更多（已瘦身：解码 / 音频 / 媒体信息 / 外部播放 / 定时关闭 / 分享 / PiP / 连播）
            IconButton(
              key: const Key('player_more'),
              icon: const Icon(Icons.more_vert, color: Colors.white),
              tooltip: l10n.playerMore,
              onPressed: () => _showMoreMenu(l10n),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar(AppLocalizations l10n) {
    final hasPrev = widget.episodes != null && _episodeIndex > 0;
    final hasNext =
        widget.episodes != null && _episodeIndex < widget.episodes!.length - 1;

    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: <Color>[Colors.black54, Colors.transparent],
          ),
        ),
        padding: EdgeInsets.only(
          left: AppTokens.spaceMd,
          right: AppTokens.spaceMd,
          bottom: MediaQuery.of(context).padding.bottom + AppTokens.spaceSm,
          top: AppTokens.spaceSm,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // 解析二级进度（加载态可见，复用 State 级 _resolveProgress）
            ValueListenableBuilder<double?>(
              valueListenable: _resolveProgress,
              builder: (BuildContext _, double? v, Widget? __) {
                if (v == null) return const SizedBox.shrink();
                return Padding(
                  padding:
                      const EdgeInsets.only(bottom: AppTokens.spaceXs),
                  child: LinearProgressIndicator(
                    value: v >= 0 ? v : null,
                    minHeight: 2,
                    backgroundColor: Colors.white24,
                    valueColor:
                        const AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                );
              },
            ),
            // 进度行：SeekBar + 时间 + 内联控件
            SeekBar(
              position: _position,
              duration: _duration,
              onSeek: _onSeek,
            ),
            // 单行控件：时间 | 上一集 | 播放/暂停 | 下一集 | 弹幕 | 弹幕设置 ‖ 倍速 | 比例 | 选集 | 全屏
            // （原两行合并：删去与快捷行完全重复的主控行按钮，弹幕设置紧邻弹幕开关）
            Row(
              children: <Widget>[
                // 时间
                Text(
                  _formatDuration(_position),
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
                const Text(
                  ' / ',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
                Text(
                  _formatDuration(_duration),
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
                const SizedBox(width: AppTokens.spaceSm),
                // 上一集
                if (hasPrev)
                  _ControlButton(
                    key: const Key('player_prev_ep'),
                    icon: Icons.skip_previous,
                    tooltip: l10n.playerPreviousEpisode,
                    onTap: _goPrevEpisode,
                  ),
                // 播放 / 暂停
                _ControlButton(
                  key: const Key('player_play_pause_bottom'),
                  icon: _isPlaying ? Icons.pause : Icons.play_arrow,
                  tooltip: _isPlaying ? l10n.pause : l10n.play,
                  onTap: () {
                    if (_isPlaying) {
                      _controller.pause();
                    } else {
                      _controller.play();
                    }
                    setState(() => _isPlaying = !_isPlaying);
                  },
                ),
                // 下一集
                if (hasNext)
                  _ControlButton(
                    key: const Key('player_next_ep'),
                    icon: Icons.skip_next,
                    tooltip: l10n.playerNextEpisode,
                    onTap: _goNextEpisode,
                  ),
                // 弹幕区域（开关 + 发送[开时] + 设置[开时]）
                _DanmakuToggle(
                  key: const Key('player_danmaku_area'),
                  isOn: _danmakuOn,
                  l10n: l10n,
                  onToggle: _toggleDanmaku,
                  onSend: _showDanmakuInput,
                  onSettings: _openDanmakuSettings,
                  onLongPressSettings: _openDanmakuSource,
                ),
                const Spacer(),
                // 倍速（弹出选择面板）
                _ControlButton(
                  key: const Key('player_quick_speed'),
                  icon: Icons.speed,
                  tooltip: '${l10n.playerPlaybackSpeed} ${_controller.playbackSpeed}x',
                  onTap: () => _showSpeedPicker(l10n),
                ),
                // 比例（循环 default / 4:3 / 16:9 / fill）
                _ControlButton(
                  key: const Key('player_quick_aspect'),
                  icon: Icons.aspect_ratio,
                  tooltip: l10n.playerAspectRatio,
                  onTap: () {
                    const ratios = <String>['default', '4:3', '16:9', 'fill'];
                    final cur = _controller.currentAspectRatio;
                    final idx = ratios.indexOf(cur);
                    final next = ratios[(idx + 1) % ratios.length];
                    unawaited(_controller.setAspectRatio(next));
                  },
                ),
                // 选集（本地 / 直链模式隐藏）
                if (!_isDirectMode)
                  _ControlButton(
                    key: const Key('player_quick_episodes'),
                    icon: Icons.video_library,
                    tooltip: l10n.playerEpisodes,
                    onTap: () => _showLineSheet(l10n),
                  ),
                // 全屏
                _ControlButton(
                  key: const Key('player_quick_fullscreen'),
                  icon: _controller.isFullscreen
                      ? Icons.fullscreen_exit
                      : Icons.fullscreen,
                  tooltip: _controller.isFullscreen
                      ? l10n.playerExitFullscreen
                      : l10n.playerFullscreen,
                  onTap: () =>
                      unawaited(_controller.toggleFullscreen()),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String get _episodeTitle {
    final ep = widget.episodes != null && widget.episodes!.isNotEmpty
        ? widget.episodes![_episodeIndex.clamp(0, widget.episodes!.length - 1)]
        : widget.episode;
    return '${widget.title} · ${ep.title}';
  }

  // ─────────────────────── 选集 / 线路面板（FR-3.4） ───────────────────────

  /// 弹出选集 + 线路 sheet（FR-3.4）。
  ///
  /// 行为（Bug F 修复）：
  /// - 上半：剧集列表，只显示**当前选中线路**的集。
  /// - 下半：播放线路分组。点击线路**只切换上方要显示的集分组**——
  ///   面板不关闭、也**不立即解析**；只有点完某一集，才由 [_changeEpisode]
  ///   走视频嗅探解析并播放。
  ///
  /// 线路分组键使用全集各 `Episode.lineName` 的**原始值**（而非
  /// [_controller.lines] 里被 canonicalize 过的名字），这样与上方剧集过滤
  /// 用的是同一把钥匙，空串线路名也能正确对上。
  ///
  /// 本地 / 直链模式 [_isDirectMode] 不应触发（调用方已隐藏入口）。
  void _showLineSheet(AppLocalizations l10n) {
    final allEpisodes = widget.episodes ?? <Episode>[];
    // 全集按 lineName 分组（保留原始值作为分组键）。
    final byLine = <String, List<int>>{};
    for (var i = 0; i < allEpisodes.length; i++) {
      final ln = allEpisodes[i].lineName ?? '';
      byLine.putIfAbsent(ln, () => <int>[]).add(i);
    }
    final distinctLines = byLine.keys.toList()..sort();

    // 当前选中线路（面板内的局部可变状态）：初始为正在播放的那条。
    String selectedLine = _selectedLine ?? widget.episode.lineName ?? '';

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext ctx) {
        return StatefulBuilder(
          builder: (BuildContext ctx, StateSetter setStateSheet) {
            final filteredIndices = byLine[selectedLine] ?? <int>[];
            // 过滤后当前位置（1 起，仅用于 header 提示）
            final currentPosInLine = filteredIndices.contains(_episodeIndex)
                ? filteredIndices.indexOf(_episodeIndex) + 1
                : 0;
            return SafeArea(
              child: SizedBox(
                height: MediaQuery.of(ctx).size.height * 0.6,
                child: Column(
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.all(AppTokens.spaceMd),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              l10n.playerEpisodes,
                              style: Theme.of(ctx).textTheme.titleMedium,
                            ),
                          ),
                          if (selectedLine.isNotEmpty &&
                              filteredIndices.isNotEmpty)
                            Text(
                              l10n.playerLineEpisodesProgress(
                                currentPosInLine, filteredIndices.length),
                              style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                                    color: Theme.of(ctx)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                            ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    // 上半：当前线路的剧集列表（仅显示过滤后的集）。
                    Expanded(
                      flex: 3,
                      child: filteredIndices.isEmpty
                          ? _buildLineHint(
                              ctx,
                              icon: Icons.error_outline,
                              text: l10n.playerLineEmpty,
                            )
                          : ListView.builder(
                              itemCount: filteredIndices.length,
                              itemBuilder: (BuildContext _, int j) {
                                final globalIdx = filteredIndices[j];
                                final ep = allEpisodes[globalIdx];
                                final selected = globalIdx == _episodeIndex;
                                final lineLabel = selectedLine.isEmpty
                                    ? _lineName(0)
                                    : selectedLine;
                                return ListTile(
                                  leading: CircleAvatar(
                                    backgroundColor: selected
                                        ? Theme.of(ctx).colorScheme.primary
                                        : null,
                                    child: Text('${j + 1}'),
                                  ),
                                  title: Text(
                                    ep.title,
                                    style: selected
                                        ? TextStyle(
                                            color: Theme.of(ctx)
                                                .colorScheme
                                                .primary,
                                            fontWeight: FontWeight.bold,
                                          )
                                        : null,
                                  ),
                                  subtitle: selectedLine.isNotEmpty
                                      ? Text(
                                          lineLabel,
                                          style: Theme.of(ctx)
                                              .textTheme
                                              .bodySmall
                                              ?.copyWith(
                                                color: Theme.of(ctx)
                                                    .colorScheme
                                                    .onSurfaceVariant,
                                              ),
                                        )
                                      : null,
                                  onTap: () {
                                    // 点集才关闭面板并解析播放。
                                    Navigator.pop(ctx);
                                    if (globalIdx != _episodeIndex) {
                                      _changeEpisode(globalIdx);
                                    }
                                  },
                                );
                              },
                            ),
                    ),
                    const Divider(height: 1),
                    // 下半：播放线路分组（仅用于切换上方要显示的集）
                    Padding(
                      padding: const EdgeInsets.fromLTRB(AppTokens.spaceMd,
                          AppTokens.spaceSm, AppTokens.spaceMd, 0),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          l10n.playerLine,
                          style: Theme.of(ctx).textTheme.titleSmall,
                        ),
                      ),
                    ),
                    Expanded(
                      flex: 2,
                      child: distinctLines.isEmpty
                          ? _buildLineHint(
                              ctx,
                              icon: Icons.error_outline,
                              text: l10n.playerLineEmpty,
                            )
                          : ListView.builder(
                              itemCount: distinctLines.length,
                              itemBuilder: (BuildContext _, int i) {
                                final rawLine = distinctLines[i];
                                final displayName =
                                    rawLine.isEmpty ? _lineName(i) : rawLine;
                                final selected = rawLine == selectedLine;
                                return ListTile(
                                  leading: Icon(
                                    selected
                                        ? Icons.radio_button_checked
                                        : Icons.radio_button_unchecked,
                                    color: selected
                                        ? Theme.of(ctx).colorScheme.primary
                                        : null,
                                  ),
                                  title: Text(displayName),
                                  trailing: selected
                                      ? Icon(Icons.play_arrow,
                                          color: Theme.of(ctx)
                                              .colorScheme
                                              .primary)
                                      : null,
                                  onTap: () {
                                    // 只切换上方要显示的集分组：不关闭面板、
                                    // 不立即解析。点完集才由 [_changeEpisode] 解析。
                                    if (rawLine == selectedLine) return;
                                    setStateSheet(() {
                                      selectedLine = rawLine;
                                    });
                                  },
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// 线路 ≤1 条时的提示占位（图标 + 文案 + 居中）。
  ///
  /// 源共创式架构下，源作者写 `urls` 数组才会出现多线路。`lines.isEmpty`
  /// 多为源未声明/解析失败；`lines.length == 1` 则源只返回了 1 条 URL，
  /// 提示用户可让源作者补 urls 数组。
  Widget _buildLineHint(
    BuildContext ctx, {
    required IconData icon,
    required String text,
  }) {
    final theme = Theme.of(ctx);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTokens.spaceLg,
        vertical: AppTokens.spaceMd,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, color: theme.colorScheme.outline, size: 20),
          const SizedBox(width: AppTokens.spaceSm),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    if (h > 0) return '$h:$mm:$ss';
    return '$mm:$ss';
  }

  void _showSleepTimerPicker(AppLocalizations l10n) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext ctx) => SafeArea(
        child: ConstrainedBox(
          constraints:
              BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
          child: SingleChildScrollView(
            child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.timer_off),
              title: Text(l10n.playerTimerOff),
              onTap: () {
                Navigator.pop(ctx);
                _sleepTimer?.cancel();
                _sleepTimer = null;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(l10n.playerTimerCanceled)),
                );
              },
            ),
            for (final m in <int>[15, 30, 45, 60, 90])
              ListTile(
                leading: const Icon(Icons.timer),
                title: Text(l10n.playerTimerMinutes(m)),
                onTap: () {
                  Navigator.pop(ctx);
                  _setSleepTimer(m, l10n);
                },
              ),
            ListTile(
              leading: const Icon(Icons.edit),
              title: Text(l10n.playerTimerCustom),
              onTap: () {
                Navigator.pop(ctx);
                _showCustomSleepTimerDialog(l10n);
              },
            ),
            const SizedBox(height: AppTokens.spaceSm),
          ],
        ),
      ),
    ),
  ),
);
  }

  void _setSleepTimer(int minutes, AppLocalizations l10n) {
    _sleepTimer?.cancel();
    _sleepTimer = Timer(Duration(minutes: minutes), () {
      _controller.pause();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.playerTimerFired)),
        );
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.playerTimerMinutes(minutes))),
    );
  }

  void _showCustomSleepTimerDialog(AppLocalizations l10n) {
    final TextEditingController controller = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AppAlertDialog(
        title: Text(l10n.playerTimer),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(hintText: l10n.playerTimerCustom),
          autofocus: true,
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () {
              final m = int.tryParse(controller.text.trim());
              if (m != null && m > 0) {
                Navigator.pop(ctx);
                _setSleepTimer(m, l10n);
              }
            },
            child: Text(l10n.ok),
          ),
        ],
      ),
    );
  }

  void _share(AppLocalizations l10n) {
    final text = '$_episodeTitle\n${_playUrl ?? widget.episode.url}';
    Share.share(text);
  }

  /// #4 A4-#4: 显示媒体信息（标题/源/剧集/当前 URL/播放进度）。
  void _showMediaInfo(AppLocalizations l10n) {
    final url = _playUrl ?? widget.episode.url;
    final pos = _position.inSeconds;
    final dur = _duration.inSeconds;
    final posStr =
        '${pos ~/ 60}:${(pos % 60).toString().padLeft(2, '0')}';
    final durStr =
        '${dur ~/ 60}:${(dur % 60).toString().padLeft(2, '0')}';
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext ctx) {
        final mq = MediaQuery.of(ctx);
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: mq.size.height * 0.85),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AppTokens.spaceMd),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(l10n.mediaInfo,
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: AppTokens.spaceSm),
                  Text('${l10n.browseLocalFileTypeVideo}: ${widget.title}'),
                  Text(_episodeTitle),
                  if (_isDirectMode)
                    Text('${l10n.localFileLabel}: ${widget.directUrl ?? widget.localUri}')
                  else
                    Text('${l10n.videoSourceLine}: ${widget.sourceId}'),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Text('URL: '),
                      Expanded(child: Text(url, softWrap: true)),
                      IconButton(
                        icon: const Icon(Icons.copy, size: 18),
                        tooltip: l10n.snifferCopy,
                        onPressed: () =>
                            unawaited(Clipboard.setData(ClipboardData(text: url))),
                      ),
                    ],
                  ),
                  Text('${l10n.novelHfProgressPercent}: $posStr / $durStr'),
                  const SizedBox(height: AppTokens.spaceMd),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: Text(l10n.close),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 播放统计面板：读 mpv 只读属性展示实际软/硬解状态、编码、分辨率、
  /// 掉帧与码率，1s 定时刷新。软/硬解状态醒目标注，用于诊断
  /// 「hwdec=auto 实际落在哪条解码路径」与花屏问题排查。
  void _showPlaybackStats(AppLocalizations l10n) {
    Timer? refreshTimer;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext ctx) => SafeArea(
        child: ConstrainedBox(
          constraints:
              BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppTokens.spaceMd),
            child: StatefulBuilder(
              builder: (BuildContext sbCtx, StateSetter setSheetState) {
                // 首次 build 时启动 1s 周期刷新；面板关闭后由 whenComplete 取消。
                refreshTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
                  if (sbCtx.mounted) setSheetState(() {});
                });
                return FutureBuilder<PlayerStats>(
                  future: _controller.queryStats(),
                  builder: (BuildContext _, AsyncSnapshot<PlayerStats> snap) {
                    final PlayerStats? stats = snap.data;
                    final theme = Theme.of(ctx);
                    Widget body;
                    if (stats == null || stats.isEmpty) {
                      body = Padding(
                        padding: const EdgeInsets.symmetric(
                            vertical: AppTokens.spaceMd),
                        child: Text(l10n.playerStatsUnavailable),
                      );
                    } else {
                      final bool isHw = stats.isHardwareDecoding;
                      // 解码状态醒目标注：硬解绿 / 软解橙，附带 hwdec-current 原值。
                      final String decodeText = isHw
                          ? '${l10n.playerStatsHardware} (${stats.hwdecCurrent})'
                          : l10n.playerStatsSoftware;
                      final ColorScheme scheme = Theme.of(ctx).colorScheme;
                      final Color decodeColor = isHw
                          ? AppStatusColors.ok(scheme)
                          : AppStatusColors.warn(scheme);
                      String orDash(String? v) =>
                          (v == null || v.isEmpty) ? '—' : v;
                      final String resolution =
                          (stats.width != null && stats.height != null)
                              ? '${stats.width}×${stats.height}'
                              : '—';
                      final String drops =
                          '${stats.frameDropCount ?? 0} / ${stats.decoderFrameDropCount ?? 0}';
                      final String bitrate = stats.videoBitrate == null
                          ? '—'
                          : '${(stats.videoBitrate! / 1000000).toStringAsFixed(2)} Mbps';
                      final String buffering = stats.cacheBufferingState == null
                          ? '—'
                          : '${stats.cacheBufferingState}%';
                      body = Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          _statsRow(
                            l10n.playerStatsDecoder,
                            decodeText,
                            valueStyle: theme.textTheme.bodyMedium?.copyWith(
                              color: decodeColor,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          _statsRow(l10n.playerStatsVideoCodec,
                              orDash(stats.videoCodec)),
                          _statsRow(l10n.playerStatsPixelFormat,
                              orDash(stats.videoFormat)),
                          _statsRow(l10n.playerStatsResolution, resolution),
                          _statsRow(l10n.playerStatsDroppedFrames, drops),
                          _statsRow(l10n.playerStatsBitrate, bitrate),
                          _statsRow(l10n.playerStatsBuffering, buffering),
                        ],
                      );
                    }
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(l10n.playerStats,
                            style: theme.textTheme.titleMedium),
                        const SizedBox(height: AppTokens.spaceSm),
                        body,
                        const SizedBox(height: AppTokens.spaceMd),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: Text(l10n.close),
                          ),
                        ),
                      ],
                    );
                  },
                );
              },
            ),
          ),
        ),
      ),
    ).whenComplete(() => refreshTimer?.cancel());
  }

  /// 播放统计面板的单行「标签: 值」。标签列上限 140（窄屏自动让位，值换行）。
  Widget _statsRow(String label, String value, {TextStyle? valueStyle}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 140),
            child: Text(label),
          ),
          const SizedBox(width: AppTokens.spaceSm),
          Expanded(child: Text(value, style: valueStyle, softWrap: true)),
        ],
      ),
    );
  }

  /// #4 A4-#4: 使用外部播放器打开当前 URL。
  Future<void> _playInExternal(AppLocalizations l10n) async {
    final url = _playUrl ?? widget.episode.url;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    final uri = Uri.tryParse(url);
    if (uri == null) {
      messenger.showSnackBar(
          SnackBar(content: Text(l10n.errorParse)));
      return;
    }
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        messenger.showSnackBar(
            SnackBar(content: Text(l10n.browseNetworkConnect)));
      }
    } on Object {
      if (mounted) {
        messenger.showSnackBar(
            SnackBar(content: Text(l10n.errorNetwork)));
      }
    }
  }
}

/// 弹幕开关区域组件：根据开关状态显示不同 UI。
///
/// **开启时**：高亮背景 + 实心图标 + 发送按钮 + 设置按钮
/// **关闭时**：透明背景 + 空心图标（仅开关）
class _DanmakuToggle extends StatelessWidget {
  const _DanmakuToggle({
    super.key,
    required this.isOn,
    required this.l10n,
    required this.onToggle,
    this.onSend,
    this.onSettings,
    this.onLongPressSettings,
  });

  final bool isOn;
  final AppLocalizations l10n;
  final VoidCallback onToggle;
  final VoidCallback? onSend;
  final VoidCallback? onSettings;
  final VoidCallback? onLongPressSettings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!isOn) {
      // 关闭态：仅显示空心开关按钮，紧凑尺寸
      return IconButton(
        icon: const Icon(Icons.comment_outlined, color: Colors.white54),
        iconSize: 22,
        tooltip: l10n.danmaku,
        onPressed: onToggle,
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        padding: const EdgeInsets.all(4),
      );
    }

    // 开启态：高亮背景 + 实心图标 + 发送 + 设置
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 2),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withOpacity(0.25),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.primary.withOpacity(0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // 弹幕开关（开启态，实心图标）
          IconButton(
            icon: Icon(Icons.comment, color: theme.colorScheme.primary, size: 20),
            tooltip: l10n.danmaku,
            onPressed: onToggle,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            padding: EdgeInsets.zero,
          ),
          // 发送弹幕按钮（仅开启时显示）
          if (onSend != null)
            IconButton(
              icon: const Icon(Icons.send, color: Colors.white70, size: 18),
              tooltip: l10n.danmakuSend ?? 'Send danmaku',
              onPressed: onSend,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              padding: EdgeInsets.zero,
            ),
          // 弹幕设置（长按=弹幕源选择）
          if (onSettings != null)
            IconButton(
              icon: const Icon(Icons.settings, color: Colors.white70, size: 18),
              tooltip: l10n.danmakuSettings,
              onPressed: onSettings,
              onLongPress: onLongPressSettings,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              padding: EdgeInsets.zero,
            ),
        ],
      ),
    );
  }
}

/// 控制按钮（透明背景圆形）。
class _ControlButton extends StatelessWidget {
  const _ControlButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.tooltip,
    this.onLongPress,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, color: Colors.white),
      tooltip: tooltip,
      onPressed: onTap,
      onLongPress: onLongPress,
    );
  }
}

/// 横向滚动文字（Marquee）：当文本超出可用宽度时自动循环滚动；
/// 文本能完整显示时静止不动（无动画开销）。
///
/// 用 [SingleChildScrollView] 承载文本，由 [AnimationController] 驱动
/// [_scrollController] 手动滚动；避免 ListView.builder(itemCount:null) 在
/// 顶栏 Row 内触发无限高度布局崩溃。
class _MarqueeText extends StatefulWidget {
  const _MarqueeText({
    required this.text,
    required this.style,
  });

  final String text;
  final TextStyle style;

  @override
  State<_MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<_MarqueeText>
    with SingleTickerProviderStateMixin {
  final ScrollController _scrollController = ScrollController();
  // 必须在 initState（context 仍有效）创建，禁止用 late final 懒初始化——
  // 若文本从未滚动、dispose 时首次访问该字段会现场 createTicker 并读取已失活的
  // TickerMode 祖先，抛「Looking up a deactivated widget's ancestor is unsafe」。
  late AnimationController _animController;

  /// 文本是否需要滚动（测量后确定）。
  bool _scrollable = false;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    )..addListener(_onAnimTick);
    // 延迟一帧测量文本宽度，决定是否需要滚动。
    WidgetsBinding.instance.addPostFrameCallback(_measure);
  }

  void _measure(_) {
    final renderer = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();
    // 容器可用宽度估算（减去返回键 + 右侧图标的大致占用）。
    final maxWidth = MediaQuery.of(context).size.width - 160;
    if (mounted && renderer.width > maxWidth) {
      // 标记需要滚动并启动动画（setState 异步，故动画启动不依赖刚刚写入的 _scrollable）。
      if (mounted) setState(() => _scrollable = true);
      if (!_animController.isAnimating) {
        _animController.repeat();
      }
    }
  }

  void _onAnimTick() {
    if (!_scrollable || !_scrollController.hasClients) return;
    final max = _scrollController.position.maxScrollExtent;
    if (max <= 0) return;
    // 滚到末尾（留 40px 间隙）后回环到起点，形成循环滚动。
    final span = max + 40;
    final v = (_animController.value * span) % span;
    _scrollController.jumpTo(v);
  }

  @override
  void didUpdateWidget(covariant _MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.style != widget.style) {
      _scrollable = false;
      _animController.stop();
      WidgetsBinding.instance.addPostFrameCallback(_measure);
    }
  }

  @override
  void dispose() {
    _animController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      controller: _scrollController,
      physics: const NeverScrollableScrollPhysics(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Text(widget.text, style: widget.style),
      ),
    );
  }
}

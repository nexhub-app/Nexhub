/// 统一嗅探页（主页浏览页「嗅探」入口，与浏览页风格统一）。
///
/// 在 [BrowsePage]（本地文件 / 网络文件 / 网页爬取 / RSS）之外，提供第五个
/// 入口。采用「网络拦截 + DOM 检测 + API 钩子」方法论（clean-room 自研实现，
/// 开源嗅探，不引入其代码）：
/// - 文档起始注入 JS 钩子（fetch/XHR/HTMLMediaElement/MediaSource/
/// URL.createObjectURL），经 `callHandler('sniffer')` 回传 Dart；
/// - `onLoadResource` 被动兜底扩大召回；
/// - 加载完成后执行 DOM 深度扫描；
/// - 规则（assets/sniffer/sniffer_rules.json）过滤广告 / 缩略图 / beacon。
/// 结果可复制 / 内置播放器播放 / 保存到下载目录。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:nexhub/core/models/episode.dart';
import 'package:nexhub/core/models/plugin_config.dart';
import 'package:nexhub/core/network/model/effective_network_profile.dart';
import 'package:nexhub/core/network/network_config_service.dart';
import 'package:nexhub/core/network/runtime/webview_source_network.dart';
import 'package:nexhub/core/scraper/http_fetcher.dart';
import 'package:nexhub/core/settings/general_settings.dart';
import 'package:nexhub/core/navigation/app_page_route.dart';
import 'package:nexhub/core/sniffer/sniffer_bridge.dart' show SnifferBridge;
import 'package:nexhub/core/sniffer/sniffer_engine.dart' show SnifferEngine;
import 'package:nexhub/core/sniffer/sniffer_models.dart'
    show MediaKind, SniffFilter, SniffedMedia;
import 'package:nexhub/core/theme/app_tokens.dart';
import 'package:nexhub/core/theme/app_theme.dart';
import 'package:nexhub/core/utils/app_haptics.dart';
import 'package:nexhub/core/widgets/app_url_input_bar.dart';
import 'package:nexhub/features/player/presentation/video_player_screen.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:path_provider/path_provider.dart';
import '../../../core/widgets/app_glass_bar.dart';

/// 黑夜模式下注入网页的暗色样式（反向滤镜 + 媒体二次反转发回原色）。
///
/// 仅在 App 处于深色主题时注入，浅色模式与嗅探逻辑完全不受影响。
/// 对已是深色的站点会被反转为浅色（已知局限），但视频站多为浅色，收益明显。
const String _kDarkModeCss = '''
(function(){
  var s = document.getElementById('nexhub_dark_css');
  if(!s){ s=document.createElement('style'); s.id='nexhub_dark_css'; (document.head||document.documentElement).appendChild(s); }
  s.textContent='html{filter:invert(1) hue-rotate(180deg) !important;background:#0b0b0b !important;}'
    + 'img,picture,video,canvas,iframe,embed,object{filter:invert(1) hue-rotate(180deg) !important;}';
})();
''';

/// 嗅探页。
class BrowseSnifferScreen extends StatefulWidget {
  final String? initialUrl;

  /// 关联源（可选）：非 null 时 WebView 与下载/探测都跟随该源的网络覆盖
  /// （内置 hosts / DoH / 代理）；为 null 时挂当前生效环境（若有）。
  final PluginConfig? source;

  const BrowseSnifferScreen({super.key, this.initialUrl, this.source});

  @override
  State<BrowseSnifferScreen> createState() => _BrowseSnifferScreenState();
}

class _BrowseSnifferScreenState extends State<BrowseSnifferScreen> {
  final TextEditingController _addressController = TextEditingController();
  final FocusNode _addressFocus = FocusNode();
  InAppWebViewController? _controller;
  bool _loading = false;
  bool _pageLoaded = false;

  /// 源级有效档案（无源 → null → 默认档案）：下载/HEAD 探测经它跟随源 hosts。
  late final EffectiveNetworkProfile? _net = widget.source == null
      ? null
      : NetworkConfigService.instance.effectiveFor(widget.source);

  /// WebView2 环境（Windows --proxy-server 跟随）；其余平台 / 无覆盖时为 null。
  WebViewEnvironment? _env;

  /// 网络跟随就绪前不创建 WebView（env 是创建期参数，后补无效）。
  bool _envReady = false;

  /// applyForSource 的在途 Future：dispose 时先等它完成再 release，保证引用
  /// 计数严格配对。
  Future<void>? _applyFuture;

  /// 页内沉浸式播放模式：blob/mse 串流无法在外部播放器打开时，将当前 WebView 作为播放器铺满屏幕。
  bool _inPagePlay = false;

  bool _deep = true;
  String? _hookJs;

  /// 当前页面地址（onLoadStart/Stop 同步维护；作播放 Referer 兜底与页内播放展示）。
  String _pageUrl = '';
  // 使用进程级共享引擎：嗅探结果在嗅探页与源视频路由 WebView 间累积。
  final SnifferEngine _engine = SnifferEngine.shared;
  late final SnifferBridge _bridge = SnifferBridge();
  SniffFilter _filter = SniffFilter.all;

  /// 文件大小探测结果（url -> 字节数），用于结果列表副标题展示。
  final Map<String, int> _sizes = <String, int>{};
  bool _probing = false;

  /// 嗅探结果刷新节流：重资源页面短时间内会上报成百条 URL，
  /// 每条都 setState 会把 UI 线程打满（与 WebView 加载互相拖慢），
  /// 故合并为最多每 200ms 刷一次。
  Timer? _updateThrottle;

  /// 加载看门狗：个别 WebView 版本 / 持续缓冲的视频页在 release 包下可能永不触发
  /// onLoadStop / onProgressChanged(>=100)，导致 [_loading] 永久为 true（顶部一直转圈、
  /// 结果区空）。超时后强制解除加载态并收尾嗅探，保证功能可用。
  Timer? _loadWatchdog;

  /// 结果面板折叠态：初始折叠仅显示拖拽把手，WebView 独占剩余空间。
  bool _panelCollapsed = true;

  /// 用户拖拽自定义的面板内容高度；null 表示尚未展开过（首次展开按可用高度
  /// 的四成取默认）。会话内保留，再次折叠后展开回到该高度。
  double? _panelHeight;

  /// 是否正在拖拽把手：拖拽中高度必须逐帧跟手（禁用动画），
  /// 点按切换折叠/展开时才有平滑过渡。
  bool _panelDragging = false;

  /// 面板顶部拖拽把手条高度。
  static const double _kHandleHeight = 32;

  /// 面板内容区最小高度：展开态向下拖低于此值即折叠。
  static const double _kPanelMinHeight = 140;

  static double _clampPanelHeight(double value, double max) {
    if (value < _kPanelMinHeight) return _kPanelMinHeight;
    if (value > max) return max;
    return value;
  }

  void _startLoadWatchdog() {
    _loadWatchdog?.cancel();
    _loadWatchdog = Timer(const Duration(seconds: 12), () {
      if (mounted && _loading) {
        setState(() {
          _loading = false;
          _pageLoaded = true;
        });
        // 加载态兜底解除后，仍补做深度扫描与文件大小探测，确保结果完整。
        _bridge.deepScan();
        _scheduleProbe();
      }
    });
  }

  void _stopLoadWatchdog() => _loadWatchdog?.cancel();

  void _onEngineUpdate() {
    if (_updateThrottle?.isActive == true) return;
    _updateThrottle = Timer(const Duration(milliseconds: 200), () {
      if (mounted) setState(() {});
    });
  }

  @override
  void initState() {
    super.initState();
    _engine.onUpdate = _onEngineUpdate;
    if (widget.initialUrl != null) {
      _addressController.text = widget.initialUrl!;
    }
    final source = widget.source;
    if (source == null) {
      _env = WebviewSourceNetwork.instance.activeEnvironment;
      _envReady = true;
    } else {
      _applyFuture = WebviewSourceNetwork.instance
          .applyForSource(source)
          .then((_) async {
        final env = WebviewSourceNetwork.instance.activeEnvironment;
        if (mounted) {
          setState(() {
            _env = env;
            _envReady = true;
          });
        }
      });
    }
    _loadHook();
  }

  @override
  void dispose() {
    _updateThrottle?.cancel();
    _stopLoadWatchdog();
    if (_engine.onUpdate == _onEngineUpdate) _engine.onUpdate = null;
    _addressController.dispose();
    _addressFocus.dispose();
    if (widget.source != null) {
      final apply = _applyFuture;
      if (apply != null) {
        // dispose 先于 apply 完成时，等 apply 落地（含引用计数自增）后再释放。
        unawaited(apply.whenComplete(
          () => WebviewSourceNetwork.instance.releaseForSource(),
        ));
      } else {
        unawaited(WebviewSourceNetwork.instance.releaseForSource());
      }
    }
    super.dispose();
  }

  Future<void> _loadHook() async {
    try {
      final js = await rootBundle.loadString('assets/sniffer/sniffer_hook.js');
      if (mounted) setState(() => _hookJs = js);
    } catch (_) {
      // 钩子加载失败也不阻断：仍有 onLoadResource 被动兜底；置空哨兵避免永久转圈。
      if (mounted) setState(() => _hookJs = '');
    }
  }

  String _normalizeUrl(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return '';
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return trimmed;
    }
    if (!trimmed.contains('.') || trimmed.contains(' ')) {
      return 'https://www.google.com/search?q=${Uri.encodeComponent(trimmed)}';
    }
    return 'https://$trimmed';
  }

  Future<void> _navigate(String input) async {
    final url = _normalizeUrl(input);
    if (url.isEmpty) return;
    _addressController.text = url;
    _addressFocus.unfocus();
    final controller = _controller;
    if (controller == null) return;
    await controller.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  void _copyUrl(String url) {
    Clipboard.setData(ClipboardData(text: url));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context).snifferCopy)),
    );
  }

  void _playUrl(SniffedMedia media) {
    final url = media.url;
    final isPageOnly = url.startsWith('blob:') ||
        url.startsWith('mediasource:') ||
        media.sourceTag == 'mse';
    if (isPageOnly) {
      // blob/MSE 串流无法在外部播放器打开，进入页内沉浸式播放（当前 WebView 即播放器）。
      if (mounted) setState(() => _inPagePlay = true);
      return;
    }
    final title = Uri.tryParse(url)?.pathSegments.isNotEmpty == true
        ? Uri.parse(url).pathSegments.last
        : url;
    // 防盗链请求头：优先捕获时记录的 Referer，缺省用当前页面地址兜底
    //（嗅探到的 m3u8 大多校验 Referer，不带必 403）。
    final ref = (media.referer?.isNotEmpty == true) ? media.referer! : _pageUrl;
    final headers = ref.isNotEmpty ? <String, String>{'Referer': ref} : null;
    Navigator.of(context).push(
      AppPageRoute<void>(
        builder: (_) => VideoPlayerScreen(
          title: title,
          episode: Episode(id: url, title: title, url: url),
          sourceId: '',
          itemId: url,
          directUrl: url,
          directHeaders: headers,
          restoreProgress:
              GeneralSettingsStore.instance.settings.rememberPosition,
        ),
      ),
    );
  }

  Future<void> _saveUrl(String url, String? referer) async {
    final l10n = AppLocalizations.of(context);
    try {
      final dir = await getApplicationDocumentsDirectory();
      final outDir = Directory('${dir.path}/NexHub/sniffer');
      await outDir.create(recursive: true);
      final name = _fileName(url);
      final outFile = '${outDir.path}/$name';
      final headers = <String, String>{};
      if (referer != null && referer.isNotEmpty) headers['Referer'] = referer;
      // 走源档案客户端：命中源内置 hosts / DoH（裸 Dio 走系统 DNS，
      // 被污染域名的嗅探结果会下载失败）。
      await HttpFetcher.instance.downloadFile(
        url,
        outFile,
        headers: headers,
        net: _net,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${l10n.snifferSave}: $name')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${l10n.snifferSave} ${l10n.failed}: $e')),
        );
      }
    }
  }

  String _fileName(String url) {
    final uri = Uri.tryParse(url);
    final seg = uri?.pathSegments.where((s) => s.isNotEmpty).toList();
    final last = seg?.isNotEmpty == true ? seg!.last : 'video';
    if (last.contains('.')) return last;
    final ext = _engineExt(url);
    return '${DateTime.now().microsecondsSinceEpoch}.$ext';
  }

  String _engineExt(String url) {
    final m = RegExp(r'\.([a-z0-9]+)(?:\?|#|$)', caseSensitive: false)
        .firstMatch(url.toLowerCase());
    return m?.group(1) ?? 'mp4';
  }

  /// 防抖触发文件大小探测：页面加载后稍等，再对尚无大小的媒体发 HEAD 请求。
  void _scheduleProbe() {
    if (_probing) return;
    _probing = true;
    Future<void>.delayed(const Duration(milliseconds: 800), () {
      _probing = false;
      if (mounted) _probeSizes();
    });
  }

  /// 对当前列表中「尚无大小」的媒体用 HEAD 请求探测 content-length。
  /// 并发上限 3，结果写入 [_sizes] 并刷新 UI；防盗链站点带 Referer 头。
  Future<void> _probeSizes() async {
    final pending = _engine.items
        .where((m) =>
            (m.url.startsWith('http://') || m.url.startsWith('https://')) &&
            !_sizes.containsKey(m.url))
        .toList();
    if (pending.isEmpty) return;
    var active = 0;
    Future<void> probeOne(SniffedMedia m) async {
      try {
        final headers = <String, String>{};
        if (m.referer != null && m.referer!.isNotEmpty) {
          headers['Referer'] = m.referer!;
        }
        final resp = await HttpFetcher.instance.head(
          m.url,
          headers: headers,
          net: _net,
        );
        // 响应头键大小写不保证，无关大小写取 content-length（显式循环取值，
        // 避免闭包内赋值导致流分析无法提升非空）。
        List<String>? lenValues;
        for (final e in resp.entries) {
          if (e.key.toLowerCase() == 'content-length' && e.value.isNotEmpty) {
            lenValues = e.value;
            break;
          }
        }
        final bytes =
            lenValues == null ? null : int.tryParse(lenValues.first);
        if (bytes != null && mounted) {
          _sizes[m.url] = bytes;
          setState(() {});
        }
      } catch (_) {
        // 探测失败不影响其它项（CORS/防盗链/HEAD 不支持都可能出现）。
      }
    }

    // 并发受限（≤3）地逐个发起，避免一次性打爆网络。
    final queue = List<SniffedMedia>.from(pending);
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final m = queue.removeAt(0);
        await probeOne(m);
      }
    }

    final workers = <Future<void>>[];
    final concurrency = pending.length < 3 ? pending.length : 3;
    for (var i = 0; i < concurrency; i++) {
      active++;
      workers.add(worker().whenComplete(() => active--));
    }
    await Future.wait(workers);
  }

  /// 人类可读的文件大小。
  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    return '${(mb / 1024).toStringAsFixed(2)} GB';
  }

  List<SniffedMedia> get _displayList => _engine.filtered(_filter);

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool isDark = scheme.brightness == Brightness.dark;

    // 钩子与网络跟随就绪前先占位：确保 initialUserScripts 在 WebView 创建时
    // 已就位；webViewEnvironment 是创建期参数，创建后再挂无效。
    if (_hookJs == null || !_envReady) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.snifferTitle)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          tooltip: l10n.cancel,
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(l10n.snifferTitle),
        actions: <Widget>[
          IconButton(
            icon: Icon(_deep
                ? Icons.auto_fix_high_rounded
                : Icons.auto_fix_high_rounded),
            tooltip: l10n.snifferDeep,
            color: _deep ? scheme.primary : null,
            onPressed: () {
              setState(() => _deep = !_deep);
              _bridge.deep = _deep;
              if (_deep) _bridge.deepScan();
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep_rounded),
            tooltip: l10n.snifferClear,
            onPressed: _engine.count == 0
                ? null
                : () {
                    _engine.clear();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(l10n.snifferClear)),
                    );
                  },
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          // 面板高度上限/默认展开值按可用空间动态计算，不写死像素。
          final double maxPanelHeight = constraints.maxHeight * 0.75;
          final double defaultPanelHeight = constraints.maxHeight * 0.4;
          return Column(
            children: <Widget>[
              if (!_inPagePlay)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppTokens.spaceMd,
                    AppTokens.spaceMd,
                    AppTokens.spaceMd,
                    AppTokens.spaceXs,
                  ),
                  child: AppUrlInputBar(
                    controller: _addressController,
                    hintText: l10n.snifferAddressHint,
                    submitLabel: l10n.snifferGo,
                    onSubmit: _navigate,
                  ),
                ),
              // 浏览器主体：占据结果面板之外的剩余空间
              Expanded(
                child: Stack(
                  children: <Widget>[
                    InAppWebView(
                      webViewEnvironment: _env,
                      initialUrlRequest: widget.initialUrl != null
                          ? URLRequest(url: WebUri(widget.initialUrl!))
                          : null,
                      initialSettings: InAppWebViewSettings(
                        javaScriptEnabled: true,
                        mediaPlaybackRequiresUserGesture: false,
                        // 插件默认 false：不开这个开关 onLoadResource 永远不回调。
                        useOnLoadResource: true,
                        // 不开 useShouldInterceptRequest：Android 端该回调是「同步阻塞」
                        // 的桥接调用（网络线程逐个请求等待 Dart 往返），重资源页面会被
                        // 拖到近乎卡死（表现为一直加载）。被动捕获靠 JS 钩子 +
                        // onLoadResource 已足够；Referer 播放时用页面地址兜底。
                        // https 页面里的 http 串流不拦（嗅探工具需要最大召回）。
                        mixedContentMode:
                            MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
                        // 暗色主题下让 WebView 背景透明，避免初始化/页面底色为白块
                        // （与已注入的 _kDarkModeCss 配合，露出 App 的暗色 surface）。
                        transparentBackground: true,
                      ),
                      initialUserScripts: UnmodifiableListView<UserScript>(
                        <UserScript>[
                          if (_hookJs != null && _hookJs!.isNotEmpty)
                            SnifferBridge.userScript(_hookJs!),
                          if (isDark)
                            UserScript(
                              source: _kDarkModeCss,
                              injectionTime:
                                  UserScriptInjectionTime.AT_DOCUMENT_END,
                            ),
                        ],
                      ),
                      onWebViewCreated: (controller) {
                        _controller = controller;
                        _bridge.attach(controller);
                      },
                      onLoadStart: (controller, url) {
                        if (mounted) {
                          setState(() {
                            _loading = true;
                            if (url != null) _pageUrl = url.toString();
                          });
                          _startLoadWatchdog();
                        }
                      },
                      // onLoadStop 在部分重定向 / SPA 页面上可能迟迟不触发，
                      // 用加载进度到 100 兜底清掉加载态，避免转圈卡死。
                      onProgressChanged: (controller, progress) {
                        if (progress >= 100 &&
                            mounted &&
                            (_loading || !_pageLoaded)) {
                          _stopLoadWatchdog();
                          setState(() {
                            _loading = false;
                            _pageLoaded = true;
                          });
                          _scheduleProbe();
                        }
                      },
                      // 主文档加载失败（DNS/SSL/超时等）也要清掉加载态。
                      onReceivedError: (controller, request, error) {
                        if (request.isForMainFrame == true && mounted) {
                          _stopLoadWatchdog();
                          setState(() {
                            _loading = false;
                            _pageLoaded = true;
                          });
                        }
                      },
                      onLoadStop: (controller, url) async {
                        final bool dark =
                            Theme.of(context).brightness == Brightness.dark;
                        if (mounted) {
                          _stopLoadWatchdog();
                          setState(() {
                            _loading = false;
                            _pageLoaded = true;
                            if (url != null) _pageUrl = url.toString();
                          });
                        }
                        // 深色主题下，页面加载完成后补注入暗色样式（覆盖主题切换 /
                        // SPA 路由等 initialUserScripts 之外的场景）。
                        if (dark) {
                          await controller.evaluateJavascript(
                              source: _kDarkModeCss);
                        }
                        await _bridge.deepScan();
                        // 页面加载完成后探测已捕获媒体的文件大小（带防抖）。
                        _scheduleProbe();
                      },
                      onLoadResource: (controller, resource) {
                        _bridge.onResource(resource.url?.toString());
                      },
                    ),
                    if (_loading)
                      const Align(
                        alignment: Alignment.topCenter,
                        child: LinearProgressIndicator(),
                      ),
                    if (widget.initialUrl != null && !_pageLoaded)
                      const Center(child: CircularProgressIndicator()),
                  ],
                ),
              ),
              // 嗅探结果面板（高度可拖拽自定义，默认折叠）
              if (!_inPagePlay)
                _buildResultPanel(
                  l10n,
                  scheme,
                  maxPanelHeight: maxPanelHeight,
                  defaultPanelHeight: defaultPanelHeight,
                ),
              if (_inPagePlay) _buildInPagePlayBar(l10n, scheme),
            ],
          );
        },
      ),
    );
  }

  /// 嗅探结果面板：高度可拖拽自定义，初始折叠为一条把手。
  ///
  /// - 把手点按在折叠/展开间切换（平滑动画）；上下拖动实时调整高度，
  ///   展开态继续向下拖过最小高度即折叠；
  /// - 折叠时仅剩把手（右缘叠加结果计数徽标），WebView 独占剩余空间。
  Widget _buildResultPanel(
    AppLocalizations l10n,
    ColorScheme scheme, {
    required double maxPanelHeight,
    required double defaultPanelHeight,
  }) {
    final bool collapsed = _panelCollapsed;
    // 折叠时补足底部系统手势条避让，保证把手可点。
    final double bottomInset =
        collapsed ? MediaQuery.paddingOf(context).bottom : 0;
    final double contentHeight = collapsed
        ? 0
        : _clampPanelHeight(_panelHeight ?? defaultPanelHeight, maxPanelHeight);
    return AnimatedContainer(
      duration:
          _panelDragging ? Duration.zero : const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      height: _kHandleHeight + (collapsed ? bottomInset : contentHeight),
      decoration: BoxDecoration(
        color: AppTheme.cardContainer(scheme),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _buildDragHandle(
            l10n,
            scheme,
            collapsed: collapsed,
            maxPanelHeight: maxPanelHeight,
            defaultPanelHeight: defaultPanelHeight,
          ),
          if (!collapsed)
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppTokens.spaceMd,
                      AppTokens.spaceSm,
                      AppTokens.spaceMd,
                      AppTokens.spaceXs,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          l10n.snifferHint,
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                        ),
                        const SizedBox(height: AppTokens.spaceXs),
                        _buildFilterChips(l10n, scheme),
                      ],
                    ),
                  ),
                  Expanded(child: _buildResultList(l10n, scheme)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 面板顶部拖拽把手：grabber 胶囊 + 折叠态右缘的结果计数徽标。
  Widget _buildDragHandle(
    AppLocalizations l10n,
    ColorScheme scheme, {
    required bool collapsed,
    required double maxPanelHeight,
    required double defaultPanelHeight,
  }) {
    final int count = _displayList.length;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragStart: (_) => _panelDragging = true,
      onVerticalDragUpdate: (details) => _onPanelDrag(
        details.delta.dy,
        maxPanelHeight: maxPanelHeight,
        defaultPanelHeight: defaultPanelHeight,
      ),
      onVerticalDragEnd: (_) => _panelDragging = false,
      onVerticalDragCancel: () => _panelDragging = false,
      onTap: () {
        setState(() {
          if (_panelCollapsed) {
            _panelCollapsed = false;
            _panelHeight ??= defaultPanelHeight;
          } else {
            _panelCollapsed = true;
          }
        });
      },
      child: Semantics(
        label: l10n.snifferPanelHandle,
        child: SizedBox(
          height: _kHandleHeight,
          child: Stack(
            alignment: Alignment.center,
            children: <Widget>[
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(AppTokens.radiusFull),
                ),
              ),
              if (collapsed && count > 0)
                Positioned(
                  right: AppTokens.spaceMd,
                  child: Text(
                    l10n.snifferResultCount(count),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 把手拖拽：折叠态向上拖即展开（后续拖动继续跟手调高度）；
  /// 展开态上拖增大、下拖减小，低于最小高度即折叠。
  void _onPanelDrag(
    double dy, {
    required double maxPanelHeight,
    required double defaultPanelHeight,
  }) {
    if (_panelCollapsed) {
      if (dy < 0) {
        setState(() {
          _panelCollapsed = false;
          _panelHeight ??= defaultPanelHeight;
        });
      }
      return;
    }
    final double current = _clampPanelHeight(
      _panelHeight ?? defaultPanelHeight,
      maxPanelHeight,
    );
    final double next = current - dy;
    if (next < _kPanelMinHeight) {
      // 保留折叠前高度，再次展开回到该值。
      setState(() => _panelCollapsed = true);
    } else {
      setState(() {
        _panelHeight = _clampPanelHeight(next, maxPanelHeight);
      });
    }
  }

  /// 页内沉浸式播放底部栏：当前 WebView 即播放器（blob/mse 无法在外部播放器打开）。
  Widget _buildInPagePlayBar(AppLocalizations l10n, ColorScheme scheme) {
    // 注意：getUrl() 是 Future，直接 toString 会得到 "Instance of 'Future'"，
    // 故改用 onLoadStart/Stop 同步维护的 _pageUrl。
    final pageUrl = _pageUrl;
    return Container(
      padding: EdgeInsets.fromLTRB(
        AppTokens.spaceMd,
        AppTokens.spaceSm,
        AppTokens.spaceMd,
        AppTokens.spaceMd + MediaQuery.paddingOf(context).bottom,
      ),
      decoration: BoxDecoration(
        color: AppTheme.cardContainer(scheme),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(bottom: AppTokens.spaceSm),
            child: Text(
              l10n.snifferInPagePlaying,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.primary,
                  ),
            ),
          ),
          Row(
            children: <Widget>[
              Expanded(
                child: FilledButton.icon(
                  icon: const Icon(Icons.copy_rounded),
                  label: Text(l10n.snifferCopyPageLink),
                  onPressed: () {
                    if (pageUrl.isEmpty) return;
                    Clipboard.setData(ClipboardData(text: pageUrl));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(l10n.snifferCopy)),
                    );
                  },
                ),
              ),
              const SizedBox(width: AppTokens.spaceSm),
              IconButton(
                icon: const Icon(Icons.close_rounded),
                tooltip: l10n.close,
                onPressed: () {
                  if (mounted) setState(() => _inPagePlay = false);
                },
              ),
            ],
          ),
          const SizedBox(height: AppTokens.spaceXs),
          Text(
            l10n.snifferInPageHint,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }

  /// 类型筛选 chips。
  Widget _buildFilterChips(AppLocalizations l10n, ColorScheme scheme) {
    final chips = <SniffFilter, String>{
      SniffFilter.all: l10n.snifferFilterAll,
      SniffFilter.video: l10n.snifferFilterVideo,
      SniffFilter.audio: l10n.snifferFilterAudio,
      SniffFilter.other: l10n.snifferFilterOther,
    };
    return Wrap(
      spacing: AppTokens.spaceXs,
      children: chips.entries.map((e) {
        return ChoiceChip(
          label: Text(e.value),
          selected: _filter == e.key,
          visualDensity: VisualDensity.compact,
          onSelected: (_) {
            AppHaptics.selectionClick();
            setState(() => _filter = e.key);
          },
        );
      }).toList(),
    );
  }

  Widget _buildResultList(AppLocalizations l10n, ColorScheme scheme) {
    final list = _displayList;
    if (list.isEmpty) {
      return Center(
        child: Text(
          l10n.snifferNoResult,
          style: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
      );
    }
    return ListView.separated(
      padding: EdgeInsets.fromLTRB(
        AppTokens.spaceMd,
        0,
        AppTokens.spaceMd,
        context.glassBarBottomInset,
      ),
      itemCount: list.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final media = list[index];
        return ListTile(
          dense: true,
          leading: Chip(
            label: Text(media.typeLabel),
            visualDensity: VisualDensity.compact,
          ),
          title: Text(
            media.url,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          subtitle: _buildSubtitle(media, l10n),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              IconButton(
                icon: const Icon(Icons.copy_rounded, size: 20),
                tooltip: l10n.snifferCopy,
                onPressed: () => _copyUrl(media.url),
              ),
              IconButton(
                icon: const Icon(Icons.play_arrow_rounded, size: 20),
                tooltip: l10n.snifferPlay,
                onPressed: () => _playUrl(media),
              ),
              IconButton(
                icon: const Icon(Icons.download_rounded, size: 20),
                tooltip: l10n.snifferSave,
                onPressed: () => _saveUrl(
                  media.url,
                  (media.referer?.isNotEmpty == true)
                      ? media.referer
                      : _pageUrl,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSubtitle(SniffedMedia media, AppLocalizations l10n) {
    final parts = <String>[];
    if (media.sourceTag != null && media.sourceTag!.isNotEmpty) {
      parts.add(media.sourceTag!);
    }
    if (media.kind == MediaKind.video) parts.add(l10n.snifferFilterVideo);
    if (media.kind == MediaKind.audio) parts.add(l10n.snifferFilterAudio);
    if (media.contentLength != null) {
      parts.add(_formatSize(media.contentLength!));
    } else if (_sizes.containsKey(media.url)) {
      parts.add(_formatSize(_sizes[media.url]!));
    } else {
      parts.add(l10n.snifferSizeUnknown);
    }
    return Text(
      parts.join(' · '),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
    );
  }
}

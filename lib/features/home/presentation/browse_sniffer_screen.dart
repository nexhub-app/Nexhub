/// 统一嗅探页（主页浏览页「嗅探」入口，与浏览页风格统一）。
///
/// 在 [BrowsePage]（本地文件 / 网络文件 / 网页爬取 / RSS）之外，提供第五个
/// 入口。采用「网络拦截 + DOM 检测 + API 钩子」方法论（clean-room 借鉴猫抓等
/// 开源嗅探，不引入其代码）：
/// - 文档起始注入 JS 钩子（fetch/XHR/HTMLMediaElement/MediaSource/
///   URL.createObjectURL），经 `callHandler('sniffer')` 回传 Dart；
/// - `onLoadResource` 被动兜底扩大召回；
/// - 加载完成后执行 DOM 深度扫描；
/// - 规则（assets/sniffer/sniffer_rules.json）过滤广告 / 缩略图 / beacon。
/// 结果可复制 / 内置播放器播放 / 保存到下载目录。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:nexhub/core/models/episode.dart';
import 'package:nexhub/core/settings/general_settings.dart';
import 'package:nexhub/core/navigation/app_page_route.dart';
import 'package:nexhub/core/sniffer/sniffer_bridge.dart' show SnifferBridge;
import 'package:nexhub/core/sniffer/sniffer_engine.dart' show SnifferEngine;
import 'package:nexhub/core/sniffer/sniffer_models.dart'
    show MediaKind, SniffFilter, SniffedMedia;
import 'package:nexhub/core/theme/app_tokens.dart';
import 'package:nexhub/core/widgets/app_url_input_bar.dart';
import 'package:nexhub/features/player/presentation/video_player_screen.dart';
import 'package:nexhub/generated/app_localizations.dart';
import 'package:path_provider/path_provider.dart';

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

  const BrowseSnifferScreen({super.key, this.initialUrl});

  @override
  State<BrowseSnifferScreen> createState() => _BrowseSnifferScreenState();
}

class _BrowseSnifferScreenState extends State<BrowseSnifferScreen> {
  final TextEditingController _addressController = TextEditingController();
  final FocusNode _addressFocus = FocusNode();
  InAppWebViewController? _controller;
  bool _loading = false;
  bool _pageLoaded = false;
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
    _loadHook();
  }

  @override
  void dispose() {
    _updateThrottle?.cancel();
    _stopLoadWatchdog();
    if (_engine.onUpdate == _onEngineUpdate) _engine.onUpdate = null;
    _addressController.dispose();
    _addressFocus.dispose();
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
      await Dio().download(
        url,
        outFile,
        options: Options(headers: headers, followRedirects: true),
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
    final dio = Dio();
    Future<void> probeOne(SniffedMedia m) async {
      try {
        final headers = <String, String>{};
        if (m.referer != null && m.referer!.isNotEmpty) {
          headers['Referer'] = m.referer!;
        }
        final resp = await dio.head(
          m.url,
          options: Options(headers: headers, followRedirects: true),
        );
        final len = resp.headers.value('content-length');
        if (len != null && mounted) {
          final bytes = int.tryParse(len);
          if (bytes != null) {
            _sizes[m.url] = bytes;
            setState(() {});
          }
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

    // 钩子就绪前先占位，确保 initialUserScripts 在 WebView 创建时已就位。
    if (_hookJs == null) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.snifferTitle)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: l10n.cancel,
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(l10n.snifferTitle),
        actions: <Widget>[
          IconButton(
            icon: Icon(_deep ? Icons.auto_fix_high : Icons.auto_fix_high_outlined),
            tooltip: l10n.snifferDeep,
            color: _deep ? scheme.primary : null,
            onPressed: () {
              setState(() => _deep = !_deep);
              _bridge.deep = _deep;
              if (_deep) _bridge.deepScan();
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
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
      body: Column(
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
          // 浏览器主体
          Expanded(
            flex: _inPagePlay ? 1 : 3,
            child: Stack(
              children: <Widget>[
                InAppWebView(
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
                    mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
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
                          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_END,
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
                    if (progress >= 100 && mounted && (_loading || !_pageLoaded)) {
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
          // 嗅探结果
          if (!_inPagePlay)
          Expanded(
            flex: 2,
            child: Container(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                border: Border(
                  top: BorderSide(
                    color: scheme.outlineVariant.withValues(alpha: 0.5),
                  ),
                ),
              ),
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
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
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
          ),
          if (_inPagePlay) _buildInPagePlayBar(l10n, scheme),
        ],
      ),
    );
  }

  /// 页内沉浸式播放底部栏：当前 WebView 即播放器（blob/mse 无法在外部播放器打开）。
  Widget _buildInPagePlayBar(AppLocalizations l10n, ColorScheme scheme) {
    // 注意：getUrl() 是 Future，直接 toString 会得到 "Instance of 'Future'"，
    // 故改用 onLoadStart/Stop 同步维护的 _pageUrl。
    final pageUrl = _pageUrl;
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppTokens.spaceMd,
        AppTokens.spaceSm,
        AppTokens.spaceMd,
        AppTokens.spaceMd,
      ),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        border: Border(
          top: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
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
                  icon: const Icon(Icons.copy),
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
                icon: const Icon(Icons.close),
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
          onSelected: (_) => setState(() => _filter = e.key),
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
      padding: const EdgeInsets.symmetric(horizontal: AppTokens.spaceMd),
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
                icon: const Icon(Icons.copy, size: 20),
                tooltip: l10n.snifferCopy,
                onPressed: () => _copyUrl(media.url),
              ),
              IconButton(
                icon: const Icon(Icons.play_arrow, size: 20),
                tooltip: l10n.snifferPlay,
                onPressed: () => _playUrl(media),
              ),
              IconButton(
                icon: const Icon(Icons.download, size: 20),
                tooltip: l10n.snifferSave,
                onPressed: () => _saveUrl(
                  media.url,
                  (media.referer?.isNotEmpty == true) ? media.referer : _pageUrl,
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

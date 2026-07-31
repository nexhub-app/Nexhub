/// 统一 HTTP 实例：Cookie 管理、强制隐身（随机延迟 + UA 轮换）、验证感知。
/// 全应用只应有一个 HttpFetcher 实例（spec：headless WebView 加载前把 Cookie 写入共享 CookieManager）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:fast_gbk/fast_gbk.dart';
import '../network/model/effective_network_profile.dart';
import '../network/network_config_service.dart';
import '../network/runtime/network_client_builder.dart';
import '../services/config_loader.dart';
import 'package:flutter/foundation.dart';
import 'cookie_store.dart';
import 'verification_detector.dart';

/// 浏览器指纹档案：UA 与 `Sec-Ch-Ua` 品牌必须配套，否则会自爆（WAF 一秒识破）。
///
/// 每个档案都对应一个真实存在的 Chrome 版本，UA 字符串里的版本号与
/// `Sec-Ch-Ua` 里 `Chromium`/`Not.A.Brand` 的版本号一致。请求时按 host 固定选用
/// 其中一个，避免同一站点前后请求 UA 漂移。
class _BrowserProfile {
  const _BrowserProfile(this.ua, this.secChUa, this.secChUaMobile, this.secChUaPlatform);
  final String ua;
  final String secChUa;
  final String secChUaMobile;
  final String secChUaPlatform;
}

/// 简单的计数信号量：限制同时进行的任务数。
///
/// 用于 HttpFetcher 的请求闸门——同一时刻最多 [_maxConcurrent] 个请求真正发出，
/// 其余排队，避免一次性并发打爆单站触发限流 / IP 封禁。
class _Semaphore {
  _Semaphore(this._max);
  final int _max;
  int _count = 0;
  final List<Completer<void>> _waiters = <Completer<void>>[];

  Future<void> acquire() {
    if (_count < _max) {
      _count++;
      return Future<void>.value();
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    return completer.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      final completer = _waiters.removeAt(0);
      completer.complete();
    } else {
      _count--;
    }
  }
}

class HttpFetcher {
  HttpFetcher._() {
    _buildDio();
  }

  static final HttpFetcher instance = HttpFetcher._();

  /// 调试/特殊网络环境下强制直连（绕过系统代理）。默认 false，不影响正常行为。
  static bool forceDirect = false;

  /// 默认档案 Dio（对应全局有效档案 / `net == null`）。
  late Dio _dio;

  /// 按有效档案签名隔离的 Dio 缓存（源级覆盖用）。
  final Map<String, Dio> _dioByProfile = <String, Dio>{};
  final Map<String, String> _cookieJar = {};

  /// 验证冷却：命中验证的 host 在冷却期内，[_throttleHost] 会延长最小间隔，
  /// 避免「验证期间继续高频打站」触发更严苛的限流 / IP 封禁。
  final Map<String, DateTime> _verifyCooldown = {};

  /// 验证冷却时长：抛出 [VerificationRequiredException] 时给该 host 记入
  /// 「此刻 + 该时长」的冷却，期间后续请求被节流。
  static const Duration _verifyCooldownDuration = Duration(seconds: 20);

  /// 可选代理（如 `127.0.0.1:7890`）。非空时所有 Dio 请求经此代理；
  /// 为 null 时沿用系统/环境代理，保持默认行为。
  static String? proxy;

  /// 会话 Cookie 版本。每次 [syncCookies] 自增并广播，供封面图加载层
  /// （[SourceImage]）在「验证回灌 Cookie」后立刻重取此前因缺 Cookie 而加载
  /// 失败的封面（_guard 等反爬系统对图片同样校验会话，否则返回 403/空）。
  int _cookieVersion = 0;
  final StreamController<int> _cookieVersionController =
      StreamController<int>.broadcast();
  Stream<int> get cookieVersionStream => _cookieVersionController.stream;
  int get cookieVersion => _cookieVersion;

  /// 每域名固定的浏览器指纹档案序号：保证同一站点每次请求用同一套 UA/指纹，
  /// 既轮换了不同站点之间的指纹，又不会在单次会话里自相矛盾。
  final Map<String, int> _hostProfile = {};

  static final List<_BrowserProfile> _profiles = const <_BrowserProfile>[
    _BrowserProfile(
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
      '"Chromium";v="124", "Google Chrome";v="124", "Not-A.Brand";v="99"',
      '?0',
      '"Windows"',
    ),
    _BrowserProfile(
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36 Edg/123.0.0.0',
      '"Chromium";v="123", "Not.A.Brand";v="99", "Microsoft Edge";v="123"',
      '?0',
      '"Windows"',
    ),
    _BrowserProfile(
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      '"Chromium";v="120", "Google Chrome";v="120", "Not-A.Brand";v="99"',
      '?0',
      '"macOS"',
    ),
  ];

  /// 为某 host 选定（或复用）指纹档案序号。
  int _profileIndexFor(String? host) {
    if (host == null || host.isEmpty) return 0;
    return _hostProfile.putIfAbsent(host, () => _random.nextInt(_profiles.length));
  }

  final Random _random = Random();

  void _buildDio() {
    _dio = _createDio(null);
  }

  /// 按有效档案创建一个配置好的 Dio。
  ///
  /// [profile] 为 null 表示默认档案（运行时用全局有效档案）；否则用该档案。
  /// 客户端构建统一走 [NetworkClientBuilder]，与全局 HttpOverrides 同一路径。
  Dio _createDio(EffectiveNetworkProfile? profile) {
    final dio = Dio();
    // 对齐旧版（AI 修改前可正常解析的版本）：补全浏览器标准请求头。
    // 缺少 Accept / Accept-Language 头时，大量国内站（小说/动漫/漫画）会直接返回 400 空响应。
    dio.options.connectTimeout = const Duration(seconds: 15);
    dio.options.receiveTimeout = const Duration(seconds: 30);
    dio.options.headers.addAll({
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
      'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
    });

    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        try {
          final service = NetworkConfigService.instance;
          final effective = profile ?? service.globalProfile;
          final client = NetworkClientBuilder.buildHttpClient(
            effective,
            proxyPassword: service.proxyPassword,
          );
          // 向后兼容：静态 forceDirect / proxy 覆盖（仅对默认档案生效）。
          if (profile == null) {
            if (forceDirect) {
              client.findProxy = (_) => 'DIRECT';
            } else if (proxy != null && proxy!.isNotEmpty) {
              client.findProxy = (_) => 'PROXY $proxy';
            }
          }
          return client;
        } on Object catch (e, st) {
          // 构建档案失败：回退裸客户端（保留自签容忍），保证该源仍可系统直连。
          debugPrint('HttpFetcher._createDio fallback: $e\n$st');
          final client = HttpClient();
          client.badCertificateCallback = (cert, host, port) => true;
          return client;
        }
      },
    );
    return dio;
  }

  /// 按有效档案取/建 Dio：
  /// - `p == null` 或与全局档案同签名 → 复用默认 Dio；
  /// - 否则按签名隔离缓存一个源级 Dio。
  Dio _dioFor(EffectiveNetworkProfile? p) {
    if (p == null) return _dio;
    final globalSig = NetworkConfigService.instance.globalProfile.signature;
    if (p.signature == globalSig) return _dio;
    return _dioByProfile.putIfAbsent(p.signature, () => _createDio(p));
  }

  /// 重建所有 Dio（全局配置变更时调用）：丢弃旧连接池，新配置即时生效。
  void rebuildAll() {
    for (final d in _dioByProfile.values) {
      d.close(force: true);
    }
    _dioByProfile.clear();
    _dio.close(force: true);
    _buildDio();
  }

  /// 运行时切换直连模式（重建全部 Dio 实例）。
  static void setForceDirect(bool value) {
    forceDirect = value;
    instance.rebuildAll();
  }

  /// 运行时切换代理（重建全部 Dio 实例）。
  static void setProxy(String? value) {
    proxy = value;
    instance.rebuildAll();
  }

  /// 返回某 URL 实际使用的 UA（经 [_profileIndexFor] 选定的指纹档案）。
  ///
  /// 全应用唯一真源：WebView 验证、AnalyzeUrl 直连、源 JSON 的 UA 都应调用本
  /// 方法取得，确保「过验证的 UA」与「后续 HTTP 重试的 UA」完全一致，避免 UA
  /// 漂移导致 Cookie 失效 → 验证死循环（幻梦ACG _guard 滑块反复弹的核心根因）。
  String userAgentForUrl(String url) => _uaForHost(Uri.tryParse(url)?.host ?? '');

  String _uaForHost(String host) => _profiles[_profileIndexFor(host)].ua;

  /// 启动时从 [CookieStore] 回填内存 Cookie jar，避免每次冷启动都重新过验证
  /// （冷启动即丢 Cookie 是「反复验证 → 高频请求 → IP 被封」的首要根因）。
  Future<void> loadPersistedCookies() async {
    try {
      final persisted = await CookieStore.load();
      _cookieJar.addAll(persisted);
    } catch (e, st) {
      debugPrint('loadPersistedCookies failed: $e\n$st');
    }
  }

  /// 记录该 host 进入验证冷却（见 [_verifyCooldown] 与 [_throttleHost]）。
  void _markVerification(String url) {
    final host = Uri.tryParse(url)?.host;
    if (host != null && host.isNotEmpty) {
      _verifyCooldown[host] = DateTime.now().add(_verifyCooldownDuration);
    }
  }

  /// 记录验证冷却并抛出 [VerificationRequiredException]（统一入口）。
  Never _recordAndThrowVerify(
    String url,
    Map<String, String>? headers,
    String? body,
    int? statusCode,
  ) {
    _markVerification(url);
    throw VerificationRequiredException(
      url: url,
      headers: headers,
      body: body,
      statusCode: statusCode,
    );
  }

  /// 同 host 最小间隔 + 验证冷却：保证短时间内同一站点不会被高频打爆，
  /// 避免触发限流 / IP 封禁。
  Future<void> _throttleHost(String url) async {
    final host = Uri.tryParse(url)?.host;
    if (host == null || host.isEmpty) return;
    final now = DateTime.now();
    var earliest =
        _hostLastSent[host]?.add(Duration(milliseconds: _minHostGapMs)) ?? now;
    final cd = _verifyCooldown[host];
    if (cd != null && cd.isAfter(earliest)) earliest = cd;
    final gap = earliest.difference(now).inMilliseconds;
    if (gap > 0) await Future.delayed(Duration(milliseconds: gap));
    _hostLastSent[host] = DateTime.now();
    // 冷却到期即清理，避免无限堆积。
    if (cd != null && now.isAfter(cd)) _verifyCooldown.remove(host);
  }

  /// 测试可见：仅执行同 host 节流 + 冷却等待（不含并发信号量/隐身延迟），
  /// 便于单测断言验证冷却行为。
  Future<void> runGate(String url) => _throttleHost(url);

  /// 测试可见：手动写入某 host 的验证冷却（生产代码由验证异常自动写入）。
  void setVerifyCooldown(String host, DateTime until) {
    _verifyCooldown[host] = until;
  }

  Future<void> _stealthDelay() async {
    // 强制隐身：请求前随机延迟 300~1100ms，降频 + 打散节拍，避免被识别为脚本。
    // 用 Random 而不是时间戳取模（后者可预测、固定间隔更可疑）。
    final ms = 300 + _random.nextInt(800);
    await Future.delayed(Duration(milliseconds: ms));
  }

  /// 并发闸门：限制全局同时发出的请求数，并在同一 host 上强制最小间隔，
  /// 避免一次性并发请求触发站点限流 / IP 封禁（如批量下载、首页多板块并发抓取、
  /// 详情页同时拉取详情+选集+推荐）。
  ///
  /// 流程：① 全局信号量排队（[release] 在请求方法末尾的 finally 中调用）→
  /// ② 同 host 最小间隔（同一站点两次请求至少间隔 [_minHostGapMs]）→
  /// ③ 隐身随机延迟（打散节拍）。
  static const int _maxConcurrent = 3;
  // 同 host 最小间隔：原 500ms，上调到 800ms 进一步降低「短时间内连续请求
  // 同一站点」触发风控 / IP 封禁的概率（首页板块已在 OnlineContentListScreen
  // 内串行化抓取，这里再加一层保险）。
  static const int _minHostGapMs = 800;
  final _Semaphore _requestSemaphore = _Semaphore(_maxConcurrent);
  final Map<String, DateTime> _hostLastSent = <String, DateTime>{};

  Future<void> _gateRequest(String url, bool stealth) async {
    // 1) 全局并发上限：超过则在此排队，直至有空闲名额（在请求方法 finally 中释放）。
    await _requestSemaphore.acquire();
    // 2) 同 host 最小间隔 + 验证冷却：防止短时间内同一站点被打爆。
    await _throttleHost(url);
    // 3) 隐身随机延迟（打散节拍）。
    if (ConfigLoader.instance.getStealthMode() && stealth) {
      await _stealthDelay();
    }
  }

  Map<String, String> _mergeHeaders(
    String? referer, [
    Map<String, String>? extra,
    String? url,
  ]) {
    // 每次请求实际发出的头。必须显式带上 Accept / Accept-Language：
    // 大量国内站（小说/动漫/漫画）会拒绝缺这些头的请求，直接回 400 空响应。
    // 注意：此处若不写全，会被请求级 Options(headers) 整体覆盖，基础配置的头不生效。
    final host = Uri.tryParse(url ?? '')?.host;
    final profile = _profiles[_profileIndexFor(host)];
    final merged = <String, String>{
      // 浏览器指纹：UA 与 Sec-Ch-Ua 品牌配套，避免自爆。
      'User-Agent': profile.ua,
      'Sec-Ch-Ua': profile.secChUa,
      'Sec-Ch-Ua-Mobile': profile.secChUaMobile,
      'Sec-Ch-Ua-Platform': profile.secChUaPlatform,
      // 现代浏览器标准头：WAF/Cloudflare 用这些判定是否真人。缺了极易被拦。
      'Accept':
          'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      'Accept-Encoding': 'gzip, deflate',
      'Sec-Fetch-Dest': 'document',
      'Sec-Fetch-Mode': 'navigate',
      'Sec-Fetch-Site': 'same-origin',
      'Sec-Fetch-User': '?1',
      'Upgrade-Insecure-Requests': '1',
      'Connection': 'keep-alive',
      if (referer != null) 'Referer': referer,
      ...?extra,
    };
    // 回带 Cookie（对齐旧版可解析版本）：站点下发的会话 Cookie 需在后续请求带回，
    // 否则部分 MacCMS/源会拒绝（400）或要求验证。匹配父域/子域。
    final cookie = _cookieHeaderFor(url);
    if (cookie != null) merged['Cookie'] = cookie;
    return merged;
  }

  /// 取与 [url] 同域（含父域/子域）的已存 Cookie，拼成 `Cookie` 头值。
  String? _cookieHeaderFor(String? url) {
    final host = Uri.tryParse(url ?? '')?.host;
    if (host == null || host.isEmpty) return null;
    final matched = <String>[];
    _cookieJar.forEach((storedHost, cookie) {
      if (cookie.isEmpty) return;
      if (host == storedHost || host.endsWith('.$storedHost')) {
        matched.add(cookie);
      }
    });
    if (matched.isEmpty) return null;
    return matched.join('; ');
  }

  /// 公开取 Cookie 头：供小说侧 [AnalyzeUrl] 等独立 Dio 复用共享 Cookie 存储。
  ///
  /// 验证系统在 WebView（内置浏览器）里被通过后，会话 Cookie 已通过
  /// [syncCookies] 写入本 jar；直连重试时必须带上才能过验证，否则重试仍撞
  /// 验证页（之前 幻梦ACG「系统安全验证」）返空列表。内部复用父域/子域匹配逻辑。
  String? cookieHeaderForUrl(String? url) => _cookieHeaderFor(url);

  /// 将响应字节按字符集解码为字符串。
  ///
  /// 对齐旧版可解析实现：国内大量漫画/小说/动漫源（如 goda、baozimh 部分镜像）
  /// 以 **GBK/GB2312/GB18030** 编码返回正文。若直接用 Dio 的 `ResponseType.plain`
  /// 走 UTF-8 解码，中文会变成乱码（烫疽 类字符），正则选择器匹配不到 → 列表空。
  /// 故统一取字节后：先按 Content-Type / <meta charset> 声明的字符集解码；
  /// 声明为 GBK 系列时直接用 [gbk]（fast_gbk，覆盖 GB2312/GB18030 绝大多数情况）
  /// 解码；未声明或声明 utf-8 时走 UTF-8，并对出现大量替换符（U+FFFD）的疑似
  /// 乱码结果再兜底尝试 GBK，避免漏掉未声明 charset 的站点。
  String _decodeBody(List<int> bytes, String? contentType) {
    if (bytes.isEmpty) return '';
    final charset = _detectCharset(bytes, contentType);
    if (charset != null && _isGbkFamily(charset)) {
      try {
        return gbk.decode(bytes);
      } on Object {
        // GBK 解码失败（极罕见非法序列）→ 退回 UTF-8。
      }
    }
    final utf8Str = utf8.decode(bytes, allowMalformed: true);
    if (_hasReplacementChars(utf8Str)) {
      try {
        final g = gbk.decode(bytes);
        if (!_hasReplacementChars(g)) return g;
      } on Object {
        // 忽略，保留 UTF-8 结果。
      }
    }
    return utf8Str;
  }

  /// 从 Content-Type 头与 <meta> 标签探测字符集声明。
  String? _detectCharset(List<int> bytes, String? contentType) {
    if (contentType != null) {
      final m = RegExp(r'charset=([^\s;]+)', caseSensitive: false)
          .firstMatch(contentType);
      if (m != null) return m.group(1)?.trim();
    }
    // 扫描 head 前若干字节内的 <meta charset=...> / <meta http-equiv=...charset=...>
    final headLen = bytes.length < 2048 ? bytes.length : 2048;
    final headAscii = String.fromCharCodes(
      bytes.sublist(0, headLen).map((b) => b < 128 ? b : 0x20),
    );
    final meta =
        RegExp(r'charset[^\w]*=[^\w]*([a-z0-9_-]+)', caseSensitive: false)
            .firstMatch(headAscii.toLowerCase());
    return meta?.group(1);
  }

  /// 是否为 GBK 系列字符集（GBK/GB2312/GB18030 等），统一用 [gbk] 解码。
  static bool _isGbkFamily(String charset) {
    final c = charset.toLowerCase().replaceAll('_', '-');
    return c == 'gbk' ||
        c == 'gb2312' ||
        c == 'gb-2312' ||
        c == 'gb18030' ||
        c == 'gb_2312' ||
        c == 'csgb2312' ||
        c == 'csiso58bgb231280';
  }

  /// 统计文本中 U+FFFD 替换符数量，超过阈值视为 UTF-8 乱码（疑似非 UTF-8 编码）。
  static bool _hasReplacementChars(String s) {
    var count = 0;
    final limit = s.length < 8000 ? s.length : 8000;
    for (var i = 0; i < limit; i++) {
      if (s.codeUnitAt(i) == 0xFFFD) count++;
      if (count > 5) return true;
    }
    return false;
  }

  /// 取 HTML 文本；命中验证特征抛 [VerificationRequiredException]。
  Future<String> getHtml(
    String url, {
    Map<String, String>? headers,
    String? referer,
    bool stealth = true,
    EffectiveNetworkProfile? net,
  }) async {
    await _gateRequest(url, stealth);
    try {
      final merged = _mergeHeaders(referer, headers, url);
      final resp = await _dioFor(net).get<List<int>>(
        url,
        options: Options(
          headers: merged,
          responseType: ResponseType.bytes,
          validateStatus: (_) => true,
        ),
      );
    final bytes = resp.data ?? const <int>[];
    if (bytes.isEmpty) {
      if (VerificationDetector.isVerificationRequired(
        statusCode: resp.statusCode,
        body: '',
        headers: _responseHeaders(resp),
      )) {
      _recordAndThrowVerify(url, merged, '', resp.statusCode);
      }
      _checkNonVerificationError(url, resp.statusCode, '');
      _storeCookies(url, resp);
      return '';
    }
    final body = _decodeBody(bytes, resp.headers.value('content-type'));
    if (VerificationDetector.isVerificationRequired(
      statusCode: resp.statusCode,
      body: body,
      headers: _responseHeaders(resp),
    )) {
      _recordAndThrowVerify(url, merged, body, resp.statusCode);
    }
    _checkNonVerificationError(url, resp.statusCode, body);
    _storeCookies(url, resp);
    return body;
    } finally {
      _requestSemaphore.release();
    }
  }

  /// 取 JSON（自动解析）。
  Future<dynamic> getJson(
    String url, {
    Map<String, String>? headers,
    String? referer,
    bool stealth = true,
    EffectiveNetworkProfile? net,
  }) async {
    final text =
        await getHtml(url, headers: headers, referer: referer, stealth: stealth, net: net);
    return _decodeJson(text);
  }

  /// POST 并返回解析后的 JSON（自动解析响应体）。
  /// 用于 meta 协议的 POST 预取分支（如 komiic 的 GraphQL 查询）。
  Future<dynamic> postJson(
    String url, {
    Map<String, String>? headers,
    Object? data,
    String? referer,
    bool stealth = true,
    EffectiveNetworkProfile? net,
  }) async {
    final text = await post(
      url,
      headers: headers,
      data: data,
      referer: referer,
      stealth: stealth,
      net: net,
    );
    return _decodeJson(text);
  }

  /// POST 表单/JSON，返回 HTML 文本。
  Future<String> post(
    String url, {
    Map<String, String>? headers,
    Object? data,
    String? referer,
    bool stealth = true,
    EffectiveNetworkProfile? net,
  }) async {
    await _gateRequest(url, stealth);
    try {
      final merged = _mergeHeaders(referer, headers, url);
      final resp = await _dioFor(net).post<List<int>>(
        url,
        data: data,
        options: Options(
          headers: merged,
          responseType: ResponseType.bytes,
          validateStatus: (_) => true,
        ),
      );
    final body = _decodeBody(resp.data ?? const <int>[], resp.headers.value('content-type'));
    if (VerificationDetector.isVerificationRequired(
      statusCode: resp.statusCode,
      body: body,
      headers: _responseHeaders(resp),
    )) {
      _recordAndThrowVerify(url, merged, body, resp.statusCode);
    }
    _checkNonVerificationError(url, resp.statusCode, body);
    _storeCookies(url, resp);
    return body;
    } finally {
      _requestSemaphore.release();
    }
  }

  /// PUT 请求，返回 HTML 文本（与 [post] 同构，method=PUT）。
  Future<String> put(
    String url, {
    Map<String, String>? headers,
    Map<String, dynamic>? data,
    String? referer,
    bool stealth = true,
    EffectiveNetworkProfile? net,
  }) async {
    _validateScheme(url);
    await _gateRequest(url, stealth);
    try {
      final merged = _mergeHeaders(referer, headers, url);
      final resp = await _dioFor(net).put<List<int>>(
        url,
        data: data,
        options: Options(
          headers: merged,
          responseType: ResponseType.bytes,
          validateStatus: (_) => true,
        ),
      );
    final body = _decodeBody(resp.data ?? const <int>[], resp.headers.value('content-type'));
    if (VerificationDetector.isVerificationRequired(
      statusCode: resp.statusCode,
      body: body,
      headers: _responseHeaders(resp),
    )) {
      _recordAndThrowVerify(url, merged, body, resp.statusCode);
    }
    _checkNonVerificationError(url, resp.statusCode, body);
    _storeCookies(url, resp);
    return body;
    } finally {
      _requestSemaphore.release();
    }
  }

  /// DELETE 请求，返回 HTML 文本。
  Future<String> delete(
    String url, {
    Map<String, String>? headers,
    String? referer,
    bool stealth = true,
    EffectiveNetworkProfile? net,
  }) async {
    _validateScheme(url);
    await _gateRequest(url, stealth);
    try {
      final merged = _mergeHeaders(referer, headers, url);
      final resp = await _dioFor(net).delete<List<int>>(
        url,
        options: Options(
          headers: merged,
          responseType: ResponseType.bytes,
          validateStatus: (_) => true,
        ),
      );
    final body = _decodeBody(resp.data ?? const <int>[], resp.headers.value('content-type'));
    if (VerificationDetector.isVerificationRequired(
      statusCode: resp.statusCode,
      body: body,
      headers: _responseHeaders(resp),
    )) {
      _recordAndThrowVerify(url, merged, body, resp.statusCode);
    }
    _checkNonVerificationError(url, resp.statusCode, body);
    _storeCookies(url, resp);
    return body;
    } finally {
      _requestSemaphore.release();
    }
  }

  /// 表单（application/x-www-form-urlencoded）POST，返回 HTML 文本。
  /// 对应 JS 沙箱 `context.http.postForm(url, params)`：params 为键值对，
  /// 编码为 `k=v&...` 并以该 Content-Type 发送（golden 源 gugu3 视频解析用到）。
  Future<String> postForm(
    String url, {
    Map<String, String>? headers,
    Map<String, String>? data,
    String? referer,
    bool stealth = true,
    EffectiveNetworkProfile? net,
  }) async {
    _validateScheme(url);
    await _gateRequest(url, stealth);
    try {
      final body = (data ?? const <String, String>{})
          .entries
          .map((e) =>
              '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
          .join('&');
    final merged = _mergeHeaders(referer, <String, String>{
      'Content-Type': 'application/x-www-form-urlencoded',
      ...?headers,
    }, url);
    final resp = await _dioFor(net).post<List<int>>(
      url,
      data: body,
      options: Options(
        headers: merged,
        responseType: ResponseType.bytes,
        validateStatus: (_) => true,
      ),
    );
    final respBody = _decodeBody(resp.data ?? const <int>[], resp.headers.value('content-type'));
    if (VerificationDetector.isVerificationRequired(
      statusCode: resp.statusCode,
      body: respBody,
      headers: _responseHeaders(resp),
    )) {
      _recordAndThrowVerify(url, merged, respBody, resp.statusCode);
    }
    _checkNonVerificationError(url, resp.statusCode, respBody);
    _storeCookies(url, resp);
    return respBody;
    } finally {
      _requestSemaphore.release();
    }
  }

  /// 通用 fetch：返回 `{status, headers, body}` 映射（JS 沙箱 http.fetch 桥）。
  Future<Map<String, dynamic>> fetch(
    String url, {
    String method = 'GET',
    Map<String, String>? headers,
    String? body,
    String? referer,
    bool stealth = true,
    EffectiveNetworkProfile? net,
  }) async {
    _validateScheme(url);
    await _gateRequest(url, stealth);
    try {
      final merged = _mergeHeaders(referer, headers, url);
      final resp = await _dioFor(net).request<List<int>>(
        url,
        data: body,
        options: Options(
          method: method,
          headers: merged,
          responseType: ResponseType.bytes,
          validateStatus: (_) => true,
        ),
      );
    final respBody = _decodeBody(resp.data ?? const <int>[], resp.headers.value('content-type'));
    if (VerificationDetector.isVerificationRequired(
      statusCode: resp.statusCode,
      body: respBody,
      headers: _responseHeaders(resp),
    )) {
      _recordAndThrowVerify(url, merged, respBody, resp.statusCode);
    }
    _storeCookies(url, resp);
    final respHeaders = <String, String>{};
    resp.headers.map.forEach((k, v) {
      respHeaders[k] = v.join(', ');
    });
    return <String, dynamic>{
      'status': resp.statusCode ?? 0,
      'headers': respHeaders,
      'body': respBody,
    };
    } finally {
      _requestSemaphore.release();
    }
  }

  /// 校验 URL scheme 仅允许 http/https（沙箱安全约束）。
  void _validateScheme(String url) {
    final lower = url.toLowerCase();
    if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
      throw ArgumentError('URL scheme must be http or https: $url');
    }
  }

  /// 把 Dio 的响应头拍平成 `Map<String,String>`（同名多值用逗号拼接）。
  ///
  /// 验证检测需要**响应头**（如 `Server: Edge/1.1.18` 这类 WAF 签名）；旧代码误把
  /// 请求头传给检测器，导致基于响应头的判断永远失效，这里统一取真实响应头。
  static Map<String, String> _responseHeaders(Response<dynamic> resp) {
    final out = <String, String>{};
    resp.headers.map.forEach((k, v) {
      out[k] = v.join(', ');
    });
    return out;
  }

  /// 验证检测通过后，若状态码仍 ≥ 400（如 404/500/502），抛
  /// [HttpStatusException] 以便上层显示明确错误 + 重试，而非把错误页
  /// body 当成正常响应交给解析器导致静默空列表。
  void _checkNonVerificationError(String url, int? statusCode, String body) {
    final code = statusCode;
    if (code != null && code >= 400) {
      throw HttpStatusException(
        url: url,
        statusCode: code,
        body: body,
      );
    }
  }

  /// 取二进制（视频/图片）。
  Future<List<int>> getBytes(String url,
      {Map<String, String>? headers, EffectiveNetworkProfile? net}) async {
    final resp = await _dioFor(net).get<List<int>>(
      url,
      options: Options(
        headers: _mergeHeaders(null, headers, url),
        responseType: ResponseType.bytes,
        validateStatus: (_) => true,
      ),
    );
    return resp.data ?? const [];
  }

  /// WebView 验证完成后把共享 Cookie 同步进 Fetcher（含父域子域匹配）。
  ///
  /// 同步后自增 [cookieVersion] 并广播，触发封面图加载层立即用新 Cookie 重取
  /// 之前失败的封面（满足「回灌 Cookie 后自动刷新封面」诉求）。
  void syncCookies(String host, String cookieHeader) {
    _cookieJar[host] = cookieHeader;
    _cookieVersion++;
    if (!_cookieVersionController.isClosed) {
      _cookieVersionController.add(_cookieVersion);
    }
    // 落盘持久化（TTL 7 天），避免重启后重新验证。UA 一并存，回灌时配套校验。
    unawaited(CookieStore.save(host, cookieHeader, _uaForHost(host)));
  }

  String? getCookieHeader(String host) => _cookieJar[host];

  /// 清除所有 Cookie（缓存清除）。
  void clearCookies() {
    _cookieJar.clear();
    unawaited(CookieStore.clear());
  }

  /// 清除单个 host 的 Cookie（源登出）：内存 jar 与持久化记录一并删除，
  /// 并自增 [cookieVersion] 广播，通知登录态缓存（SourceAuthManager）重新评估。
  void clearCookiesFor(String host) {
    _cookieJar.remove(host);
    _cookieVersion++;
    if (!_cookieVersionController.isClosed) {
      _cookieVersionController.add(_cookieVersion);
    }
    unawaited(CookieStore.delete(host));
  }

  void _storeCookies(String url, Response<dynamic> resp) {
    final setCookie = resp.headers['set-cookie'];
    if (setCookie == null || setCookie.isEmpty) return;
    final host = Uri.tryParse(url)?.host;
    if (host == null) return;
    final cookieHeader = setCookie.map((c) => c.split(';').first).join('; ');
    _cookieJar[host] = cookieHeader;
    // 落盘持久化（TTL 7 天），避免重启后重新验证。UA 一并存，回灌时配套校验。
    unawaited(CookieStore.save(host, cookieHeader, _uaForHost(host)));
  }

  dynamic _decodeJson(String text) {
    // 去除 BOM / 首尾空白；失败时退一步截取首个 { 到末个 }。
    final trimmed = text.trim();
    try {
      return jsonDecode(trimmed);
    } on Object {
      final start = trimmed.indexOf('{');
      final end = trimmed.lastIndexOf('}');
      if (start >= 0 && end > start) {
        return jsonDecode(trimmed.substring(start, end + 1));
      }
      rethrow;
    }
  }
}

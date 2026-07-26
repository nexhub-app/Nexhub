/// URL 解析器：处理书源 URL 中的 `{{key}}`/`{{page}}`/`{{...JS...}}` 占位符、
/// `,{"method":"POST","body":"...","charset":"gbk"}` 选项后缀、`<js>`/`@js:` 内嵌脚本，
/// 并执行 HTTP 请求（含 GBK 等字符集解码与重定向跟随）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fast_gbk/fast_gbk.dart';
import 'analyze_rule.dart';
import '../../../core/scraper/verification_detector.dart';
import '../../../core/scraper/http_fetcher.dart';
import '../model/xiaoshuo_book.dart';
import '../model/xiaoshuo_book_chapter.dart';
import '../model/book_source.dart';

class AnalyzeUrl {
  String url;
  String? baseUrl;
  XiaoshuoBookSource? source;
  XiaoshuoBook? ruleData;
  XiaoshuoBookChapter? chapter;
  int page;
  String? key;
  String? speakText;
  int? speakSpeed;

  final Map<String, String> headerMap = {};
  String? body;
  String? method;
  String? charset;
  int retry = 0;
  bool useWebView = false;
  String? webJs;
  String? bodyJs;
  String? proxy;
  String? dnsIp;
  String? requestType;
  int webViewDelayTime = 0;

  // 静态 Dio 实例提升性能
  static final Dio _dio = Dio()
    ..options.connectTimeout = const Duration(seconds: 15)
    ..options.receiveTimeout = const Duration(seconds: 30)
    ..options.validateStatus = (status) => status != null && status >= 200 && status < 300;

  AnalyzeUrl({
    required this.url,
    this.baseUrl,
    this.source,
    this.ruleData,
    this.chapter,
    this.page = 1,
    this.key,
    this.speakText,
    this.speakSpeed,
    Map<String, String>? headerMapF,
  }) {
    if (headerMapF != null) {
      headerMap.addAll(headerMapF);
      if (headerMapF.containsKey('proxy')) {
        proxy = headerMapF['proxy'];
        headerMap.remove('proxy');
      }
    }

    _initUrl();
  }

  void _initUrl() {
    analyzeJs();
    replaceKeyPageJs();
    analyzeUrl();
  }

  void analyzeJs() {
    final jsPattern = RegExp(r'<js>([\w\W]*?)</js>|@js:([\w\W]*)', caseSensitive: false);
    final matches = jsPattern.allMatches(url).toList();
    var start = 0;
    var result = url;

    for (final match in matches) {
      if (match.start > start) {
        final segment = url.substring(start, match.start).trim();
        if (segment.isNotEmpty) {
          result = segment.replaceAll('@result', result);
        }
      }
      final jsCode = match.group(2) ?? match.group(1) ?? '';
      final jsResult = _evalJs(jsCode, result);
      result = jsResult;
      start = match.end;
    }

    if (url.length > start) {
      final segment = url.substring(start).trim();
      if (segment.isNotEmpty) {
        result = segment.replaceAll('@result', result);
      }
    }

    url = result;
  }

  void replaceKeyPageJs() {
    if (url.contains('{{') && url.contains('}}')) {
      final jsPattern = RegExp(r'\{\{([\w\W]*?)\}\}');
      url = url.replaceAllMapped(jsPattern, (match) {
        final expr = match.group(1)!;
        if (expr == 'page') {
          return page.toString();
        }
        if (expr == 'key') {
          // 关键修复：搜索关键词必须 URL 编码，否则含中文等非 ASCII 字符的
          // 搜索地址会被 HTTP 客户端拒绝（FormatException / 空结果），
          // 导致搜索"无效果"。编码后服务端解码得到原词，行为等价且更兼容。
          return key != null && key!.isNotEmpty ? Uri.encodeComponent(key!) : '';
        }
        final jsResult = _evalJs(expr, url);
        return jsResult;
      });
    }

    // 兜底：确保任何残留的 {{key}}/{{page}} 被正确替换与编码（极少见，
    // 仅当上面的正则未覆盖时触发，不会造成重复编码）。
    if (key != null && key!.isNotEmpty) {
      url = url.replaceAll('{{key}}', Uri.encodeComponent(key!));
    }
    url = url.replaceAll('{{page}}', page.toString());
  }

  void analyzeUrl() {
    final originalUrl = url;
    final paramPattern = RegExp(r',\s*\{');
    final paramMatch = paramPattern.firstMatch(originalUrl);
    final urlNoOption = paramMatch != null ? originalUrl.substring(0, paramMatch.start) : originalUrl;

    url = _getAbsoluteUrl(urlNoOption);

    if (url.isNotEmpty) {
      try {
        final uri = Uri.parse(url);
        baseUrl = '${uri.scheme}://${uri.host}';
      } catch (_) {}
    }

    if (paramMatch != null && urlNoOption.length != originalUrl.length) {
      final optionStr = originalUrl.substring(paramMatch.end - 1);
      try {
        final option = json.decode(optionStr) as Map<String, dynamic>?;
        if (option != null) {
          method = option['method']?.toString();
          body = option['body']?.toString();
          charset = option['charset']?.toString();
          retry = option['retry'] ?? 0;
          useWebView = option['useWebView'] ?? false;
          webJs = option['webJs']?.toString();
          bodyJs = option['bodyJs']?.toString();
          dnsIp = option['dnsIp']?.toString();
          requestType = option['type']?.toString();

          final headers = option['headers'] as Map<String, dynamic>?;
          if (headers != null) {
            for (final entry in headers.entries) {
              headerMap[entry.key.toString()] = entry.value.toString();
            }
          }

          final js = option['js']?.toString();
          if (js != null && js.isNotEmpty) {
            final jsResult = _evalJs(js, url);
            url = jsResult;
          }
        }
      } catch (_) {}
    }
  }

  String _getAbsoluteUrl(String urlStr) {
    if (urlStr.isEmpty) return baseUrl ?? '';
    if (urlStr.startsWith('http')) return urlStr;
    if (baseUrl == null || baseUrl!.isEmpty) return urlStr;
    try {
      final base = Uri.parse(baseUrl!);
      return base.resolve(urlStr).toString();
    } catch (_) {
      return urlStr;
    }
  }

  String _evalJs(String jsCode, String currentResult) {
    try {
      final analyzeRule = AnalyzeRule(book: ruleData, chapter: chapter)
        ..setBaseUrl(baseUrl);
      return analyzeRule.evalJs(jsCode, currentResult);
    } catch (_) {
      return currentResult;
    }
  }

  bool get _isValidHttpUrl {
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      return false;
    }
    try {
      final uri = Uri.parse(url);
      return uri.host.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<String> getStrResponse({
    String? jsStr,
    String? sourceRegex,
    Map<String, String>? headers,
  }) async {
    if (!_isValidHttpUrl) {
      throw Exception('Invalid URL: $url');
    }

    final requestHeaders = <String, String>{
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
      'Accept':
          'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      'Referer': source?.bookSourceUrl ?? baseUrl ?? url,
    };

    if (source?.header != null && source!.header!.isNotEmpty) {
      try {
        final headerMap = _parseHeader(source!.header!);
        requestHeaders.addAll(headerMap);
      } catch (_) {}
    }

    if (headers != null) {
      requestHeaders.addAll(headers);
    }

    // 复用 HttpFetcher 共享 Cookie 存储：验证系统在 WebView（内置浏览器）里被
    // 通过后，会话 Cookie 已由 HttpBrowserScreen 同步进 HttpFetcher；AnalyzeUrl
    // 用独立 Dio，不读那个 jar，若不回带，验证重试仍会被反爬系统拦截（之前
    // 幻梦ACG「系统安全验证」即因此反复返空列表 / 「该分类暂无内容」）。
    // 首次请求时 jar 为空 → 此步为空操作，无副作用。
    final sharedCookie = HttpFetcher.instance.cookieHeaderForUrl(url);
    if (sharedCookie != null && sharedCookie.isNotEmpty) {
      final existing = requestHeaders['Cookie'];
      requestHeaders['Cookie'] = (existing != null && existing.isNotEmpty)
          ? '$existing; $sharedCookie'
          : sharedCookie;
    }

    String body;
    try {
      final options = Options(
        headers: requestHeaders,
        responseType: ResponseType.bytes,
        validateStatus: (status) => status != null && status >= 200 && status < 300,
      );

      final Response<List<int>> response;
      if (method?.toUpperCase() == 'POST') {
        response = await _dio.post<List<int>>(
          url,
          data: this.body,
          options: options,
        );
      } else {
        response = await _dio.get<List<int>>(
          url,
          options: options,
        );
      }

      final bytes = Uint8List.fromList(response.data ?? <int>[]);
      final contentType = _extractHeaderValue(
        response.headers['content-type'],
      );
      body = _decodeBody(bytes, charset, contentType);

      // 解码后统一检测「验证/反爬挑战页」（覆盖 Cloudflare、以及 PTCMS 等站点
      // 自带的「系统安全验证」等）。命中则抛 [VerificationRequiredException]，
      // 交由既有 WebView 验证回灌流程过验证，而非静默返回空结果或抛普通异常被上层吞掉。
      if (_looksLikeVerificationChallenge(body)) {
        throw VerificationRequiredException(
          url: url,
          body: body,
          statusCode: response.statusCode,
        );
      }

      if (response.statusCode != null && response.statusCode! >= 400) {
        throw Exception('请求失败：HTTP ${response.statusCode}，URL：$url');
      }
      if (response.redirects.isNotEmpty) {
        url = response.redirects.last.location.toString();
      }
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      // 非 2xx 也可能是「验证 / 反爬挑战页」：PTCMS「系统安全验证」常以 403
      // 返回挑战 HTML，此时 validateStatus 已拒收、请求体被丢给上层前必须先过
      // 一遍挑战检测；否则异常类型不对（普通 Exception 而非
      // VerificationRequiredException），验证链路不会触发 → 列表空 + 不跳 WebView。
      final errData = e.response?.data;
      if (errData is List<int> && errData.isNotEmpty) {
        final decoded = _decodeBody(
          Uint8List.fromList(errData),
          charset,
          _extractHeaderValue(e.response?.headers['content-type']),
        );
        if (_looksLikeVerificationChallenge(decoded)) {
          throw VerificationRequiredException(
            url: url,
            body: decoded,
            statusCode: status,
          );
        }
      }
      throw Exception('网络请求失败[$status]：$url，${e.message}');
    } catch (e) {
      // 关键：验证异常必须原样透传，绝不能包成普通 Exception。否则上层
      // VerificationNavigator.isVerificationError 判定失败 → 不跳 WebView，
      // 列表解析空壳 → 没封面、也不触发验证（幻梦ACG _guard 滑块挑战即此坑）。
      if (e is VerificationRequiredException) rethrow;
      throw Exception('网络请求失败：$url，${e.toString()}');
    }

    if (jsStr != null && jsStr.isNotEmpty) {
      try {
        final analyzeRule = AnalyzeRule(book: ruleData, chapter: chapter)
          ..setContent(body, url)
          ..setBaseUrl(url);
        body = analyzeRule.getString(jsStr);
      } catch (_) {}
    }

    if (sourceRegex != null && sourceRegex.isNotEmpty) {
      try {
        final regex = RegExp(sourceRegex, dotAll: true);
        final match = regex.firstMatch(body);
        if (match != null) {
          if (match.groupCount > 0) {
            body = match.group(1) ?? body;
          } else {
            body = match.group(0) ?? body;
          }
        }
      } catch (_) {}
    }

    return body;
  }

  Map<String, String> _parseHeader(String headerStr) {
    final headers = <String, String>{};
    try {
      final decoded = json.decode(headerStr);
      if (decoded is Map) {
        for (final entry in decoded.entries) {
          headers[entry.key.toString()] = entry.value.toString();
        }
        return headers;
      }
    } catch (_) {}

    for (final line in headerStr.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final colonIndex = trimmed.indexOf(': ');
      if (colonIndex > 0) {
        final key = trimmed.substring(0, colonIndex).trim();
        final value = trimmed.substring(colonIndex + 1).trim();
        headers[key] = value;
      }
    }
    return headers;
  }

  /// 字符集解码优先级：
  /// 1. URL 选项中的 charset
  /// 2. HTTP Content-Type 中的 charset
  /// 3. UTF-8 容错解码
  String _decodeBody(Uint8List bytes, String? optionCharset, String? contentType) {
    final effectiveCharset = _normalizeCharset(optionCharset) ??
        _extractCharsetFromContentType(contentType);

    if (effectiveCharset != null) {
      final lower = effectiveCharset.toLowerCase();
      if (lower == 'gbk' || lower == 'gb2312') {
        return gbk.decode(bytes);
      }
      if (lower == 'big5') {
        // Dart 内置不支持 Big5，先按 UTF-8 容错解码，避免直接崩溃
        return utf8.decode(bytes, allowMalformed: true);
      }
    }

    return utf8.decode(bytes, allowMalformed: true);
  }

  String? _normalizeCharset(String? charset) {
    if (charset == null || charset.trim().isEmpty) {
      return null;
    }
    return charset.trim().toLowerCase();
  }

  /// 从 Content-Type 提取 charset，如 `text/html; charset=gbk` -> `gbk`。
  String? _extractCharsetFromContentType(String? contentType) {
    if (contentType == null || contentType.isEmpty) {
      return null;
    }
    final match = RegExp(r'charset\s*=\s*([^\s;]+)', caseSensitive: false)
        .firstMatch(contentType);
    return match?.group(1)?.trim().toLowerCase();
  }

  String? _extractHeaderValue(List<String>? values) {
    if (values == null || values.isEmpty) {
      return null;
    }
    return values.first;
  }

  /// 识别「验证 / 反爬挑战页」（仅挑战页有、正常内容页绝不会出现的特征）。
  ///
  /// 覆盖两类场景：
  /// 1) Cloudflare 挑战页：用精确主动特征（零误杀），正常小说页不可能包含；
  /// 2) 非 Cloudflare 的站点自带验证系统（如 PTCMS 的「系统安全验证」）：
  ///    用「标题/短体验证信号」综合判定，并对弱信号加长度闸门，避免把正常
  ///    大内容页（含 footer「账号安全验证」链接等）误判为验证页。
  ///
  /// 命中即抛 [VerificationRequiredException]，交由既有 WebView 验证回灌流程过验证，
  /// 而非静默返回空结果或抛普通异常被上层吞掉。
  static bool _looksLikeVerificationChallenge(String body) {
    if (body.isEmpty) return false;
    final lower = body.toLowerCase();

    // 1) 精确 Cloudflare 主动特征（零误杀，正常内容页绝不含）。
    const cfMarkers = <String>[
      'just a moment',
      'enable javascript and cookies to continue',
      'cf-mitigated',
      '__cf_chl',
      'attention required! | cloudflare',
    ];
    if (cfMarkers.any(lower.contains)) return true;

    // 2) 通用验证/反爬挑战页识别。
    final title = _extractTitle(lower);
    final titleHasVerify = title.contains('验证') ||
        title.contains('verify') ||
        title.contains('安全验证');

    // 强特征：基本只出现在验证/反爬挑战页（如 PTCMS「系统安全验证」、geetest 滑块）。
    // 这类特征在正常小说列表页极不可能出现，命中即判，不依赖长度闸门。
    const strongBody = <String>[
      '系统安全验证',
      '请完成安全验证',
      '请滑动完成验证',
      '请拖动滑块',
      '人机验证',
      '滑动验证',
      '滑块验证',
      'verify you are human',
      'confirm you are human',
      'secapi',
      'geetest',
      // PTCMS 系「_guard」滑块反爬：真实返回体只有一行
      // `<script src="/_guard/html.js?js=slider_html"></script>`（HTTP 200，
      // 无标题、无「验证」字样）。裸正文不含任何上述特征，故需单独识别其脚本路径。
      // 用 `_guard/` 而非裸 `_guard`，避免误匹配正常页内 `_guardMode` 之类变量。
      '_guard/',
      'slider_html',
    ];
    if (strongBody.any(lower.contains)) return true;

    // 弱特征：可能出现在正常页 footer（如「账号安全验证」链接），仅在页面较小
    // 且标题也带验证词时才判，避免误伤正常大内容页。
    const weakBody = <String>[
      '安全验证',
      '安全校验',
      '验证系统',
      '请验证',
      '滑块',
    ];
    final weakHits = weakBody.where(lower.contains).length;
    final isSmall = body.length <= 65536; // 64KB 长度闸门
    if (isSmall && titleHasVerify && weakHits >= 1) return true;

    return false;
  }

  /// 从 HTML 中提取 <title> 文本（小写），用于验证页标题特征判定。
  static String _extractTitle(String lowerBody) {
    final start = lowerBody.indexOf('<title');
    if (start < 0) return '';
    final gt = lowerBody.indexOf('>', start);
    if (gt < 0) return '';
    final end = lowerBody.indexOf('</title>', gt);
    if (end < 0) return '';
    return lowerBody.substring(gt + 1, end).trim();
  }
}

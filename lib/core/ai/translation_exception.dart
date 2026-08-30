/// 翻译链路统一异常：message 为用户可读文案（B7 错误归一化）。
///
/// 三个翻译模块（小说段落 / 漫画页 / 视频字幕）的 catch 处统一经
/// [TranslationException.from] 归一化——底层 DioException / Timeout 的
/// 原始报文不再直接上屏，仅归入「连接失败 / 超时 / 其他」三类可读文案；
/// 原始细节由调用方写入 [AppLog]（详见各模块 catch 处）。
library;

/// 翻译链路异常。
class TranslationException implements Exception {
  const TranslationException(this.message, {this.kind = TranslationKind.other});

  /// 用户可读文案。
  final String message;

  /// 错误类别（F9 失败路由：仅 connection/timeout/rateLimit 触发端点切换）。
  final TranslationKind kind;

  @override
  String toString() => message;

  /// 把底层异常归一化为可读文案：
  /// - 连接类（DNS / Connection / Socket）→「网络连接失败」；
  /// - 超时类（timeout / TimedOut）→「请求超时」；
  /// - 限流类（429 / rate limit）→「请求过于频繁」；
  /// - 未配置接口 → 原样保留（含操作指引）；
  /// - 其余 →「翻译失败：」前缀保留原始摘要（截断防刷屏）。
  factory TranslationException.from(Object e) {
    if (e is TranslationException) return e;
    final s = e.toString();
    if (s.contains('Connection') ||
        s.contains('SocketException') ||
        s.contains('Failed host lookup')) {
      return const TranslationException(
        '网络连接失败，请检查网络后重试',
        kind: TranslationKind.connection,
      );
    }
    if (s.contains('429') || s.toLowerCase().contains('rate limit')) {
      return const TranslationException(
        '请求过于频繁，请稍后重试',
        kind: TranslationKind.rateLimit,
      );
    }
    if (s.contains('timeout') ||
        s.contains('TimedOut') ||
        s.contains('TimeoutException')) {
      return const TranslationException(
        '请求超时，请稍后重试',
        kind: TranslationKind.timeout,
      );
    }
    // 摘要截断：原始报文可能极长（HTML 错误页等）。
    final brief =
        s.length > 160 ? '${s.substring(0, 160)}…' : s;
    return TranslationException('翻译失败：$brief');
  }
}

/// 错误类别。
enum TranslationKind { connection, timeout, rateLimit, other }

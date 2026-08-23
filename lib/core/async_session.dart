/// 异步会话取消令牌（F-28）。
///
/// 替代各阅读器手写的 `int _loadToken` 模式，提供统一的「开启新会话 / 校验当前
/// 会话」能力，杜绝过期异步回调写状态（如用户已切集 / 退出 / 发起更新请求）。
///
/// 典型用法：在发起会被后续状态写入依赖的异步操作前取新令牌，await 之后校验
/// 令牌是否仍有效；若已被 [next] 取代（更新请求抢先），则丢弃本次结果：
///
/// ```dart
/// final int token = _loadSession.next();
/// final data = await loadSomething();
/// if (!_loadSession.isValid(token)) return; // 已被更新的请求取代
/// ```
class AsyncSession {
  int _token = 0;

  /// 当前有效令牌值。
  int get current => _token;

  /// 开启新会话：使所有旧令牌失效，返回新令牌。
  ///
  /// 每次发起可能被状态写入依赖的异步操作（解析 / 加载章节 / 拉弹幕 / 评论等）
  /// 前调用，确保更早未完成的请求在落盘前被判定为过期。
  int next() => ++_token;

  /// [token] 是否仍为当前有效会话（未被 [next] 取代）。
  bool isValid(int token) => token == _token;

  /// 使所有令牌失效（如页面销毁）。此后任何 [isValid] 均返回 false，
  /// 让悬挂的异步回调安全短路，避免向已销毁的 State 写数据。
  void invalidate() => _token = -1;
}

/// AI 端点失败路由（F9 多提供商与失败路由）。
///
/// 每个翻译功能支持「主 + 备用」端点列表；请求按序尝试，仅在
/// **连接失败 / 超时 / 429 限流**三类可切换错误上落到下一端点
/// （[TranslationKind] 归一化判定），解析失败等其他错误不切换。
///
/// **会话内健康度**：某端点连续 2 次失败后停用 5 分钟（内存记忆，
/// 不跨进程），路由直接跳过被熔断的端点；切换记录入 [AppLog]。
library;

import 'package:meta/meta.dart' show visibleForTesting;

import '../../../core/utils/app_log.dart';
import 'translation_exception.dart';
import 'vision_translation_client.dart' show AiEndpointConfig;

/// 端点路由器（无状态实例即可；健康度为类级会话记忆）。
abstract final class AiEndpointRouter {
  /// 连续失败次数达到该值后熔断端点 5 分钟。
  static const int _kFailuresToTrip = 2;
  static const Duration _kCooldown = Duration(minutes: 5);

  /// 会话内健康度记忆：端点标识 → (连续失败次数, 熔断截止时间)。
  static final Map<String, (int, DateTime)> _health =
      <String, (int, DateTime)>{};

  /// 清空健康度记忆（测试用；生产路由跨请求保持会话记忆）。
  @visibleForTesting
  static void resetHealth() => _health.clear();

  static String _identity(AiEndpointConfig cfg) =>
      '${cfg.baseUrl.trim()}|${cfg.model.trim()}';

  static bool _isCoolingDown(AiEndpointConfig cfg) {
    final state = _health[_identity(cfg)];
    if (state == null) return false;
    return state.$1 >= _kFailuresToTrip &&
        DateTime.now().isBefore(state.$2);
  }

  static void _recordFailure(AiEndpointConfig cfg) {
    final key = _identity(cfg);
    final state = _health[key] ?? (0, DateTime.fromMillisecondsSinceEpoch(0));
    _health[key] = (
      state.$1 + 1,
      state.$1 + 1 >= _kFailuresToTrip
          ? DateTime.now().add(_kCooldown)
          : state.$2
    );
  }

  static void _recordSuccess(AiEndpointConfig cfg) {
    _health.remove(_identity(cfg));
  }

  /// 按端点顺序执行 [task]：
  /// - 跳过未配置（baseUrl 为空）与熔断中的端点；
  /// - 仅 connection / timeout / rateLimit 类错误切换下一端点；
  /// - 全部失败时抛最后一次异常（调用方按现状展示）。
  static Future<T> execute<T>(
    List<AiEndpointConfig> endpoints,
    Future<T> Function(AiEndpointConfig config) task,
  ) async {
    if (endpoints.isEmpty) {
      throw const TranslationException('未配置云端 AI 接口');
    }
    Object? lastError;
    var switched = false;
    for (final cfg in endpoints) {
      if (!cfg.isConfigured) continue;
      if (_isCoolingDown(cfg)) {
        AppLog.instance
            .w('[路由] 端点熔断中，跳过: ${cfg.baseUrl} (${cfg.model})');
        continue;
      }
      try {
        final result = await task(cfg);
        _recordSuccess(cfg);
        if (switched) {
          AppLog.instance.w('[路由] 已切换到备用端点成功: ${cfg.baseUrl}');
        }
        return result;
      } on Object catch (e) {
        lastError = e;
        final kind = e is TranslationException
            ? e.kind
            : TranslationException.from(e).kind;
        _recordFailure(cfg);
        final switchable = kind == TranslationKind.connection ||
            kind == TranslationKind.timeout ||
            kind == TranslationKind.rateLimit;
        AppLog.instance.w('[路由] 端点失败（$kind，可切换=$switchable）: '
            '${cfg.baseUrl}');
        if (!switchable) rethrow;
        switched = true;
      }
    }
    // 所有端点都不可用：若有被熔断跳过的端点，仍尝试一次最后一个，
    // 避免 5 分钟冷却期内完全无服务。
    for (final cfg in endpoints) {
      if (!cfg.isConfigured) continue;
      if (_isCoolingDown(cfg)) {
        AppLog.instance.w('[路由] 冷却期内强制尝试端点: ${cfg.baseUrl}');
        return await task(cfg);
      }
    }
    if (lastError is TranslationException) throw lastError;
    throw TranslationException.from(lastError ?? Exception('无可用端点'));
  }
}

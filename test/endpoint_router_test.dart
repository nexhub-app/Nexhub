/// F9（多提供商与失败路由）单元测试。
///
/// - 连接/超时/429 类错误切换备用端点并成功返回；
/// - 解析类错误不切换（直接抛出）；
/// - 连续 2 次失败后端点熔断 5 分钟（冷却期内直接从备用开始；
///   全部熔断时强制尝试而非无服务）；
/// - 端点列表组装：主端点回落通用配置、备用留空不启用。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/ai/endpoint_router.dart';
import 'package:nexhub/core/ai/translation_exception.dart';
import 'package:nexhub/core/ai/vision_translation_client.dart';
import 'package:nexhub/features/novel/domain/novel_summary_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _primary = AiEndpointConfig(baseUrl: 'http://primary', apiKey: 'k', model: 'm1');
const _backup = AiEndpointConfig(baseUrl: 'http://backup', apiKey: 'k', model: 'm2');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // 健康度是类级会话记忆，用例间清场保证确定性。
    AiEndpointRouter.resetHealth();
  });

  test('主端点连接失败 → 自动落到备用端点并成功返回', () async {
    final result = await AiEndpointRouter.execute<String>(
      <AiEndpointConfig>[_primary, _backup],
      (cfg) async {
        if (cfg.baseUrl == 'http://primary') {
          throw Exception('SocketException: connection refused');
        }
        return 'ok-${cfg.baseUrl}';
      },
    );
    expect(result, 'ok-http://backup');
  });

  test('429 限流可切换', () async {
    final result = await AiEndpointRouter.execute<String>(
      <AiEndpointConfig>[_primary, _backup],
      (cfg) async {
        if (cfg.baseUrl == 'http://primary') {
          throw Exception('DioException [bad response]: 429 Too Many Requests');
        }
        return 'ok';
      },
    );
    expect(result, 'ok');
  });

  test('解析类错误（other）不切换，直接抛出', () async {
    await expectLater(
      AiEndpointRouter.execute<String>(
        <AiEndpointConfig>[_primary, _backup],
        (cfg) async => throw const TranslationException('翻译返回格式异常'),
      ),
      throwsA(isA<TranslationException>()),
    );
  });

  test('连续 2 次失败熔断主端点：后续请求直接跳过主端点', () async {
    var primaryCalls = 0;
    // 主端点连续失败 2 次（备用正常返回），主端点进入 5 分钟冷却。
    for (var i = 0; i < 2; i++) {
      await AiEndpointRouter.execute<String>(
        <AiEndpointConfig>[_primary, _backup],
        (cfg) async {
          if (cfg.baseUrl == 'http://primary') {
            primaryCalls++;
            throw Exception('SocketException: connection refused');
          }
          return 'ok-backup';
        },
      );
    }
    expect(primaryCalls, 2);
    // 主端点熔断中：下一请求只打备用。
    var sawPrimary = false;
    final result = await AiEndpointRouter.execute<String>(
      <AiEndpointConfig>[_primary, _backup],
      (cfg) async {
        if (cfg.baseUrl == 'http://primary') sawPrimary = true;
        return 'ok';
      },
    );
    expect(result, 'ok');
    expect(sawPrimary, isFalse);
  });

  test('全部端点熔断时强制尝试而非直接失败', () async {
    // 制造主备都熔断。
    for (var i = 0; i < 2; i++) {
      try {
        await AiEndpointRouter.execute<String>(
          <AiEndpointConfig>[_primary, _backup],
          (cfg) async => throw Exception('Connection refused'),
        );
      } on Object {
        // 预期失败。
      }
    }
    final result = await AiEndpointRouter.execute<String>(
      <AiEndpointConfig>[_primary, _backup],
      (cfg) async => 'forced-${cfg.baseUrl}',
    );
    expect(result, startsWith('forced-'));
  });

  test('主端点成功后清除失败计数', () async {
    // 1 次失败（未达熔断阈值）。
    try {
      await AiEndpointRouter.execute<String>(
        <AiEndpointConfig>[_primary],
        (cfg) async => throw Exception('Connection refused'),
      );
    } on Object {
      // 预期失败。
    }
    // 成功一次 → 计数清零；再失败 1 次不应熔断。
    await AiEndpointRouter.execute<String>(
      <AiEndpointConfig>[_primary],
      (cfg) async => 'ok',
    );
    var calls = 0;
    try {
      await AiEndpointRouter.execute<String>(
        <AiEndpointConfig>[_primary],
        (cfg) async {
          calls++;
          throw Exception('Connection refused');
        },
      );
    } on Object {
      // 预期失败。
    }
    expect(calls, 1); // 未被熔断跳过。
  });

  test('端点列表组装：主端点回落通用、备用留空不启用', () async {
    SharedPreferences.setMockInitialValues(<String, String>{
      'novel_overview_api_base_v1': 'http://common',
      'novel_translation_api_base_bak_v1': 'http://bak',
      'novel_translation_api_key_bak_v1': 'kbak',
    });
    final s = NovelSummarySettings.instance;
    final endpoints = await s.getTranslationEndpoints();
    expect(endpoints, hasLength(2));
    expect(endpoints[0].baseUrl, 'http://common'); // 功能级留空回落通用。
    expect(endpoints[1].baseUrl, 'http://bak');
    // 未配置备用 → 只有主端点。
    SharedPreferences.setMockInitialValues(<String, String>{
      'novel_overview_api_base_v1': 'http://common',
    });
    final only = await s.getTranslationEndpoints();
    expect(only, hasLength(1));
  });
}

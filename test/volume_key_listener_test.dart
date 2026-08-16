import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/utils/app_log.dart';
import 'package:nexhub/core/utils/volume_key_listener.dart';

/// Bug1 音量键翻页修复测试：
/// - start() 必须先订阅事件流（触发原生 EventChannel.onListen → 设置 volumeEventSink）
///   再开启原生拦截，消除 enable 与事件通道订阅的竞态；
/// - 'volume_down' / 'volume_up' 事件正确路由到对应回调（阅读器侧 down→next、up→prev）；
/// - enableInterception 抛异常时写日志并 rethrow（不再被 unawaited 静默吞掉）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel control = MethodChannel('nexhub/volume_control');
  const MethodChannel eventMethod = MethodChannel('nexhub/volume_events');
  // EventChannel.receiveBroadcastStream 内部以 channel name 本身作为事件流通道
  // 注册消息 handler（见 platform_channel.dart），原生事件经此通道送达。
  const String eventChannelName = 'nexhub/volume_events';

  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    AppLog.instance.clear();
    // 清除所有 mock 避免跨测试污染。
    messenger.setMockMethodCallHandler(control, null);
    messenger.setMockMethodCallHandler(eventMethod, null);
  });

  test('start 先订阅事件流再开启拦截，事件路由到对应回调', () async {
    int listenCount = 0;
    int listensWhenEnableCalled = -1;

    // 模拟 EventChannel.receiveBroadcastStream 内部的 listen 方法调用。
    messenger.setMockMethodCallHandler(eventMethod, (call) async {
      if (call.method == 'listen') {
        listenCount++;
      }
      return null;
    });

    // 控制通道：记录 enableInterception 被调用时事件流已订阅的次数。
    messenger.setMockMethodCallHandler(control, (call) async {
      if (call.method == 'enableInterception') {
        listensWhenEnableCalled = listenCount;
      }
      return null;
    });

    final List<String> down = <String>[];
    final List<String> up = <String>[];
    final listener = VolumeKeyListener();
    await listener.start(
      onVolumeDown: () => down.add('down'),
      onVolumeUp: () => up.add('up'),
    );

    // 先订阅（listen=1）后拦截（enable 时已订阅）。
    expect(listenCount, 1);
    expect(listensWhenEnableCalled, 1,
        reason: '必须先订阅事件流（原生 EventSink 就绪）再开启拦截');

    // 模拟原生侧 EventSink.success 推送事件：经事件流通道 handlePlatformMessage。
    void pushEvent(Object event) {
      messenger.handlePlatformMessage(
        eventChannelName,
        const StandardMethodCodec().encodeSuccessEnvelope(event),
        (_) {},
      );
    }

    pushEvent('volume_down');
    await Future<void>.delayed(Duration.zero);
    expect(down, <String>['down'], reason: 'volume_down 事件应路由到 onVolumeDown');

    pushEvent('volume_up');
    await Future<void>.delayed(Duration.zero);
    expect(up, <String>['up'], reason: 'volume_up 事件应路由到 onVolumeUp');

    // 无关事件不触发回调。
    pushEvent('other');
    await Future<void>.delayed(Duration.zero);
    expect(down, <String>['down']);
    expect(up, <String>['up']);

    await listener.stop();
  });

  test('start 在 enableInterception 抛异常时写日志并 rethrow', () async {
    messenger.setMockMethodCallHandler(control, (call) async {
      throw PlatformException(code: 'unavailable', message: 'channel not ready');
    });

    final listener = VolumeKeyListener();
    await expectLater(
      listener.start(onVolumeDown: () {}, onVolumeUp: () {}),
      throwsA(isA<PlatformException>()),
    );
    // 失败不再被静默吞掉：运行日志写入错误级条目。
    expect(
      AppLog.instance.entries.any((e) => e.contains('[音量键] 监听启动失败')),
      isTrue,
      reason: 'enableInterception 失败时必须写日志',
    );
  });

  test('stop 取消订阅并调用 disableInterception', () async {
    final List<String> calls = <String>[];
    messenger.setMockMethodCallHandler(control, (call) async {
      calls.add(call.method);
      return null;
    });

    final listener = VolumeKeyListener();
    await listener.start(onVolumeDown: () {}, onVolumeUp: () {});
    calls.clear();
    await listener.stop();
    expect(calls, contains('disableInterception'));
  });
}

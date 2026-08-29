// NetworkClientBuilder TLS 直连集成测试：本地 SecureServerSocket + 自签证书。
//
// 回归背景：connectionFactory 返回的 socket 会被 HttpClient 原样使用，https
// 直连时客户端不会再补做 TLS。旧实现返回裸 TCP socket → 明文打到 443。本组
// 测试以「握手必须完成、HTTP 响应必须可解析」守住该缺陷，并覆盖 SNI 覆盖 /
// 免 SNI 三种形态（服务端自签证书 CN=probe.test，客户端 onBadCertificate 容忍）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/network/model/effective_network_profile.dart';
import 'package:nexhub/core/network/model/network_config.dart';
import 'package:nexhub/core/network/runtime/network_client_builder.dart';

const String _probeHost = 'probe.test';

EffectiveNetworkProfile _profile({SniConfig? sni}) {
  final cfg = NetworkConfig(
    proxy: const ProxyConfig(mode: ProxyMode.direct),
    // Hosts 钉住 probe.test → 127.0.0.1，触发 needsCustomConnection（自定义连接）。
    hosts: const <HostsEntry>[HostsEntry(ip: '127.0.0.1', host: _probeHost)],
    sni: sni ?? SniConfig.defaults,
  );
  return EffectiveNetworkProfile.fromConfig(cfg);
}

/// 本地 TLS 服务器：读完请求头后回 200 + "OK"。
///
/// 注意：不能对 socket 的读订阅 cancel/break——Dart 的 SecureSocket 在取消
/// 读订阅后，后续 write 会静默丢失（flush 正常返回但对端收不到）。故用标记
/// 跳过后续读事件而非取消订阅。
Future<SecureServerSocket> _startTlsServer() async {
  final ctx = SecurityContext()
    ..useCertificateChainBytes(
      File('test/fixtures/sni_probe_cert.pem').readAsBytesSync(),
    )
    ..usePrivateKeyBytes(
      File('test/fixtures/sni_probe_key.pem').readAsBytesSync(),
    );
  final server = await SecureServerSocket.bind(
    InternetAddress.loopbackIPv4,
    0,
    ctx,
  );
  server.listen((socket) {
    final buffer = BytesBuilder();
    var replied = false;
    socket.listen((chunk) {
      if (replied) return;
      buffer.add(chunk);
      if (String.fromCharCodes(buffer.toBytes()).contains('\r\n\r\n')) {
        replied = true;
        socket.write('HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nOK');
        socket.flush().whenComplete(() => socket.destroy());
      }
    });
  });
  return server;
}

Future<int> _fetchStatus(HttpClient client, int port) async {
  final req = await client
      .getUrl(Uri.parse('https://$_probeHost:$port/'))
      .timeout(const Duration(seconds: 10));
  final resp = await req.close().timeout(const Duration(seconds: 10));
  final body = await resp.transform(utf8.decoder).join();
  expect(body, 'OK');
  return resp.statusCode;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SecureServerSocket server;

  setUpAll(() async {
    server = await _startTlsServer();
  });

  tearDownAll(() {
    server.close();
  });

  group('connectionFactory https 直连', () {
    test('SNI 未配置：工厂内完成 TLS（明文回归修复）', () async {
      final client = NetworkClientBuilder.buildHttpClient(_profile());
      final status = await _fetchStatus(client, server.port);
      expect(status, 200);
      client.close(force: true);
    });

    test("defaultSni='-' 免 SNI 握手成功", () async {
      final client = NetworkClientBuilder.buildHttpClient(
        _profile(sni: const SniConfig(enabled: true, defaultSni: '-')),
      );
      final status = await _fetchStatus(client, server.port);
      expect(status, 200);
      client.close(force: true);
    });

    test('domainSni 自定义 SNI 名握手成功（证书失配被容忍）', () async {
      final client = NetworkClientBuilder.buildHttpClient(
        _profile(
          sni: const SniConfig(
            enabled: true,
            domainSni: {_probeHost: 'other.name.example'},
          ),
        ),
      );
      final status = await _fetchStatus(client, server.port);
      expect(status, 200);
      client.close(force: true);
    });
  });
}

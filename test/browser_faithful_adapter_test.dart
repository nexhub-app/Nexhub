/// [BrowserFaithfulHttpClientAdapter] 单元测试。
///
/// 用本地 ServerSocket 抓取适配器发出的**原始请求字节**，验证：
/// - `Host` 位于首行、头名为 Title-Case（这是过 Cloudflare 头指纹的关键）；
/// - gzip / deflate 响应体能正确解压；
/// - chunked 传输编码能正确解块；
/// - 3xx 重定向能跟随（301/302/303 转 GET）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/scraper/browser_faithful_adapter.dart';

void main() {
  late ServerSocket server;
  final captured = <String>[];

  Dio dioFor() => Dio()
    ..options.baseUrl = 'http://127.0.0.1:${server.port}'
    ..httpClientAdapter = BrowserFaithfulHttpClientAdapter();

  tearDown(() async {
    await server.close();
    captured.clear();
  });

  /// 通用监听：每个连接读到完整请求头后回调 [respond] 取响应字节，写回并关闭。
  void serve(List<int> Function(String head, String fullRequest) respond) {
    server.listen((socket) async {
      final buf = <int>[];
      await socket.forEach((chunk) {
        buf.addAll(chunk);
        final text = latin1.decode(buf, allowInvalid: true);
        final sep = text.indexOf('\r\n\r\n');
        if (sep >= 0) {
          final head = text.substring(0, sep);
          captured.add(head);
          socket.add(respond(head, text));
          socket.flush().then((_) => socket.destroy());
        }
      });
    });
  }

  List<int> rawResponse(String body, {String extraHeaders = ''}) {
    final bytes = utf8.encode(body);
    final head = 'HTTP/1.1 200 OK\r\n'
        'Content-Type: text/html; charset=utf-8\r\n'
        'Content-Length: ${bytes.length}\r\n'
        '${extraHeaders}Connection: close\r\n\r\n';
    return [...ascii.encode(head), ...bytes];
  }

  test('请求头 Host 首行且头名为 Title-Case', () async {
    server = await ServerSocket.bind('127.0.0.1', 0);
    serve((head, full) => rawResponse('<html>ok</html>'));

    final resp = await dioFor().get<String>(
      '/book/1',
      options: Options(headers: {
        'user-agent': 'UA-Test',
        'accept': 'text/html',
        'referer': 'http://127.0.0.1/',
      }),
    );

    expect(resp.statusCode, 200);
    expect(resp.data, contains('ok'));

    final head = captured.single;
    final lines = head.split('\r\n');
    expect(lines.first, startsWith('GET /book/1 HTTP/1.1'));
    // 第一个头必须是 Host。
    expect(lines[1], startsWith('Host: 127.0.0.1:'));
    // 头名为 Title-Case，且不含全小写形式。
    expect(head, contains('User-Agent: UA-Test'));
    expect(head, contains('Accept: text/html'));
    expect(head, contains('Referer: http://127.0.0.1/'));
    expect(head, isNot(contains('user-agent:')));
    expect(head, isNot(contains('\naccept:')));
  });

  test('gzip 响应体正确解压', () async {
    server = await ServerSocket.bind('127.0.0.1', 0);
    const original = '<html>压缩正文-gzip</html>';
    final gz = gzip.encode(utf8.encode(original));
    serve((head, full) {
      final headStr = 'HTTP/1.1 200 OK\r\n'
          'Content-Type: text/html; charset=utf-8\r\n'
          'Content-Encoding: gzip\r\n'
          'Content-Length: ${gz.length}\r\n'
          'Connection: close\r\n\r\n';
      return [...ascii.encode(headStr), ...gz];
    });

    final resp = await dioFor().get<String>('/g');
    expect(resp.statusCode, 200);
    expect(resp.data, original);
  });

  test('chunked 传输编码正确解块', () async {
    server = await ServerSocket.bind('127.0.0.1', 0);
    serve((head, full) {
      // 两个块 "Hello" + "World" + 终止块。
      const chunked = '5\r\nHello\r\n5\r\nWorld\r\n0\r\n\r\n';
      const headStr = 'HTTP/1.1 200 OK\r\n'
          'Content-Type: text/plain\r\n'
          'Transfer-Encoding: chunked\r\n'
          'Connection: close\r\n\r\n';
      return [...ascii.encode(headStr), ...ascii.encode(chunked)];
    });

    final resp = await dioFor().get<String>('/c');
    expect(resp.statusCode, 200);
    expect(resp.data, 'HelloWorld');
  });

  test('302 重定向跟随并转 GET', () async {
    server = await ServerSocket.bind('127.0.0.1', 0);
    server.listen((socket) async {
      final buf = <int>[];
      await socket.forEach((chunk) {
        buf.addAll(chunk);
        final text = latin1.decode(buf, allowInvalid: true);
        final sep = text.indexOf('\r\n\r\n');
        if (sep < 0) return;
        final head = text.substring(0, sep);
        captured.add(head);
        final target = head.split('\r\n').first;
        if (target.startsWith('GET /start')) {
          const h = 'HTTP/1.1 302 Found\r\n'
              'Location: /dest\r\n'
              'Content-Length: 0\r\n'
              'Connection: close\r\n\r\n';
          socket.add(ascii.encode(h));
        } else {
          final body = utf8.encode('final-page');
          final h = 'HTTP/1.1 200 OK\r\n'
              'Content-Type: text/plain\r\n'
              'Content-Length: ${body.length}\r\n'
              'Connection: close\r\n\r\n';
          socket.add([...ascii.encode(h), ...body]);
        }
        socket.flush().then((_) => socket.destroy());
      });
    });

    final resp = await dioFor().get<String>('/start');
    expect(resp.statusCode, 200);
    expect(resp.data, 'final-page');
    expect(captured.length, 2);
    expect(captured[1].split('\r\n').first, startsWith('GET /dest'));
  });

  test('POST 携带请求体与 Content-Length', () async {
    server = await ServerSocket.bind('127.0.0.1', 0);
    serve((head, full) => rawResponse('posted'));

    final resp = await dioFor().post<String>(
      '/s',
      data: 'keyword=abc',
      options: Options(
        headers: {'content-type': 'application/x-www-form-urlencoded'},
      ),
    );

    expect(resp.statusCode, 200);
    expect(resp.data, contains('posted'));
    final full = captured.single;
    expect(full.split('\r\n').first, startsWith('POST /s HTTP/1.1'));
    expect(full, contains('Content-Type: application/x-www-form-urlencoded'));
    expect(full, contains('Content-Length: 11')); // 'keyword=abc'
  });
}

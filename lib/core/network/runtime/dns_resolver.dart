/// DNS 解析器：带 TTL 缓存，支持 system / custom(UDP) / DoH / DoT 四模式，
/// 并优先命中自定义 Hosts。
///
/// 供 [NetworkClientBuilder] 的 `connectionFactory` 使用（当档案
/// `needsCustomConnection` 时）。DoH 端点自身经独立、未挂 HttpOverrides 的裸
/// HttpClient 请求，用系统 DNS 引导，避免递归。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../model/network_config.dart';

/// 缓存条目（含过期时间）。
class _CacheEntry {
  final List<InternetAddress> addresses;
  final DateTime expiresAt;
  _CacheEntry(this.addresses, this.expiresAt);
  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

/// DNS 解析器（进程内单例，缓存全局共享）。
class DnsResolver {
  DnsResolver._();
  static final DnsResolver instance = DnsResolver._();

  final Map<String, _CacheEntry> _cache = <String, _CacheEntry>{};

  /// 默认缓存 TTL（当解析结果未给出可用 TTL 时使用）。
  static const Duration _defaultTtl = Duration(minutes: 5);

  /// 缓存条目数。
  int get cacheSize => _cache.length;

  /// 清空缓存。
  void clearCache() => _cache.clear();

  /// 解析主机名到 IP 列表。
  ///
  /// 顺序：① 命中启用的 Hosts → 直接返回其 IP（不进 DNS，不缓存）；
  /// ② 缓存命中且未过期 → 返回；③ 按 [DnsMode] 分派解析并写入缓存。
  Future<List<InternetAddress>> resolve(
    String host,
    DnsConfig cfg,
    List<HostsEntry> hosts,
  ) async {
    // 已是 IP 字面量：直接返回。
    final literal = InternetAddress.tryParse(host);
    if (literal != null) return <InternetAddress>[literal];

    // ① Hosts 优先。
    for (final h in hosts) {
      if (!h.enabled) continue;
      if (h.host.toLowerCase() == host.toLowerCase() && h.ip.isNotEmpty) {
        final addr = InternetAddress.tryParse(h.ip);
        if (addr != null) return <InternetAddress>[addr];
      }
    }

    // ② 缓存（仅在启用时）。
    final cacheKey = '${cfg.mode.name}|$host';
    if (cfg.cacheEnabled) {
      final entry = _cache[cacheKey];
      if (entry != null && !entry.isExpired) return entry.addresses;
    }

    // ③ 按模式解析。
    List<InternetAddress> result;
    try {
      switch (cfg.mode) {
        case DnsMode.system:
          result = await InternetAddress.lookup(host);
          break;
        case DnsMode.custom:
          result = await _resolveCustom(host, cfg.servers);
          break;
        case DnsMode.doh:
          result = await _resolveDoh(host, cfg.dohUrl);
          break;
        case DnsMode.dot:
          result = await _resolveDot(host, cfg.dotHost, cfg.dotPort);
          break;
      }
    } on Object catch (e, st) {
      debugPrint('DnsResolver.resolve($host, ${cfg.mode}) failed: $e\n$st');
      // 回退系统解析，保证可用性。
      result = await InternetAddress.lookup(host);
    }

    if (result.isEmpty) {
      result = await InternetAddress.lookup(host);
    }

    if (cfg.cacheEnabled) {
      _cache[cacheKey] = _CacheEntry(result, DateTime.now().add(_defaultTtl));
    }
    return result;
  }

  // ---- custom (UDP :53) ----

  Future<List<InternetAddress>> _resolveCustom(
    String host,
    List<String> servers,
  ) async {
    for (final server in servers) {
      final serverAddr = InternetAddress.tryParse(server);
      if (serverAddr == null) continue;
      try {
        final answers = await _queryUdp(host, serverAddr);
        if (answers.isNotEmpty) return answers;
      } on Object catch (e) {
        debugPrint('DnsResolver custom($server) failed: $e');
      }
    }
    return const <InternetAddress>[];
  }

  Future<List<InternetAddress>> _queryUdp(
    String host,
    InternetAddress server,
  ) async {
    final socket = await RawDatagramSocket.bind(
      server.type == InternetAddressType.IPv6
          ? InternetAddress.anyIPv6
          : InternetAddress.anyIPv4,
      0,
    );
    final completer = Completer<List<InternetAddress>>();
    final query = _buildQuery(host, type: 1); // A record
    try {
      final sub = socket.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          final dg = socket.receive();
          if (dg == null) return;
          try {
            final addrs = _parseResponse(dg.data);
            if (!completer.isCompleted) completer.complete(addrs);
          } on Object catch (e) {
            if (!completer.isCompleted) completer.completeError(e);
          }
        }
      });
      socket.send(query, server, 53);
      final result = await completer.future
          .timeout(const Duration(seconds: 5), onTimeout: () => const []);
      await sub.cancel();
      return result;
    } finally {
      socket.close();
    }
  }

  // ---- DoH (dns-json over HTTPS) ----

  Future<List<InternetAddress>> _resolveDoh(String host, String dohUrl) async {
    if (dohUrl.isEmpty) return const <InternetAddress>[];
    final base = Uri.tryParse(dohUrl);
    if (base == null) return const <InternetAddress>[];
    final uri = base.replace(queryParameters: <String, String>{
      ...base.queryParameters,
      'name': host,
      'type': 'A',
    });
    // 独立裸 HttpClient：不挂 HttpOverrides.global，用系统 DNS 引导，避免递归。
    final client = HttpClient();
    try {
      final req = await client.getUrl(uri);
      req.headers.set(HttpHeaders.acceptHeader, 'application/dns-json');
      final resp = await req.close().timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return const <InternetAddress>[];
      final body = await resp.transform(utf8.decoder).join();
      final json = jsonDecode(body);
      final answers = (json is Map) ? json['Answer'] : null;
      final out = <InternetAddress>[];
      if (answers is List) {
        for (final a in answers) {
          if (a is Map && (a['type'] == 1 || a['type'] == 28)) {
            final data = a['data'];
            if (data is String) {
              final addr = InternetAddress.tryParse(data);
              if (addr != null) out.add(addr);
            }
          }
        }
      }
      return out;
    } finally {
      client.close(force: true);
    }
  }

  // ---- DoT (TLS :853) ----

  Future<List<InternetAddress>> _resolveDot(
    String host,
    String dotHost,
    int dotPort,
  ) async {
    if (dotHost.isEmpty) return const <InternetAddress>[];
    final socket = await SecureSocket.connect(
      dotHost,
      dotPort <= 0 ? 853 : dotPort,
      onBadCertificate: (_) => true,
      timeout: const Duration(seconds: 8),
    );
    try {
      final query = _buildQuery(host, type: 1);
      // DoT/TCP：2 字节长度前缀 + DNS 报文。
      final framed = Uint8List(query.length + 2)
        ..[0] = (query.length >> 8) & 0xff
        ..[1] = query.length & 0xff
        ..setRange(2, query.length + 2, query);
      socket.add(framed);
      await socket.flush();
      final chunks = <int>[];
      await for (final data in socket.timeout(const Duration(seconds: 8))) {
        chunks.addAll(data);
        // 至少读到长度前缀 + 完整报文。
        if (chunks.length >= 2) {
          final len = (chunks[0] << 8) | chunks[1];
          if (chunks.length >= len + 2) {
            return _parseResponse(
              Uint8List.fromList(chunks.sublist(2, len + 2)),
            );
          }
        }
      }
      return const <InternetAddress>[];
    } finally {
      await socket.close();
    }
  }

  // ---- DNS wire format helpers ----

  /// 构建标准 DNS 查询报文（单问题，递归查询）。
  Uint8List _buildQuery(String host, {int type = 1}) {
    final builder = BytesBuilder();
    // Header：ID(2) Flags(2) QD(2) AN(2) NS(2) AR(2)。
    builder.add([0x12, 0x34]); // 固定 ID（UDP 单次查询无并发混淆）
    builder.add([0x01, 0x00]); // RD=1（期望递归）
    builder.add([0x00, 0x01]); // QDCOUNT=1
    builder.add([0x00, 0x00]); // ANCOUNT
    builder.add([0x00, 0x00]); // NSCOUNT
    builder.add([0x00, 0x00]); // ARCOUNT
    // Question：QNAME。
    for (final label in host.split('.')) {
      final bytes = utf8.encode(label);
      builder.addByte(bytes.length);
      builder.add(bytes);
    }
    builder.addByte(0); // 根标签
    builder.add([0x00, type & 0xff]); // QTYPE
    builder.add([0x00, 0x01]); // QCLASS=IN
    return builder.toBytes();
  }

  /// 解析 DNS 响应，提取 A/AAAA 记录。
  List<InternetAddress> _parseResponse(Uint8List data) {
    if (data.length < 12) return const <InternetAddress>[];
    final qdCount = (data[4] << 8) | data[5];
    final anCount = (data[6] << 8) | data[7];
    var offset = 12;
    // 跳过问题区。
    for (var i = 0; i < qdCount; i++) {
      offset = _skipName(data, offset);
      offset += 4; // QTYPE + QCLASS
    }
    final out = <InternetAddress>[];
    for (var i = 0; i < anCount && offset < data.length; i++) {
      offset = _skipName(data, offset);
      if (offset + 10 > data.length) break;
      final type = (data[offset] << 8) | data[offset + 1];
      final rdLength = (data[offset + 8] << 8) | data[offset + 9];
      final rdStart = offset + 10;
      if (rdStart + rdLength > data.length) break;
      if (type == 1 && rdLength == 4) {
        out.add(InternetAddress.fromRawAddress(
          Uint8List.fromList(data.sublist(rdStart, rdStart + 4)),
        ));
      } else if (type == 28 && rdLength == 16) {
        out.add(InternetAddress.fromRawAddress(
          Uint8List.fromList(data.sublist(rdStart, rdStart + 16)),
        ));
      }
      offset = rdStart + rdLength;
    }
    return out;
  }

  /// 跳过 DNS name 字段（处理压缩指针）。返回下一字段偏移。
  int _skipName(Uint8List data, int offset) {
    while (offset < data.length) {
      final len = data[offset];
      if (len == 0) return offset + 1;
      if ((len & 0xc0) == 0xc0) return offset + 2; // 压缩指针（2 字节）
      offset += len + 1;
    }
    return offset;
  }
}

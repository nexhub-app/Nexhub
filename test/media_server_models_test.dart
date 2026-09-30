/// 媒体服务器模型单测：地址规范化 / 类型识别 / 档案（反）序列化与 copyWith。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/services/media_server/media_server_models.dart';

void main() {
  group('normalizeBaseUrl', () {
    test('无 scheme 补 http://', () {
      expect(normalizeBaseUrl('192.168.1.10:8096'), 'http://192.168.1.10:8096');
    });

    test('https 与已有 scheme 原样保留', () {
      expect(
        normalizeBaseUrl('https://media.example.com'),
        'https://media.example.com',
      );
      expect(
        normalizeBaseUrl('http://192.168.1.10:8096'),
        'http://192.168.1.10:8096',
      );
    });

    test('去结尾斜杠（含多个）', () {
      expect(normalizeBaseUrl('http://nas:8096/'), 'http://nas:8096');
      expect(normalizeBaseUrl('http://nas:8096///'), 'http://nas:8096');
    });

    test('去首尾空白', () {
      expect(normalizeBaseUrl('  http://nas:8096  '), 'http://nas:8096');
    });

    test('空串保持空串（由上层报错）', () {
      expect(normalizeBaseUrl(''), '');
      expect(normalizeBaseUrl('   '), '');
    });
  });

  group('ServerType', () {
    test('fromProductName 识别两家', () {
      expect(ServerType.fromProductName('Jellyfin Server'), ServerType.jellyfin);
      expect(ServerType.fromProductName('Emby Server'), ServerType.emby);
    });

    test('fromProductName 大小写不敏感', () {
      expect(
        ServerType.fromProductName('jellyfin/10.9.2'),
        ServerType.jellyfin,
      );
    });

    test('未知 / null 返回 null（上层提示手选）', () {
      expect(ServerType.fromProductName('Kodi'), isNull);
      expect(ServerType.fromProductName(null), isNull);
    });

    test('fromVersion 兜底：实测 Emby 4.9 探测不带 ProductName', () {
      expect(ServerType.fromVersion('10.9.2'), ServerType.jellyfin);
      expect(ServerType.fromVersion('4.9.5.0'), ServerType.emby);
      expect(ServerType.fromVersion('3.0.1'), ServerType.emby);
      expect(ServerType.fromVersion(null), isNull);
    });

    test('JSON 往返', () {
      expect(ServerType.fromJson(ServerType.jellyfin.toJson()),
          ServerType.jellyfin);
      expect(
          ServerType.fromJson(ServerType.emby.toJson()), ServerType.emby);
    });
  });

  group('MediaServerInfo', () {
    test('JSON 往返保留全部字段', () {
      const info = MediaServerInfo(
        id: 'abc123',
        type: ServerType.jellyfin,
        name: '客厅 NAS',
        baseUrl: 'http://192.168.1.10:8096',
        userId: 'u1',
        username: 'alice',
        serverName: 'Jellyfin Server',
        version: '10.9.2',
      );
      final restored = MediaServerInfo.fromJson(info.toJson());
      expect(restored.id, info.id);
      expect(restored.type, info.type);
      expect(restored.name, info.name);
      expect(restored.baseUrl, info.baseUrl);
      expect(restored.userId, info.userId);
      expect(restored.username, info.username);
      expect(restored.serverName, info.serverName);
      expect(restored.version, info.version);
    });

    test('可空字段缺省反序列化为 null', () {
      final info = MediaServerInfo.fromJson(<String, dynamic>{
        'id': 'x',
        'type': 'emby',
        'name': 'n',
        'baseUrl': 'http://e:8096',
      });
      expect(info.type, ServerType.emby);
      expect(info.serverName, isNull);
      expect(info.version, isNull);
      expect(info.loggedIn, isFalse);
    });

    test('copyWith 局部更新', () {
      const base = MediaServerInfo(
        id: 'x',
        type: ServerType.jellyfin,
        name: 'n',
        baseUrl: 'http://nas:8096',
      );
      final updated = base.copyWith(userId: 'u9', username: 'bob');
      expect(updated.userId, 'u9');
      expect(updated.username, 'bob');
      expect(updated.loggedIn, isTrue);
      expect(updated.id, base.id);
      expect(updated.baseUrl, base.baseUrl);
    });
  });

  group('hasGraphicSubtitle（实测回填）', () {
    ServerMediaItem itemWith(List<String>? codecs) => ServerMediaItem(
          id: 'i',
          name: 'n',
          type: 'Movie',
          subtitleCodecs: codecs,
        );

    test('纯图形字幕（PGS）→ true', () {
      expect(itemWith(<String>['PGSSUB']).hasGraphicSubtitle, isTrue);
      expect(itemWith(<String>['HDMV_PGS_SUBTITLE']).hasGraphicSubtitle, isTrue);
    });

    test('图形 + 文本混合（实测 PGSSUB+srt/ssa）→ false，直连可出文本字幕', () {
      expect(
        itemWith(<String>['PGSSUB', 'srt', 'ssa']).hasGraphicSubtitle,
        isFalse,
      );
    });

    test('纯文本字幕 → false', () {
      expect(itemWith(<String>['srt', 'ass']).hasGraphicSubtitle, isFalse);
      expect(itemWith(<String>[]).hasGraphicSubtitle, isFalse);
      expect(itemWith(null).hasGraphicSubtitle, isFalse);
    });
  });
}

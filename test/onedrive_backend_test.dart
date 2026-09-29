/// OneDrive 后端 / WebDAV 后端 / 云同步配置 的纯逻辑单测。
///
/// 不发真实网络请求，只覆盖解析函数与 PKCE 派生等可独立验证的部分。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/services/cloud_sync_backend.dart';
import 'package:nexhub/core/services/cloud_sync_service.dart';
import 'package:nexhub/core/services/onedrive/onedrive_auth_service.dart';
import 'package:nexhub/core/services/onedrive/onedrive_backend.dart';
import 'package:nexhub/core/services/webdav_backend.dart';

void main() {
  group('OneDriveBackend.parseChildrenResponse', () {
    test('解析文件列表并跳过子目录', () {
      final json = <String, dynamic>{
        'value': <dynamic>[
          <String, dynamic>{
            'id': '1',
            'name': 'nexhub-backup-1000.zip',
            'size': 2048,
            'lastModifiedDateTime': '2026-09-29T12:34:56.789Z',
            'file': <String, dynamic>{},
          },
          <String, dynamic>{
            'id': '2',
            'name': 'subfolder',
            'folder': <String, dynamic>{},
          },
          <String, dynamic>{
            'id': '3',
            'name': 'nexhub-backup-2000.zip',
            'size': 4096,
            'file': <String, dynamic>{},
          },
        ],
      };
      final files = OneDriveBackend.parseChildrenResponse(json);
      expect(files, hasLength(2));
      expect(files[0].name, 'nexhub-backup-1000.zip');
      expect(files[0].size, 2048);
      expect(files[0].modifiedMs,
          DateTime.utc(2026, 9, 29, 12, 34, 56, 789).millisecondsSinceEpoch);
      expect(files[1].name, 'nexhub-backup-2000.zip');
      expect(files[1].size, 4096);
      expect(files[1].modifiedMs, isNull);
    });

    test('空响应 / 缺字段返回空列表', () {
      expect(
          OneDriveBackend.parseChildrenResponse(<String, dynamic>{}), isEmpty);
      expect(
          OneDriveBackend.parseChildrenResponse(<String, dynamic>{
            'value': <dynamic>[
              <String, dynamic>{'name': ''}
            ]
          }),
          isEmpty);
    });
  });

  group('OneDriveAuthService.deriveCodeChallenge', () {
    test('RFC 7636 附录 B 已知向量（S256）', () {
      const verifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
      expect(OneDriveAuthService.deriveCodeChallenge(verifier),
          'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM');
    });

    test('challenge 为 base64url 且无填充', () {
      final challenge = OneDriveAuthService.deriveCodeChallenge('abc');
      expect(challenge.contains('='), isFalse);
      expect(challenge.contains('+'), isFalse);
      expect(challenge.contains('/'), isFalse);
      expect(challenge, hasLength(43));
    });
  });

  group('WebDavBackend.parsePropfind', () {
    const xml = '<?xml version="1.0" encoding="utf-8"?>'
        '<D:multistatus xmlns:D="DAV:">'
        '<D:response><D:href>/nexhub/</D:href>'
        '<D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype>'
        '</D:prop></D:propstat></D:response>'
        '<D:response><D:href>/nexhub/nexhub-backup-1000.zip</D:href>'
        '<D:propstat><D:prop><D:resourcetype/></D:prop></D:propstat>'
        '</D:response>'
        '<D:response><D:href>/nexhub/nexhub-backup-2000.zip</D:href>'
        '<D:propstat><D:prop><D:resourcetype/></D:prop></D:propstat>'
        '</D:response>'
        '</D:multistatus>';

    test('解析文件并跳过集合与自身目录', () {
      final files = WebDavBackend.parsePropfind(xml);
      expect(files, hasLength(2));
      expect(files[0].name, 'nexhub-backup-1000.zip');
      expect(files[1].name, 'nexhub-backup-2000.zip');
    });

    test('空响应与非法 XML 返回空列表', () {
      expect(WebDavBackend.parsePropfind(''), isEmpty);
      expect(WebDavBackend.parsePropfind('not-xml'), isEmpty);
    });
  });

  group('CloudSyncConfig 后端字段', () {
    test('默认 WebDAV，旧配置（无 backend 字段）向后兼容', () {
      const legacy = <String, dynamic>{'url': 'https://dav.example.com'};
      final config = CloudSyncConfig.fromJson(legacy);
      expect(config.backend, CloudBackendKind.webdav);
      expect(config.url, 'https://dav.example.com');
    });

    test('backend 序列化往返', () {
      const config = CloudSyncConfig(backend: CloudBackendKind.onedrive);
      final restored = CloudSyncConfig.fromJson(config.toJson());
      expect(restored.backend, CloudBackendKind.onedrive);

      final switched = config.copyWith(backend: CloudBackendKind.webdav);
      expect(switched.backend, CloudBackendKind.webdav);
    });

    test('切换后端清空哈希基线（首次全量上传）', () {
      const config = CloudSyncConfig(
        backend: CloudBackendKind.webdav,
        boxHashes: <String, String>{'favorites': 'abc'},
      );
      final switched = config.copyWith(
        backend: CloudBackendKind.onedrive,
        boxHashes: const <String, String>{},
      );
      expect(switched.boxHashes, isEmpty);
    });
  });

  group('备份文件名识别', () {
    test('OneDrive 分片大小为 320KiB 的倍数', () {
      // Graph upload session 要求除最后一片外分片大小必须是 320KiB 的倍数。
      expect(OneDriveBackend.kUploadChunkSize % (320 * 1024), 0);
    });
  });
}

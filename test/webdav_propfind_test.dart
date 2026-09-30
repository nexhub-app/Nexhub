/// WebDAV PROPFIND 解析回归测试。
///
/// 背景：dart `package:xml` 6.x 中 `XmlElement.value` **恒为 null**（value 只
/// 对属性/文本节点有意义），元素文本必须用 `innerText`。此处曾误用 `.value`
/// 取 href，导致 WebDAV 远端备份列表恒为空，「恢复 / 冲突解决」静默失效。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/services/cloud_sync_service.dart';

void main() {
  group('CloudSyncService.parsePropfind', () {
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

    test('解析出文件并跳过目录自身（href 文本须为非空）', () {
      final files = CloudSyncService.parsePropfind(xml);
      expect(files, hasLength(2));
      expect(files[0].name, 'nexhub-backup-1000.zip');
      expect(files[1].name, 'nexhub-backup-2000.zip');
    });

    test('空响应与非法 XML 返回空列表', () {
      expect(CloudSyncService.parsePropfind(''), isEmpty);
      expect(CloudSyncService.parsePropfind('not-xml'), isEmpty);
    });
  });
}

/// 媒体服务器 Emby 方言客户端。
///
/// 与基类的差异仅在端点路径与 Authorization scheme：
/// - 列表类端点走老式 `/Users/{userId}/...` 路径（userId 内嵌，query 不带）；
/// - Authorization 头 scheme 为 `Emby`。
library;

import 'media_server_client.dart';

class EmbyClient extends MediaServerClientBase {
  EmbyClient({
    required super.info,
    required super.deviceId,
    super.token,
    super.deviceName,
    super.clientName,
    super.appVersion,
    super.dio,
  });

  @override
  String get authScheme => 'Emby';

  @override
  bool get itemsQueryNeedsUserId => false;

  @override
  String itemsPath(String userId) => '/Users/$userId/Items';

  @override
  String viewsPath(String userId) => '/Users/$userId/Views';

  @override
  String latestPath(String userId) => '/Users/$userId/Items/Latest';

  @override
  String resumePath(String userId) => '/Users/$userId/Items/Resume';
}

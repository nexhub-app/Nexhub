/// 媒体服务器 Jellyfin 方言客户端。
///
/// 与基类的差异仅在端点路径与 Authorization scheme：
/// - 列表类端点用 query 传 userId（10.8+ 新式路径）；
/// - Authorization 头 scheme 为 `MediaBrowser`。
library;

import 'media_server_client.dart';

class JellyfinClient extends MediaServerClientBase {
  JellyfinClient({
    required super.info,
    required super.deviceId,
    super.token,
    super.deviceName,
    super.clientName,
    super.appVersion,
    super.dio,
  });

  @override
  String get authScheme => 'MediaBrowser';

  @override
  bool get itemsQueryNeedsUserId => true;

  @override
  String itemsPath(String userId) => '/Items';

  @override
  String viewsPath(String userId) => '/UserViews';

  @override
  String latestPath(String userId) => '/Items/Latest';

  @override
  String resumePath(String userId) => '/UserItems/Resume';
}

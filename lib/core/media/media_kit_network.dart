/// media_kit（libmpv）网络配置注入：代理 + 防盗链请求头。
///
/// libmpv **自主联网**：既不经过 Dart HttpClient / HttpOverrides，也不吃
/// Dio 的代理 / DNS / SNI 配置。代理环境下「RSS 文字正常、音频永远 0:00」
/// 的直接原因即此——页面请求走了应用代理，媒体请求却是裸直连。
/// - 代理：把全局网络档案的代理写入 mpv 的 `http-proxy` 属性（manual 模式；
///   system 模式与桌面 HttpClient 行为一致，交给 mpv 自读 http_proxy 环境变量；
///   direct 模式写空值即直连）；
/// - 防盗链头：Referer / UA 由调用方经 `Media(httpHeaders:)` 传入（见
///   [buildMediaHeaders]），mpv 会随每个媒体请求携带。
library;

import 'package:media_kit/media_kit.dart';

import '../network/model/network_config.dart';
import '../network/network_config_service.dart';
import '../scraper/http_fetcher.dart';

/// 把当前全局网络档案的代理注入播放内核（幂等，开新媒体前调用均可）。
Future<void> applyAppProxyToPlayer(Player player) async {
  final Object? platform = player.platform;
  if (platform is! NativePlayer) return;
  final ProxyConfig proxy = NetworkConfigService.instance.globalProfile.proxy;
  String value = '';
  if (proxy.mode == ProxyMode.manual &&
      proxy.host.isNotEmpty &&
      proxy.port > 0) {
    value = proxy.protocol == ProxyProtocol.socks5
        ? 'socks5://${proxy.host}:${proxy.port}'
        : 'http://${proxy.host}:${proxy.port}';
  }
  try {
    await platform.setProperty('http-proxy', value);
  } on Object {
    // 注入失败不阻塞播放：直连可达的源不受影响，失败兜底由播放器 UI 接管。
  }
}

/// 媒体请求头：Referer=所在页面（防盗链校验「被哪个页面引用」），UA=统一
/// 浏览器指纹。防盗链媒体缺这俩通常表现为无声无息的 0:00 而非显式报错。
Map<String, String>? buildMediaHeaders({
  String? pageUrl,
  required String mediaUrl,
}) {
  final Map<String, String> headers = <String, String>{
    'User-Agent': HttpFetcher.instance.userAgentForUrl(mediaUrl),
  };
  if (pageUrl != null && pageUrl.isNotEmpty) {
    headers['Referer'] = pageUrl;
  }
  return headers;
}

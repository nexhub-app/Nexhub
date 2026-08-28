/// 根据源 `comments.login` 声明，构建受保护请求应附加的 Authorization 头。
///
/// 返回 null 表示无需附加（仅靠 HttpFetcher 自动注入的 Cookie，如 sessionid）。
/// 完全由源配置驱动，不写死任何站点逻辑：
/// - `sendTokenAs: "bearer"` → `Authorization: Bearer <checkCookie 对应 Cookie 值>`。
/// - `sendTokenAs: "key"`    → `Authorization: <authScheme 默认 Key> <SourceKeyStore 中手动填写的 apiKey>`。
///
/// [SourceAuthManager]（登录态探测）与 [ScriptResolver]（meta 协议预取）共用本函数，
/// 避免鉴权头拼接逻辑在两处漂移。
library;

import '../models/plugin_config.dart';
import '../scraper/http_fetcher.dart';
import 'source_key_store.dart';

Map<String, String>? sourceAuthHeader(PluginConfig source) {
  final login = source.comments?.login;
  if (login == null) return null;
  final mode = login.sendTokenAs;
  if (mode == 'bearer') {
    final ck = login.checkCookie;
    if (ck == null || ck.isEmpty) return null;
    final token = HttpFetcher.instance.cookieValue(source.site.domain, ck);
    if (token == null || token.isEmpty) return null;
    return <String, String>{'Authorization': 'Bearer $token'};
  } else if (mode == 'key') {
    final param = login.apiKeyParam ?? 'apiKey';
    final apiKey = SourceKeyStore.get(source.id, param);
    if (apiKey == null || apiKey.isEmpty) return null;
    final scheme = login.authScheme ?? 'Key';
    return <String, String>{'Authorization': '$scheme $apiKey'};
  }
  return null;
}

/// Bangumi OAuth 2.0 应用凭据配置。
///
/// 发布形态登录走标准 authorization code 流程（见 [BangumiAuth.loginWithOAuth]）：
/// 1. App 引导用户在系统浏览器访问 `https://bgm.tv/oauth/authorize`；
/// 2. 用户授权后 Bangumi 跳回 `redirectUri`（深链 `nexhub://oauth/callback`）；
/// 3. App 用回调里的 `code` 向 `https://bgm.tv/oauth/access_token` 换取
///    `access_token` + `refresh_token`。
///
/// **凭据不写死在源码里**（公开仓库会泄露）。[clientId] / [clientSecret] 通过
/// 编译期 `--dart-define` 注入，默认空字符串；本地构建请用仓库根的
/// `run_bangumi_oauth.sh` / `run_bangumi_oauth.bat`（均已 gitignore）一键注入。
/// 使用前必须先在 https://bgm.tv/dev/app/create 注册应用：
/// - 应用名称 / 主页：随意（如 NexHub）；
/// - **回调地址（Redirect URI）必须填 `nexhub://oauth/callback`**（与下方一致）。
///
/// 注意：移动端公钥式客户端无法真正保密 secret，按 Bangumi 文档将 secret 随请求
/// 发送即可（与众多 Bangumi 第三方客户端一致）。请勿把 secret 提交到公开仓库。
library;

/// Bangumi OAuth 应用配置（发布形态）。
abstract final class BangumiOAuthConfig {
  /// 在 bgm.tv/dev 注册应用后获得的 Client ID。
  ///
  /// 通过 `--dart-define=BANGUMI_CLIENT_ID=...` 注入；未注入时为空，
  /// [configured] 为 false，UI 会提示先配置。
  static const String clientId =
      String.fromEnvironment('BANGUMI_CLIENT_ID', defaultValue: '');

  /// 在 bgm.tv/dev 注册应用后获得的 Client Secret。
  static const String clientSecret =
      String.fromEnvironment('BANGUMI_CLIENT_SECRET', defaultValue: '');

  /// 回调地址：必须与 bgm.tv/dev 后台填写的 Redirect URI 完全一致，
  /// 且已在本机 AndroidManifest / iOS Info.plist 注册为深链。
  static const String redirectUri = 'nexhub://oauth/callback';

  /// 申请的权限范围（Bangumi 目前 scope 尚未强制生效，但按规范带上）。
  static const List<String> scopes = <String>['user', 'bangumi'];

  /// 是否已配置 Client ID / Secret（用于 UI 前置校验与提示）。
  static bool get configured =>
      clientId.isNotEmpty && clientSecret.isNotEmpty;
}

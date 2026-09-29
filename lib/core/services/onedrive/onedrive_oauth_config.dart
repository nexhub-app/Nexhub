/// OneDrive（Microsoft Graph）OAuth 2.0 应用凭据配置。
///
/// 走标准 authorization code + PKCE 流程（公共客户端，无需 client secret），
/// 备用路径为设备码登录（桌面端无 WebView 时使用）。见 [OneDriveAuthService]。
///
/// **凭据不写死在源码里**。[clientId] 通过编译期 `--dart-define` 注入，默认空；
/// 未注入时 [configured] 为 false，UI 会给出配置教程。
///
/// 使用前必须先在 Azure 门户（portal.azure.com → Microsoft Entra ID → 应用注册）
/// 注册应用：
/// 1. 账户类型选「任何组织目录中的帐户和个人 Microsoft 帐户」；
/// 2. 平台添加「移动和桌面应用程序」，重定向 URI 填 `http://localhost`；
/// 3. 「允许公共客户端流」设为「是」（设备码登录必需）；
/// 4. API 权限添加 Microsoft Graph 委托权限 `Files.ReadWrite.AppFolder`
///    （`User.Read` 默认已有）；
/// 5. 记录「应用程序(客户端) ID」，构建时
///    `--dart-define=ONEDRIVE_CLIENT_ID=<id>` 注入。
library;

/// OneDrive OAuth 应用配置。
abstract final class OneDriveOAuthConfig {
  /// 在 Azure 门户注册应用后获得的 Client ID（公共客户端，无 secret）。
  static const String clientId =
      String.fromEnvironment('ONEDRIVE_CLIENT_ID', defaultValue: '');

  /// 租户段：`common`（个人 + 组织账号）/ `consumers`（仅个人）/
  /// `organizations`（仅组织）。通过 dart-define 可覆盖。
  static const String tenant =
      String.fromEnvironment('ONEDRIVE_TENANT', defaultValue: 'common');

  /// 回调地址：与 Azure 门户「移动和桌面应用程序」平台注册的
  /// `http://localhost` 一致。授权页回跳时由内嵌 WebView 截获 code，
  /// 不会真正发起对 localhost 的请求。
  static const String redirectUri = 'http://localhost';

  /// 申请的权限范围：应用专用目录读写 + 基本信息 + 离线刷新。
  static const List<String> scopes = <String>[
    'Files.ReadWrite.AppFolder',
    'User.Read',
    'offline_access',
  ];

  /// 是否已配置 Client ID（用于 UI 前置校验与提示）。
  static bool get configured => clientId.isNotEmpty;

  /// OAuth v2.0 endpoint 根（含 /authorize /token /devicecode）。
  static String get authority =>
      'https://login.microsoftonline.com/$tenant/oauth2/v2.0';
}

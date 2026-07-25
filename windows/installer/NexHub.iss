; NexHub Windows 安装包脚本（Inno Setup 6）
; 由 CI 通过 Chocolatey 安装 Inno Setup 后直接调用 ISCC.exe 编译；MyAppVersion 经 /D 传入（已去掉 v 前缀的版本号）。
; 相对路径基准：SourceDir=..\.. 已回到仓库根目录，因此下文的图标 / 文件源路径均相对仓库根，不要再叠加 ..\..。

#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif
#define MyAppName "NexHub"
#define MyAppPublisher "NexHub"
#define MyAppURL "https://github.com/nexhub-app/nexhub"
#define MyAppExeName "NexHub.exe"

[Setup]
AppId={{A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
; 允许非管理员安装（安装到当前用户程序目录）
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=commandline
SourceDir=..\..
SetupIconFile=windows\runner\resources\app_icon.ico
OutputDir=Output
OutputBaseFilename=NexHub-setup-{#MyAppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64
UninstallDisplayIcon={app}\{#MyAppExeName}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Files]
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional tasks:"; Flags: unchecked

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent

# NexHub v0.2.6

> 四合一媒体聚合客户端（动漫 / 漫画 / 小说 / 影视）—— 源即插件 · 共创社区。

这是 NexHub 的 **0.2.x 早期预览版**。NexHub **不内置任何内容源**，所有内容都来自你自行导入的「源」。

## ✨ 核心特性

- **四合一聚合**：动漫、漫画、小说、影视在一个应用里统一管理、浏览、搜索、阅读与观看。
- **源即插件 · 共创模式**：解析能力完全由可导入的源 JSON 驱动，应用只提供「引擎」，不写死任何站点。
- **多引擎解析**：声明式（XPath / JSONPath / CSS）+ 脚本式（内置 JS 沙箱）自动调度。
- **首页多板块与动态筛选**：标签 / 分类「所见即所得」，自动按源结构生成。
- **漫画阅读器**：双页 / 单页、翻页手势、阅读进度持久化，并针对常见痛点做过专项修复。
- **小说阅读器**：字体、字号、行距、边距、主题、亮度等样式自定义，设置即时生效并持久化。
- **影视播放器**：基于 media_kit + fvp，配合 canvas_danmaku 弹幕渲染。
- **下载管理 / 历史与更新追踪 / Material 3 动态配色 / 多语言 / 跨平台**。

## 📝 更新日志（v0.1.0 → v0.2.0）

本版相对 v0.1.0 共合并 22 个提交，重点如下：

### 🐛 关键修复
- 修复全局页面转场淡出方向写反导致整页隐形（全局黑屏）的问题。
- 视频内核初始化失败时不再拖垮整个应用（黑屏兜底：仅视频不可用，浏览 / 阅读照常）。
- 新增全局错误兜底：构建期异常显示可读红字而非黑屏，便于定位根因。

### ✨ 新功能 / 体验
- 漫画阅读器：支持鼠标拖拽 / 滑动翻页、滚轮「作用 / 方向」设置、条漫缩放与翻页。
- 封面图 Hero 共享元素：从列表卡片平滑飞入详情页。
- 弹弹 play 弹幕改为编译期注入，并移除凭据页（密钥经 CI Secrets 注入）。

### 💫 灵动动效（全套升级）
- 底栏灵动动效 + 主题色胶囊指示。
- 统一灵动动效原语：按压回弹（AppTapScale）、入场（Entrance）、弹窗 / 抽屉回弹（AppSheetBody）。
- 全局页面切换转场最终改为零动画瞬切，消除返回时的定格卡顿。
- 列表项 / 卡片灵动入场；图标按钮与播放器控制按压回弹。
- 加载指示器升级为三点弹跳；下拉刷新弹性；顶栏滚动渐隐。
- 内容卡片按压回弹 + 对话框弹性弹出。
- 性能优先：去除唯一不必要的无限循环动画（空闲零开销）。

## 📝 更新日志（v0.2.0 → v0.2.1）

本版相对 v0.2.0 **无应用功能变更**，仅补齐 Windows 桌面端的打包与图标：

### 🐛 修复 / 补齐
- **Windows 自定义启动图标**：此前打包用的仍是 Flutter 默认 Logo。现已在 CI 中先用 `flutter_launcher_icons` 重新生成图标，Windows 安装包 / 解压包均带 NexHub 官方图标。
- **Windows exe 安装包**：在原有 zip 解压包基础上，新增 Inno Setup 生成的 `NexHub-setup-x.y.z.exe` 安装程序，支持「开始菜单 + 桌面快捷方式」一键安装与卸载。

## 📝 更新日志（v0.2.1 → v0.2.2）

本版相对 v0.2.1 **无应用功能变更**，仅补齐 macOS 与 Linux 桌面的应用图标：

### 🐛 修复 / 补齐
- **macOS 应用图标**：CI 现在会在 build 前调用 `flutter_launcher_icons` 从 `assets/icon/icon.png` 重新生成
  `AppIcon.appiconset`，与 Android / Windows 保持一致（之前仓库里 commit 的旧图标虽然也是 NexHub
  风格，但与源图不一致）。
- **Linux 应用图标**：仓库里 `linux/` 目录被简化（没有 `runner/CMakeLists.txt`、`main.cc` 等），
  CI 会用 `flutter create --platforms=linux .` 重新生成工程——而 `flutter create` 会放 Flutter 默认
  Logo 当 Linux 应用图标。现已在 Linux job build 前调用 `flutter_launcher_icons` 覆盖，
  Linux 包也会带上 NexHub 自定义图标。
- 顺手清理仓库里那个**无关的视频播放占位图** `linux/flutter/icons.png`（右下角带"图片由AI生成"水印，
  反正 CI 不使用它，删掉避免误导）。

## 📝 更新日志（v0.2.2 → v0.2.3）

本版相对 v0.2.2 **无应用功能变更**，仅修复 Windows 安装包（exe）在 CI 中无法生成的问题：

### 🐛 修复
- **Windows exe 安装包构建失败**：上一个版本 Windows job 用 `minissoftware/Inno-Setup-Action@v2`
  这个第三方 action，但该仓库不存在（CI 直接报错 `Unable to resolve action ... repository not
  found`），导致 Windows 构建一开头就挂掉，连带 GitHub Release 也发不出来。现已改为
  **Chocolatey 安装 Inno Setup 后直接调用 `ISCC.exe`** 编译 `windows/installer/NexHub.iss`，
  不再依赖任何第三方 action 仓库，更稳、可维护。

## 📝 更新日志（v0.2.3 → v0.2.4）

本版相对 v0.2.3 **无应用功能变更**，仅修复 Windows 安装包（exe）的 Inno Setup 图标路径错误：

### 🐛 修复
- **Windows exe 安装包编译报错 `Error on line 29 ... The system cannot find the path specified`**：
  上一版 `NexHub.iss` 里 `SourceDir=..\..` 已经回到仓库根目录，但 `SetupIconFile` 又多写了
  一层 `..\..`，把路径推到了仓库外，Inno Setup 找不到图标文件直接编译失败。现改为相对
  `SourceDir`（仓库根）的正确相对路径 `windows\runner\resources\app_icon.ico`，与下方
  `[Files]` 的 `build\windows\x64\runner\Release\*` 基准保持一致。

## 📝 更新日志（v0.2.4 → v0.2.5）

本版相对 v0.2.4 **无应用功能变更**，仅修复 Windows 安装包（exe）中文语言文件缺失导致的编译失败：

### 🐛 修复
- **Windows exe 安装包编译报错 `Couldn't open include file ... Languages\ChineseSimplified.isl`**：
  上一版 `NexHub.iss` 的 `[Languages]` 用 `compiler:Languages\ChineseSimplified.isl` 引用 Inno Setup
  **自带**的中文语言包，但 Chocolatey 装的 Inno Setup 在打包机上并没有这个文件，ISCC 直接 abort、
  产不出 exe。现改为**把官方 `ChineseSimplified.isl` 随仓库提交**到
  `windows/installer/Languages/`，并让 .iss 引用相对于脚本目录的本地路径
  `Languages\ChineseSimplified.isl`——安装向导继续是中文，且不再依赖打包机上有没有该语言包。

## 📝 更新日志（v0.2.5 → v0.2.6）

本版相对 v0.2.5 **无应用功能变更**，仅修正上一版中文语言文件在 Inno Setup 里的**实际解析路径**：

### 🐛 修复
- **Windows exe 安装包仍编译报错 `Couldn't open include file ...\Languages\ChineseSimplified.isl`**：
  v0.2.5 把 .isl 放进了 `windows/installer/Languages/`，但 `.iss` 里写的
  `MessagesFile: "Languages\ChineseSimplified.isl"` 会被 Inno Setup 当成**相对仓库根（SourceDir）**
  的路径，于是去找 `<仓库根>/Languages/...` 而找不到。现改为写相对仓库根的正确路径
  `windows\installer\Languages\ChineseSimplified.isl`（与 `[Files]` 的 `SourceDir=..\..` 基准一致）。
- CI 加固：Windows job 在调 `ISCC.exe` 之前**新增预校验**，确认
  `windows\installer\Languages\ChineseSimplified.isl` 存在，缺失时直接 `exit 1` 并打印
  `windows/installer` 目录树，方便以后快速定位，不再等 ISCC 编译到一半才 abort。

## 📦 安装

在下方 **Assets** 中下载对应你系统的安装包：

| 系统 | 文件 | 安装方式 |
| --- | --- | --- |
| **Android** | `app-release.apk` | 手机允许「未知来源」安装后，点击 APK 即可安装 |
| **Windows** | `NexHub-setup-x.y.z.exe`（推荐）/ `NexHub-windows-x64.zip` | 双击 exe 按向导安装；或解压 zip 后运行里面的 `NexHub.exe` |
| **Linux** | `NexHub-linux-x64.tar.gz` | 解压后运行 `bundle/nexhub` |
| **macOS** | `NexHub-macos.zip` | 解压后将 `NexHub.app` 拖入「应用程序」文件夹 |

> ⚠️ macOS 包**未公证**，首次打开可能需要在「系统设置 → 隐私与安全性」中点击「仍要打开」。

## 🔌 重要：先导入源

本应用**不内置任何源**，首次打开是空的，这是正常现象。请先导入至少一个源 JSON（应用内「源管理 / 导入源」），才能看到内容。源由社区共享维护，请通过社区渠道获取，并自行评估其合规性与内容合法性。

> 完整的使用与开发指南见仓库 [README](https://github.com/nexhub-app/nexhub#readme)。

## ⚠️ 免责声明

NexHub 是一款开源技术演示项目，本身**不提供、不存储、不中转任何受版权保护的内容**，也**不内置任何内容源**。所有内容均来自用户自行导入的源，其合法性与版权状况由源的提供方与使用方负责。使用本软件即表示你已阅读、理解并同意仓库内完整的《免责声明》（依据中华人民共和国相关法律法规拟定）。

## 🙏 致谢

感谢 [Flutter](https://flutter.dev) / Dart 团队，以及 [flutter_js](https://pub.dev/packages/flutter_js)、[media_kit](https://pub.dev/packages/media_kit)、[canvas_danmaku](https://pub.dev/packages/canvas_danmaku) 等开源项目，和所有为「源即插件 · 共创社区」理念做出贡献的开发者与源作者。

## 📝 已知限制

- **iOS 安装包暂未提供**：需 Apple 开发者账号签名，请在本机执行 `flutter build ios` 自行打包。
- **macOS 包未公证**：跨设备分发可能受系统拦截。
- **安卓 APK 使用调试签名**：适合个人 / 朋友间分发；若要上架应用商店，需配置正式签名密钥。
- **0.2.x 为早期预览**：部分高级功能仍在完善中，欢迎通过 Issue / 社区反馈问题。

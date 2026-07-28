# NexHub v0.2.13

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

## 📝 更新日志（v0.2.6 → v0.2.7）

本版相对 v0.2.6 **无应用功能变更**，仅修正 Inno Setup 安装包 exe 的**输出目录**错位：

### 🐛 修复
- **Windows job 仍失败：`ISCC 未产出安装包 exe（windows/installer/Output 下无 *.exe）`**：
  v0.2.6 编译已通过，但 ISCC 把 exe 写到了**仓库根 `Output/`**（`<仓库根>/Output/NexHub-setup-0.2.6.exe`），
  而工作流只去 `windows/installer/Output/` 找，于是找不到报错。根因同样是 `OutputDir` 相对
  **仓库根 / SourceDir** 解析——`OutputDir=Output` 被解析成 `<仓库根>/Output`。
- 把 `.iss` 的 `OutputDir` 改为 `windows\installer\Output`（相对仓库根的正确路径，与上传步骤一致）。
- 同时给 CI 加了**兜底**：调 `ISCC.exe` 后同时搜索 `windows\installer\Output` 与仓库根 `Output`
  两个位置，找到 exe 就复制到 `windows/installer/Output`，以后无论 ISCC 写到哪都能上传成功。

## 📝 更新日志（v0.2.7 → v0.2.8）

本版相对 v0.2.7 **无应用功能变更**，仅修复上一版"复制兜底"把自己复制到自己身上的问题：

### 🐛 修复
- **Windows job 仍失败：`Cannot overwrite the item ... with itself`**：
  v0.2.7 把 `OutputDir` 改成了 `windows\installer\Output`（ISCC 直接把 exe 写到正确位置），
  但 CI 里的"复制兜底"又把这个**已经在目标位置的 exe** 再 `Copy-Item` 一次到自己身上，
  PowerShell 报错并 exit 1。给复制加了守卫：源路径与目标路径相同（`-ieq`）就跳过复制、
  只打印提示，不再触发自覆盖错误。
- 现在 `OutputDir` 直接产出 + 复制守卫双重保险，无论 ISCC 写到哪都能正常上传。

## 📝 更新日志（v0.2.8 → v0.2.9）

本版相对 v0.2.8 **无应用功能变更**，仅修正"复制守卫"因**相对/绝对路径比较**失效而再次自覆盖：

### 🐛 修复
- **Windows job 仍失败：`Cannot overwrite the item ... with itself`**：
  v0.2.8 的守卫比较的是 `$out.FullName`（绝对路径，如 `D:\a\nexhub\nexhub\windows\installer\Output\...`）
  与 `$destPath`（仍是**相对路径** `windows\installer\Output\...`）——两者格式不同，`-ieq` 永远不相等，
  于是照样去复制、照样自覆盖报错。改用 `[System.IO.Path]::GetFullPath` 把目标也转成绝对路径再比，
  相同就跳过；并补了 Source/Dest 路径日志和 `try/catch` 便于以后诊断。

## 🎨 更新日志（v0.2.9 → v0.2.10）

本版**新增一个用户可见的平台能力**：Android 13+ 的「主题图标(themed icon / 莫奈取色)」——桌面图标会**跟随壁纸颜色**而变色。

### ✨ 新增
- **App 图标莫奈取色（Android 13+ 主题图标）**：之前 `flutter_launcher_icons` 只配了
  `adaptive_icon_background` 和 `adaptive_icon_foreground`，**缺一个 single-layer 的单色图层**，
  所以系统在 Android 13+ 桌面要把图标染成壁纸色时染色层缺席，图标始终是固定的青底白 "N"。
  本版新增 `assets/icon/icon_monochrome.png`（白"N" + 四角白色装饰点，透明背景，
  由源图 luminance 阈值 175 自动生成：**保留 N+4 个装饰点的白色形状、自动剔除青底渐变**），
  并在 `pubspec.yaml` 的 `flutter_launcher_icons` 块里挂上
  `adaptive_icon_monochrome: "assets/icon/icon_monochrome.png"`。下次 CI 重新跑
  `flutter_launcher_icons` 时，Android job 会一并产出 `ic_launcher_monochrome` 资源，
  桌面图标就会按系统壁纸色取色（青底不变作为品牌色，"N"+ 装饰点跟随壁纸变色）。
- 仅影响支持主题图标的 Android 13+ 设备；老设备、Android 其它版本以及
  Windows/macOS/Linux 完全不受影响（图标显示行为照旧）。

## 📝 更新日志（v0.2.10 → v0.2.11）

本版相对 v0.2.10 **无应用功能变更**，仅为项目补充「致谢」说明：

### 🙏 文档
- **新增致谢章节**：在 README 与发布说明中正式感谢 [Legado](https://github.com/gedoor/legado)（及各类改版）、[Mihon](https://github.com/mihonapp/mihon)（Tachiyomi 衍生版，及各类改版）与 [RSSHub](https://github.com/DIYgod/RSSHub)。
  - Legado 的「书源」规则系统为 NexHub「源即插件」的解析与共创理念提供了核心启发；NexHub 小说分页器以独立 Dart 实现借鉴其 `ChapterProvider` 分页算法（未复制源码），Legado 上游未附许可证，本致谢仅作启发署名。
  - Mihon（Apache-2.0，© Mihon contributors）的扩展源与漫画阅读器交互为 NexHub 的漫画解析与阅读体验提供了重要参考。
  - RSSHub（AGPL-3.0，© DIYgod）为 NexHub 的订阅功能提供 RSS 聚合服务，NexHub 仅作客户端调用，未修改或再分发其源码。
- 仅更新文档与致谢，不涉及任何代码 / 构建产物变更；应用功能与 v0.2.10 完全一致。

## 📝 更新日志（v0.2.11 → v0.2.12）

本版修复 Android 包因「每次 CI 随机生成签名」导致**无法覆盖安装**的问题：

### 🐛 修复
- **Android 无法覆盖安装**：此前 release 构建使用默认 debug 签名，而 CI 每次都是全新虚拟机、`~/.android/debug.keystore` 不存在，构建工具每次随机生成新 keystore，导致每个 APK 签名证书都不同、旧包无法覆盖。本版生成固定签名 `android/app/upload-keystore.jks`（别名 nexhub，PKCS12，RSA 2048，有效期至 2053 年）并提交入库，`build.gradle.kts` 的 release 构建改用它；并加 `.gitattributes` 把 `*.jks` 标为二进制，防止 Git 检出时换行符转换损坏 keystore。
- ⚠️ **安装注意**：你手机上已装的随机签名旧包无法被换签覆盖，必须**先卸载一次**再装 v0.2.12；之后各版本均可直接覆盖升级。

## 📝 更新日志（v0.2.12 → v0.2.13）

本版聚焦影视模块的解析与播放稳定性，并顺带纳入 v0.2.12 的 Android 固定签名：

### 🐛 修复 / 稳定性（影视模块）
- **解析层重构与稳定**：重写 `http_fetcher`（重试 / 编码 / 超时更稳），并修复 `builtin_resolver` / `webview_resolver` / `video_extractor` / `media_api_service` 多处解析失败与视频提取异常；WebView 渲染后回灌 HTML 再解析的路径更稳健。
- **播放器退出崩溃修复**：播放器在 `deactivate` 时切断 `stall/position/completed` 流订阅并置 `_disposed` 标记，修复「访问已 deactivated widget 的 ancestor」溢出崩溃；snackBar 退出动画 context 丢失兜底；修复嵌入 `Positioned` 自适应视频区填充。`webview_verification_screen` 验证 / 提取流程更稳定。
- **总集数统计修正**：改为按线路（`Episode.lineName`）分组取最大一组集数，避免多线路镜像集数被累加（如 4 线路 30 集误算 120 集）。
- **选集精确解析**：`fetchEpisodes` 支持透传 `detailUrl`，按详情页地址精确解析选集。

### ✨ 解析引擎增强（源即插件能力）
- **POST 表单路由**：`builtin_resolver` 支持 `routes.X.method:"post"`，自动把查询参数拆成表单体发送，适配 MacCMS 等「分类 / 列表由前端 JS POST 接口填充」的站点（如 `/ds_api/vod`）；纯配置驱动，不写死站点。
- **周期表（周更）解析**：新增 `week` 路由与周列表选择器支持，能从 `status` 解析开播星期并分组展示。
- **分类筛选「各不相同」**：`SourceFilterConfig` 新增 `byCategory`（按分类 id 覆盖筛选组）与 `defaults`（分类默认参数，如 233 动漫 `sort=hits/year=2026`），全部由源 JSON 声明，无需在 Dart 写死。
- **坏链修复**：`video` 路由 `{url}` 直达绝对地址，避免被 base 前缀成双 host 坏链（`https://base/https://episode`）导致播放失败；相对地址也做了 base 规范化避免 `//` 双斜杠。
- **中文搜索 / 筛选修复**：`keyword` 与含中文的筛选占位符自动 `encodeComponent`，修复中文关键词搜索错乱、MacCMS 中文筛选（如「奇幻」）无结果；MacCMS `show` 路由第 1 页 `page` 段留空，避免拼出错误段导致 404。
- **JsonPath 空值保护**：非字符串 selector 增加空值兜底，避免解析崩溃。

### 🎨 UI / 布局
- **周期表统一布局**：改用统一 `ContentCard`，跟随全局布局（网格列数 / 列表模式 / 圆角 / 标题 / 作者），`ListenableBuilder` 实时刷新；星期 Chip 全部可点（空日显示空态）。
- **全局「布局」按钮**：浏览页 AppBar 新增「布局」按钮，首页 / 周期表 / 分类 / 排行榜 Tab 均可改布局。
- **详情页主演可折叠**：影视详情页主演信息块改为可折叠（`_InfoChipsSection`），每组默认显前 N 位，超长显示「展开 N 位 / 收起」，年份始终显示。
- **首页 / 内容列表 / 源搜索 / 章节列表**等稳定性与布局修复（`online_content_list_screen` / `online_home_section` / `module_source_search_screen` / `chapter_list_section`）。
- 新增多语言文案（l10n）。

> 本版已包含 v0.2.12 的固定签名 keystore，Android 包可覆盖安装（更早的随机签名旧包需先卸载一次）。

## 📝 更新日志（v0.2.11 → v0.2.12）

本版修复 Android 包**无法覆盖安装**的关键问题：

### 🐛 修复
- **Android 每次构建签名都不同，已装旧包无法覆盖**：此前 release 构建用默认 debug keystore，而 CI 每次都是全新虚拟机、`~/.android/debug.keystore` 不存在，构建工具每次随机生成新 keystore，导致每个发出的 APK 签名都不同，覆盖安装被系统拒绝。
- **改为固定签名**：提交一份固定 keystore `android/app/upload-keystore.jks`（别名 `nexhub`，PKCS12，RSA 2048，有效期至 2053 年），并在 `android/app/build.gradle.kts` 中配置 release 构建统一使用它。从本版起，所有 Android 包签名一致，可正常覆盖安装。
  - ⚠️ 已安装的旧版（随机签名）仍需**先卸载一次**再装本版；之后各版本之间即可无缝覆盖。
  - 此 keystore 随公开仓库公开，仅用于测试分发；若要上架 Google Play 等商店，请改用私有正式签名密钥。

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

感谢 [Legado](https://github.com/gedoor/legado)（及各类改版）与 [Mihon](https://github.com/mihonapp/mihon)（Tachiyomi 衍生版，及各类改版）——前者「书源」规则系统启发了 NexHub「源即插件」的解析与共创理念，后者的扩展源与漫画阅读器交互为漫画解析与阅读体验提供了重要参考。也感谢 [Flutter](https://flutter.dev) / Dart 团队，以及 [flutter_js](https://pub.dev/packages/flutter_js)、[media_kit](https://pub.dev/packages/media_kit)、[canvas_danmaku](https://pub.dev/packages/canvas_danmaku) 等开源项目，和所有为「源即插件 · 共创社区」理念做出贡献的开发者与源作者。

## 📝 已知限制

- **iOS 安装包暂未提供**：需 Apple 开发者账号签名，请在本机执行 `flutter build ios` 自行打包。
- **macOS 包未公证**：跨设备分发可能受系统拦截。
- **安卓 APK 使用仓库内固定签名 keystore**：从 v0.2.12 起，release 包统一使用提交入库的固定 keystore（`android/app/upload-keystore.jks`），各版本之间可正常覆盖安装，适合个人 / 朋友间分发。该 keystore 随公开仓库公开，**若要上架应用商店，需改用私有正式签名密钥**（GitHub Actions secret 注入）。
- **0.2.x 为早期预览**：部分高级功能仍在完善中，欢迎通过 Issue / 社区反馈问题。

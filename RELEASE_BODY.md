# NexHub v2.0.3（正式版）

> 四合一媒体聚合客户端（动漫 / 漫画 / 小说 / 影视）—— 源即插件 · 共创社区。

---

## 🎉 正式版发布说明

NexHub **2.0.3 正式版**来了。它建立在 2.0.2 正式版之上，**基础功能完整、可安全升级**：本次聚焦**引擎健壮性、Material 3 官方触感反馈、下载与界面稳定性**三处打磨。沿用同一签名密钥，可直接覆盖安装。

🌕 **中秋快乐！** 月圆人安，愿你追番读漫皆顺心。

> ⚠️ **本应用不内置任何内容源**，首次打开是空的，这是正常现象。请先导入至少一个源 JSON（应用内「源管理 / 导入源」）才能看到内容。源由社区共享维护，请自行评估其合规性与内容合法性。

### 相对上一正式版 v2.0.2 的核心变化

- **引擎更稳**：JS 沙箱预置 `atob` / `btoa`，源脚本可直接调用、无需内嵌 polyfill；同一 JsEngine 内顶层变量跨 meta 多跳持续可见，多跳解析（如「先取 id 再提交」）更可靠。
- **触感更跟手**：按 Material 3 官方语义重构震动反馈，开关 / 滑块 / 单选 / 下拉刷新 / 长按等约 200 处统一映射；Android 高版本改用官方振动原语。
- **下载与稳定性**：修复 SAF 下载 `.cbz` 被改写扩展名导致失败；修复切 tab 入场动画重播崩溃；年龄限制开启时书架历史自动隐藏 R18 条目。

> 无破坏性数据变更：收藏 / 进度 / 书签 / 历史 / 分组 / 评分 / 短评可直接沿用；旧源 JSON 无需修改、无需重新导入。

---

## 🆕 本次正式版相较 v2.0.2 的改动（3 个提交 · 52 个文件）

> 共 3 个提交、约 780 行改动，集中在**引擎健壮性、MD3 触感规范、下载与界面稳定性**。所有改动均为通用能力，不针对任何单一站点。

### 🛠️ 引擎与源解析

- **JS 沙箱预置 `atob` / `btoa`**：采用浏览器语义 polyfill（宽松剥离非法字符与尾部 `=`），源脚本可直接调用，无需在源里内嵌同名 polyfill；若源脚本自带同名声明则覆盖默认值，既有源不受影响。
- **meta 多跳全局存续**：同一 JsEngine 实例内顶层变量跨多跳持续可见，多跳各跳的 `__processor` 不再重放整段脚本，符合「同一 JsEngine 内全局持续可见」的约定——多跳解析（如「先取 id 再提交」）更稳定。

### 🎮 界面与触感

- **按 Material 3 官方语义重构震动反馈**：`AppHaptics` 重写为 `tick` / `click` / `toggleOn` / `toggleOff` / `thunk` / `confirm` / `reject` / `gestureThreshold` 语义模式，旧 `selectionClick` / `light` / `medium` / `heavy` 保留为兼容别名（约 200 处调用点自动映射）。
- **Android 原生端改用官方振动原语**：API 31+ 用 `VibrationEffect.Composition` 组合原语（`TICK` / `CLICK` / `THUD`，先 `areAllPrimitivesSupported` 检查），29+ 用 `createPredefined`，再退化为振幅单脉冲；保留 `vibrator.cancel()` 防队列滞留。
- **组件按规范挂载**：开关 / 复选框约 45 处 → `toggleOn` / `toggleOff`（开强关弱）；滑块逐档 `tick`（松手确认）；单选 `tick`（导航栏、分段选项卡、设置分段 / chip、RadioListTile、更新渠道与镜像选择）；下拉刷新触发 → `gestureThreshold`；长按 `thunk`（条目 / 书签 / 收藏菜单、进入多选、阅读器图片菜单、长按倍速、文本选择等 15 处动作入口）。

### 📦 下载与稳定性

- **SAF 下载修复**：`.cbz` 配 `application/zip` 被 provider 按 MIME 改写为 `.cbz.zip` 且 `rename` 被 ROM 拒绝，改用 `octet-stream` 创建即得正确文件名；`rename` 后备路径加重试与同名清理。
- **入场动画修复**：`Entrance._play` 由 `late final` 改 `late`，修复切 tab 重播时二次赋值抛 `LateInitializationError` 刷屏且重播失效。
- **书架历史**：年龄限制开启时自动隐藏 `mature` 源条目（展示层过滤，关闭即恢复，无源 / 源已卸载不受影响），新增 widget 测试与入场重播回归测试。

---

## 🔞 年龄限制与免责说明

NexHub 默认开启**年龄限制保护**：标记为 **18+（成人 / mature）** 的源在默认设置下**自动隐藏**，不会出现在浏览、搜索与源列表中。如需访问，须在「设置 → 内容分级」中手动开启「显示限制级内容」，并确认你已年满法定成年年龄。

- **源作者责任**：请在源 JSON 中如实填写 `ageRating` 字段（`general` 全年龄 / `teen` 青少年 16+ / `mature` 成人 18+，支持 `all`/`16`/`r18`/`nsfw` 等别名，缺省 `general`）。应用仅依据该字段自动分级与隐藏，**最终的内容合规性与年龄适宜性由源的提供方与使用方负责**。
- **内容责任**：NexHub 为开源技术演示项目，本身**不提供、不存储、不中转任何内容**，所有内容均来自用户自行导入的源。对于源所提供内容的版权、合法性及适宜性，NexHub 不做任何形式的担保或背书。
- **合规提示**：若你所在地区法律禁止访问此类内容，或你未满法定成年年龄，请勿开启限制级内容显示。使用本软件即表示你已阅读、理解并同意仓库内完整的《免责声明》（依据中华人民共和国相关法律法规拟定）。

> 源字段完整说明见网站文档「源编写教程 · 源字段完整参考」一节，或仓库 `lib/core/models/plugin_config.dart`。

---

## 🛠️ 构建与发布

- CI 四平台（Android / Windows / Linux / macOS）build 命令均注入 `--dart-define=BANGUMI_CLIENT_ID` 与 `BANGUMI_CLIENT_SECRET`（来自仓库 Secrets），官方 Release 包的 Bangumi OAuth 登录开箱可用。
- Gradle 仓库顺序沿用既有修复（`google()` / `mavenCentral()` 优先、阿里云兜底），四平台均可正常出包。
- 本版无新增依赖。

---

## 📦 下载说明

- **Android**：APK 按 CPU 架构分包，绝大多数手机请选 **`arm64-v8a`**；很旧的机型选 `armeabi-v7a`；模拟器 / x86 平板选 `x86_64`。装错架构会提示「安装包无效」。也提供 **`app-release.apk`** 通用包（单文件全架构，无需挑架构，体积较大）。
- **Windows**：`NexHub-setup-*.exe` 为安装包（支持中英文、非管理员安装），`NexHub-windows-x64.zip` 为免安装便携版。若被 SmartScreen 拦截，点「更多信息 → 仍要运行」。
- **Linux**：`NexHub-linux-x64.tar.gz` 为免安装版（解压即运行）；`NexHub-linux-x64.deb` 为 Debian / Ubuntu 系安装包；`NexHub-linux-x64.AppImage` 为单文件便携版（赋予可执行权限后双击运行）。
- **macOS**：`NexHub-macos.zip` 为免安装版，`NexHub-macos.dmg` 为磁盘镜像（挂载后拖入「应用程序」）。首次打开需在「系统设置 → 隐私与安全性」中放行。

---

## ⚠️ 已知限制

- **ECH 暂不生效**：Dart TLS 栈无 ECH API、无可用插件，直连暂不可行；替代路径：代理模式选手动指向支持 ECH 的本地内核，或开启系统安全 DNS 由 WebView 路径自动启用 ECH。
- **SNI 运行时可控但仍受栈限制**：现可在网络设置中配置「域名 → SNI 映射」与「免 SNI（绕 SNI 封锁）」，仅对直连 https 生效；走外部代理时由代理自理；部分站点仍需实测。
- **自建构建的 Bangumi OAuth 不可用**：未注入凭据时请改用 Access Token 登录，或自行到 [bgm.tv/dev/app/create](https://bgm.tv/dev/app/create) 注册应用（回调地址 `nexhub://oauth/callback`）；
- **Bangumi 吐槽仅只读**；源站评论的可用操作取决于源 JSON 声明了哪些路由；
- 遇到问题优先到 Issues 反馈。

---

## 🙏 参与共创

- 反馈 Bug → [Issues](https://github.com/nexhub-app/Nexhub/issues)
- 路线规划 / 新功能想法 → [Discussions](https://github.com/nexhub-app/Nexhub/discussions)
- 写源 / 改引擎 → 欢迎 Pull Request

> NexHub 不内置任何内容源。首次安装后需要自行导入源，才能看到内容。

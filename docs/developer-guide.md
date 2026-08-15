**[简体中文](./developer-guide.md)** | [English](./developer-guide.en.md)

# 🛠️ 开发者指南

> 面向贡献者与源作者。环境准备、项目结构、以及最重要的——**源编写分级教程**（基础 / 中级 / 高级）与完整示例。
>
> 📚 在线版源编写教程（含双语与更多动图演示）：<https://nexhub-app.github.io/website/>；本文档与其内容一致并持续同步。

## 4.1 环境准备

- 安装 [Flutter SDK](https://flutter.dev)（本项目要求 **Flutter 3.32.0**，Dart 3.x）；
- 配置好对应平台的编译环境（如 Android Studio / Xcode / Visual Studio 等）；
- 确认 `flutter doctor` 无明显报错。

## 4.2 获取与运行代码

```bash
git clone https://github.com/nexhub-app/nexhub.git
cd nexhub
flutter pub get
flutter run
```

选择目标设备（模拟器 / 真机 / 桌面端）即可启动。

## 4.3 构建发布包

```bash
# Android
flutter build apk
# Windows
flutter build windows
# 其它平台以此类推
```

## 4.4 项目结构

```
nexhub/
├── lib/                  # 应用主体代码（Dart）
│   ├── core/             # 核心能力：网络请求、解析调度、源仓库、阅读器/播放器基础设施
│   │   ├── models/       # 数据模型（如 PluginConfig 源配置）
│   │   ├── resolver/     # 解析引擎调度（builtin / script / webview / hybrid）
│   │   ├── scraper/      # 列表/详情/章节抓取与抽取
│   │   └── services/     # 源仓库、历史、下载等服务
│   ├── features/         # 各业务模块：首页、源管理、漫画、小说、影视、设置、下载……
│   └── l10n/             # 多语言资源（中文 / 英文）
├── assets/               # 资源（图标、通用热搜词等；不含任何站点源）
├── plugins/              # 源目录（见下方说明）
│   └── builtin/          # ⚠️ 此目录在仓库中仅保留占位，不提交任何源 JSON
├── test/                 # 单元测试（含源 JSON 校验，无内置源时自动跳过）
├── android/ ios/ linux/ macos/ windows/ web/   # 各平台工程
└── pubspec.yaml          # 依赖与资源声明
```

**关于 `plugins/builtin/`**：本仓库**不会**把任何 `.json` 源文件提交进去（已在 `.gitignore` 中排除）。该目录仅以 `.gitkeep` 占位，保证工程结构完整、可正常构建。真正的源由你保存在本地、或来自社区共享，**不进入公开仓库**。

**已被排除、绝不入库的内容**：

- `plugins/builtin/*.json`（任何内置 / 预备源）
- `reference/`（源的本地备份与参考样例）
- `docs/` 下仅白名单公开文档入库（`features.md` / `user-guide.md` / `developer-guide.md` / `GITHUB_ISSUE_TEMPLATE.md` 及其 `.en.md` 英文版）；其余内部开发文档、重开发提示词与计划、测试数据扫描脚本等均不入库
- `build/`、`sdk/`（构建产物与 Flutter SDK，体积巨大）
- `.workbuddy/`、`.trae/`、`.qoder/`、`.probe_tmp/`（本地工具与探针临时产物）
- 根目录的临时脚本（如 `tmp_*.mjs`、`run_probe.*`、`net_check.*`）

---

## 4.5 源即插件：如何编写与贡献一个源

NexHub 的解析能力完全由源 JSON 驱动。一个源是一个 JSON 文件，描述如何从一个站点抓取内容。

### 4.5.1 源层级网站设置指南（site / network）

每个源的「站点元信息」与「网络访问方式」都写在源文件里，这就是**源层级的网站设置**：

**`site`（必填）**——站点基本信息：

| 子键 | 类型 | 说明 |
| --- | --- | --- |
| `site.domain` | string | 站点主域名（如 `example.com`） |
| `site.baseUrl` | string | 站点根地址（如 `https://example.com`），用于拼接相对链接 |
| `site.userAgent` | string? | 可选，自定义 UA |
| `site.cookies` | string? | 可选，站点 Cookie（如 `session=xxx`） |
| `site.headers` | object? | 可选，自定义请求头 |
| `site.mirrors` | array? | 可选，镜像站列表，每项 `{name, domain, baseUrl}`（站点主域失效时自动切换） |
| `site.publishPageUrl` | string? | 可选，发布页地址（站点主域失效时的导航页，可从中提取备用镜像） |
| `site.publishMirrorSelector` | string? | 可选，发布页镜像提取规则（正则字符串或 CSS 选择器） |

**`network`（可选，v0.4.0 新增）**——源级网络覆盖，让源可以自带「推荐网络配置」：

| 子键 | 类型 | 说明 |
| --- | --- | --- |
| `network.proxy` | object? | 代理覆盖，如 `{ "mode": "http", "host": "...", "port": 7890 }` |
| `network.dns` | object? | DNS 覆盖，如 `{ "mode": "system" }` 或 `{ "servers": ["8.8.8.8"], "dohUrl": "..." }` |
| `network.hosts` | array? | Hosts 覆盖，每项 `{ "ip": "1.2.3.4", "host": "example.com" }` |
| `network.sni` | object? | SNI 覆盖 |
| `network.ech` | object? | ECH 覆盖 |

规则：某子键**缺省 = 继承全局设置**；填写了则**整方面覆盖全局**。生效优先级：**用户对源的 UI 覆盖 > 源 JSON 的 `network` 块 > 全局设置 > 默认值**。非法值只告警、不会导致源无法启用。

> ⚠️ 诚实的限制：`sni` 受 Dart TLS 栈能力限制仅尽力生效；`ech` 运行时暂未接通。这两个键先别指望，其余（proxy / dns / hosts）都真实生效。

### 4.5.2 源编写教程（分级：基础 / 中级 / 高级）

下面按**难度分级**给出源编写教程，与在线版一致。完整双语版见 [在线教程](https://nexhub-app.github.io/website/) 与仓库内 `docs/developer-guide.md` 之下的字段速查。

#### 🟢 基础：源文件是什么 & 基础字段

**源文件是什么**：源是一个 JSON 文件，描述「如何去某个网站抓取动漫 / 漫画 / 小说 / 影视」。NexHub 只提供通用引擎，所有站点专属的解析逻辑都写在这个文件里——这就是「源即插件」。应用内置 JS 沙箱：能用声明式选择器（jsonpath / css / xpath）直接抽取字段，也能内嵌 JavaScript 处理复杂页面。

**基础字段（每个源都有）**：

| 字段 | 说明 |
| --- | --- |
| `id` | 必填，唯一标识（如 `manga_goda`）；同名源按 `version` 升级 / 跳过 |
| `name` | 必填，显示名称 |
| `version` | 整数版本号（默认 1）；同名源按版本号升级 / 跳过 |
| `type` | 必填，媒体类型：`animeSource`（影视 / 动漫）/ `mangaSource`（漫画）/ `novelSource`（小说） |
| `site` | 必填，站点信息（见 4.5.1） |
| `parser` | 解析配置：`{ type, overrides?, script? }`；`type` 取 `builtin` / `hybrid` / `script` |
| `ageRating` | **可选，年龄分级**：`general`（全年龄）/ `teen`（青少年 16+）/ `mature`（成人 18+）；兼容别名如 `all` / `16` / `r18` / `nsfw` 等；**缺省 `general`；`mature` 在默认设置下自动隐藏** |
| `enabled` | 可选，是否启用（默认 true） |

> 注意：源模型**不会读取** `author` / `lang` / `builtin` 这三个键——写进文件也会被忽略，请勿把它们当作功能字段。

**最小示例（声明式动漫源）**：

```json
{
  "id": "demo_anime",
  "name": "演示动漫",
  "version": 1,
  "type": "animeSource",
  "ageRating": "general",
  "site": {
    "domain": "example.com",
    "baseUrl": "https://example.com",
    "mirrors": [ { "name": "主站", "domain": "example.com", "baseUrl": "https://example.com" } ]
  },
  "parser": { "type": "hybrid", "overrides": { "latest": { "type": "builtin" } } }
}
```

#### 🟡 中级：六大内容模块

**搜索模块（search / ruleSearch）**——用户点击搜索框输入关键词时触发：

- 影视 / 漫画（范式 A）：在 `routes` 里定义 `search` 的 url（含 `{keyword}` 占位），用 `selectors` 或 script 把结果列表抽出来；
- 小说（范式 B，Legado 兼容）：用 `ruleSearch` 字段以 CSS 选择器声明每条结果的书名、作者、封面、详情链接；
- 返回字段通常含：`id`（详情页标识）、`title`、`cover`、`detailUrl`。

**发现 / 分类模块（discovery / ruleExplore）**——「首页」与「按分类浏览」使用此模块：

- 范式 A：`latest` / `explore` / `category` 路由 + `category.categoryEntries` 分类表；
- 范式 B：`ruleExplore` + `exploreUrl`（每行「分类名::链接」）；
- 首页板块由 `homeSections` 定义（标题、路由、样式 grid/list、数量）。

**详情 / 目录模块（detail / ruleBookInfo）**——点开一部作品时加载：标题、封面、简介、作者 / 主演、标签、状态、目录（章节 / 话数）列表。

**正文 / 章节内容模块（content / ruleContent）**——漫画的单话图片、小说的正文、影视的播放页：

- 小说范式 B：`ruleContent`（content / title / nextContentUrl）；
- 漫画：`chapters`（话列表）→ `images`（该话图片）两个端点；
- 影视：`episodes`（剧集列表）→ `video`（真实播放地址）两个端点。

**网络收藏（webFavorite，可选）**——源站自带「我的书架 / 收藏」网页时声明，让 App 在线浏览页多出一个「网络收藏」Tab（走源站账号，与 App 本地收藏相互独立）：

| 子键 | 说明 |
| --- | --- |
| `enabled` | 可选，是否启用网络收藏 Tab（默认 true） |
| `title` | 可选，Tab 显示名，如「我的书架」 |
| `route` / `url` | 查看收藏列表的路由名或完整地址；二选一，`route` 需在 `routes` 中定义 |
| `addRoute` / `addUrl` | 「加入收藏」的路由或地址，支持 `{id}` / `{detailUrl}` / `{title}` 占位符 |
| `requireLogin` | 可选，true 时要求先登录源站 |

```json
"webFavorite": {
  "title": "我的书架",
  "route": "webFavorite",
  "url": "/user/bookshelf",
  "addUrl": "/user/favorite/add?id={id}",
  "requireLogin": true
}
```

**源公告（announcement，可选）**——源作者给使用该源的用户发布一条公告（如「站点换域名」），以横幅展示在源的首页与详情页顶部：

| 子键 | 说明 |
| --- | --- |
| `title` | 必填，公告标题 |
| `body` | 可选，公告正文 |
| `url` | 可选，点击公告跳转的链接（如迁移说明页）；不填则公告不可点击 |
| `updatedAt` | 可选，更新时间，Unix 秒级时间戳（用于显示「几天前」） |

```json
"announcement": {
  "title": "站点已更换域名",
  "body": "旧域名 example-old.com 已停用，请更新到新域名。",
  "url": "https://example.com/notice",
  "updatedAt": 1700000000
}
```

**周期表 / 周更列表（schedule，可选）**——让源首页展示「周更表」（周一到周日每天更新了哪些作品）：

1. 在 `homeSections` 加一项：`{ "id": "week", "title": "周更列表", "route": "week", "style": "schedule", "limit": 0, "more": false }`；
2. 在 `routes` 里定义同名的 `week` 路由，其返回结果需带「星期」字段（App 按该字段把作品分到周一到周日）。

```json
"homeSections": [
  { "id": "week", "title": "周更列表", "route": "week", "style": "schedule", "limit": 0, "more": false }
],
"routes": {
  "week": { "url": "/api/weekly", "method": "get", "responseType": "json" }
}
```

#### 🔴 高级：选择器语法、JS 脚本约定、采集 API、网络 / 评论 / 登录

**解析方式两层结构**：

- 顶层 `parser.type` 只取三种：`builtin`（纯声明式）、`hybrid`（声明式 + 按 API 用 overrides 覆盖，**最常用**）、`script`（全部走 JS 沙箱）；
- 每个 API 可在 `parser.overrides.<api>.type` 指定实际解析方式：`builtin` / `xpath` / `jsonpath` / `css`（四种声明式子类型）/ `script`（JS 沙箱）/ `webview`（内嵌浏览器渲染后抽取，常用于 m3u8 提取）/ `webview-html`（WebView 取回 HTML 再走解析，常用于反爬搜索）。

**选择器语法速查**（按 overrides.type 选一种）：

- `jsonpath`：以 `$` 开头，适合 JSON 接口，如 `$.list[0].vod_name`；
- `css`：标准 CSS 选择器，适合 HTML，如 `.bookname a`；
- `xpath`：以 `//` 或 `./` 开头，适合 HTML，如 `//video/@src`；
- 小说源（Legado 兼容）额外支持：`@text` 取文本、`@href` / `@src` 取属性、`@textNodes` 取干净正文、`||` 为回退选择器、`a:contains(文字)` 按文本筛选、用 `.0` / `.1` / `-1` 取第 N 个。

**内嵌 JS 脚本约定**（当声明式选择器搞不定时）：

1. 函数签名固定为 `parseXxx(html, context)`，`html` 为页面字符串，`context` 含 `baseUrl`、`log` 等；
2. 必须**同步返回**结果（数组或对象）；
3. 需要异步数据时，返回 `{ __meta: true, __fetchUrl, __processor }` 协议对象——引擎会先预取该 URL，再调用 `__processor` 同步处理函数，**这是沙箱里唯一安全的异步通道**；
4. 不要写死任何站点常量到 App，全部留在源文件。

**采集 API 接口说明**——「采集 API」指一个源对外暴露的「抓取接口集合」，即 `routes` 里定义的一个个端点（search / latest / detail / video / images …）：

- 每个端点先在 `routes` 里定义 url（支持 `{keyword}` / `{page}` / `{id}` / `{url}` / `{detailUrl}` 占位符）、method、responseType、headers、params；
- 抽取方式由 `parser.overrides.<端点>` 决定：`builtin` / `xpath` / `jsonpath` / `css` / `script` / `webview` / `webview-html`；
- 声明式端点用 `selectors.<端点>` 指定选择器；脚本端点用 `overrides.<端点>.script` 提供函数；
- 常用端点一览：`search`（搜索）、`latest`（最新）、`explore` / `category`（发现 / 分类）、`detail`（详情 + 目录）、`episodes`（剧集列表）、`video`（视频地址）、`chapters`（漫画话列表）、`images`（漫画图片）、`week`（周更表）。

**源级网络 / 评论 / 登录（v0.4.0 新增）**：

- `network`：源级网络覆盖（见 4.5.1），缺省继承全局，非法值只告警；
- `comments`：声明该源的评论能力。`provider` 默认 `source`（评论来自源站）；`routes` 声明 `list`（**必需**）/ `replies` / `post` / `reply` / `like` / `report`（未声明的按钮不渲染）；`selectors` 用同一套 JSONPath / CSS / XPath 引擎抽取；`login` 可声明 WebView 登录页与登录态校验（`checkCookie` / `checkUrl`）；
- 源登录鉴权：对需登录的站点，可用 WebView 捕获会话 Cookie 或手动粘贴 Cookie，凭据仅存本地。

```json
"network": { "proxy": "direct", "dns": "system" },
"comments": {
  "provider": "source",
  "routes": { "list": { "url": "/api/comments?book={id}", "responseType": "json" } },
  "selectors": { "items": "$.list", "content": "$.content", "author": "$.user" }
}
```

### 4.5.3 完整示例（小说 / 影视 / 漫画）

#### 示例一：小说源（Legado 兼容）

> 小说源【不】使用 `id` / `name` / `type` / `site` 这些顶层字段，而是用 `bookSourceName` / `bookSourceUrl` / `bookSourceType` / `ruleSearch` / `ruleToc` / `ruleContent` / `ruleBookInfo` 等 Legado 字段；解析通过 `parser.overrides.content` 的脚本处理正文。

```json
{
  "bookSourceName": "演示小说",
  "bookSourceUrl": "https://m.example.com",
  "bookSourceType": 0,
  "enabledExplore": true,
  "enabledSearch": true,
  "exploreUrl": "玄幻小说::https://m.example.com/xuanhuan/\n都市小说::https://m.example.com/dushi/",
  "bookSourceGroup": "内置书源",
  "concurrentRate": 0,
  "ruleSearch": {
    "bookList": ".bookbox",
    "bookName": ".bookname a@text",
    "bookAuthor": ".author@text",
    "bookCoverUrl": ".bookimg img@src",
    "bookUrl": ".bookname a@href",
    "bookLastChapter": ".update a@text"
  },
  "ruleExplore": {
    "bookList": ".bookbox",
    "bookName": ".bookname a@text",
    "bookAuthor": ".author@text",
    "bookCoverUrl": ".bookimg img@src",
    "bookUrl": ".bookname a@href"
  },
  "ruleBookInfo": {
    "name": "h1@text",
    "author": "p:contains(作者)@text",
    "coverUrl": ".block_img2 img@src",
    "intro": ".intro_info@text",
    "tocUrl": "a[href^=\"/book_\"]@href",
    "lastChapter": "p:contains(最新) a@text",
    "bookStatus": "p:contains(状态) span@text"
  },
  "ruleToc": {
    "chapterList": "a[href^=\"/book_\"][href$=\".html\"]",
    "chapterName": "@text",
    "chapterUrl": "@href",
    "nextTocUrl": "a:contains(下一页)@href"
  },
  "ruleContent": {
    "content": "#nr1@html",
    "title": "#nr_title@text",
    "nextContentUrl": "a:contains(下一章)@href"
  },
  "parser": {
    "type": "hybrid",
    "overrides": {
      "content": {
        "type": "script",
        "function": "parseContent",
        "script": "function parseContent(html, context){ var raw = context.dom.queryHtml(html, '#nr1') || context.dom.queryHtml(html, '#content') || ''; raw = raw.replace(/<script.*?<\\/script>/gi, ''); return context.content.clean(raw); }"
      }
    }
  },
  "bookSourceComment": "演示小说源，正文为纯 HTML"
}
```

#### 示例二：影视源（animeSource）

> 影视源核心在 `video` 端点：这里用 `webview` 方式抽取真实播放地址（适合 m3u8 / 需执行页面 JS 才能拿到地址的站点）。**anime 源必须包含 `latest` 路由。**

```json
{
  "id": "demo_anime",
  "name": "演示影视",
  "version": 1,
  "type": "animeSource",
  "responseType": "json",
  "useWebview": true,
  "site": {
    "domain": "example.com",
    "baseUrl": "https://example.com",
    "mirrors": [ { "name": "主站", "domain": "example.com", "baseUrl": "https://example.com" } ]
  },
  "parser": {
    "type": "hybrid",
    "overrides": {
      "latest": { "type": "builtin" },
      "search": { "type": "builtin" },
      "detail": { "type": "builtin" },
      "episodes": { "type": "builtin" },
      "video": { "type": "webview" }
    }
  },
  "routes": {
    "latest": { "url": "/api/latest?page={page}", "method": "get", "responseType": "json" },
    "search": { "url": "/s?wd={keyword}&page={page}", "method": "get", "responseType": "json" },
    "detail": { "url": "/detail/{id}", "method": "get", "responseType": "json" },
    "episodes": { "url": "/detail/{id}", "method": "get", "responseType": "json" },
    "video": { "url": "{url}", "method": "get", "responseType": "html" },
    "week": { "url": "/api/weekly", "method": "get", "responseType": "json" }
  },
  "selectors": {
    "list": "$.list",
    "title": "$.vod_name",
    "cover": "$.vod_pic",
    "id": "$.vod_id",
    "detail": { "title": "$.vod_name", "cover": "$.vod_pic", "description": "$.vod_content" },
    "episodes": "ul li a"
  },
  "category": { "categoryEntries": [ { "id": "all", "title": "全部" }, { "id": "1", "title": "动漫" } ] },
  "homeSections": [
    { "id": "latest", "title": "最新更新", "route": "latest", "style": "grid", "limit": 18 },
    { "id": "week", "title": "周更列表", "route": "week", "style": "schedule", "limit": 0, "more": false }
  ]
}
```

#### 示例三：漫画源（mangaSource，GoDa漫画骨架）

> 漫画源比影视 / 小说多两个关键端点：`chapters`（话列表）与 `images`（该话图片）。要点：
> - `chapters` 常需二次请求——脚本先取页面里的 `data-mid`，再返回 `{ __meta: true, __fetchUrl, __processor }` 让引擎预取章节 API，随后由 `__processChapters` 同步处理；
> - 图片地址通常加密：把解密逻辑写在 `overrides.images.script` 的 `parseImages` 里，返回图片 URL 数组；
> - 分类标签（`selectors.category.tags`）的 `id` 用站点真实的 slug（如 古风=`gufeng`，无连字符），别自己发明。
>
> 为便于阅读，本示例把真实源里冗长的正则 / 解密脚本压缩成了骨架（直接导入会得到空结果），请把各 script 替换成真实解析逻辑后再使用。

```json
{
  "id": "manga_goda",
  "name": "GoDa漫画",
  "version": 4,
  "type": "mangaSource",
  "responseType": "html",
  "useWebview": true,
  "site": {
    "domain": "godamh.com",
    "baseUrl": "https://godamh.com",
    "mirrors": [
      { "name": "godamh.com", "domain": "godamh.com", "baseUrl": "https://godamh.com" },
      { "name": "m.baozimh.one", "domain": "m.baozimh.one", "baseUrl": "https://m.baozimh.one" }
    ]
  },
  "parser": {
    "type": "hybrid",
    "overrides": {
      "latest": {
        "type": "script",
        "function": "parseList",
        "script": "function parseList(html, context){ var baseUrl = (context.baseUrl || '').replace(/\\/$/, ''); var results = []; /* 正则抓 <a href=\"/manga/...\"> 块，取 h3 标题与封面 */ return results; }"
      },
      "search": { "type": "script", "function": "parseList", "script": "function parseList(html, context){ return []; }" },
      "detail": {
        "type": "script",
        "function": "parseDetail",
        "script": "function parseDetail(html, context){ return { title: '', cover: '', description: '', author: '', tags: [] }; }"
      },
      "chapters": {
        "type": "script",
        "function": "parseChapters",
        "script": "function parseChapters(html, context){ var m = html.match(/data-mid=\"(\\d+)\"/i); if (!m) return []; return { __meta: true, __fetchUrl: 'https://v2.apikk.top/api/manga/get?mid=' + m[1] + '&mode=all', __processor: '__processChapters' }; }"
      },
      "images": {
        "type": "script",
        "function": "parseImages",
        "script": "function parseImages(raw, context){ var urls = decrypt(raw); return urls; }"
      }
    }
  },
  "routes": {
    "latest": { "url": "/manga/list/", "method": "get", "responseType": "html" },
    "search": { "url": "/search?keyword={keyword}", "method": "get", "responseType": "html" },
    "detail": { "url": "/manga/{id}", "method": "get", "responseType": "html" },
    "chapters": { "url": "{url}", "method": "get", "responseType": "html" },
    "images": { "url": "{url}", "method": "get", "responseType": "html" }
  },
  "selectors": {
    "category": {
      "categories": [ { "id": "gufeng", "name": "古风" } ],
      "tags": [ { "id": "gufeng", "name": "古风", "url": "/manga-tag/gufeng" } ]
    }
  },
  "category": {
    "dynamicCategories": false,
    "categoryEntries": [ { "id": "all", "title": "全部" } ]
  },
  "homeSections": [
    { "id": "latest", "title": "最新更新", "route": "latest", "style": "grid", "limit": 18 }
  ]
}
```

### 4.5.4 源 JSON 字段规范（权威速查表）

> 字段以应用实际解析为准；完整约束以仓库源码 `lib/core/models/plugin_config.dart` 为最终依据。除 `id` / `name` / `type` / `site` / `parser` 外，其余字段均可选；未知键会被忽略。

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` | string | 源的唯一标识（同名导入时按 `version` 决策覆盖 / 跳过） |
| `name` | string | 源的展示名称 |
| `type` | string | `animeSource` / `mangaSource` / `novelSource` |
| `version` | int | 版本号（默认 1）；导入同名源时：`>=` 已安装版本则替换，`<` 则跳过 |
| `ageRating` | string | 可选；`general` / `teen` / `mature`（兼容别名，缺省 `general`；`mature` 默认隐藏） |
| `site` | object | 站点信息（**必填**）：见 4.5.1 |
| `parser.type` | string | 顶层解析引擎：`builtin` / `hybrid` / `script` |
| `parser.overrides` | object | 按 API 分组的解析覆盖，每项 `{ type, script?, function? }` |
| `routes` | object | 端点集合，每项 `{ url, method?, responseType?, headers?, params?, parser? }`；也支持字符串写法 `"url"` |
| `selectors` | object | 声明式抽取规则（按 overrides.type 选用 JSONPath / CSS / XPath） |
| `category` | object | 分类配置：`dynamicCategories` / `categories` / `categoryEntries`（静态分类表） |
| `homeSections` | array | 可选；自定义首页板块，每项 `{ id, title, route, params?, style?, limit?, more? }`，style 取 `grid` / `rank` / `scroll` / `schedule` |
| `filters` | object | 可选；动态筛选：`{ route?, groups?, byCategory?, defaults? }`，groups 每项 `{ id, title?, route?, param, multiSelect?, options[] }` |
| `tagSearch` | object | 可选；标签检索路由，配合 `selectors.category.tags` 生成标签筛选 |
| `antiHotlinking` | object | 可选；反盗链：`{ referer?, userAgent?, headers? }` |
| `webviewConfig` | object | 可选；`{ adblock?, timeoutSeconds? }` |
| `useWebview` | bool | 可选；整源使用 WebView 渲染 |
| `stealthMode` | bool | 可选；隐身模式（减少特征） |
| `network` | object | 可选（v0.4.0）；源级网络覆盖：`proxy` / `dns` / `hosts` / `sni` / `ech` |
| `comments` | object | 可选（v0.4.0）；评论能力：`provider` / `routes` / `selectors` / `login` |
| `announcement` | object | 可选；源公告：`title`（必填）/ `body` / `url` / `updatedAt` |
| `webFavorite` | object | 可选；网络收藏：`enabled` / `title` / `route` / `url` / `addRoute` / `addUrl` / `requireLogin` |
| `deprecated` / `enabled` / `enabledExplore` / `isHidden` | bool | 可选；废弃标记 / 启用 / 探索启用 / 隐藏 |
| `migrationMessage` | string | 可选；迁移提示 |

**`comments` 子字段（v0.4.0 新增，全部可选）**：

| 字段 | 说明 |
| --- | --- |
| `comments.provider` | 默认 `source`（评论来自源站）。`bangumi` 目前**仅解析、未实现** |
| `comments.routes.list` | **必需**（声明 `comments` 时）；评论列表路由 |
| `comments.routes.replies` / `post` / `reply` / `like` / `report` | 可选；**未声明则对应按钮不渲染** |
| `comments.selectors` | `items` / `commentId` / `author` / `avatar` / `content` / `time` / `likeCount` / `replyCount` / `hasMore` / `success` 等 |
| `comments.login.url` | 需要登录时的 WebView 登录页地址 |
| `comments.login.checkCookie` | Cookie 中出现该键名即视为已登录 |
| `comments.login.checkUrl` + `loggedInSelector` | 可选的二次探测 |

**关于 `version` 的导入规则（务必注意）**：

- 源作者发新版，只需把 JSON 里的 `version` 调大；
- 导入同名（`id`）源时：版本 **≥ 已安装版本** → 替换（高版本升级 / 同版本重新导入以应用你的编辑）；版本 **< 已安装版本** → 跳过，防止误装旧版冲掉新源；
- 内置源不可被覆盖；导入时会保留原有的「启用 / 隐藏」状态。

**调试与导入**：

1. 用浏览器开发者工具（F12）核对真实页面的 HTML / JSON 结构与选择器是否匹配；
2. 在 App 内「导入源」粘贴 JSON，若解析失败，检查 JSON 格式（注意转义引号与换行）；
3. 脚本类源可在 overrides 里用 `context.log()` 打印中间结果辅助定位；
4. 先在本地用一份最小数据源跑通一个模块（如 search），再逐步补全 detail / video / images；
5. 分享：把 JSON 文件发给朋友，或提交到社区源仓库，别人一键导入即可。

**贡献方式**：

1. 在自己的分支编写源 JSON，导入应用验证抓取是否正确；
2. 如需分享，通过社区渠道发布你的源 JSON（**请勿将源提交到本应用仓库**——仓库只托管引擎）；
3. 想改进引擎 / 阅读器 / 播放器 / 文档，欢迎提交 Issue 与 Pull Request。

> 共创的前提是**合规与尊重版权**：只解析你有权访问、且允许抓取的公开内容；不要将源用于侵犯他人合法权益的场景。

---

## 4.6 测试

```bash
flutter test
```

测试套件包含源 JSON 校验等；当本地没有内置源时，相关用例会自动跳过（契合开源无源模式）。

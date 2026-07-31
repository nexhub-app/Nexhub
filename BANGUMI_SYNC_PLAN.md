# Bangumi 同步功能实施计划

> 状态：待评审（Plan）→ 批准后进入 Craft 实现
> 方向：NexHub → Bangumi（把本地进度/收藏/评论推送到 Bangumi 个人档案）
> 范围：动漫、漫画、小说、影视 四类全做
> 认证：MVP 用「个人 Access Token」打通链路；发布形态升级为「完整 OAuth 应用」

---

## 1. 可行性结论

**可行，且契合度高。** Bangumi（bgm.tv）公开 API（v0）本身就是为"记录我看/读了什么"设计的，文档开源、维护活跃，标准 OAuth2 鉴权。NexHub 现有的进度/收藏数据模型与 Bangumi 的收藏/剧集接口高度对应，仅需解决"作品 ID 映射"与"章节模型差异"两个工程问题。

已确认现状（来自代码核查）：
- 进度数据分散在 `media_watched`（已看集 `Set<int>`）、`comic_progress`/`novel_progress`（`chapterIndex`+页码）、`FavoritesManager`（`FavoriteEntry`）。
- App 当前**没有账号系统、没有 OAuth、没有外部 ID 关联**（`MediaItem` 仅有内部 `id` 与 `sourceId`）。
- 已有可复用依赖：`dio`（HTTP）、`flutter_secure_storage`（凭证存储）、`shared_preferences`/`hive`（持久化）。
- 现有 `CloudSyncService` 是 WebDAV 整包备份，与 Bangumi 同步**目的不同、互不干扰**，本功能作为独立模块并列存在。

---

## 2. 架构设计（新增独立模块，不触碰解析器）

Bangumi 同步是**用户账号/云功能**，不是内容解析源，因此写成 Dart 模块不会违反"源即插件 / 解析逻辑全在源 JSON"的原则。新增目录 `lib/core/services/bangumi/`：

| 文件 | 职责 |
|---|---|
| `bangumi_client.dart` | dio 单例：`baseUrl=https://api.bgm.tv`；强制 `User-Agent`；Bearer 注入；统一错误/限流/重试 |
| `bangumi_auth.dart` | `FlutterSecureStorage` 存 `accessToken/refreshToken/expiry/username`；`isLoggedIn`/`logout`；OAuth 跳转（发布形态） |
| `bangumi_models.dart` | 收藏变更 payload、episode 状态、subject 简版模型（按官方 OpenAPI 对齐） |
| `subject_link_store.dart` | `contentId → subjectId` 持久化 + 标题搜索/相似度打分/低置信返回候选 |
| `bangumi_sync_service.dart` | 编排：读本地进度 → 解析 subject_id → 推送 BGM；失败项入日志不中断 |
| `settings_bangumi_screen.dart` | 设置页：Token/登录、立即同步、类型开关、状态展示（l10n） |

---

## 3. 数据映射（NexHub → Bangumi）

| NexHub 数据 | Bangumi 对应 | 可行性 |
|---|---|---|
| `media_watched` 已看集 `Set<int>` | `PUT /episodes/{id}` 标记已看 | 动漫高 / 其他低 |
| `FavoritesManager` 收藏 | `POST/PATCH /collections/{subject_id}`（想看/在看/看过） | 高 |
| `comic_progress` / `novel_progress` 章节 | book 按"卷"记录，**不精确对应** | 仅同步状态 |
| 收藏条目的 `id` | 需先绑定 `subject_id` | 中（见第 4 节） |
| 用户备注/评分 | collection `comment` / `rating` 字段 | 中（实现时对照 API 确认字段名） |

**媒体类型可行性分级：**
- **动漫（最干净）**：已看集 ↔ Bangumi 剧集，可精确到集。建议先做、先做对。
- **漫画 / 小说**：Bangumi 的 `book` 按"卷"记录，App 按章节记录，进度无法精确对应；只同步"在看/看过"+评论。
- **影视**：对应 Bangumi `real`（三次元），App 影视源为泛解析，匹配模糊；只同步状态+评论，建议后置验证。

---

## 4. subject_id 映射方案（核心难点）

Bangumi 用 `subject_id` 标识作品，NexHub 用各源内部 id，两者不互通。采用**三级解析**：

1. **缓存命中**：`subject_link_store` 中已有 `contentId → subjectId`，直接用。
2. **标题搜索**：`POST /v0/search/subjects`（带 `type` 过滤：anime=2 / book=1 / real=6）按标题相似度（如包含/编辑距离）打分。
   - 高置信（如完全匹配或高分）→ 自动采用并写缓存。
   - 低置信 → 返回候选列表，交 UI 让用户点选一次（点选后写缓存，长期有效）。
3. **手动绑定**：收藏/详情页提供"绑定 Bangumi 条目"入口（长按要求），用户从搜索结果里指定。

> 所有映射结果仅存于用户数据（收藏条目/link store），**不写死任何源**，符合共创式原则。

---

## 5. 推送流程（NexHub → Bangumi）

```
用户点"立即同步"
  └─ 校验登录（否 → 引导输入 Token / OAuth）
       └─ 遍历启用的类型下的 favorites/bookmarks
            ├─ 解析 subject_id（缓存→搜索→手动）
            ├─ 动漫：拉该 subject episodes → 按 sort 映射已看集 → PUT /episodes/{id} 标记已看
            │        整体状态：全看完→collect；否则→do
            ├─ 漫画/小说/影视：有进度→do；看完→collect（仅状态，不映射章节）
            └─ 评论：将用户备注/评分写入 collection 的 comment/rating 字段
       └─ 汇总同步日志（成功/失败/跳过）+ 上次同步时间
```

**待实现时对照实时 API 确认的点：**
- episode 标记的请求体 `type` 枚举值（预期 2=看过）。
- `comment` / `rating` 字段在收藏变更 payload 中的确切名称与取值范围（rating 1–10）。
- 番剧特殊集（OP/ED/SP）是否纳入映射（默认仅 `type=0` 本篇）。

---

## 6. 认证方案

- **MVP（个人 Access Token）**：用户在 `next.bgm.tv/demo/access-token` 生成 token，粘贴进设置页；存 `FlutterSecureStorage`。最快验证整条链路，仅自用。
- **发布形态（完整 OAuth 应用）**：在 `bgm.tv/dev` 注册应用，配置回调（deep link，如 `nexhub://oauth/callback`）；用 `app_links` 接收授权码换 token。适合分发给他人。
- 两者共用同一 `bangumi_client` 与 `bangumi_sync_service`，仅登录入口不同；先实现 token 路径，OAuth 作为后续增量。

---

## 7. UI / l10n

- 新增设置页 `settings_bangumi_screen`，与现有"云同步（WebDAV）"同级：
  - Token 输入框（或"登录 Bangumi"按钮）、"立即同步"按钮。
  - 类型开关：动漫 / 漫画 / 小说 / 影视。
  - 上次同步时间、同步日志、错误展示。
- 收藏/详情页增加"绑定 Bangumi 条目"入口。
- **全部可见文案走 l10n**：在 `lib/l10n/app_zh.arb` / `app_en.arb` 增加键（如 `bangumiSettings`、`bangumiTokenHint`、`bangumiSyncNow`、`bangumiSyncSuccess`、`bangumiBindSubject`、`bangumiLastSync` 等），并重跑 `flutter gen-l10n`（离线不可用时手动同步生成文件）。**禁止在 Dart 中硬编码中文。**

---

## 8. 依赖

- 已有（直接复用）：`dio`、`flutter_secure_storage`、`shared_preferences`、`hive`。
- 新增（仅发布形态需要）：`app_links`（OAuth 回调）。MVP 阶段无需新增依赖。

---

## 9. 实施阶段与任务拆分

**Phase 0 — 基础**
- [ ] `bangumi_client.dart`：dio 单例、baseUrl、强制 UA、Bearer、限流/重试/统一错误。
- [ ] `bangumi_auth.dart`：secure storage 存读写、`isLoggedIn`/`logout`（先支持 token 字符串）。
- [ ] `bangumi_models.dart`：收藏 payload、episode 状态、subject 简版模型。

**Phase 1 — subject_id 映射**
- [ ] `subject_link_store.dart`：缓存读写 + 标题搜索 + 相似度打分 + 候选返回。
- [ ] 收藏/详情页"绑定 Bangumi 条目"入口（长按要求，手动选）。

**Phase 2 — 推送核心**
- [ ] `bangumi_sync_service.dart`：遍历 favorites/bookmarks（按启用类型）。
- [ ] 动漫分支：拉 episodes、按 sort 映射已看集、批量标记已看、写收藏状态。
- [ ] 漫画/小说/影视分支：写状态（do/collect）。
- [ ] 评论/评分分支：写 collection `comment`/`rating`。
- [ ] 失败项收集进日志，不中断整体。

**Phase 3 — UI / l10n**
- [ ] `settings_bangumi_screen`：Token 输入、立即同步、类型开关、状态展示。
- [ ] l10n 键与生成文件同步。

**Phase 4 — 收尾**
- [ ] 限流/防抖、空状态、未登录引导、错误码友好提示。
- [ ] 本地构建验证（`flutter analyze` / `flutter run`）。

---

## 10. 风险与限制（必须已知）

1. **漫画/小说/影视只能同步"在看/看过 + 评论"**：Bangumi 的 book/real 按"卷"记录，App 按章节记录，进度无法精确对应。四类全做 ≠ 四类都精确到集。
2. **标题匹配有误差**：源站中文译名常与 Bangumi 原名不一致，强烈建议对低置信度条目手动绑定一次（绑定后长期有效）。
3. **OAuth 完整应用需注册 `bgm.tv/dev` 并配回调域名**：MVP 用个人 token 验证全流程，发布前再补。
4. **限流**：Bangumi 有频率限制，需请求间隔 + 并发上限 + 断点续传（记录上次同步，可增量）。
5. **本机无 Flutter SDK**：代码改动后需用户在本地 `flutter analyze lib` / `flutter run` 验证，本助手无法代为编译。

---

## 11. 验证方式

- 单元/逻辑层：对 `subject_link_store` 相似度打分、`bangumi_sync_service` 的映射与失败处理写轻量测试（如有 test 环境）。
- 集成层：用户本地用个人 token 登录 → 选一部已看动漫 → 点"立即同步" → 在 Bangumi 个人页确认收藏状态与已看集已更新。
- 静态：`flutter analyze lib` 无新增报错；grep 确认无 Dart 硬编码中文（l10n 全覆盖）。

---

## 12. 下一步

1. 确认本计划（含 MVP 先以"动漫 + 个人 token"最小可用版本起步，跑通后再扩展漫画/小说/影视与 OAuth）。
2. 切换到 **Craft 模式**，从 Phase 0 的 `bangumi_client` + `bangumi_auth` 开始实现。
3. 每完成一个 Phase 即做静态检查与（用户侧）真机验证，按源/类型报告结果。

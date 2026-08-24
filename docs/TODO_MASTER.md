# NexHub 主 TODO（三模块合并 · 未完成项 · 2026-08-18）

> **唯一执行入口，仅收录未完成 / 部分完成 / 归档项**。已完成项不在此列出——其状态与 commit 证据见
> `docs/TODO_COMPLETION_AUDIT.md` 及 `ku/_refs_*` 原始 TODO。
>
> 来源：完成度审计 `docs/TODO_COMPLETION_AUDIT.md`、小说 `ku/_refs_novel/TODO_novel_reader.md`（542 行）、
> 播放器 `ku/_refs_player/TODO_player.md`（184 行）、漫画 `ku/_refs_reader/TODO_comic_reader.md`（177 行）。
> 原文档保留在 `ku/`（含完整对标证据与 file:line，实施时回原始文档查证）。

## 0. 图例与未完成速览

| 标记 | 含义 |
|---|---|
| ⬜ | 未完成（待办） |
| ⚠️ | 部分完成——括号内为已做部分，剩余待办 |
| ❌ | 评估后暂不实现（归档） |
| ⚪ | 暂缓 / 不学（漫画清单，社区非标配） |

| 模块 | L2 高价值 | L3 体验 | L4 远期/归档 |
|---|---|---|---|
| 小说 | 0 待办（P1-1/P1-2 归档，P1-5/P1-7 完成） | 15（含低挂果 9） | 13（含远期单列 10） |
| 播放器 | 0 待办（9 项全部完成） | 5 | 1（F-13 归档）+ 归档 3 项 |
| 漫画 | 0 待办（P1 输入/功能 9 项全部完成） | 6 | 5 + 暂缓清单 |

> ✅ **L0 已清零**（2026-08-18）：Legado 兼容代码豁免清理裁定（§2）、Flutter 本机实扫确认 3.47.0、审计 §3 的 9 处残留已清理。**L1 已全部完成**（2026-08-18 用户逐项确认），无待办。
> ✅ **L2 漫画清零**（2026-08-22 源码审计 + 夜览盖层补齐）：P1 输入/功能 9 项全部完成并回填，详见下方漫画表；剩余 L2 待办仅 X 组跨类型项（X-1 睡眠定时→漫画、X-2 待读队列→小说/漫画 等 5 项）。
> ✅ **L2/L3/L4 逐项确认（2026-08-18 用户）**：13 项已做剔除（漫画：自动滚动、过渡动画、每屏多图、浮层、章节滑块、跳章过滤、章末过渡、首屏单图、页间距；小说：阅读统计、B11 亮度、搜索正则；播放器：F-21）；3 项决策不做归档（长按缩放、三层设置、P2-1）；2 项默认未做待检测（漫画图片加载失败重试 UI、播放器 F-29 缓存降级）。
> 🆕 **跨类型对齐评审（2026-08-18 用户）**：新增 X 组 5 项（X-1 睡眠定时→漫画、X-2 待读队列→小说/漫画、X-3 统一图片图库→播放器/小说、X-4 小说预下载、X-5 TTS 通知栏，见 L2 跨类型小节）；B2/B3/B4 作为原条目范围扩展注记（P1-2 / F-27 / F-28）。未纳入：A2、A6、B1、B5；C 类（弹幕/字幕/PiP/投屏/倍速/划线/TTS 朗读/缩放图片收藏等类型特有功能）确认不跨类型对齐。
> 📦 **已归档（用户评估裁定）**：小说 L2 两项归档，L2 无待办——**P1-1 书源多线路支持**（已决策抛弃，永不实现）；**P1-2 书源质量体检 / 调试器**（已实现并 `dart analyze` 0 error 后评估无用，实现、入口、l10n `diagnose*` 键与 `AppLog` 作用域捕获整体移除，后续不再实现）。两者详见下方 L2 表格 ❌ 行。

---

## 1. 统一分级执行清单

> 分级沿用小说 §5 的 L0-L4 五级，跨三模块统一：
> **L0 合规与正确性**（必须立即做）→ **L1 核心 bug 修复** → **L2 高价值能力补齐** → **L3 体验增强** → **L4 远期/探索**。
> 每项标注【模块 · 原始编号】，编号与原始文档一一对应（细节回原始文档）。

### L0 合规与正确性（剩余 1 项）

| 状态 | 项 | 模块·编号 | 说明 / 验收 |
|---|---|---|---|
| ✅ | **修订实机检验清单** | 工程（审计§5-4） | `REAL_DEVICE_VERIFICATION_PLAN.md` v3（2026-08-21 重建：原文件本地丢失未入库，按工作记忆沿革重建）——F-8、漫画书签/图片收藏/自然排序、小说 B-01~B-08 等实已完成项已从「已知待做」移除，改标「已完成·未纳入原检验」并补入第 3 节检验项主体；「仍真正待做」（第 5 节）仅保留真实待办 |

> （原「清理 `legado` 标识符残留」项已按 **2026-08-18 用户裁定豁免**：Legado 兼容代码保留标识、无需清理，见 §2。）

### L1 核心 bug / 正确性 — ✅ 已全部完成

> 2026-08-18 用户逐项确认：L1 全部实现（TXT 长章拆分、512KB 分块流式、跨章无缝续读、单击翻页延迟消除、清晰度切换），**无待办**；实现明细回原始 TODO 查证。

### L2 高价值能力补齐

#### 小说

| 状态 | 项 | 编号 | 要点（对标证据见原始文档 §3.4） |
|---|---|---|---|
| ❌ | 书源多线路支持 | P1-1 | **已决策抛弃，永不实现**。源允许返回多 `urls`/`lines` 数组并支持切换（对标 `BookSourcePart`） |
| ✅ | 划线/高亮摘录 | P1-5 | 选区→高亮/摘录/分享卡片；锚点就近/归一化匹配；**前置：长按选词（N6，当前仅段落级）**。2026-08-22 全部 Phase 完成 + `dart analyze lib` 0 error。Phase 0：选区基础设施（`NovelSelectionController` 章内全局字符偏移坐标系 + 活动选区 + 已存划线重定位 + 词/段范围查询、`NovelHighlightManager` Hive box `novel_highlights`、l10n 16 键、长按选区手势 arena 分离、活动选区 + 已存划线背景富文本渲染、`AnimatedBuilder` 实时刷新、底部工具条 复制/整段/划线色板×4/取消、翻页手势在选区激活时让位）。Phase 2：工具栏「摘录」入口（`_selHighlightWithNote` 落盘后弹笔记编辑）+ 划线列表 sheet（`_showHighlightList` 三点菜单 `highlights` + 编辑/删除/跳转，复用 `NovelHighlight.note` 不引入独立 box）+ manager 扩 `getByKey`/`update`。Phase 3：分享卡片（工具栏「分享」→ `_selShare` 预热书封 + `_NovelShareCard` 1080×1440 渐变文艺卡 + `RepaintBoundary` 栅格化 PNG → `Share.shareXFiles`，异常 `shareFailed`）。Phase 4：滚动模式选区（与分页共享章内全局偏移坐标系：`setBlocks` 注入、`globalOffsetForBlock`/`blockSpans`、滚动文本块包长按选整块、`buildSelectionRichText` 提顶层函数共用、滚动模式点按收起工具条）。**已知限制：多行拖拽选区当前仅行内/整块级（整段由工具条按钮覆盖）；滚动模式「整段」按钮因 `_pagination` 为空暂无效（长按已选整块）；待真机/真实源验证** |
| ✅ | **替换规则 / 高亮规则** | P1-7 | `pattern/replacement/scope/isRegex/timeout/order`；**排版期编译规则缓存 + 局部重排**（规则变更不重拉全书）；书籍级开关。2026-08-21 已实现：模型（`NovelReplaceRule`/`NovelHighlightRule`/`NovelRuleCache`）、集成到阅读器（`_applyConvert` 替换规则先行）、规则管理 UI（`NovelReplaceRuleScreen` 列表/编辑/开关） |
| ❌ | 书源质量体检 / 调试器 | P1-2 | 已实现并 `dart analyze lib` 0 error 后，**用户评估该功能无用，整体移除（归档）**：删除实现（`source_doctor.dart`、`source_diagnostics_screen.dart` 及漫画/影视 runner）、源管理页「更多」菜单入口（`source_manager_screen.dart`/`unified_source_tile.dart`）、l10n 全部 `diagnose*` 键与 `AppLog` 作用域捕获；`flutter gen-l10n` 重新同步 generated。不做保留，后续不再实现 |

#### 播放器（Phase 4/5 核心增强）

| 状态 | 项 | 编号 | 要点 |
|---|---|---|---|
| ✅ | 系统 PiP 完整生命周期 | F-23 | 进入保存位置、退出 seek 恢复、窗口三动作、条件进入；当前仅 B-9 基础生命周期落地 |
| ✅ | 投屏完整生命周期 | F-26 | DLNA 位置同步（周期上报/接收）、错误上报、断开自动暂停；现仅 LOAD 后无同步 |
| ✅ | 桌面 PiP 窗口 | F-24 | window_manager 隐藏标题栏 + 缩小主窗口置顶（480×270、16:9 锁定、320×180–960×540 可缩放），拖动视频区移动窗口，悬停/点按显示紧凑控件（关闭/播放/进度条）；进出保存并恢复原大小/位置/最大化/标题，dispose 兜底恢复；Android 仍走系统 PiP（F-23） |
| ✅ | 字幕按视频记忆 | F-22 | 按 URL/hash 记忆外部字幕列表、激活轨道与样式；默认同名文件查找 |
| ✅ | 防重叠轨道算法 | F-17 | `willClash` 速度预判 / 轨道分配，`maxTracks = 屏高×使用率/轨道高`；可先做纯 Dart 替换 canvas_danmaku 默认行为 |
| ✅ | seek 后弹幕位置稳定 | F-19 | 代数计数失效或 time-driven 布局 |
| ✅ | 播放器抽象层完善 | F-2 | `VideoPlayerBackend` 仅 5 方法；扩展为能力探测式接口，`is` 探测降级（NoOp 风格） |
| ✅ | 拆分单文件 | F-27 | 拆手势控制器/选集线路 sheet/更多菜单/媒体信息/统计/睡眠/截图/弹幕输入/投屏。`video_player_screen.dart` 5887→3909 行（9 个 part 文件：8 extension + 1 widgets），`dart analyze lib` 0 error。2026-08-18 范围扩展：三阅读器单文件拆分工程——`novel_reader_screen.dart` ~7161 行（更严重）、`comic_reader_screen.dart` ~3.2k 行 待后续 |
| ✅ | 异步会话取消抽象 | F-28 | `_loadToken` 推广为通用会话取消；所有 `await` 后校验 `isCurrent/isStale`。**2026-08-18 范围扩展：推广至 novel/comic 阅读器** |

#### 漫画（P1 输入/功能）

| 状态 | 项 | 要点 |
|---|---|---|
| ✅ | 预加载数量可配置（1-16） | `ReaderPreferences.preloadImageCount`（默认 4，clamp 1-16）+ 设置面板滑杆（`reader_settings_sheet.dart` min:1/max:16）；`_maybePreload` 双端按该值预载（`comic_reader_screen.dart:1591/1602`）。三家默认 4 对齐 |
| ✅ | 键盘快捷键补全 | `_handleKeyEvent`（`comic_reader_screen.dart:3550`）：WASD + 小键盘 2468 + PageUp·Down 翻页（条漫走单步滚动）、Ctrl+方向跳章、N/P 上下话、± 缩放、F11/Esc/空格；放大态方向键语义已定并实现——先平移（步长 ≈ 视口 1/3）到底再翻页/滚动（`_handleZoomedArrow`） |
| ✅ | 鼠标滚轮速度可调 | `ReaderPreferences.readerScrollSpeed`（clamp 0.5-3.0，默认 1.0）+ 设置面板滑杆（min:0.5/max:3.0）；webtoon 滚轮滚动距离乘该倍率（`_onPointerScroll` `dy * readerScrollSpeed`），翻页模式滚轮可配缩放/翻页（`mouseWheelAction`） |
| ✅ | 鼠标光标反馈 | 图片区 `MouseRegion(cursor: isZoomed ? grab : click)`（`MangaPageImage.build`）、章节滑块 grab、顶/底栏 click |
| ✅ | 放大态边缘滑动切页 | 等价实现（REQ-B9，`_onPanUpdate`）：放大态平移被边界夹紧后继续向边外滑，累计超过 56px 阈值触发翻页 / 条漫滚动（`_edgeSwipeAccum`/`_edgeSwipeThreshold`），与键盘方向键语义一致；未采用 Mihon 步长+250ms 动画路径 |
| ✅ | 缩放锚点可配 zoomStart | `ReaderPreferences.zoomStart`（LEFT/CENTER/RIGHT）+ `_anchorFromZoomStart`（`comic_reader_screen.dart:3032`）+ 设置面板分段选择（`_buildZoomStart`）；center 保留触点锚定 |
| ✅ | 亮度双轨方案 | 主干（REQ-C3）：正值写系统 `screenBrightness`、负值系统最低+黑遮罩（`_applyBrightness`+`_dimBrightnessActive`，透明度随 \|值\|）✅ 早已实现；**2026-08-22 补齐 VeneraX 夜览暖色盖层**：独立开关 + 强度滑杆（0.1-0.85，`ReaderPreferences.nightLightEnabled/nightLightOpacity`，色 0xFF2A1800 入 `ReaderTokens.nightLightColor`），阅读区叠加层 + 阅读器内联面板 + 全局设置屏幕，三层覆盖（global→work→device）完整 |
| ✅ | 图片加载失败重试 UI | `SourceImage`→`_RetryableNetworkImage`（`source_image.dart:196`）：指数退避重试（1s/2s/4s 共 3 次）失败后显示 broken_image + 「重试」按钮（`_buildError`），不再永久转圈；本地图失败回落 placeholder。**状态：源码确认已实现** |
| ✅ | 历史 hidden 列 | `HistoryManager`（`history_manager.dart`）：`clearHistory`/`hideAll` 批量软删除置 `hidden=true` 保留进度，`markHidden` 单条隐藏，`restore`/重读自动复原；物理清空走 `clearAll`；l10n 文案「阅读进度将保留，重新进入该作品后自动恢复」。**状态：源码确认已实现** |

> ✅ **2026-08-18 用户确认已做并移除**：自动滚动+后台暂停、翻页过渡动画+双击缩放动画、每屏多图、时间/电量浮层、章节导航滑块、跳章过滤、章末过渡/评论、首屏单图、页间距。
> ✅ **2026-08-22 源码审计回填**：上表 9 项经 `dart analyze` + 相关测试验证全部完成（其中 8 项此前已实现但未回填，仅夜览暖色盖层本轮补齐）；跨类型 X-1/X-2 仍待办见下节。
> ❌ **2026-08-18 决策不做**：长按缩放+锚点、三层设置覆盖（见 L4 归档）。

#### 跨类型对齐（X 组 · 2026-08-18 评审新增）

> 用户评审：部分功能仅单一类型具备/列入，其他类型需同步拥有。已确认 5 项加入（A2/A6/B1/B5 未选；C 类类型特有功能确认不跨类型）。

| 状态 | 项 | 目标类型 · 优先级 | 要点 |
|---|---|---|---|
| ⬜ | X-1 睡眠定时 | 漫画 · 中 | 按分钟 + 按话数；与播放器 F-5（已完成）/ 小说 TTS 睡眠定时对齐 |
| ⬜ | X-2 跨作品待读队列 | 小说/漫画 · 中 | 书架「加入队列 / 读完下一部 / 恢复最近队列」；复用播放器 F-4（已完成）的 `PlayQueueStore` 持久化模式 |
| ⬜ | X-3 统一图片收藏图库 | 播放器/小说 · 低-中 | 播放器截图、小说插图/封面一键收藏入统一图库；复用漫画 `image_favorite_gallery_screen` 架构 |
| ⬜ | X-4 阅读中预下载后续章节 | 小说 · 中 | >阈值触发后台预下载后续 N 章（离线阅读）；对齐漫画「自动下载」/ 播放器「>80% 预解析+预下载」 |
| ⬜ | X-5 朗读通知栏控制 | 小说 TTS · 低-中 | 锁屏/通知栏媒体控制（播放/暂停/上句/下句）；对齐播放器 F-25 的 `AudioPlaybackService` |

### L3 体验增强

#### 小说

| 状态 | 项 | 编号 | 要点 |
|---|---|---|---|
| ⬜ | 排版偏好补齐 + 分享 JSON | P2-10 | 字重 100–900 细粒度、两端对齐 `textFullJustify`、中文逐字断行 + 禁首禁尾标点（6 种 BreakMod）、标题上下留白、虚线/波浪下划线、墨水屏第三套背景、排版参数导出/导入 JSON（shareReadConfig）；顺带评估流式切页（A4） |
| ⬜ | 阅读进度云同步冲突裁决 | P2-8 | 拉取→章节+字符偏移双维度比较→本地>云端上传、本地<云端弹确认框再 setProgress；启动全量拉取按 syncTime/lastModify 裁决；恢复差分 upsert + 统计 max 合并；onPause/网络恢复触发。防多端回退覆盖 |
| ⬜ | 在线多音色 TTS | P2-3 | 云端 HTTP TTS：cue 判角色分句器 + 预下载 Semaphore 1-8（连续失败 3 章停）+ 静音占位降级 + 自动续章；当前仅 flutter_tts 离线 |
| ⬜ | 翻页动画与手势增强（剩余） | P2-9 | 剩余：**N3 翻页动画类型扩展**（Cover/Slide/Simulation/Scroll/Fade/None，已有 `novel_page_animation.dart`）、**N4 下滑切书签手势**（dy>0 且 absY>absX*ratio，页面随指下移+顶部提示条） |
| ⬜ | 划线批注导出与换源重定位 | P2-11 | 划线存「选中文本+前后 48 字符上下文」，换源/正文变化后 contextBefore/After 打分重定位（仅接受唯一最高分）；划线随导出附带 |
| ⬜ | 滚动模式排版/图文增强 | P2-4 | 边距/对齐/栏数；图文 SINGLE 居中/左右样式 |
| ⬜ | 低挂果（可散做） | 各 | D8 书名/作者自动解析；E2 词组级繁简+排除词表；E4 搜索标题/结果应用繁简；K3 正文多页 nextContentUrl（串行/并发）；M2 书架排序扩展（最新章/中文书名/手动/作者）；M3 未读角标/新章提示；N2 九区动作补齐（菜单/翻章/朗读/书签/净化等 14 动作）；O5 像素级平滑自动翻页；I7 书签角标自定义图（✅ 2026-08-18 已做剔除：B11 亮度独立、搜索正则化） |

#### 播放器

| 状态 | 项 | 编号 | 要点 |
|---|---|---|---|
| ✅ | 超分辨率 shader | F-7 | mpv `glsl-shaders` 注入 Anime4K 效率/质量档（无清晰度源时提升观感），注意性能档位。2026-08-24 已实现（8d2052e）：内置 Anime4K v4 GLSL 预设（Mode A Fast/HQ 共 8 文件 ≈393KB，MIT 随应用分发+致谢页署名）；`anime4k_shaders.dart` 首次使用时从资产部署到应用支持目录（版本标记重拷）；`VideoPlayerBackend.setUpscaleShaders` + `PlayerCapability.upscaleShader` + `PlayerController.setUpscaleShader`（运行时切换即时生效无需 re-open，off/失败传空串清空）；`PlayerSettings.upscaleShader`（默认关，支持按剧集覆盖）；入口：更多菜单档位下拉 + 全局播放器设置页分段（关闭/效率/质量）；7 项单测（`player_upscale_shader_test.dart`）。**待真机验证画质与性能档位帧率** |
| ⬜ | 弹幕发送上传 | F-18 | 现仅本地即时显示；接弹幕平台发送 API（需登录态），校验时长/集数 |
| ⬜ | 缓存策略降级 | F-29 | 移动网络/低内存自动降级 demuxer 缓存（1500MB→2MB），HLS 强制 `demuxer-lavf-format`。**状态：默认未做，待检测** |
| ⬜ | 错误分级重试 | F-30 | `waitUntilMediaReady` 按来源分级超时（媒体服务器 30s/网络 6s/本地 5s）+ 单次自动重试 |
| ⬜ | 声明式播放器菜单 | F-31 | 菜单项带 `visibilityPredicate` 按内核能力动态显隐，适配多内核/平台 |

#### 漫画（P2 剩余）

| 状态 | 项 | 要点 |
|---|---|---|
| ⬜ | 非防缩模式双击下限 0.5 改回「适配尺寸」 | `_toggleZoom` :1365 硬编码 0.5，绕过 minScale=1.0 |
| ⬜ | 条漫占位高评估 | 屏宽×1.5 经验值（铁律：判定必须基于真实图片高度） |
| ⬜ | 条漫纵向平移 clamp 改按列表实际总高 | 硬编码 8 倍视口（`_clampWebtoonZoomMatrix` :3253） |
| ⬜ | E-Ink 刷新设置 | Venera 系：开关/时长/间隔/样式 |
| ⬜ | ICC 校色 displayProfile | Mihon |
| ⬜ | 自动收藏封面 isAutoFavorite | KongComic/Venera 系 |

### L4 远期 / 探索

| 状态 | 项 | 模块·编号 | 要点 |
|---|---|---|---|
| ⬜ | 云同步增强（细粒度实时同步） | 小说·P2-5 | WebDAV 基础上逐书/逐章细粒度（局域网增量可参考） |
| ⬜ | 双语/段落翻译与 AI 章节配图（剩余） | 小说·P2-7 | 剩余：O3 双语/段落翻译、O4 AI 章节配图（O2 AI 摘要已实现并随 v2.0.0-beta.1 发布：离线抽取式 + 云端 AI 可切，不在本清单） |
| ⬜ | 远期单列项 | 小说·各 | A7 双页模式；D7 Mobi/PDF/Umd 格式；D9 压缩包批量导入；F4 导出自定义模板（fonts.css/cover/intro）；F5 翻译缓存随导出附带；F6 导出到 WebDAV；G3 整本分页校准；N7 内容编辑（直接改正文）；E5 书源 JS 暴露繁简函数；B3 墨水屏背景主题化 |
| ❌ | 用户 2026-08-18 决策不做 | 跨模块 | 漫画·P1 长按缩放+锚点可配（长按仅保留弹菜单）；漫画·P1 三层设置覆盖（全局→作品→设备）；小说·P2-1 AI 辅助书源生成（自动探站→生成 WebBook 源——产物本就不进 Dart，后续需要可重新评估） |
| ❌ | 进度条拖拽帧预览 | 播放器·F-13 | **已评估暂不实现（归档）**：①需常驻第二个 Player 实例，移动端易 OOM；②HLS 反复 seek+snapshot 触发缓冲劣化；③无真机验证通道。若后续要做，建议 media_kit 单实例 + `snapshot()` 轻量取帧 |
| ⬜ | 漫画 P3 资源/内存 | 漫画·P3 | CBZ 解压临时文件退出清理（`_extractCbz`）；`_preload`/`_renderedHtmlByChapter` 缓存清理策略（当前只增不减）；图片磁盘缓存管理入口（`imageCache.maximumSizeBytes` 100-500MB，退出恢复 100MB）；进程被杀状态恢复（恢复章节/页码）；连续模式解码限幅 enableResize 2560 |
| ⚪ | 暂缓 / 不学 | 漫画·P3 | WebDAV 同步、多库管理、应用锁；双页封面检测、竖屏自动单页；纵向 RTL、热区完全自定义网格；AI 图片翻译；自定义 GLSL/JS 滤镜编辑器；三指/双指特殊手势、缩放级循环、按住放大松开还原（五仓均无，非行业标配，不强制补） |

---

## 2. 合规裁定记录：`legado`/`gedoor` 标识豁免范围（2026-08-18 用户裁定）

按 `docs/ARCHITECTURE_BASELINE.md §2`，应用代码/注释不得出现 `legado`/`gedoor` 等参考仓库名。**用户 2026-08-18 裁定：与 Legado 源兼容相关的代码保留 `legado` 标识（注释 / 参数名 / commit message），无需清理**——兼容实现须以 Legado 规则语义为准（`ruleToc.formatJs`、`bookSourceType == 0`、`pick(String legado, …)` 等），点名属功能性/契约性描述；仅**非兼容代码**继续守基线。

实扫依据（`Get-ChildItem lib -Recurse -Filter *.dart | Select-String -Pattern 'legado|gedoor'`，排除 l10n/generated/about）：

- ✅ 审计 §3 的 **9 处已清理**（`library_sources_screen` / `source_manager_screen` / `source_manager_panel` / `source_import_screen` / `analyze_jsoup` / `html_utils` / `media_api_service` / `source_repository`，实扫 0 命中）——属源管理 UI 层措辞，非兼容必需。
- ⚪ **30 处评估后全部豁免**（位于 Legado 兼容实现，保留标识），清单存档备查：

| 文件 | 处数 | 行号 | 类型 | 示例 |
|---|---|---|---|---|
| `shuyuan/web_book/book_content.dart` | 8 | 156, 239, 245, 464, 477, 496, 533, 552 | 注释 | `// legado ruleContent.imageDecode…` |
| `shuyuan/web_book/book_chapter_list.dart` | 8 | 130, 230, 237, 238, 277, 286, 287, 299 | 注释 | `// legado ruleToc.formatJs…` |
| `shuyuan/analyze/rule_search.dart` | 4 | 26, 28, 29, 30 | 注释 2 + **参数名 2** | `pick(String legado, …)` |
| `shuyuan/analyze/rule_explore.dart` | 3 | 24, 26, 27 | 注释 1 + **参数名 2** | `pick(String legado, …)`（同模式） |
| `shuyuan/presentation/shuyuan_import_screen.dart` | 2 | 138, 151 | 注释 | `// …（legado bookSourceType == 0）` |
| `shuyuan/web_book/book_list.dart` | 2 | 91, 92 | 注释 | `// legado 行为：ruleSearch 复用…` |
| `shuyuan/analyze/analyze_url.dart` | 1 | 363 | 注释 | `// 对齐 legado AnalyzeUrl.evalJS` |
| `shuyuan/model/book_source.dart` | 1 | 249 | 注释 | `// 部分 Legado 书源将规则存为 JSON 字符串` |
| `features/novel/presentation/novel_reader_screen.dart` | 1 | 7161 | 注释 | `// …（legado 常见 max-width:100%）` |

**约束边界**：致谢 `about_screen.dart:315-317` 与 l10n `acknowledgementsLegado` 为既定白名单；**未来新代码若非 Legado 兼容必需，不得引入该标识**；扫描与验收见 §3.2（命中仅允许出现在本豁免清单与白名单内）。

---

## 3. 附录

### 3.1 原始文档索引

| 文档 | 路径 | 关键章节 |
|---|---|---|
| 完成度审计 | `docs/TODO_COMPLETION_AUDIT.md` | §1 [x] 抽样、§2 未回填已完成、§3 红线、§4 边角、§5 建议 |
| 小说 TODO（对标 v3.2） | `ku/_refs_novel/TODO_novel_reader.md` | §0 约束、§1 基线、§2 矩阵、§3 四仓深读（18 子系统）、§4 bug 检测、§5 87 项矩阵 + 分级清单、§6 后续动作 |
| 播放器 TODO（v2） | `ku/_refs_player/TODO_player.md` | §1 现状、§2 B-1~B-21、§3 F-1~F-31、§4 Phase 1-5 + commit 表、§5 验证 |
| 漫画 TODO（三轮） | `ku/_refs_reader/TODO_comic_reader.md` | P0-P3 全篇、暂缓/不学、进度记录 |

### 3.2 扫描 / 验证命令（每次改动后复跑）

```powershell
# 四仓标识符（小说侧）+ 五漫画仓标识符（本机无 grep，用 PowerShell 等效）
Get-ChildItem lib -Recurse -Filter *.dart | Select-String -Pattern 'legado|gedoor|IReader|TRNovel|any-reader|anyreader|KongComic|Mihon|Breeze|Venera' -CaseSensitive:$false
# 静态分析（勿加 timeout 前缀）
cd E:/nexhub && E:/flutter/bin/dart.bat analyze lib
```

验收：除致谢白名单（`about_screen` 条目 + l10n `acknowledgementsLegado` + 「作品目录式布局」描述）与 **§2 豁免清单**（Legado 兼容代码 30 处）外 **0 命中**。

### 3.3 实施约定（承自三份原始文档）

- 提交：仅 stage 修改源文件；commit 信息中性化（不出现任何禁用仓库名/软件名；**Legado 兼容实现相关提交按 §2 豁免**，可引用 `legado` 语义）；每阶段独立评估、逐项评审，非批量推进。
- 实机验证：按源逐项（成功/失败分报告）；播放器手势/弹幕/PiP/后台播放与漫画手势需真机确认；无法验证处注明。
- 状态变更：在本文件改 `⬜→✅` 时，同步回 `ku/` 原始文档补 `[x]` 与 commit（已完成清单以 `docs/TODO_COMPLETION_AUDIT.md` §2 为基准模板）。

---

*本主 TODO 由四份来源合并生成，仅含未完成项（2026-08-18）。已完成项见 `docs/TODO_COMPLETION_AUDIT.md` 与 `ku/_refs_*` 原始文档。*
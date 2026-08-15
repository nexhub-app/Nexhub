# NexHub UI 基准（UI Baseline）

> 用途：NexHub 全部界面的**统一设计基准**。新页面 / 新组件 / 新交互必须遵循本文，
> 与已有 UI 视觉与手感**无缝融合**；同时补齐「灵动性」与「窄屏适配」两块长期短板。
>
> 权威实现层：`lib/core/theme/app_tokens.dart`（Token 唯一来源）、
> `lib/core/theme/app_theme.dart`（ThemeData 工厂）、`lib/core/theme/theme_controller.dart`（运行时主题）。
> 本文件是**设计意图**层，不重复罗列每个常量；常量以代码为准。

---

## 0. 一句话原则

**已有的一切都不要推翻**。NexHub 已有成熟的 Material 3 + 莫奈动态色体系、统一的
`AppTokens` 间距/圆角/时长、NavigationRail↔BottomNav 响应式框架。**本基准只做三件事**：
把它们写清楚、补上「灵动」的微交互、补上「窄屏」的明确规则。

---

## 1. 与现有 UI 融合（不可偏离的底座）

### 1.1 技术底座（已定，沿用）
- **Material 3**（`useMaterial3: true`），**禁止**回退 M2 风格控件。
- **颜色只用 `Theme.of(context).colorScheme`**：由 seed 生成、深浅色自动适配。
  - 默认主色 `青春蓝 #0EA5E9`；设置页可切中国传统色预设（玄色 / 桃夭 / 茶红 / 群青 / 天水碧 等）。
  - **严禁**在 feature 代码硬编码 `Color(0xFF…)` / `EdgeInsets.all(8)` 等魔法数字。
- **莫奈动态色（Monet）**优先：系统提供动态 `ColorScheme` 时自动跟随系统取色。

### 1.2 Token 速查（详见 `app_tokens.dart`）
| 分类 | 取值 | 含义 |
|---|---|---|
| 间距 | none0 / xxs2 / xs4 / sm8 / md12 / lg16 / xl24 / 2xl32 / 3xl48 | 所有留白、内边距、组件间距 |
| 圆角 | none0 / xs4 / sm8 / md12 / lg16 / xl24 / full999 | 按钮 sm、卡片 md、弹窗 lg、芯片/分段 full、进度条 xs |
| 时长 | fast150 / base250 / spring420 / pageTurn450(ms) | 微交互、转场、弹簧入场 |
| 组件尺寸 | 图标按钮 40 / TabBar 56 / 底栏 68 / Rail 项 72 宽 80 | 导航与可点区域 |
| 响应式断点 | 桌面 840 / 紧凑 600 | 见 §4 |

### 1.3 组件规范（沿用既有 Theme 设定）
- **卡片**：`elevation:0` + `clipBehavior:antiAlias` + 圆角 `md(12)`；深色用
  `surfaceContainerHighest`、浅色用 `surfaceContainerLow` 作底色。
- **按钮**：Filled / Outlined / Text 一律圆角 `sm(8)`；Filled 横向 padding `lg×md`。
- **芯片 / 分段按钮**：圆角 `full`（胶囊形）。
- **对话框**：圆角 `lg(16)`、`elevation:0`。
- **SnackBar**：`floating` 行为 + 圆角 `md`。
- **AppBar**：`elevation:0`、`centerTitle:false`、`scrolledUnderElevation: sm`。

### 1.4 导航框架（沿用既有响应式模式）
- **宽屏（≥840）**：`Row` + `NavigationRail`（宽 80、项高 72）+ `IndexedStack` 主内容。
- **窄屏（<840）**：`Scaffold` + `BottomNavigationBar`（高 68、fixed 类型、主色选中）。
- 切换判定统一用 `MediaQuery.sizeOf(context).width >= AppTokens.desktopBreakpoint`，
  **不要**各页面各自写死阈值。

---

## 2. 灵动性（Liveliness）—— 这是本次新增重点

> 历史决策（2026-07-25）：**页面间转场 = 零动画瞬切**（用户明确「干脆不要转场」，
> 滑入/淡入均被否）。本基准**不推翻该决策**，把「灵动」落到**页内微交互**上，
> 既满足「灵动」诉求，又不破坏「干脆」的整体节奏。

### 2.1 微交互基线
| 场景 | 推荐做法 | 时长 |
|---|---|---|
| 点击反馈 | `InkWell`/`Material` 默认水波 + 轻微 `scale(0.97→1)` 回弹 | fast150 |
| 列表项进入 | `AnimatedOpacity`+`SlideTransition`（轻微上移 8px）错峰入场 | spring420 |
| 开关 / 选中态 | `AnimatedContainer` 平滑过渡颜色与形状 | base250 |
| 展开 / 折叠 | `AnimatedCrossFade` 或 `AnimatedSize` | base250 |
| 悬浮操作（FAB 等） | `AnimatedScale`/`AnimatedRotation` 显隐 | base250 |
| 数值 / 进度变化 | `AnimatedSwitcher` 过渡 | base250 |

### 2.2 弹簧与过冲（关键「灵动」来源）
- 入场、卡片浮起、弹窗出现使用**弹簧曲线**（`Curves.elasticOut` 轻量版或
  `Curves.easeOutBack`），时长取 `spring(420ms)`，给过冲留出自然回落。
- 弹窗/底页（BottomSheet）推荐：`showModalBottomSheet` + 顶部圆角 `lg` +
  入场轻微上滑弹簧；**不要**生硬 pop。

### 2.3 手势与物理感
- 可滚动长列表（如条漫、书架）保持**惯性滚动 + 边缘发光（overscroll glow）**，
  不要 `NeverScrollableScrollPhysics` 一刀切（除非明确禁用，如放大态图片平移）。
- 拖拽类交互（阅读器图片平移）跟随手指、松手有轻微惯性衰减。

### 2.4 触感反馈（Haptics）
- 关键操作（翻页、收藏、长按菜单弹出、缩放切换）补 `HapticFeedback.lightImpact()`，
  让「灵动」可感知。桌面端忽略即可（无副作用）。

### 2.5 数据加载的「呼吸感」
- 骨架屏（Shimmer）替代转圈；空态 / 错误态用**插画 + 主色按钮**引导，不用纯文字。

---

## 3. 视觉一致性检查清单（每次 PR 自审）
- [ ] 颜色全部取自 `colorScheme`，无硬编码色值。
- [ ] 间距 / 圆角 / 时长取自 `AppTokens`，无魔法数字。
- [ ] 组件形状（圆角、胶囊）与 §1.3 一致。
- [ ] 宽屏用 Rail、窄屏用 BottomNav，阈值统一用 `AppTokens` 断点。
- [ ] 无页面转场动画（沿用瞬切），灵动只体现在页内微交互。

---

## 4. 窄屏适配（Narrow Screen）—— 本次新增重点

**定义**：宽度 `< AppTokens.compactBreakpoint`（600px）视为窄屏；手机竖屏、桌面窄窗口均在此列。

### 4.1 布局铁律
1. **永不固定死宽度**：所有主内容用 `Expanded` / `Flexible` / 滚动容器，禁用
   `SizedBox(width: 360)` 这类硬宽。
2. **详情页头部**：窄屏下标题/操作由「横排」改「竖叠」——主图 + 标题 + 描述 +
   操作按钮（chips / 全宽 FilledButton）依次下移，**禁止**操作按钮被挤到屏幕外。
3. **网格列数随宽自适应**：
   - `<600`：2 列；`600–840`：3 列；`≥840`：4 列起（书架/漫画格用 `SliverGrid`
     + `SliverGridDelegateWithMaxCrossAxisExtent`，最大交叉轴宽≈160）。
4. **底部弹层高度**：阅读器设置弹窗等 ≤ `readerSettingsMaxHeightFactor(0.85)` 屏高，
   窄屏可进一步降到 0.9 并允许内部滚动。

### 4.2 触控目标
- 所有可点区域 **≥ 40×40**（图标按钮已是 40；文字按钮注意内边距）。
- 列表项、卡片点击区不要因窄屏压缩到不可点。

### 4.3 安全区与系统栏
- 内容避开 `SafeArea`（刘海 / 底部手势条）；`BottomNavigationBar` 已含安全区内边距。
- 横屏 / 折叠屏：监听 `MediaQuery` 尺寸变化，Rail/BottomNav 切换、网格列数实时响应。

### 4.4 窄屏专属交互
- 窄屏优先**底部 BottomSheet** 而非居中对话框（手够得到）。
- 长文本操作（如源编辑）窄屏用全屏 `PageRoute` 而非弹窗。
- 图片缩放/平移：触摸单指拖动用 `GestureDetector` 跟手，双指捏合用
  `ScaleGestureRecognizer`，双击三态（缩→放→复原）与现有阅读器一致。

### 4.5 字体与密度
- 窄屏不缩字号到难读；用 `visualDensity.adaptivePlatformDensity`（已设）自动降密度。
- 中文正文行高 ≥ 1.5，避免拥挤。

---

## 5. 反例（明令禁止）
- ❌ 页面切换加 slide/fade 转场（沿用瞬切决策）。
- ❌ 硬编码颜色 / 间距 / 圆角。
  - 合理例外：**组件固有尺寸**不是间距，不套 token。例如 `SizedBox` 带 child 时的
    封面宽高、图标框、进度圈直径；以及布局选择器里的缩略示意图
    （`layout_picker_dialog.dart` 用 1~3px 方块模拟卡片，硬套 token 会画烂）。
- ❌ 窄屏写死宽度导致横向溢出或按钮出屏。
- ❌ 为「灵动」滥用全屏弹簧（仅页内微交互用）。
- ❌ 引入与 M3 风格冲突的第三方 UI 库默认皮肤（需先改 Theme 对齐）。

---

## 6. 落地建议
1. 把 §2 的微交互封装为 `AppMotion`（如 `AppMotion.tapScale`、`AppMotion.springIn`）
   放到 `lib/core/widgets/`，避免各页面各写一遍。
2. 窄屏布局抽 `ResponsiveScaffold`（Rail/BottomNav 自动切换）复用，替代散落各处的
   `MediaQuery` 判断。
3. 新增页面前先对照 §3 清单自审，CI 可加 `flutter analyze` + 关键 Token 使用 lint。

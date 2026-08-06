/// 阅读/观看统计 —— 两个 Hive box 名称常量（单一事实源）。
///
/// 设计：
/// - 按作品粒度聚合（`reading_stats_v1`）：总时长 / 会话次数 / 最后阅读时间。
///   key 格式：`<type>|<sourceId?|<workId>`，避免不同源同名作品互相覆盖。
/// - 按天粒度聚合（`reading_daily_v1`）：热力图直接消费"天×小时"总时长。
///   key 格式：`YYYY-MM-DD`。
/// - 进行中的会话（in-progress）走 SharedPreferences `reading_session_state_v1`，
///   不入 Hive（短生命 + 高频写，不适合 box）。
///
/// splash 启动时只需新增一行 `kStorageBoxNames` 即可挂上；备份白名单已
/// 自动覆盖（云同步在 `_exportToArchive` 里枚举所有 box）。
library;

/// 按作品聚合的统计 box。
const String kReadingStatsBoxName = 'reading_stats_v1';

/// 按天聚合的统计 box（热力图数据源）。
const String kReadingDailyBoxName = 'reading_daily_v1';

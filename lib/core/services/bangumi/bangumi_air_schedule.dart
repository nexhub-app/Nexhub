/// Bangumi 放送时间（周 / 时 / 分）解析与本地覆盖存储。
///
/// 同步弹窗底部的「周 / 时 / 分」信息条此前把时 / 分写死成 `—`，且星期只用
/// [DateTime.tryParse] 解析 `air_date`——Bangumi 的放送信息大量以
/// `星期日 23:00` / `2026年7月1日 23:00` 之类的自由文本出现在 infobox 里，
/// ISO 解析必然失败，于是三格永远是 `—`。
///
/// 本文件提供两件事：
/// 1. [BangumiAirSchedule.parse]：尽最大努力从条目详情里推断周 / 时 / 分；
/// 2. [BangumiAirScheduleStore]：用户手动设置的覆盖值（按 subjectId 持久化到
///    shared_preferences），优先级高于自动解析。
library;

import 'package:shared_preferences/shared_preferences.dart';

import 'bangumi_models.dart';

/// 放送时间（周 / 时 / 分），字段可为空表示「未知」。
class BangumiAirSchedule {
  /// ISO 星期（1 = 周一 … 7 = 周日），null 表示未知。
  final int? weekday;

  /// 小时（0–23），null 表示未知。
  final int? hour;

  /// 分钟（0–59），null 表示未知。
  final int? minute;

  const BangumiAirSchedule({this.weekday, this.hour, this.minute});

  /// 空值（全部未知）。
  static const BangumiAirSchedule empty = BangumiAirSchedule();

  bool get isEmpty => weekday == null && hour == null && minute == null;

  BangumiAirSchedule copyWith({
    int? weekday,
    int? hour,
    int? minute,
    bool clearWeekday = false,
    bool clearTime = false,
  }) {
    return BangumiAirSchedule(
      weekday: clearWeekday ? null : (weekday ?? this.weekday),
      hour: clearTime ? null : (hour ?? this.hour),
      minute: clearTime ? null : (minute ?? this.minute),
    );
  }

  /// 序列化为 `w,h,m`（未知位写空），便于存 shared_preferences。
  String encode() =>
      '${weekday ?? ''},${hour ?? ''},${minute ?? ''}';

  /// 反序列化 [encode] 的结果；格式非法返回 null。
  static BangumiAirSchedule? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final parts = raw.split(',');
    if (parts.length != 3) return null;
    int? p(String s) => s.isEmpty ? null : int.tryParse(s);
    final s = BangumiAirSchedule(
      weekday: p(parts[0]),
      hour: p(parts[1]),
      minute: p(parts[2]),
    );
    return s.isEmpty ? null : s;
  }

  /// 中文星期名（一…日），未知返回 null。
  static const List<String> weekdayNamesZh = <String>[
    '一', '二', '三', '四', '五', '六', '日',
  ];

  /// 从条目详情尽力推断放送时间。
  ///
  /// 优先级：
  /// 1. infobox「放送星期」/「播放结束」等含星期的字段 → 星期；
  /// 2. infobox 中任何含 `HH:MM` 的值（优先「放送开始」）→ 时 / 分；
  /// 3. `air_date` 能被 ISO 解析时 → 星期（兜底）。
  static BangumiAirSchedule parse(BangumiSubjectDetail? detail) {
    if (detail == null) return empty;
    final info = detail.infobox;

    // ── 星期 ──────────────────────────────────────────────
    int? weekday;
    const weekdayKeys = <String>['放送星期', '播放星期', '放送日', '连载周期'];
    for (final k in weekdayKeys) {
      final v = info[k];
      if (v == null) continue;
      weekday = parseWeekday(v);
      if (weekday != null) break;
    }
    // 「放送开始」等自由文本里也可能带星期。
    if (weekday == null) {
      for (final v in info.values) {
        weekday = parseWeekday(v);
        if (weekday != null) break;
      }
    }
    // 兜底：air_date 可 ISO 解析时按日期推算星期。
    if (weekday == null) {
      final air = detail.airDate;
      if (air != null && air.isNotEmpty) {
        final dt = DateTime.tryParse(air) ?? _parseCnDate(air);
        if (dt != null) weekday = dt.weekday;
      }
    }

    // ── 时 / 分 ───────────────────────────────────────────
    int? hour;
    int? minute;
    const timeKeys = <String>['放送开始', '放送时间', '开始', '播放开始'];
    for (final k in timeKeys) {
      final t = parseTime(info[k]);
      if (t != null) {
        hour = t.$1;
        minute = t.$2;
        break;
      }
    }
    if (hour == null) {
      final t = parseTime(detail.airDate);
      if (t != null) {
        hour = t.$1;
        minute = t.$2;
      }
    }
    if (hour == null) {
      for (final v in info.values) {
        final t = parseTime(v);
        if (t != null) {
          hour = t.$1;
          minute = t.$2;
          break;
        }
      }
    }

    return BangumiAirSchedule(weekday: weekday, hour: hour, minute: minute);
  }

  /// 从自由文本里解析星期（中 / 英 / 数字），失败返回 null。
  static int? parseWeekday(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final s = raw.trim();
    // 中文：星期一 / 周一 / 礼拜一 / 周日 / 周天
    final cn = RegExp(r'(?:星期|周|週|礼拜|禮拜)\s*([一二三四五六日天七1-7])')
        .firstMatch(s);
    if (cn != null) {
      const map = <String, int>{
        '一': 1, '二': 2, '三': 3, '四': 4, '五': 5, '六': 6,
        '日': 7, '天': 7, '七': 7,
        '1': 1, '2': 2, '3': 3, '4': 4, '5': 5, '6': 6, '7': 7,
      };
      final v = map[cn.group(1)];
      if (v != null) return v;
    }
    // 英文：Mon / Monday …
    final lower = s.toLowerCase();
    const en = <String, int>{
      'monday': 1, 'tuesday': 2, 'wednesday': 3, 'thursday': 4,
      'friday': 5, 'saturday': 6, 'sunday': 7,
    };
    for (final e in en.entries) {
      if (lower.contains(e.key) || lower.contains(e.key.substring(0, 3))) {
        return e.value;
      }
    }
    return null;
  }

  /// 从自由文本里解析 `HH:MM`（支持全角冒号），失败返回 null。
  static (int, int)? parseTime(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final m = RegExp(r'(\d{1,2})\s*[:：]\s*(\d{1,2})').firstMatch(raw);
    if (m == null) return null;
    final h = int.tryParse(m.group(1)!);
    final min = int.tryParse(m.group(2)!);
    if (h == null || min == null) return null;
    if (h < 0 || h > 23 || min < 0 || min > 59) return null;
    return (h, min);
  }

  /// 解析 `2026年7月1日` 形式的中文日期，失败返回 null。
  static DateTime? _parseCnDate(String raw) {
    final m = RegExp(r'(\d{4})\s*[年\-/]\s*(\d{1,2})\s*[月\-/]\s*(\d{1,2})')
        .firstMatch(raw);
    if (m == null) return null;
    final y = int.tryParse(m.group(1)!);
    final mo = int.tryParse(m.group(2)!);
    final d = int.tryParse(m.group(3)!);
    if (y == null || mo == null || d == null) return null;
    if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
    return DateTime(y, mo, d);
  }
}

/// 用户手动设置的放送时间覆盖值（按 subjectId 持久化）。
///
/// 存 shared_preferences，key = `bangumi_air_schedule_<subjectId>`。
/// 没有覆盖值时返回 null，调用方回退到 [BangumiAirSchedule.parse]。
class BangumiAirScheduleStore {
  const BangumiAirScheduleStore();

  static const String keyPrefix = 'bangumi_air_schedule_';

  Future<BangumiAirSchedule?> load(int subjectId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return BangumiAirSchedule.decode(prefs.getString('$keyPrefix$subjectId'));
    } on Object {
      return null;
    }
  }

  Future<void> save(int subjectId, BangumiAirSchedule schedule) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (schedule.isEmpty) {
        await prefs.remove('$keyPrefix$subjectId');
      } else {
        await prefs.setString('$keyPrefix$subjectId', schedule.encode());
      }
    } on Object {
      // 写入失败静默忽略（仅影响本地展示）。
    }
  }

  Future<void> clear(int subjectId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('$keyPrefix$subjectId');
    } on Object {
      // 忽略。
    }
  }
}

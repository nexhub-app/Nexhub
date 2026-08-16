import 'package:canvas_danmaku/canvas_danmaku.dart' as cd;
import 'package:flutter/material.dart';

/// 单条弹幕（数据模型，与 canvas_danmaku 解耦）。
class DanmakuItem {
  DanmakuItem({
    required this.text,
    required this.time,
    Color? color,
    this.fontSize = 16,
    this.type = cd.DanmakuItemType.scroll,
    this.selfSend = false,
  }) : color = color ?? Colors.white;

  final String text;

  /// 在视频时间轴上的出现时刻。
  final Duration time;
  final Color color;
  final double fontSize;

  /// 弹幕类型（滚动 / 顶部固定 / 底部固定）。
  final cd.DanmakuItemType type;

  /// 是否本人发送（渲染时高亮描边）。
  final bool selfSend;
}

/// 弹幕控制器（基于 canvas_danmaku）。
///
/// 持有全部弹幕与「秒 → 弹幕索引」索引表，按视频播放位置增量注入「此刻应
/// 出现」的弹幕。通过 [attach] 绑定 [cd.DanmakuController] 后，调用 [tick]
/// 即可自动注入。
///
/// 秒索引 + 游标设计（修复 seek 后弹幕 flood 与 tick O(n) 全量扫描）：
/// - [tick] 只遍历当前秒与游标之间的索引桶（每秒一次查表），不再扫描全部弹幕；
/// - seek 后调用 [resetTo]，把游标拨回目标位置前 [lookbackSeconds] 秒，只补
///   重放该窗口内的弹幕，避免「把整条时间轴上的弹幕一次性灌进屏幕」。
class DanmakuController {
  DanmakuController([List<DanmakuItem>? items]) {
    if (items != null) setItems(items);
  }

  /// 同文本合并窗口（秒）：窗口内相同文本只保留最早一条（F-20）。
  /// 热门句被观众刷屏时同屏会出现数条一模一样的弹幕，合并后屏显更清爽。
  static const int _mergeWindowSeconds = 5;

  cd.DanmakuController? _controller;
  final List<DanmakuItem> _items = [];

  /// 秒 → 该秒内弹幕的索引列表（tick 时按秒查表，O(秒跨度) 而非 O(全部弹幕)）。
  final Map<int, List<int>> _bySecond = <int, List<int>>{};

  /// 已注入到的最大秒（游标）。小于等于该值的秒不再注入。
  int _cursorSecond = -1;

  /// 绑定 canvas_danmaku 控制器。
  void attach(cd.DanmakuController controller) => _controller = controller;

  /// 同文本合并（F-20）：按时间排序后，相同文本距上一次「保留」不足
  /// [_mergeWindowSeconds] 秒的丢弃；本人发送的弹幕不参与合并。
  static List<DanmakuItem> mergeDuplicates(List<DanmakuItem> items) {
    if (items.length < 2) return items;
    final sorted = List<DanmakuItem>.from(items)
      ..sort((a, b) => a.time.compareTo(b.time));
    final lastKept = <String, Duration>{};
    final out = <DanmakuItem>[];
    for (final it in sorted) {
      if (!it.selfSend) {
        final last = lastKept[it.text];
        if (last != null &&
            it.time - last < const Duration(seconds: _mergeWindowSeconds)) {
          continue;
        }
        lastKept[it.text] = it.time;
      }
      out.add(it);
    }
    return out;
  }

  /// 替换全部弹幕数据（清空旧的、去重合并、重建秒索引并重置游标）。
  void setItems(List<DanmakuItem> items) {
    _items
      ..clear()
      ..addAll(mergeDuplicates(items));
    _bySecond.clear();
    for (var i = 0; i < _items.length; i++) {
      final sec = _items[i].time.inSeconds;
      _bySecond.putIfAbsent(sec, () => <int>[]).add(i);
    }
    _cursorSecond = -1;
  }

  /// 更新弹幕选项（同步到 canvas_danmaku 控制器）。
  void setOption(cd.DanmakuOption option) {
    _controller?.updateOption(option);
  }

  /// 按视频位置增量注入弹幕到 canvas_danmaku 控制器。
  ///
  /// 游标后的每一秒，取该秒索引桶里的弹幕注入；已注入过的秒跳过。
  void tick(Duration position) {
    final sec = position.inSeconds;
    if (sec <= _cursorSecond) return;
    for (var s = _cursorSecond + 1; s <= sec; s++) {
      final indices = _bySecond[s];
      if (indices == null) continue;
      for (final i in indices) {
        _controller?.addDanmaku(
          cd.DanmakuContentItem(
            _items[i].text,
            color: _items[i].color,
            type: _items[i].type,
          ),
        );
      }
    }
    _cursorSecond = sec;
  }

  /// seek 后调用：清屏并把游标拨回 [position] 前 [lookbackSeconds] 秒，
  /// 使后续 [tick] 只重放目标位置附近窗口内的弹幕（修复 seek flood）。
  void resetTo(Duration position, {int lookbackSeconds = 3}) {
    _controller?.clear();
    _cursorSecond = position.inSeconds - lookbackSeconds;
  }

  /// 清空屏幕上的弹幕。
  void clear() => _controller?.clear();

  /// 重置游标（从头开始注入）。切集 / 重新加载弹幕后调用。
  void reset() => _cursorSecond = -1;

  /// 返回播放位置 [position] 之前尚未展示的弹幕（向后兼容，切片实现）。
  List<DanmakuItem> pending(Duration position) {
    final out = <DanmakuItem>[];
    final start = _cursorSecond + 1;
    final end = position.inSeconds;
    if (end <= start) return out;
    for (var s = start; s <= end; s++) {
      for (final i in _bySecond[s] ?? const <int>[]) {
        out.add(_items[i]);
      }
    }
    _cursorSecond = end;
    return out;
  }

  /// 构造均匀分布的示例弹幕。
  static List<DanmakuItem> demo(int count,
      {Duration step = const Duration(seconds: 2)}) {
    const samples = <String>[
      'Exciting!',
      'Famous scene!',
      'Tears!',
      'Awesome frame!',
      'BGM plays!',
      'Spoiler alert!',
    ];
    return [
      for (var i = 0; i < count; i++)
        DanmakuItem(
          text: samples[i % samples.length],
          time: step * i,
        ),
    ];
  }
}

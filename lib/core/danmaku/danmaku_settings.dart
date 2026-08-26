/// 弹幕设置模型。
class DanmakuSettings {
  const DanmakuSettings({
    this.filterKeywords = const <String>[],
    this.timeOffset = 0,
    this.area = 0.5,
    this.duration = 8,
    this.lineHeight = 1.2,
    this.hideTop = false,
    this.hideBottom = false,
    this.hideScroll = false,
    this.followPlaybackSpeed = false,
    this.fontSize = 16.0,
    this.opacity = 1.0,
  });

  /// 关键词过滤（支持正则）。
  final List<String> filterKeywords;

  /// 时间偏移（秒）。
  final double timeOffset;

  /// 显示区域 0.1-1.0。
  final double area;

  /// 持续时间（秒）。
  final double duration;

  /// 行高。
  final double lineHeight;

  /// 隐藏顶部。
  final bool hideTop;

  /// 隐藏底部。
  final bool hideBottom;

  /// 隐藏滚动。
  final bool hideScroll;

  /// 跟随倍速。
  final bool followPlaybackSpeed;

  /// 字体大小（12-28）。
  final double fontSize;

  /// 不透明度（0.1-1.0）。
  final double opacity;

  DanmakuSettings copyWith({
    List<String>? filterKeywords,
    double? timeOffset,
    double? area,
    double? duration,
    double? lineHeight,
    bool? hideTop,
    bool? hideBottom,
    bool? hideScroll,
    bool? followPlaybackSpeed,
    double? fontSize,
    double? opacity,
  }) =>
      DanmakuSettings(
        filterKeywords: filterKeywords ?? this.filterKeywords,
        timeOffset: timeOffset ?? this.timeOffset,
        area: area ?? this.area,
        duration: duration ?? this.duration,
        lineHeight: lineHeight ?? this.lineHeight,
        hideTop: hideTop ?? this.hideTop,
        hideBottom: hideBottom ?? this.hideBottom,
        hideScroll: hideScroll ?? this.hideScroll,
        followPlaybackSpeed: followPlaybackSpeed ?? this.followPlaybackSpeed,
        fontSize: fontSize ?? this.fontSize,
        opacity: opacity ?? this.opacity,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'filterKeywords': filterKeywords,
        'timeOffset': timeOffset,
        'area': area,
        'duration': duration,
        'lineHeight': lineHeight,
        'hideTop': hideTop,
        'hideBottom': hideBottom,
        'hideScroll': hideScroll,
        'followPlaybackSpeed': followPlaybackSpeed,
        'fontSize': fontSize,
        'opacity': opacity,
      };

  static DanmakuSettings fromJson(Map<String, dynamic> json) {
    return DanmakuSettings(
      filterKeywords: json['filterKeywords'] is List
          ? (json['filterKeywords'] as List)
              .whereType<String>()
              .toList(growable: false)
          : const <String>[],
      timeOffset: (json['timeOffset'] as num?)?.toDouble() ?? 0,
      area: (json['area'] as num?)?.toDouble() ?? 0.5,
      duration: (json['duration'] as num?)?.toDouble() ?? 8,
      lineHeight: (json['lineHeight'] as num?)?.toDouble() ?? 1.2,
      hideTop: json['hideTop'] as bool? ?? false,
      hideBottom: json['hideBottom'] as bool? ?? false,
      hideScroll: json['hideScroll'] as bool? ?? false,
      followPlaybackSpeed: json['followPlaybackSpeed'] as bool? ?? false,
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? 16.0,
      opacity: (json['opacity'] as num?)?.toDouble() ?? 1.0,
    );
  }

  /// 实际持续时间（跟随倍速时 duration / playbackSpeed）。
  double effectiveDuration(double playbackSpeed) {
    if (followPlaybackSpeed && playbackSpeed > 0) {
      return duration / playbackSpeed;
    }
    return duration;
  }

  /// 过滤弹幕（关键词 + 正则）。
  ///
  /// 返回 true 表示该弹幕应被过滤掉。
  bool shouldFilter(String text) {
    for (final keyword in filterKeywords) {
      if (keyword.isEmpty) continue;
      try {
        final regex = RegExp(keyword);
        if (regex.hasMatch(text)) return true;
      } on Object {
        if (text.contains(keyword)) return true;
      }
    }
    return false;
  }
}

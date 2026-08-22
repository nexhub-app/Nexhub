/// 应用内运行日志缓冲（设置 → 高级 → 运行日志 查看）。
///
/// 与「崩溃日志」（持久化落盘）互补：这里保存**本次运行期**的滚动日志。
///
/// 分级：
/// - `d()` 调试级：仅「详细日志」开关开启时记录（网络请求/响应明细等）；
/// - `i()` 信息级：总是记录（下载任务开始/完成、导入扫描等关键节点）；
/// - `w()` 警告级：总是记录（可恢复的异常：单页失败跳过、非致命解析错误）；
/// - `e()` 错误级：总是记录（下载失败、解析失败、未捕获异常、Flutter 错误）。
///
/// 环形缓冲，超上限自动丢弃最旧条目。所有级别同时输出到 console（debugPrint），
/// 便于连接调试器时在终端一并查看。
library;

import 'package:flutter/foundation.dart';

import '../settings/advanced_settings.dart';

/// 运行日志缓冲（单例）。
class AppLog {
  AppLog._();

  static final AppLog instance = AppLog._();

  /// 环形缓冲上限（条）。
  static const int _maxEntries = 3000;

  final List<String> _entries = <String>[];
  final List<String> _timestamps = <String>[];

  /// 作用域日志捕获缓冲：非 null 时，[ _add ] 会同步写入此缓冲，
  /// 用于书源诊断面板「单步规则调试」——在某一诊断步骤前后 start/stop，
  /// 即可拿到该步骤产生的全部规则解析日志，而不污染全局运行日志环形缓冲。
  static StringBuffer? _scopeCapture;

  /// 只读快照（最新在前）。
  List<String> get entries {
    final List<String> out = <String>[];
    for (int i = _entries.length - 1; i >= 0; i--) {
      out.add('${_timestamps[i]}  ${_entries[i]}');
    }
    return out;
  }

  bool get isEmpty => _entries.isEmpty;

  /// 详细日志开关：控制「调试级」记录（网络请求/响应等）。
  bool get detailedEnabled => AdvancedSettingsStore.instance.detailedLogging;

  /// 当前日志级别标签（错误/警告/信息/调试）。
  static const String _lblE = 'E';
  static const String _lblW = 'W';
  static const String _lblI = 'I';
  static const String _lblD = 'D';

  void _add(String level, String msg) {
    final DateTime now = DateTime.now();
    final String ts = '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}';
    _timestamps.add(ts);
    _entries.add('[$level] $msg');
    if (_scopeCapture != null) {
      _scopeCapture!.write('[$level] $msg\n');
    }
    if (_entries.length > _maxEntries) {
      _entries.removeAt(0);
      _timestamps.removeAt(0);
    }
  }

  /// 开始作用域日志捕获（用于书源诊断单步规则调试）。
  void startScopeCapture() {
    _scopeCapture = StringBuffer();
  }

  /// 结束作用域捕获并返回捕获到的日志文本（无内容返回 null）。
  String? stopScopeCapture() {
    final buf = _scopeCapture;
    _scopeCapture = null;
    if (buf == null) return null;
    final text = buf.toString().trim();
    return text.isEmpty ? null : text;
  }

  /// 调试级（受「详细日志」开关控制）：网络请求/响应明细等。
  void d(String msg) {
    if (!detailedEnabled) return;
    _add(_lblD, msg);
    debugPrint(msg);
  }

  /// 信息级（总是记录）：下载任务开始/完成、导入扫描等关键节点。
  void i(String msg) {
    _add(_lblI, msg);
    debugPrint(msg);
  }

  /// 警告级（总是记录）：可恢复的异常（单页失败跳过、非致命解析错误）。
  void w(String msg) {
    _add(_lblW, msg);
    debugPrint(msg);
  }

  /// 错误级（总是记录）：下载失败、解析失败、未捕获异常、Flutter 错误等。
  void e(String msg) {
    _add(_lblE, msg);
    debugPrint(msg);
  }

  /// 错误级，带堆栈（总是记录）。
  void eWithStack(String msg, Object error, [StackTrace? stack]) {
    final StringBuffer buf = StringBuffer('$msg: $error');
    if (stack != null) buf.write('\n$stack');
    _add(_lblE, buf.toString());
    debugPrint(buf.toString());
  }

  void clear() {
    _entries.clear();
    _timestamps.clear();
  }
}

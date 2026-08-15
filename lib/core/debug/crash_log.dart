/// 崩溃 / 未捕获异常日志落盘工具。
///
/// 在 [main] 的 zone 错误处理器与 [FlutterError.onError] 中调用 [record]，
/// 把运行期异常追加写入应用支持目录下的 `crash_log.txt`，供「高级设置 →
/// 崩溃日志」页查看 / 复制 / 清空。用户无需 adb/logcat 即可把日志发给开发者。
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

class CrashLog {
  CrashLog._();

  /// 日志文件名（应用支持目录下）。
  static const String fileName = 'crash_log.txt';

  /// 日志最大字节数：超过后保留末尾 [trimKeepBytes] 字节（先裁后写）。
  static const int maxBytes = 256 * 1024;
  static const int trimKeepBytes = 192 * 1024;

  static File? _cachedFile;

  /// 取日志文件（懒加载目录；失败返回 null，绝不抛到调用方）。
  static Future<File?> _file() async {
    try {
      if (_cachedFile != null) return _cachedFile;
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}${Platform.pathSeparator}$fileName');
      _cachedFile = file;
      return file;
    } catch (_) {
      return null;
    }
  }

  /// 记录一条崩溃 / 异常日志。
  ///
  /// [kind] 为短类别（如「未捕获异常」「构建错误」），[details] 为正文，
  /// [stack] 为可选堆栈。写入失败静默忽略（日志系统本身不能影响应用运行）。
  static Future<void> record(
    String kind,
    String details, {
    StackTrace? stack,
  }) async {
    try {
      final file = await _file();
      if (file == null) return;
      final now = DateTime.now().toLocal();
      final stamp = '${now.year}-${_pad(now.month)}-${_pad(now.day)} '
          '${_pad(now.hour)}:${_pad(now.minute)}:${_pad(now.second)}';
      final entry = StringBuffer()
        ..writeln('[$stamp] $kind')
        ..writeln(details);
      if (stack != null) {
        entry.writeln(stack.toString());
      }
      entry.writeln('---');
      await _appendTrimmed(file, entry.toString());
    } catch (_) {
      // 静默：日志失败不影响主流程。
    }
  }

  /// 读取完整日志（不存在返回空串）。
  static Future<String> read() async {
    try {
      final file = await _file();
      if (file == null || !await file.exists()) return '';
      return await file.readAsString();
    } catch (_) {
      return '';
    }
  }

  /// 清空日志。返回是否成功。
  static Future<bool> clear() async {
    try {
      final file = await _file();
      if (file == null) return false;
      if (await file.exists()) await file.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 追加并裁剪：若文件将超过 [maxBytes]，先保留末尾 [trimKeepBytes] 再写，
  /// 避免日志无限膨胀（也避免每次整文件重写）。
  static Future<void> _appendTrimmed(File file, String entry) async {
    if (!await file.exists()) {
      await file.writeAsString(entry, flush: true);
      return;
    }
    final existing = await file.readAsString();
    final merged = '$existing$entry';
    if (merged.length <= maxBytes) {
      await file.writeAsString(merged, flush: true);
      return;
    }
    final kept = merged.substring(merged.length - trimKeepBytes);
    await file.writeAsString(kept, flush: true);
  }

  static String _pad(int v) => v.toString().padLeft(2, '0');
}

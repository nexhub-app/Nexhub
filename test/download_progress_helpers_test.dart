import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/download/download_handler.dart';

void main() {
  group('reportOverallProgress', () {
    test('编码结果按 (downloaded + chapterProgress) / total 还原总进度', () {
      final cases = <(double, int)>[
        (0.0, 1),
        (0.35, 1),
        (0.8, 1),
        (1.0, 1),
        (0.1, 4),
        (0.5, 4),
        (1.0, 120),
      ];
      for (final (fraction, total) in cases) {
        final calls = <(int, int, double)>[];
        reportOverallProgress(
          (downloaded, t, chapterProgress) =>
              calls.add((downloaded, t, chapterProgress)),
          fraction,
          total,
        );
        final (downloaded, t, chapterProgress) = calls.single;
        expect(t, total, reason: 'totalChapters 应原样透传');
        final overall = (downloaded + chapterProgress) / t;
        expect(
          overall,
          closeTo(fraction.clamp(0.0, 1.0), 1e-9),
          reason: 'f=$fraction total=$total 还原失败',
        );
        expect(downloaded, inInclusiveRange(0, total));
      }
    });

    test('阶段区间拼接（嗅探 10% + 下载 90%）全程单调递增不回跳', () {
      // 模拟媒体 handler 的分段上报序列：嗅探估计值 → 每集字节进度。
      final overallSeq = <double>[];
      void report(double fraction, int total) => reportOverallProgress(
            (downloaded, _, chapterProgress) =>
                overallSeq.add((downloaded + chapterProgress) / total),
            fraction,
            3,
          );
      report(0.1 * 0.3, 3);
      report(0.1 * 0.9, 3);
      report(0.1, 3);
      report(0.1 + 0.9 * 0.5 / 3, 3);
      report(0.1 + 0.9 * 1.0 / 3, 3);
      report(0.1 + 0.9 * (1 + 0.7) / 3, 3);
      report(1.0, 3);
      for (var i = 1; i < overallSeq.length; i++) {
        expect(overallSeq[i], greaterThanOrEqualTo(overallSeq[i - 1]),
            reason: '进度在第 $i 步回跳');
      }
      expect(overallSeq.last, 1.0);
    });

    test('onProgress 为 null 时安全跳过', () {
      reportOverallProgress(null, 0.5, 3); // 不应抛异常
    });
  });

  group('estimateOpaqueProgress', () {
    test('周期上报渐近值，阶段结束后定时器取消且保留返回值', () async {
      final values = <double>[];
      final completer = Completer<int>();
      final future = estimateOpaqueProgress(
        () => completer.future,
        onValue: values.add,
        tick: const Duration(milliseconds: 50),
        halfTime: const Duration(seconds: 1),
      );
      await Future<void>.delayed(const Duration(milliseconds: 280));
      completer.complete(42);
      expect(await future, 42);

      expect(values.length, greaterThanOrEqualTo(3));
      expect(values.first, greaterThan(0));
      // 渐近曲线：单调递增且不虚假逼近上限。
      for (var i = 1; i < values.length; i++) {
        expect(values[i], greaterThan(values[i - 1]));
      }
      expect(values.last, lessThan(0.95));

      // 阶段结束后定时器必须停止（不再产生新上报）。
      final countAtEnd = values.length;
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(values.length, countAtEnd);
    });

    test('阶段抛出异常时同样取消定时器并透传异常', () async {
      final values = <double>[];
      final future = estimateOpaqueProgress(
        () async => throw StateError('boom'),
        onValue: values.add,
        tick: const Duration(milliseconds: 50),
      );
      await expectLater(future, throwsStateError);
      final countAtEnd = values.length;
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(values.length, countAtEnd);
    });
  });
}

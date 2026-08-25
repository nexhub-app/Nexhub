/// P2-8 小说进度云同步冲突裁决单测：
/// - decideProgressConflict 纯函数全分支（章节维度 / 章内偏移 / 相等防回退）
/// - 进度快照 JSON 编解码
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/novel/novel_progress_conflict.dart';

NovelProgressPoint _point(
  String id, {
  int chapterIndex = 0,
  int? charOffset,
  int page = 0,
}) =>
    NovelProgressPoint(
      novelId: id,
      chapterIndex: chapterIndex,
      charOffset: charOffset,
      page: page,
    );

void main() {
  group('P2-8 裁决：章节维度为主', () {
    test('本地章节靠后 → localWins（应上传本地）', () {
      final local = _point('n1', chapterIndex: 10, charOffset: 100);
      final remote = _point('n1', chapterIndex: 3, charOffset: 50);
      expect(decideProgressConflict(local: local, remote: remote),
          ProgressConflictDecision.localWins);
    });

    test('云端章节靠后 → remoteWins（应确认采用云端）', () {
      final local = _point('n1', chapterIndex: 2, charOffset: 40);
      final remote = _point('n1', chapterIndex: 9, charOffset: 10);
      expect(decideProgressConflict(local: local, remote: remote),
          ProgressConflictDecision.remoteWins);
    });
  });

  group('P2-8 裁决：章内偏移为次维度', () {
    test('同章内本地偏移大 → localWins', () {
      final local = _point('n1', chapterIndex: 5, charOffset: 800);
      final remote = _point('n1', chapterIndex: 5, charOffset: 300);
      expect(decideProgressConflict(local: local, remote: remote),
          ProgressConflictDecision.localWins);
    });

    test('同章内云端偏移大 → remoteWins', () {
      final local = _point('n1', chapterIndex: 5, charOffset: 120);
      final remote = _point('n1', chapterIndex: 5, charOffset: 900);
      expect(decideProgressConflict(local: local, remote: remote),
          ProgressConflictDecision.remoteWins);
    });
  });

  group('P2-8 裁决：charOffset 缺失回退页码', () {
    test('一端有偏移一端只有页码：用偏移比较', () {
      final local = _point('n1', chapterIndex: 7, charOffset: 500);
      final remote = _point('n1', chapterIndex: 7, page: 100);
      expect(decideProgressConflict(local: local, remote: remote),
          ProgressConflictDecision.localWins);
    });

    test('都无偏移时用页码比较', () {
      final local = _point('n1', chapterIndex: 7, page: 12);
      final remote = _point('n1', chapterIndex: 7, page: 4);
      expect(decideProgressConflict(local: local, remote: remote),
          ProgressConflictDecision.localWins);
    });
  });

  group('P2-8 裁决：相等与防回退', () {
    test('完全一致 → equal（不覆盖任一）', () {
      final local = _point('n1', chapterIndex: 5, charOffset: 400, page: 9);
      final remote = _point('n1', chapterIndex: 5, charOffset: 400, page: 9);
      expect(decideProgressConflict(local: local, remote: remote),
          ProgressConflictDecision.equal);
    });

    test('章节与章内均相同但页码不同 → 仍 equal（偏移优先）', () {
      final local = _point('n1', chapterIndex: 5, charOffset: 400, page: 9);
      final remote = _point('n1', chapterIndex: 5, charOffset: 400, page: 10);
      expect(decideProgressConflict(local: local, remote: remote),
          ProgressConflictDecision.equal);
    });

    test('防多端回退：落后端本地进度不覆盖领先云端（remoteWins）', () {
      // 场景：设备 A 已读到 20 章，设备 B 还在 5 章。B 上传自身进度时
      // 裁决为 remoteWins → 不会把云端 20 章回退成 5 章。
      final local = _point('n1', chapterIndex: 5, charOffset: 10);
      final remote = _point('n1', chapterIndex: 20, charOffset: 10);
      expect(decideProgressConflict(local: local, remote: remote),
          ProgressConflictDecision.remoteWins);
    });
  });

  group('P2-8 快照 JSON 编解码', () {
    test('toJson/fromJson round-trip 保留全部字段', () {
      const p = NovelProgressPoint(
        novelId: 'n1',
        chapterIndex: 12,
        charOffset: 3456,
        page: 7,
      );
      final back = NovelProgressPoint.fromJson('n1', p.toJson());
      expect(back.novelId, 'n1');
      expect(back.chapterIndex, 12);
      expect(back.charOffset, 3456);
      expect(back.page, 7);
    });

    test('charOffset 为空时 fromJson 容错', () {
      final back = NovelProgressPoint.fromJson('n1', <String, dynamic>{
        'chapterIndex': 3,
        'page': 5,
      });
      expect(back.charOffset, isNull);
      expect(back.inChapterMetric, 5); // 回退页码
    });
  });
}
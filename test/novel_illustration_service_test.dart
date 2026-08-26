import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/local/local_novel_parser.dart';
import 'package:nexhub/core/models/novel_block.dart';
import 'package:nexhub/core/novel/novel_content_edit_manager.dart';
import 'package:nexhub/features/novel/domain/novel_illustration_service.dart';

void main() {
  group('O4 AI 章节配图：纯函数', () {
    test('buildPrompt 含章名并截断超长正文', () {
      final p1 = NovelIllustrationService.buildPrompt('风起', '夜色渐深');
      expect(p1, contains('风起'));
      expect(p1, contains('夜色渐深'));

      final long = 'x' * 2000;
      final p2 = NovelIllustrationService.buildPrompt('', long);
      expect(p2, contains('未命名章节'));
      expect(p2.length < long.length + 200, isTrue); // 截断到 ~500 字
    });

    test('markerLineFor 生成 N7 编辑管线可解析的占位行', () {
      final line = NovelIllustrationService.markerLineFor('/data/ill/1.png');
      expect(line, startsWith(kNexhubImgMarker));
      final blocks = NovelContentEditManager.parseEditableText(
        '段落一\n\n$line\n\n段落二',
      );
      expect(blocks.length, 3);
      final img = blocks[1] as NovelImageBlock;
      expect(img.url, '/data/ill/1.png');
    });
  });
}

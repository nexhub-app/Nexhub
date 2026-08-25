/// 本地书文件名书名/作者自动解析自测（D8）：
/// 四种命名模式命中、扩展名截断、清洗规则、未命中回退。
import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/local/local_novel_parser.dart';

void main() {
  group('LocalNovelParser.analyzeNameAuthor', () {
    test('模式一：《书名》…作者：xxx', () {
      final r = LocalNovelParser.analyzeNameAuthor('斗破苍穹《异界纵横》作者：天蚕土豆.txt');
      expect(r.name, '异界纵横');
      expect(r.author, '天蚕土豆');
    });

    test('模式二：《书名》后缀（无作者标记）', () {
      final r = LocalNovelParser.analyzeNameAuthor('我的阅读《诡秘之主》(校对版).epub');
      expect(r.name, '诡秘之主');
      expect(r.author, isNull);
    });

    test('模式三：书名 作者：xxx', () {
      final r = LocalNovelParser.analyzeNameAuthor('雪中悍刀行 作者：烽火戏诸侯.txt');
      expect(r.name, '雪中悍刀行');
      expect(r.author, '烽火戏诸侯');
    });

    test('模式四：书名 by author（英文名）', () {
      final r = LocalNovelParser.analyzeNameAuthor('The Long Way by John Doe.txt');
      expect(r.name, 'The Long Way');
      expect(r.author, 'John Doe');
    });

    test('无标记纯文件名：整名为书名、作者为空', () {
      final r = LocalNovelParser.analyzeNameAuthor('斗破苍穹.txt');
      expect(r.name, '斗破苍穹');
      expect(r.author, isNull);
    });

    test('无扩展名文件名不误截', () {
      final r = LocalNovelParser.analyzeNameAuthor('凡人修仙传');
      expect(r.name, '凡人修仙传');
      expect(r.author, isNull);
    });

    test('书名清洗：去除「xx 著」署名尾缀', () {
      // 未命中任何模式时整名清洗出书名，剩余「罗贯中 著」清洗为作者。
      final r = LocalNovelParser.analyzeNameAuthor('三国演义 罗贯中 著.txt');
      expect(r.name, '三国演义');
      expect(r.author, '罗贯中');
    });

    test('《书名》后缀带「XX著」署名时提取作者', () {
      final r = LocalNovelParser.analyzeNameAuthor('文集《聊斋志异》蒲松龄著.txt');
      expect(r.name, '聊斋志异');
      expect(r.author, '蒲松龄');
    });
  });

  group('parseTxt / parseEpub 书名兜底（analyzeNameAuthor 接线）', () {
    test('splitTxtChapters fallbackTitle 与解析书名一致（回归）', () {
      // analyzeNameAuthor 为纯函数，这里只验证其输出可直接作为切分标题。
      final r = LocalNovelParser.analyzeNameAuthor('第一章测试《书名》.txt');
      expect(r.name, '书名');
      final chapters = LocalNovelParser.splitTxtChapters(
        '正文内容，没有章节标题。',
        fallbackTitle: r.name,
      );
      expect(chapters.first.title, '书名');
    });
  });
}

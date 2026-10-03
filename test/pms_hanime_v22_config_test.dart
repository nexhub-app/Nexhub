import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexhub/core/models/plugin_config.dart';

/// pms_hanime.json v22 配置层验收：用引擎真实的 PluginConfig.fromJson 消费
/// 交付物文件，验证评论/网络收藏新增块的全部关键字段按引擎契约落地。
void main() {
  late PluginConfig source;

  setUpAll(() {
    final file = File('plugins/builtin/pms_hanime.json');
    final map = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    source = PluginConfig.fromJson(map);
  });

  group('pms_hanime v25 配置消费', () {
    test('版本号与基础块保持 v21 兼容（v25 = tags 面 7 组 235 值 + tags[] 数组路由）', () {
      expect(source.version, 25);
      expect(source.id, 'pms_hanime');
      expect(source.type, SourceType.animeSource);
      expect(source.routes.containsKey('latest'), isTrue);
      expect(source.routes.containsKey('search'), isTrue);
      expect(source.routes.containsKey('detail'), isTrue);
      expect(source.routes.containsKey('episodes'), isTrue);
      expect(source.routes.containsKey('category'), isTrue);
      expect(source.routes.containsKey('video'), isTrue);
      // v22 列表 id 改提纯数字 code（评论/收藏路由可用），detailUrl 显式补齐
      final searchSel = source.selectors?['search'];
      expect(searchSel, isNotNull);
      expect(searchSel!['id'], "substring-after(//a/@href, 'watch?v=')");
      expect(searchSel['detailUrl'], '//a/@href');
      final categorySel = source.selectors?['category'];
      expect(categorySel!['id'], "substring-after(//a/@href, 'watch?v=')");
    });

    test('comments.login 修键：hanime1_session（真实登录态 cookie）', () {
      final comments = source.comments!;
      expect(comments.login, isNotNull);
      expect(comments.login!.url, 'https://hanime1.me/login');
      expect(comments.login!.checkCookie, 'hanime1_session');
    });

    test('comments.routes：list/replies 路由与 responseType', () {
      final comments = source.comments!;
      // routes 是独立命名空间（comments.routes 而非顶层 routes）
      expect(comments.routes, isNotNull);
      expect(comments.routes.containsKey('list'), isTrue,
          reason: 'list 为必需路由');
      expect(comments.routes.containsKey('replies'), isTrue,
          reason: '回复折叠加载依赖 replies 路由');
      expect(comments.routes['list']!.url,
          contains('/loadComment?type=video&id={id}'));
      expect(comments.routes['replies']!.url, contains('/loadReplies?id={commentId}'));
    });

    test('comments.selectors：embedded 块级 + routeSelectors.replies 覆盖', () {
      final sel = source.comments!.selectors;
      expect(sel, isNotNull);
      expect(sel!['items'], r'$.comments');
      expect(sel['embeddedHtml'], true);
      expect(sel['container'], '#comment-start');
      expect(sel['chunkSize'], 4);
      expect(sel['commentId'],
          "substring-after(//div[starts-with(@id,'reply-section-wrapper')]/@id, 'wrapper-')");
      // routeSelectors 嵌在 selectors 块内（引擎 _selectorsFor 契约）
      final rs = sel['routeSelectors'];
      expect(rs, isA<Map>());
      final replies = (rs as Map)['replies'];
      expect(replies, isA<Map>());
      final rSel = replies as Map;
      expect(rSel['items'], r'$.replies');
      expect(rSel['container'], "div[id^='reply-start']");
      expect(rSel['chunkSize'], 2);
      // commentId:null 清除块级继承（回复楼无 id 语义）
      expect(rSel.containsKey('commentId'), isTrue);
      expect(rSel['commentId'], isNull);
      expect(rSel['likeCount'],
          "//div[@id='comment-like-form-wrapper']/span[2]");
    });

    test('webFavorite：门控/列表/添加三链路字段全部落地', () {
      final wf = source.webFavorite!;
      expect(wf.enabled, isTrue);
      expect(wf.route, 'favorites');
      expect(wf.listEntry, 'favList');
      expect(wf.folders, isTrue);
      expect(wf.requireLogin, isTrue);
      // UI 门控（hasWebFavoriteAdd 只认顶层 addRoute + routes 键）
      expect(wf.addRoute, 'favoritesAdd');
      expect(wf.add, isNotNull);
      expect(wf.add!.route, 'favoritesAdd');
      // 引擎门控断言
      expect(source.hasWebFavoriteAdd, isTrue,
          reason: '顶层 addRoute=favoritesAdd 且 routes 含该键');
      expect(source.hasWebFavoriteBrowse, isTrue,
          reason: 'route=favorites 且 routes 含该键');
    });

    test('收藏相关路由与脚本 override 就位', () {
      expect(source.routes.containsKey('favorites'), isTrue);
      expect(source.routes.containsKey('favoritesAdd'), isTrue);
      expect(source.routes['favorites']!.url, 'https://hanime1.me/');
      final ov = source.parser.overrides ?? const <String, ParserOverride>{};
      expect(ov.containsKey('folders'), isTrue, reason: 'folders=true 时用 overrides.folders');
      expect(ov.containsKey('favList'), isTrue, reason: 'listEntry=favList');
      expect(ov.containsKey('favoritesAdd'), isTrue);
      expect(ov['favList']?.type, 'script');
      expect(ov['folders']?.type, 'script');
      expect(ov['favoritesAdd']?.type, 'script');
      // favoritesAdd 脚本内必须同时含两函数（引擎入口 fallback 契约）
      final script = ov['favoritesAdd']?.script ?? '';
      expect(script, contains('function favoritesAdd('));
      expect(script, contains('function favoritesAddStep2('));
    });

    test('v23 拆源：javchu 不再是 hanime 的镜像', () {
      final raw = File('plugins/builtin/pms_hanime.json').readAsStringSync();
      expect(raw.contains('javchu'), isFalse,
          reason: 'javchu.com 是相似结构的独立网站，已拆为 pms_javchu');
      final hosts = source.network?.hosts ?? const <dynamic>[];
      expect(hosts.where((h) => '${h.host}'.contains('javchu')), isEmpty);
    });

    test('v24 筛选对齐参考库：genre 9 值无新番預告，search 路由带 tags[] 数组占位', () {
      final raw = File('plugins/builtin/pms_hanime.json').readAsStringSync();
      expect(raw.contains('新番預告'), isFalse,
          reason: '参考库 genre.json 无「新番預告」，站点搜索不接受该值');
      expect(source.routes['search']!.url, contains('tags[]={tags}'),
          reason: 'v25 起站点 tags 走 tags[]= 重复参数（数组语义），逗号串会被当成一个不存在的 tag');
      expect(raw.contains('&tags={tags}'), isFalse,
          reason: '旧逗号占位形态必须移除');
      final groups = source.filters?.groups ?? const <FilterGroupConfig>[];
      final genre = groups.firstWhere((g) => g.id == 'genre');
      final values = genre.options.map((o) => o.value).toSet();
      expect(values.length, 9);
      expect(values, containsAll(<String>[
        '裏番', '泡麵番', 'Motion Anime', '3DCG', '2.5D',
        '2D動畫', 'AI生成', 'MMD', 'Cosplay',
      ]));
    });

    test('v25 tags 面：7 组 235 值全 multiSelect，param=tags，value 繁体 label 简体', () {
      final groups = source.filters?.groups ?? const <FilterGroupConfig>[];
      final expected = <String, int>{
        'video_attributes': 9,
        'character_relationships': 9,
        'characteristics': 47,
        'appearance_and_figure': 47,
        'story_location': 24,
        'story_plot': 45,
        'sex_positions': 54,
      };
      final titles = <String, String>{
        'video_attributes': '影片属性',
        'character_relationships': '人物关系',
        'characteristics': '角色设定',
        'appearance_and_figure': '外貌身材',
        'story_location': '情景场所',
        'story_plot': '故事剧情',
        'sex_positions': '性交体位',
      };
      var total = 0;
      expected.forEach((id, count) {
        final g = groups.firstWhere(
          (x) => x.id == id,
          orElse: () => throw StateError('缺 tags 组 $id'),
        );
        expect(g.options.length, count, reason: '$id 选项数对齐参考库 tags.json');
        expect(g.multiSelect, isTrue, reason: '$id 需多选');
        expect(g.param, 'tags', reason: '$id 共用 tags 占位符');
        expect(g.title, titles[id], reason: '$id 标题对齐参考库 zh-rCN strings');
        for (final o in g.options) {
          expect(o.value, isNotEmpty);
          expect(o.label, isNotEmpty);
        }
        // 繁体值→简体名的代表性样例（values 首条：無碼/无码）。
        if (id == 'video_attributes') {
          expect(g.options.first.value, '無碼');
          expect(g.options.first.label, '无码');
        }
        total += g.options.length;
      });
      expect(total, 235, reason: '7 组合计 235 值 = 参考库 tags.json 全量');
      expect(groups.length, 10, reason: 'genre/sort/broad + 7 tags 组');
    });

    test('v24 homeSections：参考库 12 版块参数映射逐一落地', () {
      final sections = source.homeSections;
      expect(sections.length, 12, reason: '参考库 buildCategoryList 12 版块');
      Map<String, Object> paramsOf(String id) {
        final s = sections.firstWhere((x) => x.id == id);
        return s.params;
      }

      expect(sections.every((s) => s.route == 'search'), isTrue,
          reason: '全部走 search 路由（首页整页混合 12 版块，语义不准）');
      expect(paramsOf('latest-hanime')['genre'], '裏番');
      expect(paramsOf('latest-release')['sort'], '最新上市');
      expect(paramsOf('latest-upload')['sort'], '最新上傳');
      expect(paramsOf('watching-now')['sort'], '他們在看');
      expect(paramsOf('instant-noodle')['genre'], '泡麵番');
      expect(paramsOf('instant-noodle')['sort'], '最新上傳');
      expect(paramsOf('motion-anime')['genre'], 'Motion Anime');
      expect(paramsOf('3d-animation')['genre'], '3DCG');
      expect(paramsOf('animation-2-5d')['genre'], '2.5D');
      expect(paramsOf('animation-2d')['genre'], '2D動畫');
      expect(paramsOf('ai-generated')['genre'], 'AI生成');
      expect(paramsOf('ai-generated')['sort'], '最新上傳');
      expect(paramsOf('mmd')['genre'], 'MMD');
      expect(paramsOf('cosplay')['genre'], 'Cosplay');
    });
  });
}
